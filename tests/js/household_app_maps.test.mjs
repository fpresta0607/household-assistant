// Maps in the app's conversations, from deploy/openclaw/plugins/household-app: a map a
// person shares, once or live, signed like any message and kept like one, the live
// updates to it and their end, and a person's answer to a reminder by place that would
// watch them.
//
// Run with `node --test tests/js/household_app_maps.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { liveText } from "../../deploy/openclaw/plugins/household-app/map-share.js";
import { createMediaStore } from "../../deploy/openclaw/plugins/household-app/media.js";
import { placeAnswerText } from "../../deploy/openclaw/plugins/household-app/place-consent.js";
import { createRoom } from "../../deploy/openclaw/plugins/household-app/room.js";
import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";

const NOW = Date.UTC(2026, 9, 15, 22, 52);
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

function phone() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const signing = (text) => sign(null, Buffer.from(text, "utf8"), privateKey).toString("base64url");
  return {
    key: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url"),
    message: (message) => ({ ...message, signature: signing(signedText(message)) }),
    live: (update) => ({ ...update, signature: signing(liveText(update)) }),
    answer: (answer) => ({ ...answer, signature: signing(placeAnswerText(answer)) }),
  };
}

const FRANCO = phone();
const GIA = phone();

// Franco on Maple Street, eighteen minutes from home.
const MAPLE = { latitudeE6: 39_768_403, longitudeE6: -86_158_068, accuracy: 12, at: NOW - 5000 };
const FARTHER = { latitudeE6: 39_771_950, longitudeE6: -86_151_210, accuracy: 9, at: NOW + 4 * MINUTE };

function shared(id, location, overrides = {}) {
  return { conversation: "family", id, at: NOW - 1000, replyTo: null, media: [], text: "", location, ...overrides };
}

const LIVE_HOUR = { ...MAPLE, until: NOW - 1000 + HOUR };
const ONCE = { ...MAPLE, until: null };

async function setup({ ownerName = "Franco" } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-maps-"));
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const clock = { now: NOW };
  const seen = { events: [], outboxes: [], pushes: [], dispatched: [], warnings: [] };
  const room = createRoom({
    identity: {
      owner: { id: "franco", name: ownerName, keys: [FRANCO.key] },
      assistant: { id: "corey", name: "Corey" },
      peer: {
        person: { id: "gia", name: "Gia", keys: [GIA.key] },
        assistant: { id: "denise", name: "Denise" },
      },
    },
    sessionKeys: { family: "agent:main:household:group:family", direct: "agent:main:household:direct:franco" },
    store,
    media: createMediaStore(directory),
    now: () => clock.now,
    emit: (name, payload) => seen.events.push([name, payload]),
    writeOutbox: (outbox) => seen.outboxes.push(outbox),
    push: {
      async notify(phones, note) {
        seen.pushes.push({ phones, note });
        return phones.map((device) => ({ token: device.token, ok: true }));
      },
    },
    dispatch: async (turn) => seen.dispatched.push(turn),
    isAddressed: async (message, facts) => facts.isReplyToAssistant || /corey/i.test(message.text),
    log: { warn: (line) => seen.warnings.push(line), info() {} },
  });
  room.registerDevice({ token: "a1".repeat(32), environment: "production", key: Buffer.alloc(32, 7).toString("base64") });
  return { room, store, seen, clock };
}

// What Gia's gateway hands this one through the relay: her map, and her updates to it.
function relayed(entries) {
  return { entries, typing: {}, identity: { person: { id: "gia", keys: [GIA.key] }, assistant: { id: "denise", name: "Denise" } } };
}

function giasMap(location = { ...MAPLE, until: NOW - 1000 + HOUR }) {
  return { kind: "message", author: "gia", ...GIA.message(shared("m-gia-map-0001", location)) };
}

function giasUpdate(update) {
  return { kind: "live", author: "gia", conversation: "family", ...GIA.live(update) };
}

// MARK: - A map shared in a conversation

test("a shared map is signed with its place and its end, and kept and relayed like a message", async () => {
  const { room, store, seen } = await setup();
  const { entry } = await room.send(FRANCO.message(shared("m-map-00000001", LIVE_HOUR)));
  assert.equal(entry.author, "franco");
  assert.deepEqual(store.message("m-map-00000001").location, LIVE_HOUR);
  assert.deepEqual(seen.outboxes.at(-1).entries.map((outgoing) => [outgoing.id, outgoing.location?.until]), [["m-map-00000001", LIVE_HOUR.until]]);
});

