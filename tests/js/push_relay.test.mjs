// The app publisher's push relay, deploy/push-relay: who it lets in, what it lets through
// to Apple, and its HTTP server and admin tool, with Apple faked.
//
// Run with `node --test tests/js/push_relay.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { createPush, createRelaySender, decryptPayload, pushPayload } from "../../deploy/openclaw/plugins/household-app/push.js";
import { addHousehold, fingerprint, listHouseholds, main as admin, publicKeyPem, removeHousehold } from "../../deploy/push-relay/admin.mjs";
import { BURST, WINDOW_MS, checkPush, createRelay, householdsFrom, parseHouseholds } from "../../deploy/push-relay/relay.mjs";
import { createRelayServer } from "../../deploy/push-relay/server.mjs";

const START = Date.UTC(2026, 9, 24, 18, 0);
const HOUSEHOLD = "marina-steve";
const KEYS = generateKeyPairSync("ed25519");
const PRIVATE = KEYS.privateKey.export({ format: "pem", type: "pkcs8" });
const PUBLIC = KEYS.publicKey.export({ format: "pem", type: "spki" });
const OTHER = generateKeyPairSync("ed25519");
const DEVICE_KEY = randomBytes(32).toString("base64");
const PHONE = { token: "a".repeat(64), environment: "production", key: DEVICE_KEY };
const NOTE = { conversation: "family", messageId: "m-1", sender: "steve", title: "Steve", body: "Home in ten" };

function fakeApple(status = 200, reason = undefined) {
  const sent = [];
  return {
    sent,
    async send(push) {
      sent.push(push);
      return status === 200 ? { status } : { status, reason };
    },
  };
}

function households(entries = { [HOUSEHOLD]: PUBLIC }) {
  return parseHouseholds(JSON.stringify({ households: Object.fromEntries(Object.entries(entries).map(([id, key]) => [id, { publicKey: key, enabled: true }])) }));
}

function relayWith({ apple = fakeApple(), clock = { now: START }, known = households(), ...options } = {}) {
  return { apple, clock, relay: createRelay({ households: () => known, sender: apple, now: () => clock.now, ...options }) };
}

function notification(overrides = {}) {
  return {
    token: PHONE.token,
    environment: "production",
    collapseId: "m-1",
    payload: pushPayload(NOTE, Buffer.from(DEVICE_KEY, "base64")),
    ...overrides,
  };
}

// A request as household-app's relay sender signs it.
function signed(value, { household = HOUSEHOLD, key = KEYS.privateKey, at = START } = {}) {
  const body = Buffer.from(typeof value === "string" ? value : JSON.stringify(value));
  const digest = createHash("sha256").update(body).digest("hex");
  const signature = sign(null, Buffer.from(`${household}\n${at}\n${digest}`), key).toString("base64");
  return { headers: { "x-household": household, "x-timestamp": String(at), "x-signature": signature }, body };
}

async function pushed(relay, value, options) {
  return relay.handle({ path: "/v1/push", ...signed(value, options) });
}

// MARK: - What is let through

test("a household's notification goes to Apple as it came, and Apple's answer comes back", async () => {
  const { relay, apple } = relayWith();
  const request = notification();
  assert.deepEqual(await pushed(relay, request), { status: 200, body: { status: 200 } });
  assert.deepEqual(apple.sent, [{ token: PHONE.token, environment: "production", collapseId: "m-1", body: JSON.stringify(request.payload) }]);
  assert.equal(decryptPayload(JSON.parse(apple.sent[0].body).e, DEVICE_KEY).body, "Home in ten");
});

test("a reminder's time-sensitive notification is let through", async () => {
  const { relay } = relayWith();
  const payload = pushPayload({ ...NOTE, conversation: "direct", isTimeSensitive: true }, Buffer.from(DEVICE_KEY, "base64"));
  assert.equal((await pushed(relay, notification({ payload }))).status, 200);
});

