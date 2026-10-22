// Sign in with Apple for the app, from deploy/openclaw/plugins/household-app/apple-signin.js:
// a phone pairs with no Telegram once its person's Apple ID is known to their gateway.
//
// Apple's keys are replaced with one made here, so these tests sign their own identity
// tokens and nothing reaches Apple.
//
// Run with `node --test tests/js/household_app_apple.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import {
  APPLE_ISSUER,
  APP_AUDIENCE,
  approvalText,
  createAppleKeys,
  createAppleSignIn,
  createNonces,
  verifyAppleToken,
} from "../../deploy/openclaw/plugins/household-app/apple-signin.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";

const NOW = Date.UTC(2026, 9, 15, 5, 0);
const DAY = 24 * 60 * 60_000;
const APPLE = generateKeyPairSync("rsa", { modulusLength: 2048 });
const STRANGER = generateKeyPairSync("rsa", { modulusLength: 2048 });
const KEYS = [{ ...APPLE.publicKey.export({ format: "jwk" }), kid: "apple-1", alg: "RS256", use: "sig" }];
const FRANCO_APPLE = "001234.franco-apple-id";
const GIA_APPLE = "001234.gia-apple-id";

const sha256 = (text) => createHash("sha256").update(text).digest("hex");
const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

function token(claims = {}, { key = APPLE.privateKey, kid = "apple-1", alg = "RS256" } = {}) {
  const head = part({ kid, alg });
  const body = part({
    iss: APPLE_ISSUER,
    aud: APP_AUDIENCE,
    exp: NOW / 1000 + 600,
    iat: NOW / 1000 - 5,
    sub: FRANCO_APPLE,
    nonce: sha256("raw-nonce"),
    email: "hidden@privaterelay.appleid.com",
    ...claims,
  });
  const signature = sign("RSA-SHA256", Buffer.from(`${head}.${body}`), key).toString("base64url");
  return `${head}.${body}.${signature}`;
}

test("a token Apple signed for this app, with this nonce, says who signed in", () => {
  const claims = verifyAppleToken({ token: token(), rawNonce: "raw-nonce", keys: KEYS, now: () => NOW });
  assert.equal(claims.sub, FRANCO_APPLE);
});

for (const [name, made, rawNonce] of [
  ["a signature from another key", () => token({}, { key: STRANGER.privateKey }), "raw-nonce"],
  ["an unknown key id", () => token({}, { kid: "nobody" }), "raw-nonce"],
  ["another algorithm", () => token({}, { alg: "HS256" }), "raw-nonce"],
  ["another app as the audience", () => token({ aud: "com.example.other" }), "raw-nonce"],
  ["another issuer", () => token({ iss: "https://example.com" }), "raw-nonce"],
  ["an expired token", () => token({ exp: NOW / 1000 - 120 }), "raw-nonce"],
  ["a token from the future", () => token({ iat: NOW / 1000 + 600 }), "raw-nonce"],
  ["another nonce", () => token(), "other-nonce"],
  ["no subject", () => token({ sub: "" }), "raw-nonce"],
  ["a malformed token", () => "not.a-token", "raw-nonce"],
]) {
  test(`${name} is refused`, () => {
    assert.throws(() => verifyAppleToken({ token: made(), rawNonce, keys: KEYS, now: () => NOW }), { code: "INVALID_REQUEST" });
  });
}

test("a nonce works once and only while fresh", () => {
  let clock = NOW;
  const nonces = createNonces({ now: () => clock });
  const { nonce } = nonces.issue();
  assert.equal(nonces.consume(nonce), true);
  assert.equal(nonces.consume(nonce), false);
  const late = nonces.issue().nonce;
  clock += 11 * 60_000;
  assert.equal(nonces.consume(late), false);
  assert.equal(nonces.consume("never-issued"), false);
});

// One gateway's sign-in, on a real room store. Franco's phone key is "franco-key", and
// a signature is faked as the key and the text it signs.
async function gateway({ owner = "franco", peer = "gia", approverKeys = ["franco-key"], clock = { now: NOW } } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-apple-"));
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const nonces = createNonces({ now: () => clock.now });
  const issued = [];
  let changes = 0;
  let ids = 0;
  let tickets = 0;
  const signIn = createAppleSignIn({
    owner: { id: owner },
    peer: { id: peer },
    approver: "franco",
    store,
    nonces,
    keys: async () => KEYS,
    issueCode: async () => {
      issued.push(owner);
      return { code: `${owner}-setup-code-${issued.length}`, expiresAtMs: clock.now + 600_000 };
    },
    approverKeys: async () => approverKeys,
    isSignedBy: (text, signature, keys) => keys.some((key) => signature === `${key}:${text}`),
    changed: () => {
      changes += 1;
    },
    makeId: () => `${owner}-req-${++ids}`,
    makeTicket: () => `${owner}-ticket-${++tickets}`,
    now: () => clock.now,
  });
  // A phone signing in with Apple as `sub`, with a nonce this gateway issued.
  const signInAs = (sub) => {
    const { nonce } = nonces.issue();
    return { identityToken: token({ sub, nonce: sha256(nonce), iat: clock.now / 1000 - 5, exp: clock.now / 1000 + 600 }), nonce };
  };
  return { signIn, store, nonces, issued, signInAs, changes: () => changes };
}