test("a map whose place, accuracy or end changed after the phone signed it is refused", async () => {
  const { room, store } = await setup();
  const signed = FRANCO.message(shared("m-map-00000002", LIVE_HOUR));
  for (const changed of [
    { latitudeE6: MAPLE.latitudeE6 + 1 },
    { longitudeE6: MAPLE.longitudeE6 - 1 },
    { accuracy: 5 },
    { until: LIVE_HOUR.until + HOUR },
    { until: null },
  ]) {
    await assert.rejects(room.send({ ...signed, location: { ...signed.location, ...changed } }), /signature/);
  }
  assert.equal(store.message("m-map-00000002"), null);
});

test("a map signed as a plain message cannot carry a place", async () => {
  const { room, store } = await setup();
  const plain = FRANCO.message(shared("m-map-00000003", undefined));
  await assert.rejects(room.send({ ...plain, location: ONCE }), /signature/);
  assert.equal(store.message("m-map-00000003"), null);
});

test("a map's end comes after it is shared and within a day, and it carries no attachments", async () => {
  const { room } = await setup();
  for (const until of [NOW - 1000, NOW - 5000, NOW - 1000 + 27 * HOUR, 1.5]) {
    await assert.rejects(room.send(FRANCO.message(shared("m-map-00000004", { ...MAPLE, until }))), /end of the share/);
  }
  for (const position of [{ latitudeE6: 91_000_000 }, { longitudeE6: 39.5 }, { accuracy: 0 }, { at: NOW - 2 * HOUR }]) {
    await assert.rejects(room.send(FRANCO.message(shared("m-map-00000005", { ...ONCE, ...position }))), /bad|out of range/);
  }
  const photo = { id: "a".repeat(64), kind: "photo", mime: "image/jpeg", bytes: 10 };
  await assert.rejects(room.send(FRANCO.message(shared("m-map-00000006", ONCE, { media: [photo] }))), /attachments/);
});

test("a map in the owner's own thread starts the assistant's turn", async () => {
  const { room, seen } = await setup();
  await room.send(FRANCO.message(shared("d-map-00000001", ONCE, { conversation: "direct" })));
  assert.deepEqual(seen.dispatched.map((turn) => turn.message.location), [ONCE]);
});

test("a map the other person shares reaches the owner's phones as a location", async () => {
  const { room, seen } = await setup();
  const { accepted } = await room.acceptPeer(relayed([giasMap(), { kind: "message", author: "gia", ...GIA.message(shared("m-gia-map-0002", ONCE)) }]));
  assert.equal(accepted, 2);
  assert.deepEqual(seen.pushes.map((push) => push.note.body), ["Live location", "Location"]);
});

// MARK: - Live updates

test("live updates to a live map are kept, newest only, and reach the relay", async () => {
  const { room, store, seen, clock } = await setup();
  await room.send(FRANCO.message(shared("m-map-00000010", LIVE_HOUR)));
  clock.now = NOW + 2 * MINUTE;
  await room.live(FRANCO.live({ messageId: "m-map-00000010", at: NOW + 2 * MINUTE, position: { ...MAPLE, at: NOW + 2 * MINUTE } }));
  clock.now = NOW + 4 * MINUTE;
  const { entry } = await room.live(FRANCO.live({ messageId: "m-map-00000010", at: NOW + 4 * MINUTE, position: FARTHER }));
  assert.deepEqual(store.live("m-map-00000010").position, FARTHER);
  assert.deepEqual(seen.events.at(-1), ["changed", { rev: entry.rev }]);
  const outbox = seen.outboxes.at(-1).entries;
  assert.deepEqual(outbox.filter((outgoing) => outgoing.kind === "live").map((outgoing) => outgoing.position), [FARTHER]);
});

test("an update no newer than the last one kept is refused", async () => {
  const { room, store, clock } = await setup();
  await room.send(FRANCO.message(shared("m-map-00000011", LIVE_HOUR)));
  clock.now = NOW + 4 * MINUTE;
  await room.live(FRANCO.live({ messageId: "m-map-00000011", at: NOW + 4 * MINUTE, position: FARTHER }));
  const older = FRANCO.live({ messageId: "m-map-00000011", at: NOW + 3 * MINUTE, position: { ...MAPLE, at: NOW + 3 * MINUTE } });
  await assert.rejects(room.live(older), /newer/);
  await assert.rejects(room.live(FRANCO.live({ messageId: "m-map-00000011", at: NOW + 4 * MINUTE, position: FARTHER })), /newer/);
  await assert.rejects(room.live(FRANCO.live({ messageId: "m-map-00000011", at: NOW - 2000, position: MAPLE })), /newer|out of range/);
  assert.deepEqual(store.live("m-map-00000011").position, FARTHER);
});