test("Apple's refusal comes back as Apple's, so the gateway forgets a phone that is gone", async () => {
  const { relay } = relayWith({ apple: fakeApple(410, "Unregistered") });
  assert.deepEqual(await pushed(relay, notification()), { status: 200, body: { status: 410, reason: "Unregistered" } });
});

test("Apple out of reach is the relay's 502", async () => {
  const apple = { async send() { throw new Error("connect ETIMEDOUT"); } };
  const { relay } = relayWith({ apple });
  assert.deepEqual(await pushed(relay, notification()), { status: 502, body: { reason: "Apple could not be reached" } });
});

// MARK: - Who is let in

test("a household the publisher did not let in is refused", async () => {
  const { relay, apple } = relayWith();
  const answer = await pushed(relay, notification(), { household: "someone-else", key: OTHER.privateKey });
  assert.deepEqual(answer, { status: 403, body: { reason: "the household is not let in" } });
  assert.equal(apple.sent.length, 0);
});

test("a request signed by any key but the household's is refused", async () => {
  const { relay, apple } = relayWith();
  assert.equal((await pushed(relay, notification(), { key: OTHER.privateKey })).status, 401);
  assert.equal(apple.sent.length, 0);
});

test("a body changed after it was signed is refused", async () => {
  const { relay, apple } = relayWith();
  const request = signed(notification());
  const changed = Buffer.from(request.body.toString("utf8").replace("a".repeat(64), "b".repeat(64)));
  assert.equal((await relay.handle({ path: "/v1/push", headers: request.headers, body: changed })).status, 401);
  assert.equal(apple.sent.length, 0);
});

test("a request with no signature, or one that is not base64 of 64 bytes, is refused", async () => {
  const { relay } = relayWith();
  const request = signed(notification());
  for (const signature of [undefined, "", "not base64 at all", Buffer.alloc(63).toString("base64")]) {
    const headers = { ...request.headers, "x-signature": signature };
    assert.equal((await relay.handle({ path: "/v1/push", headers, body: request.body })).status, 401);
  }
});

for (const [name, offset, status] of [
  ["just inside five minutes behind", -WINDOW_MS, 200],
  ["just inside five minutes ahead", WINDOW_MS, 200],
  ["more than five minutes behind", -WINDOW_MS - 1, 401],
  ["more than five minutes ahead", WINDOW_MS + 1, 401],
]) {
  test(`a request signed ${name} of the relay's clock is ${status === 200 ? "let through" : "refused"}`, async () => {
    const { relay } = relayWith();
    assert.equal((await pushed(relay, notification(), { at: START + offset })).status, status);
  });
}

test("the same request sent again is refused, however soon", async () => {
  const { relay, apple, clock } = relayWith();
  const request = signed(notification());
  assert.equal((await relay.handle({ path: "/v1/push", ...request })).status, 200);
  clock.now += 1000;
  assert.deepEqual(await relay.handle({ path: "/v1/push", ...request }), { status: 409, body: { reason: "the relay has had this request before" } });
  assert.equal(apple.sent.length, 1);
});

test("a request the relay saw is forgotten only once its clock check would refuse it anyway", async () => {
  const { relay, clock } = relayWith();
  const request = signed(notification(), { at: START + WINDOW_MS });
  assert.equal((await relay.handle({ path: "/v1/push", ...request })).status, 200);
  clock.now += 2 * WINDOW_MS - 1;
  assert.equal((await relay.handle({ path: "/v1/push", ...request })).status, 409);
  clock.now += 2;
  assert.equal((await relay.handle({ path: "/v1/push", ...request })).status, 401);
});

