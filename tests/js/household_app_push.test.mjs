// The family room's notifications through Apple, straight or through the publisher's push
// relay, from deploy/openclaw/plugins/household-app.
//
// Run with `node --test tests/js/household_app_push.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createDecipheriv, createHash, generateKeyPairSync, randomBytes, verify } from "node:crypto";
import { test } from "node:test";

import {
  PLAIN_ALERT,
  createPhonePush,
  createPush,
  createRelaySender,
  decryptPayload,
  isWanted,
} from "../../deploy/openclaw/plugins/household-app/push.js";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const PRIVATE_KEY = privateKey.export({ format: "pem", type: "pkcs8" });
const START = Date.UTC(2026, 9, 14, 23, 0);

function fakeApple(status = 200, reason = undefined) {
  const sent = [];
  return {
    sent,
    async send(request) {
      sent.push(request);
      return { status, body: reason ? JSON.stringify({ reason }) : "" };
    },
  };
}

function push(apple, clock = { now: START }) {
  return createPush({
    keyId: "ABC123DEFG",
    teamId: "TEAM123456",
    privateKey: PRIVATE_KEY,
    topic: "com.siqstack.stewardai",
    transport: apple,
    now: () => clock.now,
  });
}

const DEVICE_KEY = randomBytes(32).toString("base64");
const PHONE = { token: "a".repeat(64), environment: "production", key: DEVICE_KEY };
const NOTE = { conversation: "family", messageId: "m-1", sender: "gia", title: "Gia", body: "Corey, are we out of milk?" };

test("Apple is told only that there is a new message", async () => {
  const apple = fakeApple();
  await push(apple).notify([PHONE], NOTE);
  const body = apple.sent[0].body;
  assert.equal(body.includes("milk"), false);
  assert.equal(body.includes("Gia"), false);
  const payload = JSON.parse(body);
  assert.deepEqual(payload.aps.alert, { title: "Steward AI", body: "New message" });
  assert.equal(payload.aps["mutable-content"], 1);
  assert.equal(payload.aps["thread-id"], "family");
});

// The extension needs mutable-content to run, the thread to stack by conversation, and
// the category for the reply and the reactions. Who wrote it is sealed with the words.
test("in the clear there is only the plain alert, how to show it, and the sealed part", async () => {
  const apple = fakeApple();
  await push(apple).notify([PHONE, { ...PHONE, token: "b".repeat(64) }], NOTE);
  await push(apple).notify([PHONE], { ...NOTE, conversation: "direct", sender: "corey", title: "Corey" });
  const [family, , direct] = apple.sent.map((request) => JSON.parse(request.body));
  assert.deepEqual(Object.keys(family).sort(), ["aps", "e"]);
  assert.deepEqual(family.aps, {
    alert: { title: "Steward AI", body: "New message" },
    sound: "default",
    "mutable-content": 1,
    "thread-id": "family",
    category: "family-message",
  });
  assert.equal(direct.aps["thread-id"], "direct");
  assert.equal(direct.aps.category, "direct-message");
});

// A scheduled reminder gets through a Focus, which the app's Time Sensitive entitlement
// allows. Every other message keeps the plain alert above.
test("a reminder's push is time sensitive, and only a reminder's", async () => {
  const apple = fakeApple();
  await push(apple).notify([PHONE], { ...NOTE, conversation: "direct", sender: "corey", title: "Corey", isTimeSensitive: true });
  await push(apple).notify([PHONE], NOTE);
  const [reminder, message] = apple.sent.map((request) => JSON.parse(request.body));
  assert.equal(reminder.aps["interruption-level"], "time-sensitive");
  assert.equal("interruption-level" in message.aps, false);
  assert.equal("isTimeSensitive" in decryptPayload(reminder.e, DEVICE_KEY), false);
});

