// The push relay's decisions, apart from its HTTP server (server.mjs) so they can be tested
// without a socket.
//
// The relay is the app publisher's, and it holds the app's Apple push key so that no
// household's box has to. A household's gateways hand it notifications they have already
// built and sealed for each phone (household-app's push.js), each request signed with the
// household's own Ed25519 key, whose public half the publisher added to the households file
// (admin.mjs). What the relay passes to Apple is only what Apple would have seen from a box
// that held the key: the plain "New message" alert, how to show it, and the sealed part
// nobody but the phone can open.
//
// So a request is refused unless every one of these holds, in this order:
// - it names a household the publisher let in, and that household's key signed who it is,
//   when, and the body's hash;
// - it was signed within five minutes of the relay's clock, and the relay has not seen the
//   same signature before, so a captured request cannot be sent again later;
// - the household has not used up its share of the relay, a bucket of BURST requests that
//   fills again at PER_MINUTE a minute, so one household cannot spend Apple's patience for
//   the others;
// - the body is exactly the shape push.js sends. A household can then make the relay say
//   only "New message", and only to the phones that registered with its own gateways,
//   since a phone's token is not something anyone else is handed.
//
// Apple's answer goes back as it came, so a gateway still forgets a phone Apple says is
// gone. Nothing of a request is logged but the household, the outcome and the reason.

import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync, statSync } from "node:fs";

export const WINDOW_MS = 5 * 60_000;
export const PER_MINUTE = 120;
export const BURST = 60;
// The whole request: Apple's own limit for a notification is 4 KB, and the token, the
// collapse id and the JSON around them are well inside the rest.
export const MAX_REQUEST_BYTES = 8 * 1024;
const MAX_APPLE_BODY_BYTES = 4096;
const MAX_SEALED_CHARACTERS = 3000;
// The nonce and the tag of AES-256-GCM, with at least a byte between them.
const MIN_SEALED_BYTES = 12 + 16 + 1;
const PLAIN_ALERT = { title: "Steward AI", body: "New message" };
const HOUSEHOLD = /^[a-z][a-z0-9-]{0,31}$/;
const TOKEN = /^[0-9a-fA-F]{64,200}$/;
const CONVERSATION = /^[A-Za-z0-9_-]{1,64}$/;
const COLLAPSE_ID = /^[\x20-\x7e]{1,64}$/;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const ENVIRONMENTS = new Set(["production", "sandbox"]);
const PUSH_KEYS = ["collapseId", "environment", "payload", "token"];
const APS_REQUIRED = ["alert", "category", "mutable-content", "sound", "thread-id"];

