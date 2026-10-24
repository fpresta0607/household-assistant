// family_history in the household app: the family room's own retained messages, for a turn of
// one of its people, read-only and bounded. Ported from the household-family-room plugin's
// tests when Telegram was retired, with The Fam's transcript and supplement gone.

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";

import { FAMILY_HISTORY_TOOL, createFamilyHistoryTool } from "../../deploy/openclaw/plugins/household-app/family-history.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";

const START = 1_790_000_000_000;
// The household app's people on this gateway: its owner and the person on the other one.
const OWNER = "sam";
const PEER = "alex";
const FAMILY_TURN = {
  messageChannel: "household", agentAccountId: "default", agentId: "main", nativeChannelId: undefined,
  requesterSenderId: PEER, sessionKey: "agent:main:household:group:family",
  deliveryContext: { channel: "household", accountId: "default", to: "household:family" },
};
const PRIVATE_TURN = {
  ...FAMILY_TURN, requesterSenderId: OWNER, sessionKey: `agent:main:household:direct:${OWNER}`,
  deliveryContext: { channel: "household", accountId: "default", to: `household:${OWNER}` },
};

async function fixture(context) {
  const directory = await mkdtemp(path.join(tmpdir(), "family-history-"));
  context.after(async () => { await rm(directory, { recursive: true, force: true }); });
  const runtime = { value: {
    channels: { household: { enabled: true, owner: { id: OWNER }, peer: { person: { id: PEER } } } },
    session: { dmScope: "per-channel-peer", groupScope: "per-group" },
  } };
  const access = { stateDir: () => directory };
  const discover = (turn) => createFamilyHistoryTool({ context: turn, current: () => runtime.value, stateDir: () => access.stateDir() });
  const store = () => openRoomStore(path.join(directory, "household-app", "room.sqlite"));
  return { directory, runtime, access, discover, store };
}

async function page(tool, args = {}) {
  assert.ok(tool, "a turn of one of the room's people must receive family_history");
  const result = await tool.execute("test-call", args);
  assert.notEqual(result.isError, true, result.content?.[0]?.text);
  assert.ok(Buffer.byteLength(result.content[0].text) <= 24_000);
  return JSON.parse(result.content[0].text);
}

test("family history is the household app's tool, with a bounded input schema", async (context) => {
  const { discover } = await fixture(context);
  const tool = discover(FAMILY_TURN);
  const manifest = JSON.parse(await readFile(new URL("../../deploy/openclaw/plugins/household-app/openclaw.plugin.json", import.meta.url), "utf8"));
  assert.equal(tool.name, FAMILY_HISTORY_TOOL);
  assert.ok(manifest.contracts.tools.includes(FAMILY_HISTORY_TOOL));
  assert.equal(tool.parameters.additionalProperties, false);
  assert.deepEqual(Object.keys(tool.parameters.properties).sort(), ["limit", "offset", "source"]);
  assert.deepEqual(tool.parameters.properties.source, { type: "string", enum: ["app"], default: "app" });
});

test("family history admits the family room and its owner's own thread", async (context) => {
  const setup = await fixture(context);
  const store = setup.store();
  store.addMessage({ id: "m1", conversation: "family", author: PEER, at: START, text: "Family plans", media: [], origin: "local" });
  store.close();
  for (const turn of [
    FAMILY_TURN,
    { ...FAMILY_TURN, requesterSenderId: OWNER },
    { ...FAMILY_TURN, requesterSenderId: `household:${PEER}`, nativeChannelId: "family" },
    // The owner's family-room turn, in the owner's own session of the room.
    { ...FAMILY_TURN, requesterSenderId: OWNER, sessionKey: `agent:main:household:group:family:sender:${OWNER}` },
    PRIVATE_TURN,
  ]) {
    assert.deepEqual((await page(setup.discover(turn))).entries.map((entry) => entry.text), ["Family plans"], JSON.stringify(turn));
  }
});

test("family history denies every other route before touching storage", async (context) => {
  const setup = await fixture(context);
  setup.access.stateDir = () => { assert.fail("a denied turn reached storage"); };
  for (const turn of [
    { ...FAMILY_TURN, requesterSenderId: "pat" },
    { ...FAMILY_TURN, requesterSenderId: undefined },
    { ...FAMILY_TURN, nativeChannelId: OWNER },
    { ...FAMILY_TURN, sessionKey: "agent:main:household:group:other" },
    { ...FAMILY_TURN, sessionKey: `agent:main:household:direct:${OWNER}` },
    { ...FAMILY_TURN, sessionKey: `agent:main:household:group:family:sender:${OWNER}` },
    { ...FAMILY_TURN, sessionKey: `agent:main:household:group:family:sender:${PEER}` },
    { ...FAMILY_TURN, deliveryContext: { channel: "household", accountId: "default", to: "household:other" } },
    { ...FAMILY_TURN, deliveryContext: { channel: "household", accountId: "other", to: "household:family" } },
    { ...FAMILY_TURN, deliveryContext: { channel: "telegram", accountId: "default", to: "household:family" } },
    { ...FAMILY_TURN, deliveryContext: { channel: "household", accountId: "default", to: "household:family", threadId: "1" } },
    { ...FAMILY_TURN, deliveryContext: undefined },
    { ...FAMILY_TURN, messageChannel: "telegram" },
    { ...FAMILY_TURN, messageChannel: "cli" },
    { ...FAMILY_TURN, agentAccountId: "other" },
    { ...PRIVATE_TURN, requesterSenderId: PEER },
    { ...PRIVATE_TURN, sessionKey: `agent:main:household:direct:${PEER}`,
      deliveryContext: { channel: "household", accountId: "default", to: `household:${PEER}` } },
    { ...PRIVATE_TURN, sessionKey: "agent:main:main" },
    { ...PRIVATE_TURN, agentId: "other" },
    { ...PRIVATE_TURN, oneShotCliRun: true },
    undefined,
  ]) {
    assert.equal(setup.discover(turn), null, JSON.stringify(turn));
  }
  for (const mutate of [
    (config) => { delete config.channels.household; },
    (config) => { config.channels.household.enabled = false; },
    (config) => { config.session.dmScope = "main"; },
    (config) => { config.session.groupScope = "per-sender"; },
    (config) => { config.plugins = { enabled: false }; },
  ]) {
    const original = structuredClone(setup.runtime.value);
    mutate(setup.runtime.value);
    assert.equal(setup.discover(FAMILY_TURN), null);
    setup.runtime.value = original;
  }
});