test("the phone's own key opens who said what", async () => {
  const apple = fakeApple();
  await push(apple).notify([PHONE], NOTE);
  const payload = JSON.parse(apple.sent[0].body);
  assert.deepEqual(decryptPayload(payload.e, DEVICE_KEY), {
    conversation: "family",
    messageId: "m-1",
    sender: "gia",
    title: "Gia",
    body: "Corey, are we out of milk?",
  });
});

test("the sealed words are AES-256-GCM: nonce, then ciphertext, then tag", async () => {
  const apple = fakeApple();
  await push(apple).notify([PHONE], NOTE);
  const sealed = Buffer.from(JSON.parse(apple.sent[0].body).e, "base64");
  const decipher = createDecipheriv("aes-256-gcm", Buffer.from(DEVICE_KEY, "base64"), sealed.subarray(0, 12));
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  const opened = Buffer.concat([decipher.update(sealed.subarray(12, sealed.length - 16)), decipher.final()]);
  assert.equal(JSON.parse(opened.toString("utf8")).title, "Gia");
});

test("a long message is clipped before it is sealed", async () => {
  const apple = fakeApple();
  await push(apple).notify([PHONE], { ...NOTE, body: "x".repeat(5000) });
  const opened = decryptPayload(JSON.parse(apple.sent[0].body).e, DEVICE_KEY);
  assert.ok(opened.body.length <= 181);
  assert.ok(Buffer.byteLength(apple.sent[0].body) < 4096, "Apple's limit is 4 KB");
});

test("the request goes to the phone's environment with a signed token", async () => {
  const apple = fakeApple();
  await push(apple).notify([PHONE, { ...PHONE, token: "b".repeat(64), environment: "sandbox" }], NOTE);
  assert.deepEqual(apple.sent.map((request) => request.host), ["api.push.apple.com", "api.sandbox.push.apple.com"]);
  const request = apple.sent[0];
  assert.equal(request.path, `/3/device/${"a".repeat(64)}`);
  assert.equal(request.headers["apns-topic"], "com.siqstack.stewardai");
  assert.equal(request.headers["apns-push-type"], "alert");
  const [header, claims, signature] = request.headers.authorization.replace(/^bearer /, "").split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url")), { iss: "TEAM123456", iat: START / 1000 });
  assert.equal(
    verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")),
    true,
  );
});

test("the token is reused for forty minutes, then made again", async () => {
  const apple = fakeApple();
  const clock = { now: START };
  const sender = push(apple, clock);
  await sender.notify([PHONE], NOTE);
  clock.now += 39 * 60_000;
  await sender.notify([PHONE], NOTE);
  clock.now += 2 * 60_000;
  await sender.notify([PHONE], NOTE);
  const tokens = apple.sent.map((request) => request.headers.authorization);
  assert.equal(tokens[0], tokens[1]);
  assert.notEqual(tokens[1], tokens[2]);
});

for (const [status, reason] of [[410, "Unregistered"], [400, "BadDeviceToken"]]) {
  test(`Apple's ${reason} marks the phone's token as gone`, async () => {
    const results = await push(fakeApple(status, reason)).notify([PHONE], NOTE);
    assert.deepEqual(results, [{ token: PHONE.token, ok: false, gone: true, reason }]);
  });
}

test("any other refusal is reported and keeps the token", async () => {
  const results = await push(fakeApple(429, "TooManyRequests")).notify([PHONE], NOTE);
  assert.deepEqual(results, [{ token: PHONE.token, ok: false, gone: false, reason: "TooManyRequests" }]);
});

test("a transport failure is reported and keeps the token", async () => {
  const sender = createPush({
    keyId: "ABC123DEFG",
    teamId: "TEAM123456",
    privateKey: PRIVATE_KEY,
    topic: "com.siqstack.stewardai",
    transport: { async send() { throw new Error("connect ETIMEDOUT"); } },
    now: () => START,
  });
  assert.deepEqual(await sender.notify([PHONE], NOTE), [{ token: PHONE.token, ok: false, gone: false, reason: "connect ETIMEDOUT" }]);
});

