// Tapbacks, from deploy/openclaw/plugins/household-app: the assistant's household_react
// tool, which turns it answers in and which messages it may react to, its reaction crossing
// to the other gateway, and the quiet line an assistant is told when a person reacts to one
// of its messages.
//
// Run with `node --test tests/js/household_app_tapbacks.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { createMediaStore } from "../../deploy/openclaw/plugins/household-app/media.js";
import { REACT_TOOL, createReactTool } from "../../deploy/openclaw/plugins/household-app/react-tool.js";
import { createRoom } from "../../deploy/openclaw/plugins/household-app/room.js";
import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";
import { TAPBACKS, reactionNote } from "../../deploy/openclaw/plugins/household-app/tapbacks.js";
import { stubChannelSdk } from "./fixtures/openclaw-channel-sdk.mjs";

const PLUGIN = new URL("../../deploy/openclaw/plugins/household-app/", import.meta.url);
const NOW = Date.UTC(2026, 9, 15, 23, 0);
const HEART = "❤️";
const LAUGH = "😂";
const SESSION_KEYS = { family: "agent:main:household:group:family", direct: "agent:main:household:direct:franco" };

// The turns household_react answers in on Corey's gateway, as OpenClaw hands them to tools.
const DIRECT = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  deliveryContext: { channel: "household", accountId: "default", to: "household:franco" },
  requesterSenderId: "franco",
  sessionKey: SESSION_KEYS.direct,
};
const FAMILY = {
  ...DIRECT,
  deliveryContext: { ...DIRECT.deliveryContext, to: "household:family" },
  requesterSenderId: "gia",
  sessionKey: SESSION_KEYS.family,
};

function phone() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    key: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url"),
    sign: (message) => sign(null, Buffer.from(signedText(message), "utf8"), privateKey).toString("base64url"),
  };
}

const FRANCO = phone();
const GIA = phone();

// One gateway's room: Corey's, whose owner is Franco, or Denise's, whose owner is Gia.
async function gateway(persona, { enqueue } = {}) {
  const isCorey = persona === "corey";
  const directory = await mkdtemp(path.join(tmpdir(), `household-app-tapbacks-${persona}-`));
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const seen = { outboxes: [], dispatched: [], notes: [], warnings: [] };
  const franco = { id: "franco", name: "Franco", keys: [FRANCO.key] };
  const gia = { id: "gia", name: "Gia", keys: [GIA.key] };
  const room = createRoom({
    identity: isCorey
      ? { owner: franco, assistant: { id: "corey", name: "Corey" }, peer: { person: gia, assistant: { id: "denise", name: "Denise" } } }
      : { owner: gia, assistant: { id: "denise", name: "Denise" }, peer: { person: franco, assistant: { id: "corey", name: "Corey" } } },
    sessionKeys: isCorey
      ? SESSION_KEYS
      : { family: SESSION_KEYS.family, direct: "agent:main:household:direct:gia" },
    store,
    media: createMediaStore(directory),
    now: () => NOW,
    emit: () => {},
    writeOutbox: (outbox) => seen.outboxes.push(outbox),
    push: { notify: async () => [] },
    dispatch: async (turn) => seen.dispatched.push(turn),
    isAddressed: async () => false,
    enqueue: enqueue ?? (async (injection) => {
      seen.notes.push(injection);
      return { enqueued: true, id: `note-${seen.notes.length}`, sessionKey: injection.sessionKey };
    }),
    log: { warn: (line) => seen.warnings.push(line), info() {} },
  });
  return { room, store, seen, directory, close: () => store.close() };
}

function said(id, text, overrides = {}) {
  return { conversation: "family", id, at: NOW - 1000, replyTo: null, media: [], text, ...overrides };
}

const signedBy = (person, message) => ({ ...message, signature: person.sign(message) });

