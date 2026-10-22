// The family room's store, from deploy/openclaw/plugins/household-app.
//
// Run with `node --test tests/js/household_app_store.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";

const AT = Date.UTC(2026, 9, 14, 23, 0);

async function store() {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-store-"));
  return openRoomStore(path.join(directory, "room.sqlite"));
}

function message(id, overrides = {}) {
  return {
    id,
    conversation: "family",
    author: "franco",
    at: AT,
    text: `said ${id}`,
    media: [],
    replyTo: null,
    origin: "local",
    ...overrides,
  };
}

test("a message is kept once, however often it arrives", async () => {
  const room = await store();
  const first = room.addMessage(message("m-1"));
  const again = room.addMessage(message("m-1", { text: "changed on the way" }));
  assert.equal(first.added, true);
  assert.equal(again.added, false);
  assert.equal(room.message("m-1").text, "said m-1");
  assert.equal(room.changesSince(0).entries.length, 1);
});

test("every change gets the next revision, and a phone catches up from its last one", async () => {
  const room = await store();
  room.addMessage(message("m-1"));
  room.addMessage(message("m-2", { author: "corey" }));
  const { rev } = room.changesSince(0);
  room.setReaction({ messageId: "m-2", author: "franco", emoji: "❤️", at: AT + 1, origin: "local" });
  room.markRead({ conversation: "family", author: "franco", messageId: "m-2", at: AT + 2, origin: "local" });

  const caughtUp = room.changesSince(rev);
  assert.deepEqual(caughtUp.entries.map((entry) => entry.kind), ["reaction", "read"]);
  assert.equal(caughtUp.rev, rev + 2);
  assert.equal(caughtUp.hasMore, false);
  assert.ok(caughtUp.entries.every((entry, index) => entry.rev === rev + 1 + index));
});

test("catching up is paged and says when there is more", async () => {
  const room = await store();
  for (let index = 1; index <= 5; index += 1) room.addMessage(message(`m-${index}`));
  const page = room.changesSince(0, 2);
  assert.deepEqual(page.entries.map((entry) => entry.id), ["m-1", "m-2"]);
  assert.equal(page.hasMore, true);
  assert.equal(page.rev, 2);
  const rest = room.changesSince(page.rev, 10);
  assert.deepEqual(rest.entries.map((entry) => entry.id), ["m-3", "m-4", "m-5"]);
  assert.equal(rest.hasMore, false);
});

test("a person's reaction replaces their earlier one and can be taken back", async () => {
  const room = await store();
  room.addMessage(message("m-1"));
  room.setReaction({ messageId: "m-1", author: "gia", emoji: "👍", at: AT + 1, origin: "peer" });
  room.setReaction({ messageId: "m-1", author: "gia", emoji: "😂", at: AT + 2, origin: "peer" });
  assert.deepEqual(room.reactions("m-1"), [{ author: "gia", emoji: "😂" }]);
  room.setReaction({ messageId: "m-1", author: "gia", emoji: null, at: AT + 3, origin: "peer" });
  assert.deepEqual(room.reactions("m-1"), []);
  const latest = room.changesSince(0).entries.filter((entry) => entry.kind === "reaction");
  assert.equal(latest.length, 1, "one row per person and message, carrying the latest state");
  assert.equal(latest[0].emoji, null);
});

test("a reaction older than the one kept is ignored", async () => {
  const room = await store();
  room.addMessage(message("m-1"));
  room.setReaction({ messageId: "m-1", author: "gia", emoji: "😂", at: AT + 5, origin: "peer" });
  const stale = room.setReaction({ messageId: "m-1", author: "gia", emoji: "👍", at: AT + 4, origin: "peer" });
  assert.equal(stale, null);
  assert.deepEqual(room.reactions("m-1"), [{ author: "gia", emoji: "😂" }]);
});

