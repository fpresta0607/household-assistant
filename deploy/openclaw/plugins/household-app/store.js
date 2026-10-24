// Everything said in the app on this gateway: the family room and the owner's own thread
// with the assistant, with reactions and read markers, in one SQLite file in this
// plugin's directory under the gateway's state.
//
// Each change takes the next revision, and a phone catches up by asking for what came
// after the last revision it saw. A message never changes once kept, so its revision
// is also its place in the conversation. A reaction or a read marker is one row per
// person and message or conversation, moved to a new revision whenever it changes, so
// catching up returns its latest state once rather than its whole history. How an
// approval card ended is one row for that card, kept once, and so are a person's voice
// note's words as this gateway heard them. A live map's newest update,
// and each person's answer to a reminder by place that would watch them, are one row each
// in the same way as a reaction.
//
// A call with the assistant, once it ends, is one entry that takes the place of the
// messages it folds (call-log.js): they go, with everything that points at them, and the
// call is dropped thirty days after it ended.
//
// The same id arriving twice is the same message: the phone retries a send it never saw
// answered, and the relay may hand a gateway something it already has. So adding is
// idempotent and keeps the first copy.
//
// OpenClaw 2026.9.4 refuses its own SQLite plugin store to a plugin loaded from a local
// path, so this opens its own file with node's built-in driver, as the gateway itself does.