// What each gateway's own person and assistant said in the family room, carried to the
// other one as it reads the share: the newest outbox's entries.
async function relay(from, to) {
  return to.room.acceptPeer(from.seen.outboxes.at(-1));
}

function toolFor(context, corey) {
  return createReactTool({ context, owner: "franco", people: ["franco", "gia"], room: corey.room });
}

async function run(found, args) {
  const result = await found.execute("call-1", args, undefined);
  return { ...JSON.parse(result.content[0].text), isError: result.isError === true };
}

// Corey's gateway with Franco's own message and Corey's reply in their thread, Gia's message
// in the family room, and Corey's and Denise's there too.
async function coreysRoom() {
  const corey = await gateway("corey");
  await corey.room.send(signedBy(FRANCO, said("d-00000001", "We got the house!", { conversation: "direct" })));
  const reply = await corey.room.reply({ conversation: "direct", text: "That is wonderful news, congratulations to you both." });
  await corey.room.acceptPeer({
    entries: [
      { kind: "message", author: "gia", ...signedBy(GIA, said("m-00000001", "Dinner is on me tonight")) },
      { kind: "message", author: "denise", ...said("a-00000001", "I booked the table for 7.") },
    ],
  });
  const own = await corey.room.reply({ conversation: "family", text: "I put dinner on the family calendar." });
  return { corey, reply, own };
}

// MARK: - The five

test("the tapbacks are the five the app offers, each as the emoji keyboard sends it", () => {
  assert.deepEqual(TAPBACKS, ["❤️", "👍", "😂", "‼️", "❓"]);
  assert.deepEqual(TAPBACKS.map((emoji) => [...emoji].length), [2, 1, 1, 2, 1]);
});

// MARK: - The turns it answers in

test("the tool is offered in the owner's own thread and in the family room", async () => {
  const { corey } = await coreysRoom();
  try {
    for (const context of [DIRECT, FAMILY, { ...FAMILY, requesterSenderId: "franco" }]) {
      const found = toolFor(context, corey);
      assert.equal(found.name, REACT_TOOL);
      assert.equal(REACT_TOOL, "household_react");
      assert.equal(found.parameters.additionalProperties, false);
      assert.deepEqual(found.parameters.properties.emoji.enum, TAPBACKS);
      assert.match(found.description, /sparingly/);
      assert.match(found.description, /never instead of answering/);
    }
  } finally {
    corey.close();
  }
});

for (const [why, context] of [
  ["Telegram", { ...DIRECT, messageChannel: "telegram", deliveryContext: { ...DIRECT.deliveryContext, channel: "telegram" } }],
  ["an automation with no sender", { ...DIRECT, requesterSenderId: undefined }],
  ["a gateway client speaking as itself", { ...DIRECT, requesterSenderId: "openclaw-ios", deliveryContext: { ...DIRECT.deliveryContext, to: "household:openclaw-ios" } }],
  ["the other person in the owner's thread", { ...DIRECT, requesterSenderId: "gia" }],
  ["a stranger in the family room", { ...FAMILY, requesterSenderId: "mallory" }],
  ["a turn the other assistant's @mention started", { ...FAMILY, requesterSenderId: "denise" }],
  ["another agent", { ...DIRECT, agentId: "helper" }],
]) {
  test(`the tool is not offered to ${why}`, async () => {
    const corey = await gateway("corey");
    try {
      assert.equal(toolFor(context, corey), null);
    } finally {
      corey.close();
    }
  });
}

// MARK: - What it reacts to

for (const emoji of TAPBACKS) {
  test(`the assistant reacts ${emoji} to the owner's message in their own thread`, async () => {
    const { corey } = await coreysRoom();
    try {
      const answer = await run(toolFor(DIRECT, corey), { messageId: "d-00000001", emoji });
      assert.deepEqual(answer, { reacted: emoji, messageId: "d-00000001", isError: false });
      assert.deepEqual(corey.store.reactions("d-00000001"), [{ author: "corey", emoji }]);
      assert.equal(corey.seen.dispatched.length, 1, "only Franco's own message started a turn");
    } finally {
      corey.close();
    }
  });
}