test("read markers only move forward", async () => {
  const room = await store();
  room.addMessage(message("m-1"));
  room.addMessage(message("m-2"));
  room.markRead({ conversation: "family", author: "gia", messageId: "m-2", at: AT + 2, origin: "peer" });
  const backwards = room.markRead({ conversation: "family", author: "gia", messageId: "m-1", at: AT + 3, origin: "peer" });
  assert.equal(backwards, null);
  assert.equal(room.readMarker("family", "gia"), "m-2");
});

test("a read marker for a message this store never saw is ignored", async () => {
  const room = await store();
  assert.equal(
    room.markRead({ conversation: "family", author: "gia", messageId: "m-9", at: AT, origin: "peer" }),
    null,
  );
});

test("history reads one conversation backwards a page at a time", async () => {
  const room = await store();
  room.addMessage(message("m-1"));
  room.addMessage(message("d-1", { conversation: "direct" }));
  room.addMessage(message("m-2"));
  room.addMessage(message("m-3"));

  const newest = room.history("family", { limit: 2 });
  assert.deepEqual(newest.messages.map((entry) => entry.id), ["m-2", "m-3"]);
  assert.equal(newest.hasMore, true);
  const older = room.history("family", { before: newest.messages[0].rev, limit: 2 });
  assert.deepEqual(older.messages.map((entry) => entry.id), ["m-1"]);
  assert.equal(older.hasMore, false);
});

test("the outbox holds only what this gateway's own people and assistant did in the family room", async () => {
  const room = await store();
  room.addMessage(message("m-1"));
  room.addMessage(message("m-2", { author: "corey" }));
  room.addMessage(message("m-3", { author: "gia", origin: "peer" }));
  room.addMessage(message("d-1", { conversation: "direct" }));
  room.setReaction({ messageId: "m-3", author: "franco", emoji: "❤️", at: AT + 1, origin: "local" });
  room.setReaction({ messageId: "m-1", author: "gia", emoji: "👍", at: AT + 1, origin: "peer" });

  const outbox = room.outbox(10);
  assert.deepEqual(
    outbox.map((entry) => `${entry.kind}:${entry.id}`),
    ["message:m-1", "message:m-2", "reaction:reaction:m-3:franco"],
  );
});

test("the outbox keeps the newest entries when it is bounded", async () => {
  const room = await store();
  for (let index = 1; index <= 4; index += 1) room.addMessage(message(`m-${index}`));
  assert.deepEqual(room.outbox(2).map((entry) => entry.id), ["m-3", "m-4"]);
});

test("media and the signature round-trip", async () => {
  const room = await store();
  const media = [{ id: "a".repeat(64), kind: "voice", mime: "audio/mp4", bytes: 2048, durationMs: 3100, waveform: [0.1, 0.9] }];
  room.addMessage(message("m-1", { media, signature: "c2ln", replyTo: "m-0" }));
  const kept = room.message("m-1");
  assert.deepEqual(kept.media, media);
  assert.equal(kept.signature, "c2ln");
  assert.equal(kept.replyTo, "m-0");
});

test("an assistant's message keeps the run it came from", async () => {
  const room = await store();
  room.addMessage(message("a-1", { author: "corey", runId: "run-7" }));
  assert.equal(room.message("a-1").runId, "run-7");
});

test("how an approval card ended is kept once, and only for an approval card", async () => {
  const room = await store();
  const approval = { id: "plugin:1", kind: "plugin", title: "Add to the family calendar", decisions: ["allow-once", "deny"] };
  room.addMessage(message("ap-1", { conversation: "direct", author: "corey", approval }));
  room.addMessage(message("a-1", { conversation: "direct", author: "corey" }));
  assert.deepEqual(room.message("ap-1").approval, approval);
  assert.equal(room.approvalState("ap-1"), null);

  const ended = room.setApprovalState({ messageId: "ap-1", state: "denied", at: AT + 1 });

  assert.deepEqual([ended.kind, ended.conversation, ended.messageId, ended.state], ["approval", "direct", "ap-1", "denied"]);
  assert.equal(room.setApprovalState({ messageId: "ap-1", state: "approved", at: AT + 2 }), null);
  assert.equal(room.approvalState("ap-1"), "denied");
  assert.equal(room.setApprovalState({ messageId: "a-1", state: "approved", at: AT }), null);
  assert.equal(room.setApprovalState({ messageId: "ap-unknown", state: "approved", at: AT }), null);
  assert.equal(room.approvalState("a-1"), null);
  assert.deepEqual(room.outbox(10), [], "the owner's own thread is never in the outbox");
});