const approval = (requestId, person, { key = "franco-key", at = NOW } = {}) => ({
  requestId,
  person,
  at,
  signature: `${key}:${approvalText({ requestId, person, at })}`,
});

test("a phone whose Apple ID is linked to this gateway's person gets a setup code", async () => {
  const { signIn, store, signInAs } = await gateway();
  store.linkApple({ sub: FRANCO_APPLE, person: "franco", at: NOW });
  const answer = await signIn.pair(signInAs(FRANCO_APPLE));
  assert.deepEqual(answer, { setupCode: "franco-setup-code-1", expiresAtMs: NOW + 600_000 });
});

test("an Apple ID this gateway does not know waits with a ticket, and gets no code", async () => {
  const { signIn, issued, signInAs, changes } = await gateway();
  const answer = await signIn.pair({ ...signInAs(GIA_APPLE), name: "Gia's new iPhone" });
  assert.deepEqual(answer, { waiting: true, requestId: "franco-req-1", ticket: "franco-ticket-1" });
  assert.deepEqual(issued, []);
  assert.deepEqual(signIn.waiting(), [{ id: "franco-req-1", name: "Gia's new iPhone", at: NOW, person: "franco" }]);
  assert.equal(changes(), 1);
});

test("a name a phone sends that is not plain text is replaced", async () => {
  const { signIn, signInAs } = await gateway();
  await signIn.pair({ ...signInAs(GIA_APPLE), name: "two\nlines" });
  assert.equal(signIn.waiting()[0].name, "A new iPhone");
});

test("an Apple ID is never matched by its email", async () => {
  const { signIn, store, signInAs } = await gateway();
  store.linkApple({ sub: "001234.someone-else", person: "franco", at: NOW });
  const answer = await signIn.pair(signInAs(FRANCO_APPLE));
  assert.equal(answer.waiting, true);
});

test("a pairing without a nonce this gateway issued is refused before Apple's token is read", async () => {
  const { signIn } = await gateway();
  await assert.rejects(signIn.pair({ identityToken: token(), nonce: "raw-nonce" }), { code: "INVALID_REQUEST" });
});

test("a phone already paired links its person's Apple ID in one step", async () => {
  const { signIn, store, signInAs } = await gateway();
  assert.deepEqual(await signIn.link(signInAs(FRANCO_APPLE)), { linked: true });
  assert.equal(store.personForApple(FRANCO_APPLE), "franco");
});

test("a waiting phone collects its setup code once, after the approver says yes", async () => {
  const { signIn, store, signInAs } = await gateway();
  const { requestId, ticket } = await signIn.pair(signInAs(FRANCO_APPLE));
  assert.deepEqual(await signIn.status({ requestId, ticket }), { waiting: true });
  assert.deepEqual(await signIn.approve(approval(requestId, "franco")), { approved: true });
  assert.equal(store.personForApple(FRANCO_APPLE), "franco");
  assert.deepEqual(signIn.waiting(), []);
  assert.deepEqual(await signIn.status({ requestId, ticket }), { setupCode: "franco-setup-code-1", expiresAtMs: NOW + 600_000 });
  await assert.rejects(signIn.status({ requestId, ticket }), { code: "INVALID_REQUEST" });
});

for (const [name, change] of [
  ["a ticket the phone was not given", { ticket: "guessed" }],
  ["no ticket", { ticket: undefined }],
  ["a request that is not waiting", { requestId: "franco-req-99" }],
]) {
  test(`asking after a sign-in with ${name} is refused`, async () => {
    const { signIn, signInAs } = await gateway();
    const waiting = await signIn.pair(signInAs(FRANCO_APPLE));
    await assert.rejects(signIn.status({ requestId: waiting.requestId, ticket: waiting.ticket, ...change }), { code: "INVALID_REQUEST" });
  });
}

test("the same Apple ID asking again keeps one request, answered to the newest ticket", async () => {
  const { signIn, signInAs } = await gateway();
  const first = await signIn.pair(signInAs(GIA_APPLE));
  const again = await signIn.pair(signInAs(GIA_APPLE));
  assert.equal(again.requestId, first.requestId);
  assert.equal(signIn.waiting().length, 1);
  await assert.rejects(signIn.status(first), { code: "INVALID_REQUEST" });
  assert.deepEqual(await signIn.status(again), { waiting: true });
});

test("no more than eight sign-ins wait at once, and one waits a day at most", async () => {
  const clock = { now: NOW };
  const { signIn, signInAs } = await gateway({ clock });
  for (let index = 0; index < 8; index += 1) await signIn.pair(signInAs(`001234.stranger-${index}`));
  await assert.rejects(signIn.pair(signInAs("001234.stranger-9")), { code: "INVALID_REQUEST" });
  clock.now += 24 * 60 * 60_000 + 1;
  assert.equal((await signIn.pair(signInAs("001234.stranger-9"))).waiting, true);
  assert.equal(signIn.waiting().length, 1);
});