test("a phone whose key is not 32 bytes gets nothing sealed for it", async () => {
  const apple = fakeApple();
  const results = await push(apple).notify([{ ...PHONE, key: "AAAA" }], NOTE);
  assert.equal(apple.sent.length, 0);
  assert.deepEqual(results, [{ token: PHONE.token, ok: false, gone: true, reason: "bad device key" }]);
});

// MARK: - Each phone's choice for a conversation

const NAMED = { ...NOTE, body: "Corey, are we out of milk?", mentions: ["Gia", "Denise"] };

for (const [choice, body, isTold] of [
  [undefined, "anything at all", true],
  ["all", "anything at all", true],
  ["off", "Gia, dinner is ready", false],
  ["mentions", "@Gia, dinner is ready", true],
  ["mentions", "ask @denise about it", true],
  ["mentions", "Gia, dinner is ready", false],
  ["mentions", "@Corey, are we out of milk?", false],
  ["mentions", "@Giant pumpkins on sale", false],
]) {
  test(`a phone that chose ${choice ?? "nothing"} is ${isTold ? "" : "not "}told about "${body}"`, async () => {
    const apple = fakeApple();
    const phone = { ...PHONE, notifications: choice ? { family: choice } : {} };
    await push(apple).notify([phone], { ...NAMED, body });
    assert.equal(apple.sent.length, isTold ? 1 : 0);
  });
}

test("a choice for one conversation leaves the other as it was", async () => {
  const apple = fakeApple();
  const phone = { ...PHONE, notifications: { family: "off" } };
  await push(apple).notify([phone], { ...NAMED, conversation: "direct" });
  assert.equal(apple.sent.length, 1);
});

test("each phone is told by its own choice", async () => {
  const apple = fakeApple();
  const quiet = { ...PHONE, token: "b".repeat(64), notifications: { family: "off" } };
  const results = await push(apple).notify([PHONE, quiet], NAMED);
  assert.deepEqual(apple.sent.map((request) => request.path), [`/3/device/${"a".repeat(64)}`]);
  assert.deepEqual(results.map((result) => result.token), [PHONE.token]);
});

test("whether a phone wants a message is decided the same way outside the sender", () => {
  assert.equal(isWanted({ notifications: { family: "mentions" } }, { ...NAMED, body: "@Denise?" }), true);
  assert.equal(isWanted({ notifications: { family: "mentions" } }, { ...NAMED, body: "Voice note" }), false);
});

// MARK: - Through the publisher's push relay, for a box without the Apple key

const RELAY_KEYS = generateKeyPairSync("ed25519");
const RELAY_PRIVATE = RELAY_KEYS.privateKey.export({ format: "pem", type: "pkcs8" });

function fakeRelay(reply = { status: 200, body: { status: 200 } }) {
  const calls = [];
  return {
    calls,
    async fetch(url, options) {
      calls.push({ url, options });
      const { status, body } = typeof reply === "function" ? reply(calls.length) : reply;
      return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
    },
  };
}

function relayPush(relay, clock = { now: START }) {
  return createPush({
    sender: createRelaySender({
      url: "https://push.example.com/",
      household: "marina-steve",
      privateKey: RELAY_PRIVATE,
      fetch: relay.fetch,
      now: () => clock.now,
    }),
  });
}