test("in the family room it reacts to either person's message, and a second tapback replaces its first", async () => {
  const { corey } = await coreysRoom();
  try {
    await corey.room.send(signedBy(FRANCO, said("m-00000002", "Corey, which night works?")));
    const found = toolFor(FAMILY, corey);
    await run(found, { messageId: "m-00000001", emoji: HEART });
    await run(found, { messageId: "m-00000002", emoji: "👍" });
    await run(found, { messageId: "m-00000001", emoji: LAUGH });
    assert.deepEqual(corey.store.reactions("m-00000001"), [{ author: "corey", emoji: LAUGH }]);
    assert.deepEqual(corey.store.reactions("m-00000002"), [{ author: "corey", emoji: "👍" }]);
  } finally {
    corey.close();
  }
});

for (const [why, turn, args, code] of [
  ["an emoji that is not one of the five", DIRECT, { messageId: "d-00000001", emoji: "👎" }, "not_a_tapback"],
  ["an emoji the picker used to offer", DIRECT, { messageId: "d-00000001", emoji: "🦉" }, "not_a_tapback"],
  ["a tapback's name instead of its emoji", DIRECT, { messageId: "d-00000001", emoji: "heart" }, "not_a_tapback"],
  ["taking a tapback back", DIRECT, { messageId: "d-00000001", emoji: null }, "not_a_tapback"],
  ["a field the tool does not have", DIRECT, { messageId: "d-00000001", emoji: HEART, author: "franco" }, "invalid_arguments"],
  ["no message id", DIRECT, { emoji: HEART }, "not_reactable"],
  ["a message this gateway does not have", DIRECT, { messageId: "d-00000404", emoji: HEART }, "not_reactable"],
  ["a family-room message from the owner's own thread", DIRECT, { messageId: "m-00000001", emoji: HEART }, "not_reactable"],
  ["the owner's own thread from the family room", FAMILY, { messageId: "d-00000001", emoji: HEART }, "not_reactable"],
  ["its own message", FAMILY, { messageId: "own", emoji: HEART }, "not_reactable"],
  ["its own reply in the owner's thread", DIRECT, { messageId: "reply", emoji: HEART }, "not_reactable"],
  ["the other assistant's message", FAMILY, { messageId: "a-00000001", emoji: HEART }, "not_reactable"],
]) {
  test(`the tool refuses ${why} and keeps nothing`, async () => {
    const { corey, reply, own } = await coreysRoom();
    try {
      const messageId = { own: own.id, reply: reply.id }[args.messageId] ?? args.messageId;
      const answer = await run(toolFor(turn, corey), { ...args, ...(args.messageId ? { messageId } : {}) });
      assert.equal(answer.isError, true);
      assert.equal(answer.code, code);
      for (const id of ["d-00000001", "m-00000001", "a-00000001", own.id, reply.id]) {
        assert.deepEqual(corey.store.reactions(id), [], id);
      }
      assert.equal(corey.seen.outboxes.at(-1).entries.some((entry) => entry.kind === "reaction"), false);
    } finally {
      corey.close();
    }
  });
}

// MARK: - Across the relay

test("the assistant's tapback in the family room crosses to the other gateway, and its phones see it", async () => {
  const corey = await gateway("corey");
  const denise = await gateway("denise");
  try {
    await denise.room.send(signedBy(GIA, said("m-00000001", "Dinner is on me tonight")));
    await relay(denise, corey);
    await run(toolFor(FAMILY, corey), { messageId: "m-00000001", emoji: HEART });

    const carried = corey.seen.outboxes.at(-1).entries.filter((entry) => entry.kind === "reaction");
    assert.deepEqual(carried.map(({ author, messageId, emoji }) => ({ author, messageId, emoji })), [
      { author: "corey", messageId: "m-00000001", emoji: HEART },
    ]);
    assert.deepEqual(await relay(corey, denise), { accepted: 1, refused: 0 });
    assert.deepEqual(denise.store.reactions("m-00000001"), [{ author: "corey", emoji: HEART }]);
    assert.deepEqual(denise.room.history({ conversation: "family" }).reactions["m-00000001"], [{ author: "corey", emoji: HEART }]);
    assert.deepEqual(denise.seen.notes, [], "Denise is not told of Corey's tapback");
  } finally {
    corey.close();
    denise.close();
  }
});

