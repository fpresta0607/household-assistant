// The two assistants' direct line, driven through the plugin's own entry: a handoff one
// assistant writes crosses in the outbox, the other gateway marks it seen as it arrives and
// answers it in a turn of the line's own session, which posts nothing in the family room,
// and both people's phones read every step of it from `household-app.line`.
//
// Run with `node --test tests/js/household_app_pair.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { test } from "node:test";

import { runningChannel, until as untilQuickly } from "./fixtures/household-app-channel.mjs";

// Every wait here is on the inbox, which a busy machine may only scan every two seconds.
const until = (what, condition) => untilQuickly(what, condition, { attempts: 2000 });

const CFG = {
  channels: {
    household: {
      owner: { id: "gia", name: "Gia" },
      assistant: { id: "denise", name: "Denise" },
      peer: { person: { id: "franco", name: "Franco" }, assistant: { id: "corey", name: "Corey" } },
    },
  },
};

const OWNERS_THREAD = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  deliveryContext: { channel: "household", accountId: "default", to: "household:gia" },
  requesterSenderId: "gia",
  sessionKey: "agent:main:household:direct:gia",
};
const PAIR_SESSION = "agent:main:household:group:pair";

function noteTool(channel, context) {
  return channel.tools.find(({ options }) => options.names.includes("household_note")).factory(context);
}

async function run(tool, args) {
  return JSON.parse((await tool.execute("call-1", args)).content[0].text);
}

// Corey's handoff to Denise, as his gateway's outbox carries it.
function handoff({ at = Date.now(), text = "Denise - anything on your side for the vet visit that I'd miss?" } = {}) {
  return {
    id: "ns-00000000-0000-4000-8000-000000000001",
    at,
    author: "corey",
    kind: "add",
    line: { id: "hn-0f0f0f01", topic: "Handoffs", text, owner: "denise", for: "franco" },
  };
}

async function deliverFromCorey(channel, steps) {
  await writeFile(
    path.join(channel.stateDir, "household-app", "inbox", `${Date.now()}-from-corey.json`),
    JSON.stringify({ from: "corey", batch: { entries: [], notes: steps } }),
  );
}

const outboxOf = async (channel) => JSON.parse(await readFile(path.join(channel.stateDir, "household-app", "outbox.json"), "utf8"));

test("a handoff from the other assistant is marked seen at once and answered in the line's own turn, posting nothing in the room", async () => {
  // Arrange: the turn OpenClaw runs answers with one final reply.
  const channel = await runningChannel(CFG, {
    dispatch: async (params) => {
      await params.delivery.deliver({ text: "Nothing of Gia's that the vet needs. The litter's due dates are in the note." }, { kind: "final" });
      return { admission: { kind: "dispatch" } };
    },
  });

  try {
    // Act
    await deliverFromCorey(channel, [handoff()]);
    await until("Denise's answer in the outbox", async () =>
      ((await outboxOf(channel).catch(() => ({ notes: [] }))).notes ?? []).some((step) => step.kind === "reply"));

    // Assert: seen first, then the answer, both Denise's own steps for the relay to carry.
    const { notes, entries } = await outboxOf(channel);
    assert.deepEqual(notes.map((step) => [step.author, step.kind, step.line]), [["denise", "seen", "hn-0f0f0f01"], ["denise", "reply", "hn-0f0f0f01"]]);
    assert.equal(notes[1].text, "Nothing of Gia's that the vet needs. The litter's due dates are in the note.");
    assert.equal(entries.filter((entry) => entry.kind === "message").length, 0, "nothing in the family room");
    // The turn ran in the line's own session, sent by Corey as a bot, told who reads it.
    assert.equal(channel.dispatches.length, 1);
    const [context] = channel.contexts;
    assert.equal(context.route.dispatchSessionKey, PAIR_SESSION);
    assert.deepEqual(context.sender, { id: "corey", name: "Corey", isBot: true });
    assert.equal(context.conversation.id, "pair");
    assert.match(context.supplemental.groupSystemPrompt, /handed you this through your direct line, which Gia and Franco can read in the app/);
    assert.match(context.supplemental.groupSystemPrompt, /Gia's private things, such as money, mail, calendar details and private notes, are not Corey's to hear/);
    assert.equal(context.message.body, "Denise - anything on your side for the vet visit that I'd miss?");
    assert.equal(context.access.commands.authorized, false);
  } finally {
    await channel.stop();
  }
});