test("the store survives being opened again", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-store-"));
  const file = path.join(directory, "room.sqlite");
  const first = openRoomStore(file);
  first.addMessage(message("m-1"));
  first.close();
  const second = openRoomStore(file);
  assert.equal(second.message("m-1").text, "said m-1");
  second.addMessage(message("m-2"));
  assert.equal(second.changesSince(0).rev, 2);
});

test("a phone's push registration is kept, replaced and removed by its token", async () => {
  const room = await store();
  room.putDevice({ token: "t1", environment: "production", key: "k1", at: AT });
  room.putDevice({ token: "t2", environment: "sandbox", key: "k2", at: AT });
  room.putDevice({ token: "t1", environment: "production", key: "k1-new", at: AT + 1 });
  assert.deepEqual(room.devices(), [
    { token: "t1", environment: "production", key: "k1-new", phone: null },
    { token: "t2", environment: "sandbox", key: "k2", phone: null },
  ]);
  room.removeDevice("t2");
  assert.deepEqual(room.devices().map((device) => device.token), ["t1"]);
});

test("a phone's push registration is not a change a phone catches up on", async () => {
  const room = await store();
  room.putDevice({ token: "t1", environment: "production", key: "k1", at: AT });
  assert.deepEqual(room.changesSince(0).entries, []);
});

test("every person's read marker in one conversation", async () => {
  const room = await store();
  room.addMessage(message("m-1"));
  room.addMessage(message("d-1", { conversation: "direct" }));
  room.markRead({ conversation: "family", author: "gia", messageId: "m-1", at: AT, origin: "peer" });
  room.markRead({ conversation: "family", author: "franco", messageId: "m-1", at: AT, origin: "local" });
  room.markRead({ conversation: "direct", author: "franco", messageId: "d-1", at: AT, origin: "local" });
  assert.deepEqual(room.readMarkers("family"), [
    { author: "franco", messageId: "m-1" },
    { author: "gia", messageId: "m-1" },
  ]);
});

test("an Apple ID linked to a person is found by Apple's id, and linking again moves it", async () => {
  const kept = await store();
  assert.equal(kept.personForApple("001234.apple"), null);
  kept.linkApple({ sub: "001234.apple", person: "franco", at: AT });
  assert.equal(kept.personForApple("001234.apple"), "franco");
  kept.linkApple({ sub: "001234.apple", person: "gia", at: AT + 1 });
  assert.equal(kept.personForApple("001234.apple"), "gia");
});

test("a waiting sign-in is kept once per Apple ID, answered to the phone that asked last", async () => {
  const kept = await store();
  kept.requestApple({ id: "req-1", sub: "001234.apple", name: "New iPhone", at: AT, ticket: "hash-1" });
  const again = kept.requestApple({ id: "req-2", sub: "001234.apple", name: "Same iPhone", at: AT + 5, ticket: "hash-2" });
  const expected = { id: "req-1", sub: "001234.apple", name: "Same iPhone", at: AT, ticket: "hash-2", approvedAt: null };
  assert.deepEqual(again, expected);
  assert.deepEqual(kept.appleRequests(), [expected]);
  assert.deepEqual(kept.appleRequest("req-1"), expected);
  assert.equal(kept.appleRequest("req-2"), null);
});