test("an update once the share has ended is refused, on the gateway's clock and on the update's", async () => {
  const { room, store, clock } = await setup();
  await room.send(FRANCO.message(shared("m-map-00000012", { ...MAPLE, until: NOW + 15 * MINUTE })));
  clock.now = NOW + 15 * MINUTE;
  await assert.rejects(
    room.live(FRANCO.live({ messageId: "m-map-00000012", at: NOW + 14 * MINUTE, position: { ...MAPLE, at: NOW + 14 * MINUTE } })),
    /ended/,
  );
  clock.now = NOW + 14 * MINUTE;
  await assert.rejects(
    room.live(FRANCO.live({ messageId: "m-map-00000012", at: NOW + 15 * MINUTE + 1, position: { ...MAPLE, at: NOW + 14 * MINUTE } })),
    /ended/,
  );
  assert.equal(store.live("m-map-00000012"), null);
});

test("a stop ends a live share early, and nothing after it is taken", async () => {
  const { room, store, clock } = await setup();
  await room.send(FRANCO.message(shared("m-map-00000013", LIVE_HOUR)));
  clock.now = NOW + MINUTE;
  await room.live(FRANCO.live({ messageId: "m-map-00000013", at: NOW + MINUTE, position: null }));
  assert.equal(store.live("m-map-00000013").position, null);
  clock.now = NOW + 2 * MINUTE;
  await assert.rejects(room.live(FRANCO.live({ messageId: "m-map-00000013", at: NOW + 2 * MINUTE, position: { ...MAPLE, at: NOW + 2 * MINUTE } })), /stopped/);
});

test("a map shared once, a plain message and a missing one take no updates", async () => {
  const { room } = await setup();
  await room.send(FRANCO.message(shared("m-map-00000014", ONCE)));
  await room.send(FRANCO.message(shared("m-plain-0000001", undefined, { text: "On my way" })));
  for (const messageId of ["m-map-00000014", "m-plain-0000001", "m-missing-000001"]) {
    await assert.rejects(room.live(FRANCO.live({ messageId, at: NOW, position: MAPLE })), /no live map/);
  }
});

test("only the owner's phone moves the owner's map, and never anybody else's", async () => {
  const { room, store } = await setup();
  await room.send(FRANCO.message(shared("m-map-00000015", LIVE_HOUR)));
  await assert.rejects(room.live(GIA.live({ messageId: "m-map-00000015", at: NOW, position: MAPLE })), /signature/);
  const signed = FRANCO.live({ messageId: "m-map-00000015", at: NOW, position: MAPLE });
  await assert.rejects(room.live({ ...signed, position: FARTHER }), /signature/);
  await room.acceptPeer(relayed([giasMap()]));
  await assert.rejects(room.live(FRANCO.live({ messageId: "m-gia-map-0001", at: NOW, position: MAPLE })), /no live map/);
  assert.equal(store.live("m-map-00000015"), null);
});

test("the other gateway's live updates count only with the person's signature, in order and before the end", async () => {
  const { room, store, seen } = await setup();
  const first = giasUpdate({ messageId: "m-gia-map-0001", at: NOW + MINUTE, position: { ...MAPLE, at: NOW + MINUTE } });
  const second = giasUpdate({ messageId: "m-gia-map-0001", at: NOW + 3 * MINUTE, position: FARTHER });
  const forged = { ...giasUpdate({ messageId: "m-gia-map-0001", at: NOW + 4 * MINUTE, position: MAPLE }), position: FARTHER };
  const late = giasUpdate({ messageId: "m-gia-map-0001", at: LIVE_HOUR.until + 1, position: FARTHER });
  const { accepted, refused } = await room.acceptPeer(relayed([giasMap(), second, first, forged, late]));
  assert.equal(accepted, 2);
  assert.equal(refused, 3);
  assert.deepEqual(store.live("m-gia-map-0001").position, FARTHER);
  assert.equal(store.live("m-gia-map-0001").origin, "peer");
  assert.equal(seen.pushes.length, 1, "an update is never a notification");
});

test("the other gateway cannot move the owner's map", async () => {
  const { room, store } = await setup();
  await room.send(FRANCO.message(shared("m-map-00000016", LIVE_HOUR)));
  const { refused } = await room.acceptPeer(relayed([
    { kind: "live", author: "gia", conversation: "family", ...GIA.live({ messageId: "m-map-00000016", at: NOW + MINUTE, position: FARTHER }) },
    { kind: "live", author: "franco", conversation: "family", ...FRANCO.live({ messageId: "m-map-00000016", at: NOW + MINUTE, position: FARTHER }) },
  ]));
  assert.equal(refused, 2);
  assert.equal(store.live("m-map-00000016"), null);
});

