// The document and deadline vault, from deploy/openclaw/plugins/household-app/vault.js and
// vault-tool.js: a document photographed once in the owner's own thread is kept with its day,
// the day goes into the household note unless the owner keeps it to themselves, the owner is
// told thirty days out and not on the day, and the picture never leaves the owner's side.
// Every document here is made up.
//
// Run with `node --test tests/js/household_app_vault.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { createVault } from "../../deploy/openclaw/plugins/household-app/vault.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const DAY_MS = 86_400_000;
// Thursday 22 October 2026, noon in Chicago.
const NOW = Date.UTC(2026, 9, 22, 17, 0);
const PICTURE = "a".repeat(64);
const ROOT = mkdtempSync(path.join(os.tmpdir(), "household-vault-"));
const opened = [];
after(() => {
  for (const each of opened) each.close();
  rmSync(ROOT, { recursive: true, force: true });
});

function vaultAt(moment) {
  let clock = moment;
  let counter = 0;
  const vault = createVault({
    file: path.join(mkdtempSync(path.join(ROOT, "gateway-")), "vault.sqlite"),
    now: () => clock,
    newId: () => String(++counter).padStart(8, "0"),
    timeZone: "America/Chicago",
  });
  opened.push(vault);
  return { vault, at: (next) => {
    clock = next;
  } };
}

const passport = (date) => ({ what: "passport", kind: "passport", date, dateKind: "expires", pictures: [PICTURE] });

test("a document is told thirty days before its day, once, and not on the day", () => {
  // Arrange: a made-up passport that expires on 21 December 2026, 60 days on.
  const { vault, at } = vaultAt(NOW);
  const kept = vault.keep(passport("2026-12-21"));

  // Act
  at(NOW + 29 * DAY_MS);
  const dayEarly = vault.due();
  at(NOW + 30 * DAY_MS);
  const due = vault.due();
  const again = vault.due();
  at(NOW + 60 * DAY_MS);
  const onTheDay = vault.due();

  // Assert
  assert.equal(kept.tell, undefined, "sixty days out is no news for the reply");
  assert.equal(kept.pictures, 1);
  assert.doesNotMatch(JSON.stringify(kept), new RegExp(PICTURE), "a turn never sees a picture's id");
  assert.deepEqual(dayEarly, []);
  assert.deepEqual(due, ["Your passport expires in 30 days, Mon, Dec 21, 2026. It is in your vault in Steward."]);
  assert.deepEqual(again, [], "once for that day");
  assert.deepEqual(onTheDay, [], "nothing on the day itself");
});

test("a document kept with less than thirty days left is said in that turn's reply, not again", () => {
  const { vault } = vaultAt(NOW);
  const kept = vault.keep({ what: "car registration", kind: "registration", date: "2026-11-03", dateKind: "renews", pictures: [PICTURE] });
  assert.equal(kept.tell, "It renews in 12 days, Tue, Nov 3, 2026: say so in your reply.");
  assert.deepEqual(vault.due(), []);
});

test("a document past its day is said in the reply as expired", () => {
  const { vault } = vaultAt(NOW);
  assert.match(vault.keep(passport("2026-10-01")).tell, /^It expired Thu, Oct 1, 2026/);
});

test("a renewed document's new day is told thirty days before it, again", () => {
  // Arrange: told about this year's day already.
  const { vault, at } = vaultAt(NOW);
  const { document } = vault.keep(passport("2026-11-15"));
  at(NOW + 2 * DAY_MS);

  // Act: renewed for ten years.
  const updated = vault.update(document, { date: "2036-11-15" });
  at(Date.UTC(2036, 9, 16, 17, 0));
  const due = vault.due();

  // Assert
  assert.equal(updated.expires, "2036-11-15");
  assert.equal(due.length, 1);
  assert.match(due[0], /^Your passport expires in 30 days, Sat, Nov 15, 2036\./);
});

for (const [why, fields] of [
  ["a day that does not exist", { date: "2027-02-30" }],
  ["no picture", { pictures: [] }],
  ["a picture that is no media id", { pictures: ["../../etc/passwd"] }],
  ["a kind it does not know", { kind: "diploma" }],
  ["no words for what it is", { what: "  " }],
]) {
  test(`a document with ${why} is refused`, () => {
    const { vault } = vaultAt(NOW);
    assert.throws(() => vault.keep({ ...passport("2027-03-01"), ...fields }), (error) => ["invalid_document", "no_picture"].includes(error.code));
    assert.deepEqual(vault.view(), { documents: [] });
  });
}

// Through the plugin, on Corey's gateway: Franco photographs a made-up passport in his own
// thread, and the vault keeps it there.

