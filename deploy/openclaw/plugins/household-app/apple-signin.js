// Sign in with Apple, so a phone can pair with no Telegram.
//
// The phone asks its gateway for a nonce, signs in with Apple using that nonce's hash, and
// sends back Apple's identity token. The gateway checks the token itself: Apple's own keys,
// Apple as the issuer, this app as the audience, the nonce it issued, once. Apple's stable
// user id (`sub`) is then looked up among the Apple IDs this gateway knows for its person,
// and a known one gets the same single-use setup code /app gives. An email is never used to
// match anyone, since Apple can hide it.
//
// An Apple ID nobody linked waits as a request until the household's approver (Franco)
// approves it from his own phone, and the phone that asked collects its code with the
// ticket it was given. His approval is signed by that phone, so the other gateway, which
// only hears it over the relay, can check it was him against the keys that gateway
// vouches for, the same keys that sign his family-room messages.

import { createHash, createPublicKey, randomBytes, randomUUID, verify } from "node:crypto";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
export const APP_AUDIENCE = "com.siqstack.stewardai";
// Where a phone with no pairing yet signs in, on its gateway's tailnet address.
export const APPLE_PATH = "/household-app/apple";

const KEYS_MS = 60 * 60_000;
const KEYS_FETCH_MS = 10_000;
const NONCE_MS = 10 * 60_000;
const MAX_NONCES = 64;
const SKEW_S = 60;
const APPROVAL_MS = 24 * 60 * 60_000;
const REQUEST_MS = 24 * 60 * 60_000;
const MAX_REQUESTS = 8;
const REQUEST_ID = /^[A-Za-z0-9-]{1,64}$/;
const NAME = /^[^\u0000-\u001f]{1,60}$/;

const refuse = (message) => {
  throw Object.assign(new Error(message), { code: "INVALID_REQUEST" });
};

const sha256 = (text) => createHash("sha256").update(text, "utf8").digest("hex");

