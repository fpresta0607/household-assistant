// The family room's notifications through Apple, from deploy/openclaw/plugins/household-app.
//
// Run with `node --test tests/js/household_app_push.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createDecipheriv, generateKeyPairSync, randomBytes, verify } from "node:crypto";
import { test } from "node:test";

import { createPush, decryptPayload, isWanted } from "../../deploy/openclaw/plugins/household-app/push.js";

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