test("the relay is handed what Apple would have been, signed with the household's key", async () => {
  const relay = fakeRelay();
  const results = await relayPush(relay).notify([PHONE], NOTE);
  assert.deepEqual(results, [{ token: PHONE.token, ok: true }]);
  const [{ url, options }] = relay.calls;
  assert.equal(url, "https://push.example.com/v1/push");
  assert.equal(options.method, "POST");
  const sent = JSON.parse(options.body);
  assert.deepEqual(Object.keys(sent).sort(), ["collapseId", "environment", "payload", "token"]);
  assert.equal(sent.token, PHONE.token);
  assert.equal(sent.collapseId, "m-1");
  assert.deepEqual(sent.payload.aps.alert, PLAIN_ALERT);
  assert.equal(options.body.includes("milk"), false);
  assert.deepEqual(decryptPayload(sent.payload.e, DEVICE_KEY).body, "Corey, are we out of milk?");
  const { "x-household": household, "x-timestamp": timestamp, "x-signature": signature } = options.headers;
  assert.equal(household, "marina-steve");
  assert.equal(timestamp, String(START));
  const digest = createHash("sha256").update(options.body).digest("hex");
  assert.equal(verify(null, Buffer.from(`marina-steve\n${START}\n${digest}`), RELAY_KEYS.publicKey, Buffer.from(signature, "base64")), true);
});

test("the relay's notification is the same one the Apple key would have sent", async () => {
  const apple = fakeApple();
  const relay = fakeRelay();
  await push(apple).notify([PHONE], NOTE);
  await relayPush(relay).notify([PHONE], NOTE);
  const direct = JSON.parse(apple.sent[0].body);
  const relayed = JSON.parse(relay.calls[0].options.body).payload;
  assert.deepEqual(relayed.aps, direct.aps);
  assert.deepEqual(Object.keys(relayed).sort(), Object.keys(direct).sort());
});

for (const [status, reason] of [[410, "Unregistered"], [400, "BadDeviceToken"]]) {
  test(`Apple's ${reason} through the relay still marks the phone's token as gone`, async () => {
    const results = await relayPush(fakeRelay({ status: 200, body: { status, reason } })).notify([PHONE], NOTE);
    assert.deepEqual(results, [{ token: PHONE.token, ok: false, gone: true, reason }]);
  });
}

for (const [status, reason] of [[403, "the household is not let in"], [429, "the household has sent too many for now"], [410, "nothing"], [502, "Apple could not be reached"]]) {
  test(`the relay's own ${status} keeps the phone's token`, async () => {
    const results = await relayPush(fakeRelay({ status, body: { reason } })).notify([PHONE], NOTE);
    assert.deepEqual(results, [{ token: PHONE.token, ok: false, gone: false, reason: `the push relay refused it: ${reason}` }]);
  });
}

test("a relay that answers with something not JSON keeps the token", async () => {
  const results = await relayPush(fakeRelay({ status: 502, body: "<html>Bad Gateway</html>" })).notify([PHONE], NOTE);
  assert.deepEqual(results, [{ token: PHONE.token, ok: false, gone: false, reason: "the push relay refused it: HTTP 502" }]);
});

test("a relay that cannot be reached keeps the token", async () => {
  const sender = createRelaySender({
    url: "https://push.example.com",
    household: "marina-steve",
    privateKey: RELAY_PRIVATE,
    fetch: async () => { throw new Error("fetch failed"); },
  });
  assert.deepEqual(await createPush({ sender }).notify([PHONE], NOTE), [{ token: PHONE.token, ok: false, gone: false, reason: "fetch failed" }]);
});

test("each request is signed afresh, so none is the same as another", async () => {
  const relay = fakeRelay();
  const clock = { now: START };
  const sender = relayPush(relay, clock);
  await sender.notify([PHONE], NOTE);
  clock.now += 1;
  await sender.notify([PHONE], NOTE);
  const [first, second] = relay.calls.map((call) => call.options.headers["x-signature"]);
  assert.notEqual(first, second);
});

test("a key that is not Ed25519 is refused before anything is sent", () => {
  assert.throws(
    () => createRelaySender({ url: "https://push.example.com", household: "marina-steve", privateKey: PRIVATE_KEY }),
    /not an Ed25519 key/,
  );
});