test("a household that has sent its share waits for the bucket to fill, and the others do not", async () => {
  const second = generateKeyPairSync("ed25519");
  const known = households({ [HOUSEHOLD]: PUBLIC, "ada-rex": second.publicKey.export({ format: "pem", type: "spki" }) });
  const { relay, clock } = relayWith({ known, burst: 2, perMinute: 60 });
  const send = (household = HOUSEHOLD, key = KEYS.privateKey) => pushed(relay, notification({ collapseId: `m-${clock.now}-${household}` }), { household, key, at: clock.now });
  assert.equal((await send()).status, 200);
  clock.now += 1;
  assert.equal((await send()).status, 200);
  clock.now += 1;
  assert.deepEqual(await send(), { status: 429, body: { reason: "the household has sent too many for now" } });
  assert.equal((await send("ada-rex", second.privateKey)).status, 200);
  clock.now += 1000;
  assert.equal((await send()).status, 200);
});

test("the bucket starts full at BURST", async () => {
  const { relay, clock } = relayWith();
  const answers = [];
  for (let index = 0; index <= BURST; index += 1) {
    answers.push((await pushed(relay, notification({ collapseId: `m-${index}` }), { at: clock.now })).status);
  }
  assert.deepEqual([...new Set(answers.slice(0, BURST))], [200]);
  assert.equal(answers.at(-1), 429);
});

test("a check answers whether the household is let in, without reaching Apple", async () => {
  const { relay, apple } = relayWith();
  assert.deepEqual(await relay.handle({ path: "/v1/check", ...signed({}) }), { status: 200, body: { ok: true, household: HOUSEHOLD } });
  assert.equal((await relay.handle({ path: "/v1/check", ...signed({}, { key: OTHER.privateKey }) })).status, 401);
  assert.equal(apple.sent.length, 0);
});

// MARK: - Only the shape push.js sends

const SHAPES = [
  ["a field beside the notification", (request) => ({ ...request, topic: "com.example.other" })],
  ["no token", ({ token, ...request }) => request],
  ["a token that is not hex", (request) => ({ ...request, token: "../../3/device/x".padEnd(64, "a") })],
  ["a token too short", (request) => ({ ...request, token: "a".repeat(10) })],
  ["an environment that is not one", (request) => ({ ...request, environment: "staging" })],
  ["a collapse id with a line break", (request) => ({ ...request, collapseId: "m-1\nx" })],
  ["a collapse id too long", (request) => ({ ...request, collapseId: "m".repeat(65) })],
  ["a different alert", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, alert: { title: "Steward AI", body: "Your account is locked" } } } })],
  ["an alert with a subtitle", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, alert: { ...request.payload.aps.alert, subtitle: "x" } } } })],
  ["an alert as a string", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, alert: "New message" } } })],
  ["a badge", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, badge: 99 } } })],
  ["a silent push", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, "content-available": 1 } } })],
  ["another sound", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, sound: "alarm.caf" } } })],
  ["no mutable content", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, "mutable-content": 0 } } })],
  ["a category not the thread's", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, category: "direct-message" } } })],
  ["a critical alert", (request) => ({ ...request, payload: { ...request.payload, aps: { ...request.payload.aps, "interruption-level": "critical" } } })],
  ["a field beside aps and the sealed part", (request) => ({ ...request, payload: { ...request.payload, url: "https://example.com" } })],
  ["words in the clear in place of the sealed part", (request) => ({ ...request, payload: { ...request.payload, e: "Steve: home in ten" } })],
  ["a sealed part too short to be sealed", (request) => ({ ...request, payload: { ...request.payload, e: Buffer.alloc(20).toString("base64") } })],
  ["a sealed part too long", (request) => ({ ...request, payload: { ...request.payload, e: "A".repeat(3004) } })],
  ["a payload that is a list", (request) => ({ ...request, payload: [] })],
];

for (const [name, change] of SHAPES) {
  test(`a notification with ${name} is refused`, async () => {
    const { relay, apple } = relayWith();
    const answer = await pushed(relay, change(notification()));
    assert.equal(answer.status, 400, JSON.stringify(answer));
    assert.equal(apple.sent.length, 0);
  });
}

