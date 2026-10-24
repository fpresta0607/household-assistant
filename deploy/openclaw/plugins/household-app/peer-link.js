// The other gateway's half of the family room, read straight from its share (share.js),
// which this gateway's container mounts read-only at PEER_SHARE. It took the place of the
// host relay, which copied each outbox across with `docker exec` and, between the outbox's
// own triggers, on a fifteen-second timer: the folder is watched, so a change is read the
// moment it lands, and every two seconds as a backstop for a watch that missed one.
//
// What may cross is narrowed here the way the relay narrowed it: what the other gateway's
// own person and own assistant did in the family room, and the room's own photo, which
// either person may set; the sign-ins waiting there for its own person, and its approver's
// approvals for this gateway's; and the steps its own assistant took in the household cart,
// the household note and the wishlist. Whether each is believed is decided where it is
// accepted, as before: a person's message counts only with that person's phone signature.
//
// The share belongs to the other gateway, so every read of it is bounded, refuses anything
// but a regular file and follows no link at the file itself, and an attachment counts only
// when its bytes hash to its name. What has been read is kept in this gateway's own state.

import { createHash } from "node:crypto";
import { constants, watch as watchFolder } from "node:fs";
import { mkdir, open, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

import { isMediaId } from "./media.js";
import { SHARED_MEDIA, SHARED_OUTBOX } from "./share.js";

export const PEER_SHARE = "/opt/household-peer";
// What a family-room entry may be: a message, a map shared as one among them, a reaction or
// a read marker, a face, an assistant's page, a live map's newest update, a person's answer
// to a reminder by place that would watch them, and a change to the room's shared look.
const CARRIED_KINDS = new Set(["message", "reaction", "read", "avatar", "profile", "live", "place", "look"]);
// The family room's own photo, the one entry that speaks for neither side's person nor
// assistant (FAMILY_FACE in room.js).
const FAMILY_FACE = "family";
// What both assistants write and both gateways replay, as the steps each took: the cart
// (cart.js), the household note (notes.js) and the wishlist's private steps (wishes.js).
const STEP_LOGS = ["cart", "notes", "wishes"];
// The plugin keeps the newest 500 entries in the outbox, each with at most 8,000 characters
// of text, so a real one is well inside this.
const MAX_OUTBOX_BYTES = 16 * 1024 * 1024;
const MAX_MEDIA_BYTES = 50 * 1024 * 1024;
// One batch's attachments together; a message's own are held under it (room.js).
const MAX_BATCH_MEDIA_BYTES = 120 * 1024 * 1024;
const ENTRIES_PER_BATCH = 100;
const SCAN_MS = 2000;
const NOTHING_WAITING = JSON.stringify({ approvals: [], signIns: [] });
const NO_STEPS = JSON.stringify([]);

class ShareError extends Error {}

// A file of the share, or null when it is not there. Opened without following a link at the
// file and without blocking on a FIFO, as a regular file of bounded size.
async function readBounded(file, limit) {
  let handle;
  try {
    handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw new ShareError(`${path.basename(file)} cannot be read: ${error.code ?? error.message}`);
  }
  try {
    const status = await handle.stat();
    if (!status.isFile()) throw new ShareError(`${path.basename(file)} is not a regular file`);
    if (status.size > limit) throw new ShareError(`${path.basename(file)} is over its size bound`);
    const buffer = Buffer.alloc(status.size);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    return { bytes: buffer.subarray(0, bytesRead), seen: `${status.ino}:${status.size}:${status.mtimeMs}` };
  } finally {
    await handle.close();
  }
}

// JSON with every object's keys in order, so the same typing state always reads the same.
function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

// The outbox's entries the other gateway may say at all, oldest first.
export function carried(outbox, peer) {
  const allowed = new Set([peer.person, peer.assistant]);
  const entries = Array.isArray(outbox?.entries) ? outbox.entries : [];
  return entries
    .filter((entry) => entry && typeof entry === "object" &&
      (allowed.has(entry.author) || (entry.author === FAMILY_FACE && entry.kind === "avatar")) &&
      entry.conversation === "family" && CARRIED_KINDS.has(entry.kind) && Number.isSafeInteger(entry.rev))
    .sort((a, b) => a.rev - b.rev);
}

// The sign-ins waiting there for the other gateway's own person, and the approvals its
// approver gave for this gateway's.
export function waiting(outbox, peer, owner) {
  const rows = (key, person) => (Array.isArray(outbox?.[key]) ? outbox[key] : [])
    .filter((row) => row && typeof row === "object" && row.person === person);
  return { signIns: rows("signIns", peer.person), approvals: rows("approvals", owner) };
}

// The steps the other gateway's own assistant took in one of STEP_LOGS.
export function assistantSteps(outbox, peer, key) {
  return (Array.isArray(outbox?.[key]) ? outbox[key] : [])
    .filter((step) => step && typeof step === "object" && step.author === peer.assistant);
}

// `peer` is `{ person, assistant }` of the other gateway, `owner` this gateway's person.
// `putMedia(bytes, id)` keeps an attachment in this gateway's media store, and `ingest(batch)`
// accepts one batch, as the inbox's files were accepted.
export function createPeerLink({ folder = PEER_SHARE, cursorFile, peer, owner, putMedia, ingest, log, scanMs = SCAN_MS, watch = watchFolder }) {
  let cursor = null;
  let lastSeen = null;
  let running = null;
  let again = false;
  let watcher = null;
  let warned = null;

  async function loadCursor() {
    if (cursor) return cursor;
    try {
      const kept = JSON.parse(await readFile(cursorFile, "utf8"));
      cursor = kept && typeof kept === "object" && Number.isSafeInteger(kept.rev) ? kept : { rev: 0 };
    } catch {
      cursor = { rev: 0 };
    }
    return cursor;
  }

  async function saveCursor() {
    await mkdir(path.dirname(cursorFile), { recursive: true, mode: 0o700 });
    const temporary = `${cursorFile}.${process.pid}.tmp`;
    await writeFile(temporary, JSON.stringify(cursor), { mode: 0o600 });
    await rename(temporary, cursorFile);
  }

  async function readMedia(id) {
    if (!isMediaId(id)) return null;
    try {
      const read = await readBounded(path.join(folder, SHARED_MEDIA, id), MAX_MEDIA_BYTES);
      if (!read || createHash("sha256").update(read.bytes).digest("hex") !== id) return null;
      return read.bytes;
    } catch {
      return null;
    }
  }

  // One batch from the other side, if anything is new. True when there may be more.
  async function once(outbox) {
    const state = await loadCursor();
    const entries = carried(outbox, peer);
    // An outbox that starts over, a gateway restored from far back, counts from its start
    // again; anything already kept is kept once.
    if ((entries.at(-1)?.rev ?? 0) < state.rev) state.rev = 0;
    const pending = entries.filter((entry) => entry.rev > state.rev);
    const typing = stable(outbox.typing ?? {});
    const signs = waiting(outbox, peer, owner);
    const signsText = JSON.stringify(signs);
    const steps = Object.fromEntries(STEP_LOGS.map((key) => [key, assistantSteps(outbox, peer, key)]));
    const stepsText = Object.fromEntries(STEP_LOGS.map((key) => [key, JSON.stringify(steps[key])]));
    const isNew = pending.length > 0 || typing !== (state.typing ?? "{}") ||
      signsText !== (state.signIns ?? NOTHING_WAITING) ||
      STEP_LOGS.some((key) => stepsText[key] !== (state[key] ?? NO_STEPS));
    if (!isNew) return false;

    const batchEntries = [];
    let mediaBytes = 0;
    let lastRev = state.rev;
    for (const entry of pending.slice(0, ENTRIES_PER_BATCH)) {
      const found = [];
      for (const item of Array.isArray(entry.media) ? entry.media : []) {
        const bytes = await readMedia(item?.id);
        if (bytes) found.push([item.id, bytes]);
      }
      const size = found.reduce((sum, [, bytes]) => sum + bytes.length, 0);
      if (batchEntries.length > 0 && mediaBytes + size > MAX_BATCH_MEDIA_BYTES) break;
      for (const [id, bytes] of found) await putMedia(bytes, id);
      mediaBytes += size;
      batchEntries.push(entry);
      lastRev = entry.rev;
    }
    const batch = {
      entries: batchEntries,
      typing: outbox.typing ?? {},
      ...(outbox.identity && typeof outbox.identity === "object" ? { identity: outbox.identity } : {}),
      ...signs,
      ...steps,
    };
    await ingest(batch);
    Object.assign(state, { rev: Math.max(state.rev, lastRev), typing, signIns: signsText, ...stepsText });
    await saveCursor();
    return batchEntries.length < pending.length;
  }

  async function catchUp() {
    let read;
    try {
      read = await readBounded(path.join(folder, SHARED_OUTBOX), MAX_OUTBOX_BYTES);
    } catch (error) {
      if (warned !== error.message) log?.warn?.(`household-app: the other gateway's share was refused: ${error.message}`);
      warned = error.message;
      return;
    }
    if (!read || read.seen === lastSeen) return;
    let outbox;
    try {
      outbox = JSON.parse(read.bytes.toString("utf8"));
    } catch {
      return;
    }
    if (!outbox || typeof outbox !== "object" || outbox.persona !== peer.assistant) {
      const problem = "its outbox is not the other assistant's";
      if (warned !== problem) log?.warn?.(`household-app: the other gateway's share was refused: ${problem}`);
      warned = problem;
      return;
    }
    warned = null;
    while (await once(outbox));
    lastSeen = read.seen;
  }

  // One catch-up at a time; a change seen during one is read right after it.
  function poke() {
    if (running) {
      again = true;
      return running;
    }
    running = (async () => {
      do {
        again = false;
        try {
          await catchUp();
        } catch (error) {
          log?.warn?.(`household-app: the other gateway's half of the family room was not read: ${error?.message ?? error}`);
        }
      } while (again);
    })().finally(() => {
      running = null;
    });
    return running;
  }

  function startWatching() {
    if (watcher) return;
    try {
      watcher = watch(folder, () => void poke());
      watcher.on?.("error", () => {
        watcher?.close();
        watcher = null;
      });
    } catch {
      watcher = null;
    }
  }

  return {
    poke,
    // Reads now, then on every change to the share and every `scanMs`, until `signal` aborts.
    start(signal) {
      startWatching();
      const sweep = setInterval(() => {
        startWatching();
        void poke();
      }, scanMs);
      signal?.addEventListener("abort", () => {
        clearInterval(sweep);
        watcher?.close();
        watcher = null;
      }, { once: true });
      return poke();
    },
  };
}