test("a waiting sign-in is approved once, and dropped when collected or too old", async () => {
  const kept = await store();
  kept.requestApple({ id: "req-1", sub: "001234.a", name: "One", at: AT, ticket: "hash-1" });
  kept.requestApple({ id: "req-2", sub: "001234.b", name: "Two", at: AT + 60_000, ticket: "hash-2" });
  assert.equal(kept.approveAppleRequest("req-1", AT + 1), true);
  assert.equal(kept.approveAppleRequest("req-1", AT + 2), false);
  assert.equal(kept.approveAppleRequest("req-9", AT + 2), false);
  assert.equal(kept.appleRequest("req-1").approvedAt, AT + 1);
  kept.dropAppleRequest("req-1");
  assert.equal(kept.appleRequest("req-1"), null);
  kept.dropAppleRequestsBefore(AT + 60_001);
  assert.deepEqual(kept.appleRequests(), []);
});

test("a phone's push registration keeps which phone it is, and one made before that has none", async () => {
  const room = await store();
  room.putDevice({ token: "t1", environment: "production", key: "k1", phone: "iphone", at: AT });
  room.putDevice({ token: "t2", environment: "production", key: "k2", at: AT });
  assert.deepEqual(room.devices().map((device) => [device.token, device.phone]), [["t1", "iphone"], ["t2", null]]);
});

test("a removed phone's push registrations go with it, and no other phone's", async () => {
  const room = await store();
  room.putDevice({ token: "t1", environment: "production", key: "k1", phone: "franco-ipad", at: AT });
  room.putDevice({ token: "t2", environment: "sandbox", key: "k2", phone: "franco-ipad", at: AT });
  room.putDevice({ token: "t3", environment: "production", key: "k3", phone: "this-iphone", at: AT });
  room.putDevice({ token: "t4", environment: "production", key: "k4", at: AT });
  room.removeDevicesOf("franco-ipad");
  assert.deepEqual(room.devices().map((device) => device.token), ["t3", "t4"]);
});

test("a store made before phones were remembered gains the column and keeps its tokens", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-store-"));
  const file = path.join(directory, "room.sqlite");
  const { DatabaseSync } = await import("node:sqlite");
  const old = new DatabaseSync(file);
  old.exec("CREATE TABLE devices (token TEXT PRIMARY KEY, environment TEXT NOT NULL, key TEXT NOT NULL, updated_at INTEGER NOT NULL)");
  old.prepare("INSERT INTO devices VALUES (?, ?, ?, ?)").run("t1", "production", "k1", AT);
  old.close();
  const room = openRoomStore(file);
  assert.deepEqual(room.devices(), [{ token: "t1", environment: "production", key: "k1", phone: null }]);
});

test("an assistant's page is one entry per assistant, newest kept", async () => {
  const room = await store();
  const first = room.setProfile({ author: "corey", at: AT, origin: "local", name: "Corey", voice: "will", voiceName: "Will", modelName: "GLM 5.3 Flash" });
  assert.equal(first.id, "profile:corey");
  assert.equal(room.setProfile({ author: "corey", at: AT - 1, origin: "local", name: "Corey", voice: "liam", voiceName: "Liam", modelName: "GLM 5.3 Flash" }), null);
  room.setProfile({ author: "corey", at: AT + 1, origin: "local", name: "Corey", voice: "liam", voiceName: "Liam", modelName: "GLM 5.3 Flash" });
  assert.deepEqual(room.profiles(), { corey: { name: "Corey", voice: "liam", voiceName: "Liam", modelName: "GLM 5.3 Flash" } });
  assert.deepEqual(room.outbox(10).map((entry) => entry.kind), ["profile"]);
});

const DAY = 86_400_000;

function call(id, overrides = {}) {
  return {
    id: `call:${id}`,
    author: "franco",
    at: AT,
    endedAt: AT + 60_000,
    with: "corey",
    turnIds: [],
    transcript: [],
    isCut: false,
    origin: "local",
    ...overrides,
  };
}