test("a change after the tool was offered is checked again before storage", async (context) => {
  const setup = await fixture(context);
  const tool = setup.discover(FAMILY_TURN);
  delete setup.runtime.value.channels.household;
  setup.access.stateDir = () => { assert.fail("a revoked turn reached storage"); };
  const result = await tool.execute("test-call", {});
  assert.equal(result.isError, true);
  assert.equal(JSON.parse(result.content[0].text).code, "access_denied");
});

test("family history reads saved voice transcripts without opening audio, and never a private thread", async (context) => {
  const setup = await fixture(context);
  const store = setup.store();
  const voice = [{ id: "audio-does-not-exist", kind: "voice", mime: "audio/mp4" }];
  const add = (id, conversation, text, media = [], author = PEER) => store.addMessage({
    id, conversation, author, at: START + Number(id.slice(-1)), text, media, origin: "local",
  });
  add("note1", "family", "Appointment details", voice);
  store.setTranscript({ messageId: "note1", author: "corey", words: "Thursday at three.", at: START + 10 });
  add("note2", "direct", "PRIVATE_SENTINEL", voice);
  store.setTranscript({ messageId: "note2", author: "corey", words: "PRIVATE_AUDIO_SENTINEL", at: START + 11 });
  add("note3", "family", "", voice);
  add("note4", "family", "I will remind you.", voice, "corey");
  store.close(); // The lookup must read what survived a restart, without a live hearing service.

  const tool = setup.discover(FAMILY_TURN);
  const first = await page(tool, { limit: 1 });
  assert.equal(first.source, "app");
  assert.equal(first.entries[0].text, "Appointment details\n[Voice note transcript (machine-generated)]: Thursday at three.");
  assert.equal(first.entries[0].role, "user");
  const second = await page(tool, { offset: first.nextOffset });
  assert.deepEqual(second.entries.map((entry) => entry.text), ["[Voice note: saved transcript unavailable]", "I will remind you."]);
  assert.equal(second.entries[1].role, "assistant");
  assert.equal(second.hasMore, false);
  assert.match(second.retention.note, /do not download or re-transcribe old audio/);
  assert.doesNotMatch(JSON.stringify([first, second]), /PRIVATE|audio-does-not-exist|room.sqlite/);
  assert.deepEqual((await page(setup.discover(PRIVATE_TURN), { source: "app" })).entries.map((entry) => entry.messageId), ["note1", "note3", "note4"]);
});

test("family history bounds saved transcripts and pages past malformed messages", async (context) => {
  const setup = await fixture(context);
  const file = path.join(setup.directory, "household-app", "room.sqlite");
  const store = setup.store();
  for (let index = 0; index < 55; index++) {
    store.addMessage({ id: `voice-${index}`, conversation: "family", author: OWNER, at: START + index, text: "", media: [{ kind: "voice" }], origin: "local" });
    store.setTranscript({ messageId: `voice-${index}`, author: "corey", words: "long transcript ".repeat(700), at: START + index });
  }
  store.close();
  const db = new DatabaseSync(file);
  for (const [index, body] of ["not json", "null", '{"media":[null]}'].entries()) {
    db.prepare("UPDATE entries SET body = ? WHERE id = ?").run(body, `voice-${index}`);
  }
  db.close();
  const tool = setup.discover(FAMILY_TURN);
  const first = await page(tool, { limit: 50 });
  assert.equal(first.skippedMalformedEvents, 3);
  assert.equal(first.truncated, true);
  assert.equal(first.hasMore, true);
  assert.ok(first.entries.every((entry) => entry.text.length <= 2000));
  const second = await page(tool, { offset: first.nextOffset, limit: 50 });
  assert.notEqual(first.entries.at(-1).messageId, second.entries[0].messageId);
});

test("family history refuses a source or a page it does not have, and says when the room is unreadable", async (context) => {
  const setup = await fixture(context);
  const tool = setup.discover(FAMILY_TURN);
  for (const args of [{ source: "transcript" }, { source: "room" }, { limit: 0 }, { limit: 51 }, { offset: -1 }, { other: 1 }, null]) {
    const result = await tool.execute("test-call", args);
    assert.equal(result.isError, true, JSON.stringify(args));
    assert.equal(JSON.parse(result.content[0].text).code, "invalid_arguments");
  }
  const missing = await tool.execute("test-call", {});
  assert.equal(missing.isError, true);
  assert.equal(JSON.parse(missing.content[0].text).code, "history_unavailable");
});