test("a body that is not JSON is refused", async () => {
  const { relay } = relayWith();
  assert.deepEqual(await pushed(relay, "{not json"), { status: 400, body: { reason: "the request is not JSON" } });
});

test("what push.js builds is the shape the relay lets through, for every conversation", () => {
  for (const conversation of ["family", "direct", "pair"]) {
    const payload = pushPayload({ ...NOTE, conversation, body: "x".repeat(5000) }, Buffer.from(DEVICE_KEY, "base64"));
    assert.doesNotThrow(() => checkPush(notification({ payload })));
  }
});

// MARK: - The households file

test("only households let in with an Ed25519 key count", () => {
  const p256 = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({ format: "pem", type: "spki" });
  const warnings = [];
  const parsed = parseHouseholds(JSON.stringify({
    households: {
      [HOUSEHOLD]: { publicKey: PUBLIC, enabled: true },
      "switched-off": { publicKey: PUBLIC, enabled: false },
      "wrong-kind": { publicKey: p256 },
      "Not A Name": { publicKey: PUBLIC },
      "no-key": {},
    },
  }), { warn: (line) => warnings.push(line) });
  assert.deepEqual([...parsed.keys()], [HOUSEHOLD]);
  assert.equal(warnings.length, 2);
});

test("the households file is read again when it changes, and a missing one lets nobody in", () => {
  const folder = mkdtempSync(path.join(tmpdir(), "push-relay-"));
  const file = path.join(folder, "households.json");
  const current = householdsFrom(file, { warn() {} });
  assert.equal(current().size, 0);
  writeFileSync(file, JSON.stringify({ households: { [HOUSEHOLD]: { publicKey: PUBLIC } } }));
  assert.deepEqual([...current().keys()], [HOUSEHOLD]);
  writeFileSync(file, JSON.stringify({ households: { "ada-rex": { publicKey: PUBLIC }, [HOUSEHOLD]: { publicKey: PUBLIC } } }));
  assert.deepEqual([...current().keys()].sort(), ["ada-rex", HOUSEHOLD]);
  writeFileSync(file, "{ broken");
  assert.equal(current().size, 0);
});

// MARK: - The admin tool

test("a household is let in by the line its box printed, listed by fingerprint, and let go", () => {
  const folder = mkdtempSync(path.join(tmpdir(), "push-relay-admin-"));
  const file = path.join(folder, "etc", "households.json");
  const line = KEYS.publicKey.export({ format: "der", type: "spki" }).toString("base64");
  const print = addHousehold(file, HOUSEHOLD, line, { now: () => new Date(START) });
  assert.equal(print, fingerprint(PUBLIC));
  assert.equal(statSync(file).mode & 0o777, 0o644);
  const written = JSON.parse(readFileSync(file, "utf8"));
  assert.deepEqual(written, { households: { [HOUSEHOLD]: { publicKey: PUBLIC, enabled: true, added: "2026-10-24" } } });
  assert.deepEqual([...parseHouseholds(readFileSync(file, "utf8")).keys()], [HOUSEHOLD]);
  assert.deepEqual(listHouseholds(file), [{ household: HOUSEHOLD, enabled: true, added: "2026-10-24", fingerprint: print }]);
  assert.throws(() => addHousehold(file, HOUSEHOLD, line), /let in already; --replace/);
  const rotated = OTHER.publicKey.export({ format: "pem", type: "spki" });
  assert.equal(addHousehold(file, HOUSEHOLD, rotated, { replace: true }), fingerprint(rotated));
  removeHousehold(file, HOUSEHOLD);
  assert.deepEqual(listHouseholds(file), []);
  assert.throws(() => removeHousehold(file, HOUSEHOLD), /not let in/);
});

test("the admin tool refuses a key that is not Ed25519 and a name that is not one", () => {
  const file = path.join(mkdtempSync(path.join(tmpdir(), "push-relay-admin-")), "households.json");
  const p256 = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({ format: "pem", type: "spki" });
  assert.throws(() => publicKeyPem(p256), /not an Ed25519 public key/);
  assert.throws(() => addHousehold(file, "../etc", PUBLIC), /not a household name/);
  assert.throws(() => publicKeyPem("not a key"));
});