test("a call takes the place of the messages it folds, and of everything that points at them", async () => {
  const room = await store();
  room.addMessage(message("d-1", { conversation: "direct" }));
  room.addMessage(message("d-2", { conversation: "direct", author: "corey" }));
  room.addMessage(message("d-3", { conversation: "direct" }));
  room.setReaction({ messageId: "d-1", author: "franco", emoji: "👍", at: AT + 1, origin: "local" });
  room.markRead({ conversation: "direct", author: "franco", messageId: "d-2", at: AT + 2, origin: "local" });
  const transcript = [{ author: "franco", text: "said d-1", at: AT }, { author: "corey", text: "said d-2", at: AT }];

  const { added, entry } = room.addCall(call("c-1", { turnIds: ["d-1", "d-2"], transcript }));

  assert.equal(added, true);
  assert.deepEqual(entry, {
    id: "call:c-1",
    rev: 6,
    kind: "call",
    conversation: "direct",
    author: "franco",
    at: AT,
    endedAt: AT + 60_000,
    with: "corey",
    turnIds: ["d-1", "d-2"],
    transcript,
    isCut: false,
    origin: "local",
  });
  assert.deepEqual(room.changesSince(0).entries.map((kept) => kept.id), ["d-3", "call:c-1"]);
  assert.deepEqual(room.changesSince(0).entries.at(-1), entry);
  assert.deepEqual(room.reactions("d-1"), []);
  assert.equal(room.readMarker("direct", "franco"), null);
});

test("a call ended again is the call first kept, and folds nothing more", async () => {
  const room = await store();
  room.addMessage(message("d-1", { conversation: "direct" }));
  const first = room.addCall(call("c-1"));

  const again = room.addCall(call("c-1", { turnIds: ["d-1"], isCut: true }));

  assert.equal(again.added, false);
  assert.deepEqual(again.entry, first.entry);
  assert.equal(room.message("d-1").text, "said d-1");
});

test("the owner's own thread pages back through its calls in order with its messages", async () => {
  const room = await store();
  room.addMessage(message("d-1", { conversation: "direct" }));
  room.addCall(call("c-1"));
  room.addMessage(message("d-2", { conversation: "direct" }));

  assert.deepEqual(room.history("direct").messages.map((entry) => entry.id), ["d-1", "call:c-1", "d-2"]);
  assert.deepEqual(room.history("direct", { limit: 1, before: 3 }).messages.map((entry) => entry.id), ["call:c-1"]);
});

test("calls that ended before the cut-off are dropped, and nothing else is", async () => {
  const room = await store();
  room.addCall(call("old", { at: AT - 31 * DAY, endedAt: AT - 31 * DAY + 60_000 }));
  room.addCall(call("recent", { at: AT - 29 * DAY, endedAt: AT - 29 * DAY + 60_000 }));
  room.addMessage(message("d-1", { conversation: "direct", at: AT - 40 * DAY }));

  room.dropCallsEndedBefore(AT - 30 * DAY);

  assert.deepEqual(room.history("direct").messages.map((entry) => entry.id), ["call:recent", "d-1"]);
});

test("the newest entry is never dropped, so no revision a phone has seen is given again", async () => {
  const room = await store();
  room.addCall(call("old", { at: AT - 31 * DAY, endedAt: AT - 31 * DAY + 60_000 }));

  room.dropCallsEndedBefore(AT - 30 * DAY);
  room.addMessage(message("d-1", { conversation: "direct" }));
  room.dropCallsEndedBefore(AT - 30 * DAY);

  assert.deepEqual(room.changesSince(0).entries.map((entry) => [entry.id, entry.rev]), [["d-1", 2]]);
});

test("a message a handed-over turn wrote keeps its mark, and no other message has one", async () => {
  const room = await store();
  room.addMessage(message("a-1", { author: "corey", handedOver: true }));
  room.addMessage(message("a-2", { author: "corey" }));
  assert.equal(room.message("a-1").handedOver, true);
  assert.equal("handedOver" in room.message("a-2"), false);
  assert.equal(room.outbox(10)[0].handedOver, true);
});