test("a family tapback and written reply reach the peer and survive storage reopening", async () => {
  const corey = await gateway("corey");
  const denise = await gateway("denise");
  const answerText = "I will bring dessert.";
  let isStoreClosed = false;
  try {
    await denise.room.send(signedBy(GIA, said("m-react-and-reply", "Dinner is on me tonight")));
    assert.deepEqual(await relay(denise, corey), { accepted: 1, refused: 0 });

    assert.deepEqual(await run(toolFor(FAMILY, corey), { messageId: "m-react-and-reply", emoji: HEART }), {
      reacted: HEART, messageId: "m-react-and-reply", isError: false,
    });
    const reply = await corey.room.reply({ conversation: "family", text: answerText, runId: "run-react-and-reply" });
    const changes = corey.room.sync({ since: 0 }).entries;
    assert.ok(changes.some((entry) => entry.kind === "reaction" && entry.messageId === "m-react-and-reply" && entry.emoji === HEART));
    assert.ok(changes.some((entry) => entry.kind === "message" && entry.id === reply.id && entry.text === answerText));

    assert.deepEqual(await relay(corey, denise), { accepted: 2, refused: 0 });
    const peerHistory = denise.room.history({ conversation: "family" });
    assert.deepEqual(peerHistory.reactions["m-react-and-reply"], [{ author: "corey", emoji: HEART }]);
    assert.equal(peerHistory.messages.find((message) => message.id === reply.id)?.text, answerText);

    corey.close();
    denise.close();
    isStoreClosed = true;
    for (const gatewayData of [corey, denise]) {
      const reopened = openRoomStore(path.join(gatewayData.directory, "room.sqlite"));
      try {
        assert.deepEqual(reopened.reactions("m-react-and-reply"), [{ author: "corey", emoji: HEART }]);
        assert.equal(reopened.message(reply.id)?.text, answerText);
      } finally {
        reopened.close();
      }
    }
  } finally {
    if (!isStoreClosed) {
      corey.close();
      denise.close();
    }
  }
});

test("a direct tapback and written reply survive sync and storage reopening", async () => {
  const corey = await gateway("corey");
  const answerText = "I will handle that.";
  let isStoreClosed = false;
  try {
    await corey.room.send(signedBy(FRANCO, said("d-react-and-reply", "Please handle that", { conversation: "direct" })));
    assert.deepEqual(await run(toolFor(DIRECT, corey), { messageId: "d-react-and-reply", emoji: HEART }), {
      reacted: HEART, messageId: "d-react-and-reply", isError: false,
    });
    const reply = await corey.room.reply({ conversation: "direct", text: answerText, runId: "run-direct-reply" });
    const changes = corey.room.sync({ since: 0 }).entries;
    assert.ok(changes.some((entry) => entry.kind === "reaction" && entry.messageId === "d-react-and-reply" && entry.emoji === HEART));
    assert.ok(changes.some((entry) => entry.kind === "message" && entry.id === reply.id && entry.text === answerText));
    assert.deepEqual(corey.room.history({ conversation: "direct" }).reactions["d-react-and-reply"], [{ author: "corey", emoji: HEART }]);
    assert.equal(corey.seen.outboxes.length, 0);

    corey.close();
    isStoreClosed = true;
    const reopened = openRoomStore(path.join(corey.directory, "room.sqlite"));
    try {
      assert.deepEqual(reopened.reactions("d-react-and-reply"), [{ author: "corey", emoji: HEART }]);
      assert.equal(reopened.message(reply.id)?.text, answerText);
    } finally {
      reopened.close();
    }
  } finally {
    if (!isStoreClosed) corey.close();
  }
});