import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS entries (
    id TEXT PRIMARY KEY,
    rev INTEGER NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    conversation TEXT NOT NULL,
    author TEXT NOT NULL,
    at INTEGER NOT NULL,
    origin TEXT NOT NULL,
    target TEXT,
    body TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS entries_by_conversation ON entries (kind, conversation, rev);
  CREATE INDEX IF NOT EXISTS entries_by_target ON entries (target, kind);
  CREATE TABLE IF NOT EXISTS devices (
    token TEXT PRIMARY KEY,
    environment TEXT NOT NULL,
    key TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    phone TEXT
  );
  CREATE TABLE IF NOT EXISTS apple_ids (
    sub TEXT PRIMARY KEY,
    person TEXT NOT NULL,
    linked_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS apple_requests (
    id TEXT PRIMARY KEY,
    sub TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    at INTEGER NOT NULL,
    ticket TEXT NOT NULL,
    approved_at INTEGER
  );
`;

function toEntry(row) {
  if (!row) return null;
  return {
    id: row.id,
    rev: Number(row.rev),
    kind: row.kind,
    conversation: row.conversation,
    author: row.author,
    at: Number(row.at),
    origin: row.origin,
    ...JSON.parse(row.body),
  };
}

export function openRoomStore(file) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
  db.exec(SCHEMA);
  // Which paired phone a push token belongs to, so each phone's notification choices
  // apply to its own pushes. A store from before has the table without it.
  if (!db.prepare("PRAGMA table_info(devices)").all().some((column) => column.name === "phone")) {
    db.exec("ALTER TABLE devices ADD COLUMN phone TEXT");
  }

  const statements = {
    nextRev: db.prepare("SELECT COALESCE(MAX(rev), 0) + 1 AS rev FROM entries"),
    latestRev: db.prepare("SELECT COALESCE(MAX(rev), 0) AS rev FROM entries"),
    byId: db.prepare("SELECT * FROM entries WHERE id = ?"),
    insert: db.prepare(
      "INSERT INTO entries (id, rev, kind, conversation, author, at, origin, target, body) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ),
    replace: db.prepare(
      "INSERT OR REPLACE INTO entries (id, rev, kind, conversation, author, at, origin, target, body) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ),
    since: db.prepare("SELECT * FROM entries WHERE rev > ? ORDER BY rev LIMIT ?"),
    history: db.prepare(
      "SELECT * FROM entries WHERE kind IN ('message', 'call') AND conversation = ? AND rev < ? " +
        "ORDER BY rev DESC LIMIT ?",
    ),
    dropMessage: db.prepare("DELETE FROM entries WHERE id = ? AND kind = 'message'"),
    dropPointingAt: db.prepare("DELETE FROM entries WHERE target = ?"),
    // The newest entry stays until something newer is kept, so the next revision is never
    // one a phone has already caught up past.
    dropCallsEndedBefore: db.prepare(
      "DELETE FROM entries WHERE kind = 'call' AND json_extract(body, '$.endedAt') < ? " +
        "AND rev < (SELECT MAX(rev) FROM entries)",
    ),
    reactions: db.prepare(
      "SELECT * FROM entries WHERE target = ? AND kind = 'reaction' ORDER BY at, rev",
    ),
    placeAnswers: db.prepare(
      "SELECT * FROM entries WHERE target = ? AND kind = 'place' ORDER BY author",
    ),
    outbox: db.prepare(
      "SELECT * FROM entries WHERE origin = 'local' AND conversation = 'family' AND kind != 'transcript' " +
        "ORDER BY rev DESC LIMIT ?",
    ),
    reads: db.prepare(
      "SELECT * FROM entries WHERE kind = 'read' AND conversation = ? ORDER BY author",
    ),
    avatars: db.prepare("SELECT * FROM entries WHERE kind = 'avatar' ORDER BY author"),
    profiles: db.prepare("SELECT * FROM entries WHERE kind = 'profile' ORDER BY author"),
    looks: db.prepare("SELECT * FROM entries WHERE kind = 'look' AND conversation = 'family' ORDER BY at, rev"),
    looksBetween: db.prepare(
      "SELECT * FROM entries WHERE kind = 'look' AND conversation = ? AND rev >= ? AND rev < ? ORDER BY rev",
    ),
    putDevice: db.prepare(
      "INSERT OR REPLACE INTO devices (token, environment, key, updated_at, phone) VALUES (?, ?, ?, ?, ?)",
    ),
    devices: db.prepare("SELECT token, environment, key, phone FROM devices ORDER BY token"),
    removeDevice: db.prepare("DELETE FROM devices WHERE token = ?"),
    removeDevicesOf: db.prepare("DELETE FROM devices WHERE phone = ?"),
    personForApple: db.prepare("SELECT person FROM apple_ids WHERE sub = ?"),
    linkApple: db.prepare("INSERT OR REPLACE INTO apple_ids (sub, person, linked_at) VALUES (?, ?, ?)"),
    requestApple: db.prepare(
      `INSERT INTO apple_requests (id, sub, name, at, ticket) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (sub) DO UPDATE SET name = excluded.name, ticket = excluded.ticket`,
    ),
    appleRequestBySub: db.prepare("SELECT * FROM apple_requests WHERE sub = ?"),
    appleRequest: db.prepare("SELECT * FROM apple_requests WHERE id = ?"),
    appleRequests: db.prepare("SELECT * FROM apple_requests ORDER BY at, id"),
    approveAppleRequest: db.prepare("UPDATE apple_requests SET approved_at = ? WHERE id = ? AND approved_at IS NULL"),
    dropAppleRequest: db.prepare("DELETE FROM apple_requests WHERE id = ?"),
    dropAppleRequestsBefore: db.prepare("DELETE FROM apple_requests WHERE at < ?"),
  };

  const toRequest = (row) =>
    row
      ? {
          id: row.id,
          sub: row.sub,
          name: row.name,
          at: Number(row.at),
          ticket: row.ticket,
          approvedAt: row.approved_at === null ? null : Number(row.approved_at),
        }
      : null;

  function write(statement, entry, rev) {
    const { id, kind, conversation, author, at, origin, target, ...body } = entry;
    statement.run(id, rev, kind, conversation, author, at, origin, target ?? null, JSON.stringify(body));
    return { ...entry, rev };
  }

  function transaction(work) {
    db.exec("BEGIN IMMEDIATE");
    try {
      const result = work();
      db.exec("COMMIT");
      return result;
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  }

  const nextRev = () => Number(statements.nextRev.get().rev);
  const message = (id) => {
    const entry = toEntry(statements.byId.get(id));
    return entry?.kind === "message" ? entry : null;
  };

  return {
    message,

    addMessage({ id, conversation, author, at, text, media, replyTo, location, signature, runId, approval, handedOver, did, origin }) {
      return transaction(() => {
        const existing = message(id);
        if (existing) return { added: false, entry: existing };
        const entry = write(
          statements.insert,
          {
            id,
            kind: "message",
            conversation,
            author,
            at,
            origin,
            text: text ?? "",
            media: media ?? [],
            replyTo: replyTo ?? null,
            ...(location ? { location } : {}),
            ...(signature ? { signature } : {}),
            ...(runId ? { runId } : {}),
            ...(approval ? { approval } : {}),
            ...(handedOver === true || handedOver === "final" ? { handedOver: true } : {}),
            ...(handedOver === "final" ? { final: true } : {}),
            ...(did?.length ? { did } : {}),
          },
          nextRev(),
        );
        return { added: true, entry };
      });
    },

    // A call with the assistant, once it ended, written in one go with removing the messages
    // it folds and everything that points at them, a reaction, a read marker or anything
    // else kept by message, so neither history nor catching up returns them again. The same
    // call ended twice is the first one kept: the phone retries an end it never saw answered.
    addCall({ id, author, at, endedAt, with: partner, turnIds, transcript, isCut, origin }) {
      return transaction(() => {
        const existing = toEntry(statements.byId.get(id));
        if (existing) return { added: false, entry: existing };
        const entry = write(
          statements.insert,
          { id, kind: "call", conversation: "direct", author, at, origin, endedAt, with: partner, turnIds, transcript, isCut },
          nextRev(),
        );
        for (const turnId of turnIds) {
          statements.dropMessage.run(turnId);
          statements.dropPointingAt.run(turnId);
        }
        return { added: true, entry };
      });
    },

    dropCallsEndedBefore(at) {
      statements.dropCallsEndedBefore.run(at);
    },

    // How an approval card ended, kept once: a card that ended never waits again. Null
    // when the message is not an approval or its end is already kept.
    setApprovalState({ messageId, state, at }) {
      return transaction(() => {
        const card = message(messageId);
        const id = `approval:${messageId}`;
        if (!card?.approval || statements.byId.get(id)) return null;
        return write(
          statements.insert,
          { id, kind: "approval", conversation: card.conversation, author: card.author, at, origin: "local", target: messageId, messageId, state },
          nextRev(),
        );
      });
    },

    approvalState(messageId) {
      return toEntry(statements.byId.get(`approval:${messageId}`))?.state ?? null;
    },

    // What a person's voice note said, as this gateway heard it (voice-notes.js), kept once.
    // It is this gateway's own: never in the outbox, so never relayed. Null when the
    // message is unknown here or its words are already kept.
    setTranscript({ messageId, author, words, at }) {
      return transaction(() => {
        const note = message(messageId);
        const id = `transcript:${messageId}`;
        if (!note || statements.byId.get(id)) return null;
        return write(
          statements.insert,
          { id, kind: "transcript", conversation: note.conversation, author, at, origin: "local", target: messageId, messageId, words },
          nextRev(),
        );
      });
    },

    transcript(messageId) {
      return toEntry(statements.byId.get(`transcript:${messageId}`))?.words ?? null;
    },

    // Null when the message is unknown here or a newer reaction is already kept.
    setReaction({ messageId, author, emoji, at, origin }) {
      return transaction(() => {
        const target = message(messageId);
        if (!target) return null;
        const id = `reaction:${messageId}:${author}`;
        const current = toEntry(statements.byId.get(id));
        if (current && current.at > at) return null;
        return write(
          statements.replace,
          { id, kind: "reaction", conversation: target.conversation, author, at, origin, target: messageId, messageId, emoji: emoji ?? null },
          nextRev(),
        );
      });
    },

    reactions(messageId) {
      return statements.reactions
        .all(messageId)
        .map(toEntry)
        .filter((entry) => entry.emoji)
        .map(({ author, emoji }) => ({ author, emoji }));
    },

    // A live map's newest update, signed by its person's phone; a null position stopped it.
    // Null when the map is unknown here or a newer update is already kept.
    setLive({ messageId, author, at, origin, position, signature }) {
      return transaction(() => {
        const map = message(messageId);
        if (!map) return null;
        const id = `live:${messageId}`;
        const current = toEntry(statements.byId.get(id));
        if (current && current.at >= at) return null;
        return write(
          statements.replace,
          { id, kind: "live", conversation: map.conversation, author, at, origin, target: messageId, messageId, position, signature },
          nextRev(),
        );
      });
    },

    live(messageId) {
      return toEntry(statements.byId.get(`live:${messageId}`));
    },

    // A person's answer to a reminder by place that would watch them, signed by their
    // phone. Null when the card is unknown here or a newer answer is already kept.
    setPlaceAnswer({ messageId, author, answer, at, origin, signature }) {
      return transaction(() => {
        const card = message(messageId);
        if (!card) return null;
        const id = `place:${messageId}:${author}`;
        const current = toEntry(statements.byId.get(id));
        if (current && current.at >= at) return null;
        return write(
          statements.replace,
          { id, kind: "place", conversation: card.conversation, author, at, origin, target: messageId, messageId, answer, signature },
          nextRev(),
        );
      });
    },

    placeAnswers(messageId) {
      return statements.placeAnswers.all(messageId).map(toEntry).map(({ author, answer }) => ({ author, answer }));
    },

    // Null when the message is unknown here or the marker is already at or past it.
    markRead({ conversation, author, messageId, at, origin }) {
      return transaction(() => {
        const read = message(messageId);
        if (!read || read.conversation !== conversation) return null;
        const id = `read:${conversation}:${author}`;
        const current = toEntry(statements.byId.get(id));
        const currentMessage = current ? message(current.messageId) : null;
        if (currentMessage && currentMessage.rev >= read.rev) return null;
        return write(
          statements.replace,
          { id, kind: "read", conversation, author, at, origin, target: messageId, messageId },
          nextRev(),
        );
      });
    },

    readMarker(conversation, author) {
      return toEntry(statements.byId.get(`read:${conversation}:${author}`))?.messageId ?? null;
    },

    // A participant's face, one entry each in the family room, so the relay carries it
    // with its photo. Null when a newer face is already kept.
    setAvatar({ author, at, origin, media }) {
      return transaction(() => {
        const id = `avatar:${author}`;
        const current = toEntry(statements.byId.get(id));
        if (current && current.at > at) return null;
        return write(statements.replace, { id, kind: "avatar", conversation: "family", author, at, origin, media }, nextRev());
      });
    },

    // Each participant's photo by participant id.
    avatars() {
      return Object.fromEntries(statements.avatars.all().map(toEntry).map(({ author, media }) => [author, media[0]]));
    },

    // An assistant's page, its name, voice and model, one entry each in the family room so
    // the relay carries it to the other gateway. Null when a newer page is already kept.
    setProfile({ author, at, origin, name, voice, voiceName, modelName }) {
      return transaction(() => {
        const id = `profile:${author}`;
        const current = toEntry(statements.byId.get(id));
        if (current && current.at > at) return null;
        return write(
          statements.replace,
          { id, kind: "profile", conversation: "family", author, at, origin, name, voice, voiceName, modelName },
          nextRev(),
        );
      });
    },

    // One change to the family room's shared look by the person who made it (family-look.js),
    // kept as made so the room shows a line for each. Null when it is already kept, as the
    // relay may bring one twice.
    addLook({ author, at, origin, ...change }) {
      return transaction(() => {
        const id = `look:${author}:${at}`;
        if (statements.byId.get(id)) return null;
        return write(statements.insert, { id, kind: "look", conversation: "family", author, at, origin, ...change }, nextRev());
      });
    },

    // Every change to the family room's look, in the order they were made.
    looks() {
      return statements.looks.all().map(toEntry);
    },

    // Each assistant's page by assistant id.
    profiles() {
      return Object.fromEntries(statements.profiles.all().map(toEntry).map(({ author, name, voice, voiceName, modelName }) => [
        author,
        { name, voice, voiceName, modelName },
      ]));
    },

    readMarkers(conversation) {
      return statements.reads.all(conversation).map(toEntry).map(({ author, messageId }) => ({ author, messageId }));
    },

    changesSince(rev, limit = 500) {
      const rows = statements.since.all(rev, limit + 1).map(toEntry);
      const entries = rows.slice(0, limit);
      const latest = entries.length ? entries[entries.length - 1].rev : Number(statements.latestRev.get().rev);
      return { entries, rev: Math.max(rev, latest), hasMore: rows.length > limit };
    },

    // A page of messages, newest `limit` before `before`, with the changes to the family
    // room's look made among them: from the page's oldest message, or from the start once
    // nothing older is left, so paging back meets each change once.
    history(conversation, { before = Number.MAX_SAFE_INTEGER, limit = 100 } = {}) {
      const rows = statements.history.all(conversation, before, limit + 1).map(toEntry);
      const messages = rows.slice(0, limit).reverse();
      const hasMore = rows.length > limit;
      const from = hasMore ? (messages[0]?.rev ?? before) : 0;
      return { messages, hasMore, looks: statements.looksBetween.all(conversation, from, before).map(toEntry) };
    },

    // What this gateway's own person and assistant did in the family room, newest
    // `limit` of it, oldest first: the outbox the other gateway reads (share.js).
    outbox(limit) {
      return statements.outbox.all(limit).map(toEntry).reverse();
    },

    // The owner's phones Apple can reach, each with the key its notifications are
    // sealed under and the paired phone it is, when it said. Not a change in any
    // conversation, so not in what phones catch up on.
    putDevice({ token, environment, key, phone, at }) {
      statements.putDevice.run(token, environment, key, at, phone ?? null);
    },

    devices() {
      return statements.devices.all().map(({ token, environment, key, phone }) => ({ token, environment, key, phone }));
    },

    removeDevice(token) {
      statements.removeDevice.run(token);
    },

    // Every push token of one paired phone, once its pairing is gone.
    removeDevicesOf(phone) {
      statements.removeDevicesOf.run(phone);
    },

    // Apple IDs this gateway knows for its person, by Apple's stable user id, never email.
    personForApple(sub) {
      return statements.personForApple.get(sub)?.person ?? null;
    },

    linkApple({ sub, person, at }) {
      statements.linkApple.run(sub, person, at);
    },

    // A sign-in waiting for the approver: one per Apple ID, its first id and time kept,
    // answered to the phone that asked last. `ticket` is the hash of what that phone holds.
    requestApple({ id, sub, name, at, ticket }) {
      statements.requestApple.run(id, sub, name, at, ticket);
      return toRequest(statements.appleRequestBySub.get(sub));
    },

    appleRequest(id) {
      return toRequest(statements.appleRequest.get(id));
    },

    appleRequests() {
      return statements.appleRequests.all().map(toRequest);
    },

    // True when this approved it, false when it was already approved or is not there.
    approveAppleRequest(id, at) {
      return statements.approveAppleRequest.run(at, id).changes === 1;
    },

    dropAppleRequest(id) {
      statements.dropAppleRequest.run(id);
    },

    dropAppleRequestsBefore(at) {
      statements.dropAppleRequestsBefore.run(at);
    },

    close() {
      db.close();
    },
  };
}