test("a page carries each live map's newest position", async () => {
  const { room, clock } = await setup();
  await room.send(FRANCO.message(shared("m-map-00000017", LIVE_HOUR)));
  await room.send(FRANCO.message(shared("m-map-00000018", ONCE)));
  clock.now = NOW + 4 * MINUTE;
  await room.live(FRANCO.live({ messageId: "m-map-00000017", at: NOW + 4 * MINUTE, position: FARTHER }));
  const page = room.history({ conversation: "family" });
  assert.deepEqual(page.lives, { "m-map-00000017": { at: NOW + 4 * MINUTE, position: FARTHER } });
  assert.deepEqual(page.messages.map((message) => message.location?.until ?? null), [LIVE_HOUR.until, null]);
});

// MARK: - A reminder by place that watches somebody

const AT_WORK = { label: "Franco's work", latitude: 39.7817, longitude: -86.1478, radius: 200 };

function placeCard(fields) {
  return "Gia asked me to tell her.\n\n```steward-card\n" +
    JSON.stringify({ type: "place-reminder", text: "Tell Gia", place: AT_WORK, when: "leave", ...fields }) + "\n```";
}

function denise(id, text) {
  return { kind: "message", id, conversation: "family", author: "denise", at: NOW - 2000, replyTo: null, media: [], text };
}

test("a person answers a reminder by place that would watch them, signed by their phone", async () => {
  const { room, store, seen } = await setup();
  await room.acceptPeer(relayed([denise("a-place-000001", placeCard({ for: "Franco" }))]));
  const { entry } = await room.answerPlace(FRANCO.answer({ messageId: "a-place-000001", answer: "yes", at: NOW }));
  assert.deepEqual(store.placeAnswers("a-place-000001"), [{ author: "franco", answer: "yes" }]);
  assert.deepEqual(seen.outboxes.at(-1).entries.filter((outgoing) => outgoing.kind === "place").map((outgoing) => outgoing.answer), ["yes"]);
  assert.equal(entry.kind, "place");
  await room.answerPlace(FRANCO.answer({ messageId: "a-place-000001", answer: "no", at: NOW + 1 }));
  assert.deepEqual(store.placeAnswers("a-place-000001"), [{ author: "franco", answer: "no" }]);
  assert.deepEqual(room.history({ conversation: "family" }).places, { "a-place-000001": [{ author: "franco", answer: "no" }] });
});

test("an answer is refused unless the card asks this person, the phone signed it and it is newer", async () => {
  const { room, store } = await setup();
  await room.acceptPeer(relayed([
    denise("a-place-000002", placeCard({ for: "Gia" })),
    denise("a-place-000003", "No card here."),
    denise("a-place-000004", placeCard({ for: "franco" })),
  ]));
  await room.send(FRANCO.message(shared("m-place-0000001", undefined, { text: placeCard({ for: "Franco" }) })));
  for (const messageId of ["a-place-000002", "a-place-000003", "m-place-0000001", "a-missing-00001"]) {
    await assert.rejects(room.answerPlace(FRANCO.answer({ messageId, answer: "yes", at: NOW })), /asks/);
  }
  await assert.rejects(room.answerPlace(GIA.answer({ messageId: "a-place-000004", answer: "yes", at: NOW })), /signature/);
  await assert.rejects(room.answerPlace(FRANCO.answer({ messageId: "a-place-000004", answer: "maybe", at: NOW })), /yes or no/);
  await assert.rejects(room.answerPlace(FRANCO.answer({ messageId: "a-place-000004", answer: "yes", at: NOW - HOUR })), /out of range/);
  await room.answerPlace(FRANCO.answer({ messageId: "a-place-000004", answer: "yes", at: NOW }));
  await assert.rejects(room.answerPlace(FRANCO.answer({ messageId: "a-place-000004", answer: "no", at: NOW - 1 })), /newer/);
  assert.deepEqual(store.placeAnswers("a-place-000004"), [{ author: "franco", answer: "yes" }]);
});

test("the other person's answer to this assistant's card arrives through the relay, signed by their phone", async () => {
  const { room, store } = await setup();
  const card = await room.reply({ conversation: "family", text: placeCard({ for: "Gia", text: "Tell Franco" }) });
  const answer = (fields, by = GIA) => ({ kind: "place", author: "gia", conversation: "family", ...by.answer({ messageId: card.id, ...fields }) });
  const { accepted, refused } = await room.acceptPeer(relayed([
    answer({ answer: "yes", at: NOW }),
    answer({ answer: "no", at: NOW - 5 }),
    answer({ answer: "no", at: NOW + 5 }, FRANCO),
  ]));
  assert.equal(accepted, 1);
  assert.equal(refused, 2);
  assert.deepEqual(store.placeAnswers(card.id), [{ author: "gia", answer: "yes" }]);
});
