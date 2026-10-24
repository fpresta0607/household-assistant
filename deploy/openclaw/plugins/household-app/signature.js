// What a person's phone signs when it says something, in the family room or its own thread,
// and the check a gateway makes before it believes the message came from that person. The
// other gateway checks a family message, and this one checks every message its owner
// sends, since the owner's own thread reaches the owner's private tools.
//
// Each phone already holds an Ed25519 key pair: the device identity it pairs with its
// own gateway by. A family message travels from that gateway to the other one through
// its share (share.js), and the share sits in a directory the sending assistant can
// write. So without a signature, an assistant that had been talked into
// it could put words in its own person's mouth for the other assistant, which then
// answers with the other person's tools. The phone signs, the receiving gateway checks
// against the keys the box pinned for that person when it set the room up, and an
// assistant that never holds the phone's private key cannot forge one.
//
// The signed text is one line per field, the message's own words last, so a newline in
// them cannot be read as a field boundary: every field before them is checked to have
// none.
//
// A map a person shares (map-share.js) is signed under a version line of its own, with
// its place and its end in place of the attachments, so a message signed without a place
// can never be given one and a map can never lose it.
//
// The end of a call with the assistant (call-log.js) is signed under a version line of its
// own too, naming the messages that were the call's, so only the owner's phone decides
// which of the owner's messages fold into it.

import { createPublicKey, verify } from "node:crypto";

export const SIGNATURE_VERSION = "household-app/v1";
export const MAP_SIGNATURE_VERSION = "household-app/map/v1";
export const CALL_SIGNATURE_VERSION = "household-app/call/v1";

// An Ed25519 public key in DER: this fixed prefix, then the raw 32 bytes the phone sends.
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const BASE64URL = /^[A-Za-z0-9_-]+$/;
const LINE_FREE = /^[^\r\n]*$/;

export function decodeBase64Url(text) {
  if (typeof text !== "string" || !BASE64URL.test(text)) return null;
  return Buffer.from(text, "base64url");
}

// The exact text the phone signs. Nil when a field could not be put on one line.
export function signedText({ conversation, id, at, replyTo, media, text, location }) {
  const head = [conversation, id, String(at), replyTo ?? ""];
  const fields = location
    ? [...head, ...[location.until ?? "", location.latitudeE6, location.longitudeE6, location.accuracy, location.at].map(String)]
    : [...head, (media ?? []).map((item) => item.id).join(",")];
  if (!fields.every((field) => typeof field === "string" && LINE_FREE.test(field))) return null;
  if (typeof text !== "string") return null;
  return [location ? MAP_SIGNATURE_VERSION : SIGNATURE_VERSION, ...fields, text].join("\n");
}

// The exact text the phone signs when a call ends, its turns' message ids on one line.
// Nothing in it can span a line: call-log.js checks every field before this is built.
export function callEndSignedText({ callId, startedAt, endedAt, turns }) {
  return [CALL_SIGNATURE_VERSION, callId, String(startedAt), String(endedAt), turns.join(",")].join("\n");
}

export function publicKeyFrom(raw) {
  const bytes = decodeBase64Url(raw);
  if (!bytes || bytes.length !== 32) return null;
  return createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, bytes]), format: "der", type: "spki" });
}

// True for a phone's public key as OpenClaw lists a paired device: 32 raw Ed25519 bytes
// as unpadded URL-safe base64.
export function isPhoneKey(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value) && publicKeyFrom(value) !== null;
}

// True when one of `publicKeys`, each the phone's unpadded URL-safe base64 raw key,
// signed exactly this message.
export function isSignedBy(message, signature, publicKeys) {
  const payload = signedText(message);
  return payload !== null && isTextSignedBy(payload, signature, publicKeys);
}

// The same check for any text a phone signs, such as the approver's approval of a sign-in.
export function isTextSignedBy(text, signature, publicKeys) {
  const signatureBytes = decodeBase64Url(signature);
  if (typeof text !== "string" || !signatureBytes || signatureBytes.length !== 64) return false;
  return (publicKeys ?? []).some((raw) => {
    const key = publicKeyFrom(raw);
    return key !== null && verify(null, Buffer.from(text, "utf8"), key, signatureBytes);
  });
}