test("the admin tool's command line adds, lists and removes", () => {
  const file = path.join(mkdtempSync(path.join(tmpdir(), "push-relay-admin-")), "households.json");
  const lines = [];
  const out = (line) => lines.push(line);
  const line = KEYS.publicKey.export({ format: "der", type: "spki" }).toString("base64");
  assert.equal(admin(["add", HOUSEHOLD, line], { file, out }), 0);
  assert.equal(admin(["list"], { file, out }), 0);
  assert.equal(admin(["remove", HOUSEHOLD], { file, out }), 0);
  assert.match(lines[0], /^marina-steve is let in, key SHA256:/);
  assert.match(lines[1], /^marina-steve\tlet in\t\d{4}-\d{2}-\d{2}\tSHA256:/);
  assert.equal(lines[2], "marina-steve is let in no more");
  assert.equal(admin(["frobnicate"], { file, out }), 2);
});

// MARK: - The HTTP server, end to end with household-app's sender

async function serving(relay, options = {}) {
  const server = createRelayServer({ relay, ...options });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return { server, url: `http://127.0.0.1:${port}` };
}

test("a gateway's notification crosses the relay to Apple, and a phone Apple says is gone is forgotten", async () => {
  const apple = fakeApple();
  const live = createRelay({ households: () => households(), sender: apple });
  const { server, url } = await serving(live);
  try {
    const sender = createRelaySender({ url, household: HOUSEHOLD, privateKey: PRIVATE });
    assert.deepEqual(await sender.check(), { ok: true });
    assert.deepEqual(await createPush({ sender }).notify([PHONE], NOTE), [{ token: PHONE.token, ok: true }]);
    assert.equal(apple.sent.length, 1);
    assert.equal(decryptPayload(JSON.parse(apple.sent[0].body).e, DEVICE_KEY).title, "Steve");
    const gone = createRelay({ households: () => households(), sender: fakeApple(410, "Unregistered") });
    const second = await serving(gone);
    try {
      const goneSender = createRelaySender({ url: second.url, household: HOUSEHOLD, privateKey: PRIVATE });
      assert.deepEqual(await createPush({ sender: goneSender }).notify([PHONE], NOTE), [{ token: PHONE.token, ok: false, gone: true, reason: "Unregistered" }]);
    } finally {
      second.server.close();
    }
    const stranger = createRelaySender({ url, household: "someone-else", privateKey: OTHER.privateKey.export({ format: "pem", type: "pkcs8" }) });
    assert.deepEqual(await stranger.check(), { ok: false, reason: "the household is not let in" });
    assert.deepEqual(await createPush({ sender: stranger }).notify([PHONE], NOTE), [{ token: PHONE.token, ok: false, gone: false, reason: "the push relay refused it: the household is not let in" }]);
  } finally {
    server.close();
  }
});

test("the server answers its health, refuses other paths and methods, and a body past its bound", async () => {
  const { relay } = relayWith();
  const { server, url } = await serving(relay, { maxRequestBytes: 1024 });
  try {
    const health = await fetch(`${url}/healthz`);
    assert.deepEqual([health.status, await health.json()], [200, { ok: true }]);
    assert.equal((await fetch(`${url}/healthz`, { method: "POST" })).status, 405);
    assert.equal((await fetch(`${url}/v1/push`)).status, 405);
    assert.equal((await fetch(`${url}/v1/other`, { method: "POST", body: "{}" })).status, 404);
    const large = await fetch(`${url}/v1/push`, { method: "POST", body: "x".repeat(4096) });
    assert.deepEqual([large.status, await large.json()], [413, { reason: "the request is too large" }]);
  } finally {
    server.close();
  }
});