function decode(part) {
  try {
    return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

// The claims of an identity token Apple signed for this app with this nonce, or a refusal.
export function verifyAppleToken({ token, rawNonce, keys, audience = APP_AUDIENCE, now = Date.now }) {
  const parts = String(token ?? "").split(".");
  if (parts.length !== 3) refuse("not an Apple identity token");
  const [head, body, signature] = parts;
  const header = decode(head);
  const claims = decode(body);
  if (!header || !claims) refuse("not an Apple identity token");
  if (header.alg !== "RS256") refuse("Apple identity tokens are RS256");
  const jwk = (keys ?? []).find((key) => key?.kid === header.kid && key?.kty === "RSA");
  if (!jwk) refuse("signed by a key Apple does not publish");
  const isGenuine = verify(
    "RSA-SHA256",
    Buffer.from(`${head}.${body}`, "utf8"),
    createPublicKey({ key: jwk, format: "jwk" }),
    Buffer.from(signature, "base64url"),
  );
  if (!isGenuine) refuse("Apple did not sign this token");
  const seconds = now() / 1000;
  if (claims.iss !== APPLE_ISSUER) refuse("not issued by Apple");
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(audience)) refuse("issued for another app");
  if (!(Number(claims.exp) > seconds - SKEW_S)) refuse("the token has expired");
  if (!(Number(claims.iat) <= seconds + SKEW_S)) refuse("the token was issued in the future");
  if (typeof rawNonce !== "string" || claims.nonce !== sha256(rawNonce)) refuse("the token is for another sign-in");
  if (typeof claims.sub !== "string" || claims.sub.length === 0) refuse("the token names nobody");
  return claims;
}

async function fetchAppleKeys() {
  const response = await fetch(APPLE_KEYS_URL, { signal: AbortSignal.timeout(KEYS_FETCH_MS) });
  if (!response.ok) throw new Error(`Apple's keys answered ${response.status}`);
  return (await response.json())?.keys;
}

// Apple's signing keys, read from Apple at most once an hour while the last read holds.
export function createAppleKeys({ fetchKeys = fetchAppleKeys, now = Date.now } = {}) {
  let cached = null;
  let fetchedAtMs = 0;
  return async () => {
    if (cached && now() - fetchedAtMs < KEYS_MS) return cached;
    const keys = await fetchKeys();
    if (!Array.isArray(keys)) throw new Error("Apple's answer has no keys");
    cached = keys;
    fetchedAtMs = now();
    return cached;
  };
}

// Single-use nonces, each good for ten minutes, a bounded number outstanding.
export function createNonces({ now = Date.now, random = () => randomBytes(32).toString("base64url") } = {}) {
  const issued = new Map();
  const sweep = () => {
    for (const [nonce, expiresAtMs] of issued) if (expiresAtMs <= now()) issued.delete(nonce);
  };
  return {
    issue() {
      sweep();
      while (issued.size >= MAX_NONCES) issued.delete(issued.keys().next().value);
      const nonce = random();
      const expiresAtMs = now() + NONCE_MS;
      issued.set(nonce, expiresAtMs);
      return { nonce, expiresAtMs };
    },
    consume(nonce) {
      const expiresAtMs = issued.get(nonce);
      issued.delete(nonce);
      return expiresAtMs !== undefined && expiresAtMs > now();
    },
  };
}

// What the approver's phone signs to let one waiting Apple ID in as one person.
export function approvalText({ requestId, person, at }) {
  return `household-app/apple-approve/v1\n${requestId}\n${person}\n${at}`;
}

// A waiting sign-in as the approver's phone sees it, never with who Apple says it is.
function shown({ id, name, at }, person) {
  return { id, name, at, person };
}

export function createAppleSignIn({
  owner,
  peer,
  approver,
  store,
  nonces,
  keys,
  issueCode,
  approverKeys,
  isSignedBy,
  changed,
  makeId = () => randomUUID(),
  makeTicket = () => randomBytes(32).toString("base64url"),
  now = Date.now,
}) {
  const isApprover = owner.id === approver;
  // Sign-ins waiting on the other gateway, as it last said, which only the approver uses.
  let peerSignIns = [];
  // The approver's approvals for the other person, until the other gateway stops listing
  // the sign-in, or they are too old to count.
  let approvals = [];

  async function claimsFor({ identityToken, nonce }) {
    if (!nonces.consume(nonce)) refuse("ask for a new sign-in");
    return verifyAppleToken({ token: identityToken, rawNonce: nonce, keys: await keys(), now });
  }

  const isRequestId = (value) => typeof value === "string" && REQUEST_ID.test(value);

  async function isApproved({ requestId, person, at, signature }) {
    if (!isRequestId(requestId)) return false;
    if (!Number.isSafeInteger(at) || Math.abs(now() - at) > APPROVAL_MS) return false;
    return isSignedBy(approvalText({ requestId, person, at }), signature, await approverKeys());
  }

  const waitingHere = () => store.appleRequests().filter((request) => request.approvedAt === null);

  // An approval from this gateway's approver or relayed from the other gateway, for a
  // sign-in waiting here. The phone that asked collects its setup code with `status`.
  async function acceptApproval(approval) {
    if (approval?.person !== owner.id || !isRequestId(approval.requestId)) return false;
    const request = store.appleRequest(approval.requestId);
    if (!request || request.approvedAt !== null || !(await isApproved(approval))) return false;
    store.linkApple({ sub: request.sub, person: owner.id, at: now() });
    store.approveAppleRequest(request.id, now());
    changed();
    return true;
  }

  return {
    // An unpaired phone: a setup code when its Apple ID is known here, otherwise a wait,
    // with a ticket only that phone holds for collecting the code once approved.
    async pair({ identityToken, nonce, name }) {
      const claims = await claimsFor({ identityToken, nonce });
      if (store.personForApple(claims.sub) === owner.id) {
        const { code, expiresAtMs } = await issueCode();
        return { setupCode: code, expiresAtMs };
      }
      store.dropAppleRequestsBefore(now() - REQUEST_MS);
      const others = store.appleRequests().filter((request) => request.sub !== claims.sub);
      if (others.length >= MAX_REQUESTS) refuse("too many sign-ins are waiting");
      const ticket = makeTicket();
      const request = store.requestApple({
        id: makeId(),
        sub: claims.sub,
        name: NAME.test(name ?? "") ? name : "A new iPhone",
        at: now(),
        ticket: sha256(ticket),
      });
      changed();
      return { waiting: true, requestId: request.id, ticket };
    },

    // The waiting phone asking again: its setup code once the approver said yes.
    async status({ requestId, ticket }) {
      const request = isRequestId(requestId) ? store.appleRequest(requestId) : null;
      if (!request || typeof ticket !== "string" || sha256(ticket) !== request.ticket) refuse("no such sign-in is waiting");
      if (request.approvedAt === null) return { waiting: true };
      if (store.personForApple(request.sub) !== owner.id) refuse("no such sign-in is waiting");
      const { code, expiresAtMs } = await issueCode();
      store.dropAppleRequest(request.id);
      return { setupCode: code, expiresAtMs };
    },

    // A phone already paired here: its person's Apple ID, from now on.
    async link({ identityToken, nonce }) {
      const claims = await claimsFor({ identityToken, nonce });
      store.linkApple({ sub: claims.sub, person: owner.id, at: now() });
      return { linked: true };
    },

    // The sign-ins the approver's phone lists: this gateway's and the other's.
    waiting() {
      if (!isApprover) return [];
      return [...waitingHere().map((request) => shown(request, owner.id)), ...peerSignIns];
    },

    // The approver's phone approving: here at once, or passed on for the other gateway.
    async approve(approval) {
      if (!isApprover) refuse("only the approver can approve a sign-in");
      if (!(await isApproved(approval ?? {}))) refuse("that approval is not signed by the approver");
      const { requestId, person, at, signature } = approval;
      if (person === owner.id) {
        if (!(await acceptApproval(approval))) refuse("no such sign-in is waiting");
        return { approved: true };
      }
      if (person !== peer.id || !peerSignIns.some((request) => request.id === requestId)) refuse("no such sign-in is waiting");
      approvals = [...approvals.filter((kept) => kept.requestId !== requestId), { requestId, person, at, signature }];
      changed();
      return { approved: true };
    },

    // What the other gateway hears from this one about sign-ins.
    outbox() {
      approvals = approvals.filter((approval) => Math.abs(now() - approval.at) <= APPROVAL_MS);
      return { signIns: waitingHere().map((request) => shown(request, owner.id)), approvals };
    },

    // What the other gateway said: its waiting sign-ins, and the approver's approvals.
    async acceptPeer({ signIns, approvals: relayed } = {}) {
      if (Array.isArray(signIns)) {
        peerSignIns = signIns
          .filter((request) =>
            request?.person === peer.id &&
            isRequestId(request.id) &&
            typeof request.name === "string" && NAME.test(request.name) &&
            Number.isSafeInteger(request.at))
          .slice(0, MAX_REQUESTS)
          .map((request) => shown(request, peer.id));
        const before = approvals.length;
        approvals = approvals.filter((approval) => peerSignIns.some((request) => request.id === approval.requestId));
        if (approvals.length !== before) changed();
      }
      for (const approval of Array.isArray(relayed) ? relayed.slice(0, MAX_REQUESTS) : []) await acceptApproval(approval);
    },
  };
}