test("the relay is asked once whether it knows the household", async () => {
  const known = createRelaySender({ url: "https://push.example.com", household: "marina-steve", privateKey: RELAY_PRIVATE, fetch: fakeRelay({ status: 200, body: { ok: true } }).fetch });
  const unknown = createRelaySender({ url: "https://push.example.com", household: "marina-steve", privateKey: RELAY_PRIVATE, fetch: fakeRelay({ status: 403, body: { reason: "the household is not let in" } }).fetch });
  assert.deepEqual(await known.check(), { ok: true });
  assert.deepEqual(await unknown.check(), { ok: false, reason: "the household is not let in" });
});

// MARK: - Which way this gateway reaches Apple

function recordingLog() {
  const lines = [];
  return { lines, info: (line) => lines.push(["info", line]), warn: (line) => lines.push(["warn", line]) };
}

const APPLE_ENVIRONMENT = {
  HOUSEHOLD_APNS_KEY_ID: "ABC123DEFG",
  HOUSEHOLD_APNS_TEAM_ID: "TEAM123456",
  HOUSEHOLD_APNS_PRIVATE_KEY: PRIVATE_KEY.replaceAll("\n", "\\n"),
};
const RELAY_CONFIG = { push: { relay: { url: "https://push.example.com", household: "marina-steve" } } };
const RELAY_ENVIRONMENT = { HOUSEHOLD_PUSH_RELAY_KEY: RELAY_PRIVATE.replaceAll("\n", "\\n") };

test("a box with the Apple key sends to Apple itself, relay or not", async () => {
  const apple = fakeApple();
  const relay = fakeRelay();
  const log = recordingLog();
  const phonePush = createPhonePush({ config: RELAY_CONFIG, environment: { ...APPLE_ENVIRONMENT, ...RELAY_ENVIRONMENT }, log, fetch: relay.fetch, transport: apple });
  await phonePush.notify([PHONE], NOTE);
  assert.equal(apple.sent.length, 1);
  assert.equal(relay.calls.length, 0);
  assert.equal(apple.sent[0].headers["apns-topic"], "com.siqstack.stewardai");
});

test("a box with the relay's key and the relay named sends through the relay, and says whether it is let in", async () => {
  const relay = fakeRelay((call) => (call === 1 ? { status: 200, body: { ok: true, household: "marina-steve" } } : { status: 200, body: { status: 200 } }));
  const log = recordingLog();
  const phonePush = createPhonePush({ config: RELAY_CONFIG, environment: RELAY_ENVIRONMENT, log, fetch: relay.fetch });
  await phonePush.notify([PHONE], NOTE);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(relay.calls.map((call) => new URL(call.url).pathname).sort(), ["/v1/check", "/v1/push"]);
  assert.deepEqual(log.lines, [["info", "household-app: phones are notified through the push relay at https://push.example.com"]]);
});

test("a relay that does not let the household in yet is said in the log", async () => {
  const log = recordingLog();
  createPhonePush({ config: RELAY_CONFIG, environment: RELAY_ENVIRONMENT, log, fetch: fakeRelay({ status: 403, body: { reason: "the household is not let in" } }).fetch });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(log.lines.length, 1);
  assert.equal(log.lines[0][0], "warn");
  assert.match(log.lines[0][1], /does not let in marina-steve yet \(the household is not let in\)/);
});

for (const [name, config, environment, level, words] of [
  ["neither key", {}, {}, "info", /no Apple push key/],
  ["the relay named without its key", RELAY_CONFIG, {}, "warn", /HOUSEHOLD_PUSH_RELAY_KEY is not in the environment/],
  ["a relay key that is not Ed25519", RELAY_CONFIG, { HOUSEHOLD_PUSH_RELAY_KEY: PRIVATE_KEY.replaceAll("\n", "\\n") }, "warn", /cannot be used/],
]) {
  test(`a box with ${name} notifies no phone and says so once`, () => {
    const log = recordingLog();
    assert.equal(createPhonePush({ config, environment, log }), null);
    assert.equal(log.lines.length, 1);
    assert.equal(log.lines[0][0], level);
    assert.match(log.lines[0][1], words);
  });
}