class Refusal extends Error {
  constructor(status, reason) {
    super(reason);
    this.status = status;
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function sameKeys(value, keys) {
  return isPlainObject(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(",");
}

// The households the publisher let in, read again whenever the file changes. A household
// switched off, or whose key is not an Ed25519 public key, is not let in.
export function householdsFrom(file, { log } = {}) {
  let seen = null;
  let households = new Map();
  return function current() {
    let status;
    try {
      status = statSync(file);
    } catch {
      if (seen !== "missing") log?.warn?.(`push-relay: no households file at ${file}, so nobody is let in`);
      seen = "missing";
      households = new Map();
      return households;
    }
    const stamp = `${status.ino}:${status.size}:${status.mtimeMs}`;
    if (stamp === seen) return households;
    seen = stamp;
    households = parseHouseholds(readFileSync(file, "utf8"), log);
    return households;
  };
}

export function parseHouseholds(text, log) {
  const households = new Map();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    log?.warn?.("push-relay: the households file is not JSON, so nobody is let in");
    return households;
  }
  for (const [id, entry] of Object.entries(isPlainObject(parsed?.households) ? parsed.households : {})) {
    if (!HOUSEHOLD.test(id) || !isPlainObject(entry) || entry.enabled === false) continue;
    try {
      const key = createPublicKey(String(entry.publicKey));
      if (key.asymmetricKeyType !== "ed25519") throw new Error("not an Ed25519 key");
      households.set(id, key);
    } catch (error) {
      log?.warn?.(`push-relay: ${id}'s key cannot be used: ${error.message}`);
    }
  }
  return households;
}

// What may go to Apple for one phone: exactly the payload push.js builds.
export function checkPush(request) {
  if (!sameKeys(request, PUSH_KEYS)) throw new Refusal(400, "the request is not a notification");
  const { token, environment, collapseId, payload } = request;
  if (typeof token !== "string" || !TOKEN.test(token)) throw new Refusal(400, "the phone's token is not one");
  if (!ENVIRONMENTS.has(environment)) throw new Refusal(400, "the phone's environment is not one");
  if (typeof collapseId !== "string" || !COLLAPSE_ID.test(collapseId)) throw new Refusal(400, "the collapse id is not one");
  if (!sameKeys(payload, ["aps", "e"])) throw new Refusal(400, "the notification holds more than the alert and the sealed part");
  const { aps, e } = payload;
  const timeSensitive = isPlainObject(aps) && "interruption-level" in aps;
  if (!sameKeys(aps, timeSensitive ? [...APS_REQUIRED, "interruption-level"] : APS_REQUIRED)) {
    throw new Refusal(400, "the alert says how to show it with something else");
  }
  if (!sameKeys(aps.alert, ["title", "body"]) || aps.alert.title !== PLAIN_ALERT.title || aps.alert.body !== PLAIN_ALERT.body) {
    throw new Refusal(400, "the alert is not the plain one");
  }
  if (aps.sound !== "default" || aps["mutable-content"] !== 1) throw new Refusal(400, "the alert is not shown the app's way");
  const thread = aps["thread-id"];
  if (typeof thread !== "string" || !CONVERSATION.test(thread) || aps.category !== `${thread}-message`) {
    throw new Refusal(400, "the alert's conversation is not one");
  }
  if (timeSensitive && aps["interruption-level"] !== "time-sensitive") throw new Refusal(400, "the alert's interruption level is not allowed");
  if (typeof e !== "string" || e.length > MAX_SEALED_CHARACTERS || !BASE64.test(e) || Buffer.from(e, "base64").length < MIN_SEALED_BYTES) {
    throw new Refusal(400, "the sealed part is not one");
  }
  const body = JSON.stringify(payload);
  if (Buffer.byteLength(body) > MAX_APPLE_BODY_BYTES) throw new Refusal(400, "the notification is over Apple's size");
  return { token, environment, collapseId, body };
}

// `households()` answers the households let in, id to public key; `sender` is Apple's
// (household-app's apple-push.js), `send({ token, environment, body, collapseId })`.
export function createRelay({ households, sender, now = Date.now, perMinute = PER_MINUTE, burst = BURST, log }) {
  // Each signature seen, until it could no longer pass the clock check: one signed at the
  // far edge of the window is good until twice the window after it arrives. Insertion order
  // is expiry order, so the oldest are dropped from the front.
  const seen = new Map();
  const buckets = new Map();

  function forget(at) {
    for (const [signature, expires] of seen) {
      if (expires > at) break;
      seen.delete(signature);
    }
  }

  function take(household, at) {
    const bucket = buckets.get(household) ?? { level: burst, at };
    bucket.level = Math.min(burst, bucket.level + ((at - bucket.at) * perMinute) / 60_000);
    bucket.at = at;
    buckets.set(household, bucket);
    if (bucket.level < 1) return false;
    bucket.level -= 1;
    return true;
  }

  function authenticate(headers, body) {
    const household = String(headers["x-household"] ?? "");
    const key = HOUSEHOLD.test(household) ? households().get(household) : undefined;
    if (!key) throw new Refusal(403, "the household is not let in");
    const stamp = String(headers["x-timestamp"] ?? "");
    const at = now();
    if (!/^[0-9]{1,16}$/.test(stamp) || Math.abs(at - Number(stamp)) > WINDOW_MS) {
      throw new Refusal(401, "the request was not signed within five minutes of the relay's clock");
    }
    const signature = Buffer.from(String(headers["x-signature"] ?? ""), "base64");
    const digest = createHash("sha256").update(body).digest("hex");
    let good = false;
    try {
      good = signature.length === 64 && verify(null, Buffer.from(`${household}\n${stamp}\n${digest}`), key, signature);
    } catch {
      good = false;
    }
    if (!good) throw new Refusal(401, "the household's key did not sign it");
    forget(at);
    const id = signature.toString("base64");
    if (seen.has(id)) throw new Refusal(409, "the relay has had this request before");
    seen.set(id, at + 2 * WINDOW_MS);
    if (!take(household, at)) throw new Refusal(429, "the household has sent too many for now");
    return household;
  }

  return {
    // One request, `path` "/v1/push" or "/v1/check", its headers lower-cased and its body as
    // the bytes that came. Answers `{ status, body }` for the HTTP server to send.
    async handle({ path, headers, body }) {
      let household = String(headers["x-household"] ?? "");
      try {
        household = authenticate(headers, body);
        if (path === "/v1/check") return { status: 200, body: { ok: true, household } };
        let request;
        try {
          request = JSON.parse(body.toString("utf8"));
        } catch {
          throw new Refusal(400, "the request is not JSON");
        }
        const push = checkPush(request);
        let answer;
        try {
          answer = await sender.send(push);
        } catch (error) {
          log?.warn?.(`push-relay: ${household}: Apple could not be reached: ${error?.message ?? error}`);
          return { status: 502, body: { reason: "Apple could not be reached" } };
        }
        if (answer.status !== 200) log?.info?.(`push-relay: ${household}: Apple answered ${answer.status} ${answer.reason ?? ""}`.trimEnd());
        return { status: 200, body: answer.status === 200 ? { status: 200 } : { status: answer.status, reason: answer.reason } };
      } catch (error) {
        if (!(error instanceof Refusal)) throw error;
        log?.info?.(`push-relay: ${HOUSEHOLD.test(household) ? household : "unnamed"}: refused, ${error.message}`);
        return { status: error.status, body: { reason: error.message } };
      }
    },
  };
}