test("a sign-in waiting on the other gateway reaches the approver and his approval lets it in", async () => {
  const franco = await gateway({ owner: "franco", peer: "gia" });
  const gia = await gateway({ owner: "gia", peer: "franco" });

  const { requestId, ticket } = await gia.signIn.pair({ ...gia.signInAs(GIA_APPLE), name: "Gia's iPhone" });
  assert.deepEqual(gia.signIn.waiting(), [], "only the approver lists sign-ins");
  await franco.signIn.acceptPeer(gia.signIn.outbox());
  assert.deepEqual(franco.signIn.waiting(), [{ id: requestId, name: "Gia's iPhone", at: NOW, person: "gia" }]);

  await franco.signIn.approve(approval(requestId, "gia"));
  assert.deepEqual(franco.signIn.outbox().approvals, [approval(requestId, "gia")]);
  await gia.signIn.acceptPeer(franco.signIn.outbox());
  assert.equal(gia.store.personForApple(GIA_APPLE), "gia");
  assert.deepEqual(await gia.signIn.status({ requestId, ticket }), { setupCode: "gia-setup-code-1", expiresAtMs: NOW + 600_000 });

  await franco.signIn.acceptPeer(gia.signIn.outbox());
  assert.deepEqual(franco.signIn.waiting(), []);
  assert.deepEqual(franco.signIn.outbox().approvals, []);
});

for (const [name, made] of [
  ["signed by a key that is not the approver's", (requestId) => approval(requestId, "gia", { key: "gia-key" })],
  ["for another person", (requestId) => approval(requestId, "franco")],
  ["for a request that is not waiting", () => approval("gia-req-99", "gia")],
  ["older than a day", (requestId) => approval(requestId, "gia", { at: NOW - DAY - 1 })],
  ["with no request id", () => ({ ...approval("gia-req-1", "gia"), requestId: undefined })],
]) {
  test(`a relayed approval ${name} lets nobody in`, async () => {
    const gia = await gateway({ owner: "gia", peer: "franco" });
    const { requestId, ticket } = await gia.signIn.pair(gia.signInAs(GIA_APPLE));
    await gia.signIn.acceptPeer({ approvals: [made(requestId)] });
    assert.equal(gia.store.personForApple(GIA_APPLE), null);
    assert.deepEqual(await gia.signIn.status({ requestId, ticket }), { waiting: true });
  });
}

test("only the approver may approve", async () => {
  const gia = await gateway({ owner: "gia", peer: "franco" });
  const { requestId } = await gia.signIn.pair(gia.signInAs(GIA_APPLE));
  await assert.rejects(gia.signIn.approve(approval(requestId, "gia")), { code: "INVALID_REQUEST" });
});

for (const [name, made] of [
  ["not signed by his phone", () => approval("gia-req-1", "gia", { key: "gia-key" })],
  ["for a sign-in the other gateway never listed", () => approval("gia-req-7", "gia")],
  ["for somebody outside the household", () => approval("gia-req-1", "stranger")],
]) {
  test(`the approver's approval ${name} is refused`, async () => {
    const franco = await gateway();
    await franco.signIn.acceptPeer({ signIns: [{ id: "gia-req-1", name: "Gia's iPhone", at: NOW, person: "gia" }] });
    await assert.rejects(franco.signIn.approve(made()), { code: "INVALID_REQUEST" });
    assert.deepEqual(franco.signIn.outbox().approvals, []);
  });
}

test("sign-ins the other gateway lists for anyone but its own person, or malformed, are ignored", async () => {
  const franco = await gateway();
  await franco.signIn.acceptPeer({
    signIns: [
      { id: "gia-req-1", name: "Gia's iPhone", at: NOW, person: "gia" },
      { id: "gia-req-2", name: "Not Gia", at: NOW, person: "franco" },
      { id: "gia req 3", name: "Bad id", at: NOW, person: "gia" },
      { id: "gia-req-4", name: "two\nlines", at: NOW, person: "gia" },
      { id: "gia-req-5", name: "No time", person: "gia" },
      null,
    ],
  });
  assert.deepEqual(franco.signIn.waiting().map((request) => request.id), ["gia-req-1"]);
});

test("Apple's keys are fetched once an hour, and a failed fetch is not kept", async () => {
  const clock = { now: NOW };
  const answers = [new Error("offline"), KEYS, [{ kid: "apple-2" }]];
  let fetched = 0;
  const appleKeys = createAppleKeys({
    fetchKeys: async () => {
      const answer = answers[fetched++];
      if (answer instanceof Error) throw answer;
      return answer;
    },
    now: () => clock.now,
  });
  await assert.rejects(appleKeys());
  assert.deepEqual(await appleKeys(), KEYS);
  clock.now += 59 * 60_000;
  assert.deepEqual(await appleKeys(), KEYS);
  clock.now += 2 * 60_000;
  assert.deepEqual(await appleKeys(), [{ kid: "apple-2" }]);
  assert.equal(fetched, 3);
});

test("an answer from Apple with no key list is refused", async () => {
  const appleKeys = createAppleKeys({ fetchKeys: async () => undefined, now: () => NOW });
  await assert.rejects(appleKeys());
});