const keyPair = () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { privateKey, raw: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url") };
};
const FRANCO = keyPair();
const GIA = keyPair();
const signedBy = (person, message) => ({
  ...message,
  signature: sign(null, Buffer.from(signedText(message), "utf8"), person.privateKey).toString("base64url"),
});
const COREY = {
  agents: { entries: { main: { identity: { name: "Corey" } } } },
  channels: {
    household: {
      owner: { id: "franco", name: "Franco", deviceKeys: [FRANCO.raw] },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia", deviceKeys: [GIA.raw] }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};
const turnIn = (sessionKey, to, sender = "franco") => ({
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  deliveryContext: { channel: "household", accountId: "default", to },
  requesterSenderId: sender,
  sessionKey,
});
const FRANCOS_THREAD = turnIn("agent:main:household:direct:franco", "household:franco");
const FRANCOS_ROOM = turnIn("agent:main:household:group:family:sender:franco", "household:family");
const SHARED_ROOM = turnIn("agent:main:household:group:family", "household:family", "gia");
// A made-up passport photo's bytes, with a made-up number on it.
const PASSPORT_NUMBER = "X00000000";

async function photo(stateDir, label) {
  const bytes = Buffer.from(`made-up photo: ${label}`);
  const id = createHash("sha256").update(bytes).digest("hex");
  const folder = path.join(stateDir, "household-app", "media");
  await mkdir(folder, { recursive: true });
  await writeFile(path.join(folder, id), bytes);
  return { id, kind: "photo", mime: "image/jpeg", bytes: bytes.length, width: 1200, height: 800 };
}

const run = async (tool, args) => JSON.parse((await tool.execute("call-1", args)).content[0].text);
const vaultTool = (channel, context) => channel.tools.find(({ options }) => options.names.includes("household_vault")).factory(context);
const dayFromNow = (days) => {
  const date = new Date();
  date.setDate(date.getDate() + days);
  return date.toLocaleDateString("en-CA");
};

test("through the plugin, a passport photographed in the owner's thread is kept there, its day in the note, its picture nowhere else", async () => {
  // Arrange
  const channel = await runningChannel(COREY);
  const outbox = path.join(channel.stateDir, "household-app", "share", "outbox.json");
  try {
    const picture = await photo(channel.stateDir, `passport ${PASSPORT_NUMBER}`);
    const message = { conversation: "direct", id: "v-00000001", at: Date.now(), replyTo: null, text: "My passport, keep an eye on it", media: [picture] };
    await channel.send(signedBy(FRANCO, message));
    await until("the turn", () => channel.contexts.length === 1);
    const tool = vaultTool(channel, FRANCOS_THREAD);
    const expires = dayFromNow(200);

    // Act
    const kept = await run(tool, { action: "keep", messageId: channel.contexts[0].messageId, what: "passport", kind: "passport", date: expires });
    await until("the note line in the outbox", async () => (await readFile(outbox, "utf8").catch(() => "")).includes("Renewals"), { attempts: 2000 });
    const crossing = await readFile(outbox, "utf8");
    const line = JSON.stringify((await channel.call("household-app.line", {})).payload);
    const turn = JSON.stringify(await channel.promptBuild({ prompt: "What is coming up?" }, SHARED_ROOM));

    // Assert
    assert.equal(kept.expires, expires);
    assert.equal(kept.isShared, true);
    assert.match(crossing, /Franco's passport expires/, "the day crosses in the note");
    assert.doesNotMatch(crossing, new RegExp(picture.id), "the picture never crosses");
    assert.doesNotMatch(crossing, new RegExp(PASSPORT_NUMBER));
    assert.match(line, /Franco's passport expires/, "both phones see the note's line");
    assert.match(turn, /Renewals/, "the other side's turns see the day");
    assert.doesNotMatch(JSON.stringify([channel.logs, channel.pluginLogs]), /passport/i, "no log line names a document");
    assert.equal(vaultTool(channel, FRANCOS_ROOM), null, "never from the family room, even the owner's own session");
    assert.equal(vaultTool(channel, SHARED_ROOM), null);
  } finally {
    await channel.stop();
  }
});

test("through the plugin, a document the owner keeps to themselves has no note line", async () => {
  const channel = await runningChannel(COREY);
  try {
    const picture = await photo(channel.stateDir, "car insurance card");
    const message = { conversation: "direct", id: "v-00000002", at: Date.now(), replyTo: null, text: "Insurance card, just for me", media: [picture] };
    await channel.send(signedBy(FRANCO, message));
    await until("the turn", () => channel.contexts.length === 1);
    const tool = vaultTool(channel, FRANCOS_THREAD);
    const kept = await run(tool, { action: "keep", messageId: "v-00000002", what: "car insurance", kind: "insurance", date: dayFromNow(100), dateKind: "renews", isPrivate: true });
    assert.equal(kept.isShared, false);
    assert.doesNotMatch(JSON.stringify((await channel.call("household-app.line", {})).payload), /insurance/);
    assert.deepEqual((await run(tool, { action: "view" })).documents.map((each) => each.what), ["car insurance"]);
  } finally {
    await channel.stop();
  }
});

test("through the plugin, a family-room photo or a message with no picture is never kept", async () => {
  const channel = await runningChannel(COREY);
  try {
    const picture = await photo(channel.stateDir, "warranty card");
    await channel.send(signedBy(FRANCO, { conversation: "family", id: "v-00000003", at: Date.now(), replyTo: null, text: "@Corey our warranty", media: [picture] }));
    await channel.send(signedBy(FRANCO, { conversation: "direct", id: "v-00000004", at: Date.now(), replyTo: null, text: "Keep my license", media: [] }));
    await until("both turns", () => channel.contexts.length === 2);
    const tool = vaultTool(channel, FRANCOS_THREAD);
    for (const messageId of ["v-00000003", "v-00000004", "v-unknown-1"]) {
      const answer = await run(tool, { action: "keep", messageId, what: "warranty", kind: "warranty", date: dayFromNow(300) });
      assert.equal(answer.code, "no_picture", messageId);
    }
    assert.deepEqual(await run(tool, { action: "view" }), { documents: [] });
  } finally {
    await channel.stop();
  }
});

test("through the plugin, a document thirty days out is posted in the owner's own thread as the channel starts, once, across fall DST", async (context) => {
  const previousTimeZone = process.env.TZ;
  process.env.TZ = "America/Chicago";
  context.after(() => {
    if (previousTimeZone === undefined) delete process.env.TZ;
    else process.env.TZ = previousTimeZone;
  });
  context.mock.timers.enable({ apis: ["Date"], now: new Date("2026-10-24T00:30:00-05:00") });

  // Arrange: the vault an earlier run left two days ago, with a made-up license that renews in
  // 30 days now.
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "household-app-channel-"));
  const earlier = createVault({ file: path.join(stateDir, "household-app", "vault.sqlite"), now: () => Date.now() - 2 * DAY_MS });
  earlier.keep({ what: "driver's license", kind: "license", date: dayFromNow(30), dateKind: "renews", pictures: [PICTURE] });
  earlier.close();

  // Act
  const thread = async (channel) => (await channel.call("household-app.history", { conversation: "direct" })).payload.messages;
  const notices = (messages) => messages.filter((each) => each.text.startsWith("Your driver's license renews in 30 days"));
  const first = await runningChannel(COREY, { stateDir });
  let posted;
  try {
    await until("the notice", async () => notices(await thread(first)).length > 0, { attempts: 2000 });
    posted = notices(await thread(first));
  } finally {
    await first.stop();
  }
  const second = await runningChannel(COREY, { stateDir });
  let again;
  try {
    again = notices(await thread(second));
  } finally {
    await second.stop();
  }

  // Assert
  assert.equal(posted.length, 1);
  assert.equal(posted[0].text, "Your driver's license renews in 30 days, Mon, Nov 23, 2026. It is in your vault in Steward.");
  assert.equal(posted[0].author, "corey");
  assert.equal(again.length, 1, "a restart posts it no second time");
  assert.deepEqual((await (async () => {
    const family = await runningChannel(COREY, { stateDir });
    try {
      return (await family.call("household-app.history", { conversation: "family" })).payload.messages.filter((each) => /license/.test(each.text));
    } finally {
      await family.stop();
    }
  })()), [], "nothing of it in the family room");
});

test("through the plugin, a renewed document corrects its note line, and a removed one takes it out", async () => {
  // Arrange
  const channel = await runningChannel(COREY);
  try {
    const picture = await photo(channel.stateDir, "warranty for a made-up dishwasher");
    await channel.send(signedBy(FRANCO, { conversation: "direct", id: "v-00000005", at: Date.now(), replyTo: null, text: "Dishwasher warranty", media: [picture] }));
    await until("the turn", () => channel.contexts.length === 1);
    const tool = vaultTool(channel, FRANCOS_THREAD);
    const { document } = await run(tool, { action: "keep", messageId: "v-00000005", what: "dishwasher warranty", kind: "warranty", date: dayFromNow(90) });
    const lineNow = async () => JSON.stringify((await channel.promptBuild({ prompt: "renewals" }, SHARED_ROOM)));

    // Act
    const updated = await run(tool, { action: "update", document, date: dayFromNow(455) });
    const afterUpdate = await lineNow();
    const removed = await run(tool, { action: "remove", document });
    const afterRemove = await lineNow();

    // Assert
    assert.equal(updated.expires, dayFromNow(455));
    assert.match(afterUpdate, /dishwasher warranty expires/);
    assert.equal((afterUpdate.match(/dishwasher warranty expires/g) ?? []).length, 1, "corrected, not added twice");
    assert.deepEqual(removed, { removed: "dishwasher warranty" });
    assert.doesNotMatch(afterRemove, /dishwasher/);
    assert.deepEqual(await run(tool, { action: "view" }), { documents: [] });
  } finally {
    await channel.stop();
  }
});