test("the assistant's tapback in the owner's own thread never leaves this gateway", async () => {
  const { corey } = await coreysRoom();
  try {
    const before = corey.seen.outboxes.length;
    await run(toolFor(DIRECT, corey), { messageId: "d-00000001", emoji: HEART });
    assert.equal(corey.seen.outboxes.length, before);
  } finally {
    corey.close();
  }
});

for (const [why, entry] of [
  ["an emoji that is not a tapback", { messageId: "m-00000001", emoji: "🦉" }],
  ["a reaction to an assistant's message", { messageId: "a-00000001", emoji: HEART }],
]) {
  test(`the other gateway's assistant is refused ${why}`, async () => {
    const { corey } = await coreysRoom();
    try {
      const result = await corey.room.acceptPeer({ entries: [{ kind: "reaction", author: "denise", at: NOW, ...entry }] });
      assert.deepEqual(result, { accepted: 0, refused: 1 });
      assert.deepEqual(corey.store.reactions(entry.messageId), []);
    } finally {
      corey.close();
    }
  });
}

test("the other gateway's assistant may take its tapback back", async () => {
  const { corey } = await coreysRoom();
  try {
    await corey.room.acceptPeer({ entries: [{ kind: "reaction", author: "denise", messageId: "m-00000001", emoji: HEART, at: NOW }] });
    await corey.room.acceptPeer({ entries: [{ kind: "reaction", author: "denise", messageId: "m-00000001", emoji: null, at: NOW + 1 }] });
    assert.deepEqual(corey.store.reactions("m-00000001"), []);
  } finally {
    corey.close();
  }
});

// MARK: - What the assistant is told

test("the owner's tapback on the assistant's reply waits for its next turn there, and starts none", async () => {
  const { corey, reply } = await coreysRoom();
  try {
    const turns = corey.seen.dispatched.length;
    await corey.room.react({ messageId: reply.id, emoji: HEART });
    assert.deepEqual(corey.seen.notes, [{
      sessionKey: SESSION_KEYS.direct,
      text: 'Franco reacted ❤️ to your message: "That is wonderful news, congratulations to you both."\n' +
        "It is a reaction in the app, not a message, so it needs no answer.",
      ttlMs: 86_400_000,
    }]);
    assert.equal(corey.seen.dispatched.length, turns, "a reaction starts no turn");
  } finally {
    corey.close();
  }
});

test("a changed tapback and one taken back are told too, and one kept again unchanged is not", async () => {
  const { corey, reply } = await coreysRoom();
  try {
    await corey.room.react({ messageId: reply.id, emoji: HEART });
    await corey.room.react({ messageId: reply.id, emoji: HEART });
    await corey.room.react({ messageId: reply.id, emoji: LAUGH });
    await corey.room.react({ messageId: reply.id, emoji: null });
    await corey.room.react({ messageId: reply.id, emoji: null });
    const quote = '"That is wonderful news, congratulations to you both."';
    assert.deepEqual(corey.seen.notes.map((note) => note.text.split("\n")[0]), [
      `Franco reacted ❤️ to your message: ${quote}`,
      `Franco reacted 😂 to your message: ${quote}`,
      `Franco took back their 😂 on your message: ${quote}`,
    ]);
  } finally {
    corey.close();
  }
});

test("the other person's tapback on the assistant's family message is told in the family room", async () => {
  const { corey, own } = await coreysRoom();
  try {
    await corey.room.acceptPeer({ entries: [{ kind: "reaction", author: "gia", messageId: own.id, emoji: "‼️", at: NOW }] });
    assert.deepEqual(corey.seen.notes.map(({ sessionKey, text }) => [sessionKey, text.split("\n")[0]]), [
      [SESSION_KEYS.family, 'Gia reacted ‼️ to your message: "I put dinner on the family calendar."'],
    ]);
  } finally {
    corey.close();
  }
});