test("a handoff from before the bound is marked seen but starts no turn", async () => {
  const channel = await runningChannel(CFG);
  try {
    await deliverFromCorey(channel, [handoff({ at: Date.now() - 10 * 60_000 })]);
    await until("the seen step", async () => ((await outboxOf(channel).catch(() => ({ notes: [] }))).notes ?? []).length === 1);
    assert.equal(channel.dispatches.length, 0);
  } finally {
    await channel.stop();
  }
});

test("a handoff delivered twice is seen and answered once", async () => {
  const channel = await runningChannel(CFG);
  try {
    // The relay carries the whole list again with every delivery.
    await writeFile(path.join(channel.stateDir, "household-app", "inbox", "0001-from-corey.json"), JSON.stringify({ from: "corey", batch: { entries: [], notes: [handoff()] } }));
    await writeFile(path.join(channel.stateDir, "household-app", "inbox", "0002-from-corey.json"), JSON.stringify({ from: "corey", batch: { entries: [], notes: [handoff()] } }));
    await until("both deliveries read", async () => (await readdir(path.join(channel.stateDir, "household-app", "inbox"))).length === 0);
    await until("the seen step", async () => ((await outboxOf(channel).catch(() => ({ notes: [] }))).notes ?? []).length === 1);
    assert.equal(channel.dispatches.length, 1);
    assert.equal((await outboxOf(channel)).notes.length, 1);
  } finally {
    await channel.stop();
  }
});

test("the line's turn starts with the whole household note and has no household tool, so it cannot hand anything back", async () => {
  const channel = await runningChannel(CFG);
  try {
    await run(noteTool(channel, OWNERS_THREAD), { action: "add", topic: "Kitten weights", item: "Mochi", text: "212 g" });
    const turn = await channel.promptBuild({ prompt: "anything on your side?" }, { agentId: "main", sessionKey: PAIR_SESSION });
    assert.match(turn.prependContext, /"Mochi": "212 g"/);
    const handoffTurn = {
      ...OWNERS_THREAD,
      deliveryContext: { ...OWNERS_THREAD.deliveryContext, to: "household:pair" },
      requesterSenderId: "corey",
      sessionKey: PAIR_SESSION,
    };
    assert.equal(noteTool(channel, handoffTurn), null);
  } finally {
    await channel.stop();
  }
});

test("hand writes a line for the other assistant, which crosses in the outbox and shows as not seen until it is", async () => {
  const channel = await runningChannel(CFG);
  try {
    // Act
    const handed = await run(noteTool(channel, OWNERS_THREAD), { action: "hand", text: "Corey, can you add cat litter to Franco's run?" });
    const corey = {
      id: "ns-00000000-0000-4000-8000-000000000009",
      at: Date.now() + 1,
      author: "corey",
      kind: "seen",
      line: handed.lines[0].id,
    };

    // Assert
    assert.equal(handed.topic, "Handoffs");
    assert.deepEqual({ owner: handed.lines[0].owner, seen: handed.lines[0].seen }, { owner: "Corey", seen: null });
    await until("the handoff in the outbox", async () => ((await outboxOf(channel).catch(() => ({ notes: [] }))).notes ?? []).length === 1);
    assert.equal((await outboxOf(channel)).notes[0].line.owner, "corey");
    const before = (await channel.promptBuild({ prompt: "" }, { agentId: "main", ...OWNERS_THREAD })).prependContext;
    assert.match(before, /Corey to do, not seen yet/);
    await deliverFromCorey(channel, [corey]);
    await until("Corey's seen step", async () =>
      /Corey to do, seen /.test((await channel.promptBuild({ prompt: "" }, { agentId: "main", ...OWNERS_THREAD })).prependContext));
  } finally {
    await channel.stop();
  }
});

