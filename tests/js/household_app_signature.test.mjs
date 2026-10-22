// The family room's message signatures, from deploy/openclaw/plugins/household-app.
//
// Run with `node --test tests/js/household_app_signature.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { test } from "node:test";

import {
  CALL_SIGNATURE_VERSION,
  callEndSignedText,
  isSignedBy,
  isTextSignedBy,
  publicKeyFrom,
  signedText,
} from "../../deploy/openclaw/plugins/household-app/signature.js";

function phone() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(12);
  return {
    publicKey: raw.toString("base64url"),
    sign: (text) => sign(null, Buffer.from(text, "utf8"), privateKey).toString("base64url"),
  };
}

const MESSAGE = {
  conversation: "family",
  id: "m-6f1d0c3e-1b2a-4c5d-9e8f-0a1b2c3d4e5f",
  at: 1792540800000,
  replyTo: null,
  media: [],
  text: "Corey, can you add milk to the list?\nAnd eggs.",
};

test("the signed text is one line per field with the words last", () => {
  assert.equal(
    signedText(MESSAGE),
    "household-app/v1\nfamily\nm-6f1d0c3e-1b2a-4c5d-9e8f-0a1b2c3d4e5f\n1792540800000\n\n\nCorey, can you add milk to the list?\nAnd eggs.",
  );
});

test("a field that would span two lines cannot be signed", () => {
  assert.equal(signedText({ ...MESSAGE, id: "m-1\nfamily" }), null);
  assert.equal(signedText({ ...MESSAGE, replyTo: "m-2\r" }), null);
  assert.equal(signedText({ ...MESSAGE, media: [{ id: "a\nb" }] }), null);
});

test("a message signed by the person's own phone is believed", () => {
  const franco = phone();
  const signature = franco.sign(signedText(MESSAGE));
  assert.equal(isSignedBy(MESSAGE, signature, [franco.publicKey]), true);
});

test("any one of the person's pinned phones may have signed it", () => {
  const old = phone();
  const current = phone();
  const signature = current.sign(signedText(MESSAGE));
  assert.equal(isSignedBy(MESSAGE, signature, [old.publicKey, current.publicKey]), true);
});

test("a signature from somebody else's phone is refused", () => {
  const franco = phone();
  const gia = phone();
  const signature = gia.sign(signedText(MESSAGE));
  assert.equal(isSignedBy(MESSAGE, signature, [franco.publicKey]), false);
});

for (const [name, change] of [
  ["the words", { text: "Corey, can you add beer to the list?\nAnd eggs." }],
  ["the id", { id: "m-6f1d0c3e-1b2a-4c5d-9e8f-0a1b2c3d4e60" }],
  ["the time", { at: 1792540800001 }],
  ["the conversation", { conversation: "direct" }],
  ["what it replies to", { replyTo: "m-0" }],
  ["the attachments", { media: [{ id: "a".repeat(64) }] }],
]) {
  test(`changing ${name} after signing breaks the signature`, () => {
    const franco = phone();
    const signature = franco.sign(signedText(MESSAGE));
    assert.equal(isSignedBy({ ...MESSAGE, ...change }, signature, [franco.publicKey]), false);
  });
}

for (const [name, signature, keys] of [
  ["no signature", undefined, ["A".repeat(43)]],
  ["a signature that is not base64url", "not a signature!", ["A".repeat(43)]],
  ["a short signature", "AAAA", ["A".repeat(43)]],
  ["no pinned keys", "A".repeat(86), []],
  ["a pinned key of the wrong length", "A".repeat(86), ["AAAA"]],
]) {
  test(`${name} is refused rather than thrown`, () => {
    assert.equal(isSignedBy(MESSAGE, signature, keys), false);
  });
}

test("a key of the wrong length is no key", () => {
  assert.equal(publicKeyFrom("AAAA"), null);
  assert.equal(publicKeyFrom(undefined), null);
});

test("any text a phone signs, such as an approval, is checked against that phone's key", () => {
  const franco = phone();
  const gia = phone();
  const approval = "household-app/apple-approve/v1\nreq-1\ngia\n1792540800000";
  assert.equal(isTextSignedBy(approval, franco.sign(approval), [franco.publicKey]), true);
  assert.equal(isTextSignedBy(approval, gia.sign(approval), [franco.publicKey]), false);
  assert.equal(isTextSignedBy(`${approval}0`, franco.sign(approval), [franco.publicKey]), false);
});

const CALL = {
  callId: "6f1d0c3e-1b2a-4c5d-9e8f-0a1b2c3d4e5f",
  startedAt: 1792540800000,
  endedAt: 1792541100000,
  turns: ["d-00000001", "a-00000002"],
};

test("a call's end is signed as its own version line, its times, and its turns on one line", () => {
  assert.equal(CALL_SIGNATURE_VERSION, "household-app/call/v1");
  assert.equal(
    callEndSignedText(CALL),
    "household-app/call/v1\n6f1d0c3e-1b2a-4c5d-9e8f-0a1b2c3d4e5f\n1792540800000\n1792541100000\nd-00000001,a-00000002",
  );
  assert.equal(callEndSignedText({ ...CALL, turns: [] }).split("\n").at(-1), "");
});

for (const [name, change] of [
  ["the turns", { turns: ["d-00000001", "a-00000002", "d-00000003"] }],
  ["the start", { startedAt: CALL.startedAt - 1 }],
  ["the end", { endedAt: CALL.endedAt + 1 }],
  ["the call", { callId: "6f1d0c3e-1b2a-4c5d-9e8f-0a1b2c3d4e60" }],
]) {
  test(`changing ${name} of a call's end after signing breaks the signature`, () => {
    const franco = phone();
    const signature = franco.sign(callEndSignedText(CALL));
    assert.equal(isTextSignedBy(callEndSignedText({ ...CALL, ...change }), signature, [franco.publicKey]), false);
  });
}