test("a tapback on anyone else's message tells this assistant nothing", async () => {
  const { corey } = await coreysRoom();
  try {
    await corey.room.react({ messageId: "a-00000001", emoji: HEART });
    await corey.room.react({ messageId: "m-00000001", emoji: HEART });
    await corey.room.acceptPeer({ entries: [{ kind: "reaction", author: "gia", messageId: "d-00000001", emoji: HEART, at: NOW }] });
    await run(toolFor(FAMILY, corey), { messageId: "m-00000001", emoji: LAUGH });
    assert.deepEqual(corey.seen.notes, []);
  } finally {
    corey.close();
  }
});

test("a line OpenClaw could not keep is a warning, and the tapback stands", async () => {
  const corey = await gateway("corey", { enqueue: async () => { throw new Error("session store busy"); } });
  try {
    const reply = await corey.room.reply({ conversation: "direct", text: "Done." });
    const entry = await corey.room.react({ messageId: reply.id, emoji: HEART });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(entry.emoji, HEART);
    assert.deepEqual(corey.store.reactions(reply.id), [{ author: "franco", emoji: HEART }]);
    assert.deepEqual(corey.seen.warnings, ["household-app: a reaction was not kept for the assistant's next turn: session store busy"]);
  } finally {
    corey.close();
  }
});

for (const [why, message, said] of [
  ["a long message is quoted to a word near its start", { text: "I booked the table at Lucia's for seven, and asked for the quiet room at the back.", media: [] },
    'Gia reacted ❤️ to your message: "I booked the table at Lucia\'s for seven, and asked for the…"'],
  ["a card's block is left out of the quote", { text: "Here is the list:\n```steward-card\n{\"type\":\"checklist\"}\n```\nAnything else?", media: [] },
    'Gia reacted ❤️ to your message: "Here is the list: Anything else?"'],
  ["a photo with no words is named for what it is", { text: "", media: [{ kind: "photo" }] }, "Gia reacted ❤️ to your photo"],
  ["a card with no words around it is a message", { text: "```steward-card\n{}\n```", media: [] }, "Gia reacted ❤️ to your message"],
]) {
  test(`the line says what was reacted to: ${why}`, () => {
    assert.equal(reactionNote({ name: "Gia", emoji: HEART, previous: null, message }).split("\n")[0], said);
  });
}

// MARK: - Through the plugin

test("the plugin registers the tool as optional and declares it, and offers it only while its channel runs", async () => {
  const manifest = JSON.parse(readFileSync(new URL("openclaw.plugin.json", PLUGIN), "utf8"));
  assert.ok(manifest.contracts.tools.includes(REACT_TOOL));
  assert.deepEqual(manifest.toolMetadata[REACT_TOOL], { optional: true, replaySafe: true, sideEffecting: true });

  stubChannelSdk(fileURLToPath(new URL("index.js", PLUGIN)));
  const { default: entry } = await import(new URL("index.js", PLUGIN));
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-tapbacks-plugin-"));
  const tools = [];
  entry.setRuntime({
    config: { current: () => ({}) },
    state: { resolveStateDir: () => directory },
    events: { onSessionTranscriptUpdate: () => () => {} },
  });
  const api = new Proxy(
    { registerTool: (factory, options) => tools.push({ factory, options }), session: { workflow: {} }, logger: {} },
    { get: (target, key) => (key in target ? target[key] : () => {}) },
  );
  try {
    entry.registerFull(api);
    const react = tools.find((one) => one.options.names?.includes(REACT_TOOL));
    assert.deepEqual(react.options, { names: [REACT_TOOL], optional: true });
    assert.equal(react.factory(DIRECT), null);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