test("both people's phones read every step of the line, a page at a time, and every page says when it last moved", async () => {
  const channel = await runningChannel(CFG);
  try {
    // Arrange
    await run(noteTool(channel, OWNERS_THREAD), { action: "add", topic: "Kitten weights", rows: [{ item: "Mochi", text: "212 g" }, { item: "Pepper", text: "198 g" }] });
    // A second after the rows, so the handoff cannot share their millisecond and sort between them.
    await deliverFromCorey(channel, [handoff({ at: Date.now() + 1000 })]);
    await until("the handoff seen", async () => ((await channel.call("household-app.line", {})).payload?.events ?? []).length === 4);

    // Act
    const page = (await channel.call("household-app.line", {})).payload;
    const older = (await channel.call("household-app.line", { before: page.events[2].at, limit: 1 })).payload;
    const sync = (await channel.call("household-app.sync", { since: 0 })).payload;

    // Assert
    assert.deepEqual(page.events.map((event) => [event.by, event.kind]), [
      ["denise", "added"],
      ["denise", "added"],
      ["corey", "handed"],
      ["denise", "seen"],
    ]);
    assert.deepEqual(page.events[2].line, { id: "hn-0f0f0f01", topic: "Handoffs", text: "Denise - anything on your side for the vet visit that I'd miss?", owner: "denise" });
    assert.equal(page.more, false);
    assert.deepEqual(older.events.map((event) => event.line.item), ["Pepper"]);
    assert.equal(older.more, true);
    assert.equal(sync.pair.lastAt, page.events.at(-1).at);
  } finally {
    await channel.stop();
  }
});

// "Remind us Saturday at 4:40 about it, every week" had lived only on Corey's side: a turn
// in the room's shared session has no automations, and rightly, since a scheduled run holds
// every tool. A family reminder in the note is posted by its assistant's own gateway.
test("a family reminder Denise takes in the room's shared session is posted by her gateway when it comes due, and moves to its next week", async () => {
  // Arrange: Franco asks Denise in the family room, for a time ten minutes ago, as a
  // gateway that restarted since would find it.
  const sharedRoom = {
    ...OWNERS_THREAD,
    deliveryContext: { ...OWNERS_THREAD.deliveryContext, to: "household:family" },
    requesterSenderId: "franco",
    sessionKey: "agent:main:household:group:family",
  };
  const first = await runningChannel(CFG);
  const ago = new Date(Date.now() - 10 * 60_000);
  const local = (value) => String(value).padStart(2, "0");
  const due = `${ago.getFullYear()}-${local(ago.getMonth() + 1)}-${local(ago.getDate())}`;
  const time = `${local(ago.getHours())}:${local(ago.getMinutes())}`;
  let set;
  try {
    set = await run(noteTool(first, sharedRoom), { action: "remind", text: "Pack the bags for Sunday", due, time, every: "week" });
  } finally {
    await first.stop();
  }

  // Act
  const channel = await runningChannel(CFG, { stateDir: first.stateDir });
  try {
    await until("the reminder in the room", async () =>
      ((await channel.call("household-app.sync", { since: 0 })).payload?.entries ?? []).some((entry) => entry.kind === "message"));

    // Assert
    assert.deepEqual(set.lines.map(({ owner, for: forWho }) => ({ owner, forWho })), [{ owner: "Denise", forWho: "Franco" }]);
    const [posted] = (await channel.call("household-app.sync", { since: 0 })).payload.entries.filter((entry) => entry.kind === "message");
    assert.deepEqual(
      { conversation: posted.conversation, author: posted.author, text: posted.text, handedOver: posted.handedOver },
      { conversation: "family", author: "denise", text: "Reminder: Pack the bags for Sunday", handedOver: true },
    );
    const next = new Date(ago.getFullYear(), ago.getMonth(), ago.getDate() + 7);
    const [line] = (await run(noteTool(channel, OWNERS_THREAD), { action: "view", topic: "Reminders" })).lines;
    assert.equal(line.due, next.toLocaleDateString("en-US", { weekday: "short", day: "numeric", month: "short" }));
  } finally {
    await channel.stop();
  }
});
