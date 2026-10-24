// Finding older chats: OpenClaw's own full-text index of transcripts, read-only,
// limited to the household app's chats a turn may see. In the family room that is the
// room alone. In the owner's own thread it is every session linked to that thread, and
// the room.
//
// OpenClaw's sessions_search needs every word of a query to match. This takes any of
// them and ranks lines by how many they share, so a question in different words from
// the original still finds it.

import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const MAX_TERMS = 10;
const MAX_ROWS = 60;
const SNIPPET = 280;
// A line this recent is the turn being answered, or the one just before it.
const RECENT_MS = 2 * 60_000;

const STOPWORDS = new Set(`
  a about above after again ago all also am an and any are aren as ask asked at be been before
  being below between both but by can could did didn do does doing don down during each few for
  from further get got had has have having he her here hers him his how i if in into is isn it its
  just know last let like me mean month months more most much my myself no nor not now of off on
  once one only or other our ours out over own please really remember remind said say same see she
  should so some still such tell than that the their them then there these they thing things this
  those through time to told too under until up us very want was wasn we week weeks were weren what
  when where which while who whom why will with won would yes yet you your yours yourself day days
  earlier recall decide decided talked talk mentioned mention okay ok hey hi
`.split(/\s+/).filter(Boolean));

export function termsOf(text) {
  const seen = new Set();
  for (const word of String(text ?? "").toLowerCase().match(/[a-z0-9]+/g) ?? []) {
    if (word.length >= 3 && !STOPWORDS.has(word)) seen.add(word);
  }
  return [...seen].slice(0, MAX_TERMS);
}

export function sharedTerms(terms, text) {
  const words = String(text ?? "").toLowerCase().match(/[a-z0-9]+/g) ?? [];
  return terms.filter((term) => words.some((word) => word.startsWith(term))).length;
}

function snippet(text, terms) {
  const flat = String(text).replace(/\s+/g, " ").trim();
  if (flat.length <= SNIPPET) return flat;
  const lower = flat.toLowerCase();
  const first = Math.min(...terms.map((term) => lower.indexOf(term)).filter((at) => at >= 0), flat.length);
  const start = Math.max(0, Math.min(first - 80, flat.length - SNIPPET));
  return `${start > 0 ? "…" : ""}${flat.slice(start, start + SNIPPET)}${start + SNIPPET < flat.length ? "…" : ""}`;
}

// Which conversations a chat may read: the app's family room, and in the private chat
// also the owner's own thread. Its parameters come from visibleChats, in order.
export const VISIBLE_CHATS = `(
  chat.channel = 'household' AND ((chat.kind = 'group' AND chat.peer_id = 'family') OR (? AND chat.kind = 'direct' AND chat.peer_id = ?))
)`;

export function visibleChats({ owner, isPrivate }) {
  return [isPrivate ? 1 : 0, owner];
}

// The best `limit` lines, best first, from the sessions linked to the given chats. Each
// is { at, role, where, text }. An empty list when nothing shares enough words.
//
// The owner's own session of the app's family room (household-app's turn.js) is linked to
// the family room too, but its transcript holds what the owner's tools returned and the
// words written beside those calls, which the room never saw. So only a search the owner's
// private view makes reads it.
export function searchHistory(stateDirectory, { owner, ownersFamilySession, isPrivate, query, now, limit }) {
  const terms = termsOf(query);
  if (terms.length === 0) return [];
  const needed = Math.min(2, terms.length);
  const database = new DatabaseSync(path.join(stateDirectory, "agents", "main", "agent", "openclaw-agent.sqlite"), {
    readOnly: true,
  });
  let rows;
  try {
    database.exec("PRAGMA query_only = ON; PRAGMA busy_timeout = 1000");
    rows = database.prepare(`
      SELECT line.text AS text, line.role AS role, line.timestamp AS at, chat.kind AS kind
      FROM session_transcript_fts AS line
      JOIN session_conversations AS link ON link.session_id = line.session_id
      JOIN conversations AS chat ON chat.conversation_id = link.conversation_id
      WHERE session_transcript_fts MATCH ?
        AND chat.account_id = 'default'
        AND (chat.thread_id IS NULL OR chat.thread_id = '')
        AND ${VISIBLE_CHATS}
        AND (SELECT COUNT(*) FROM session_conversations AS other WHERE other.session_id = line.session_id) = 1
        AND (? OR line.session_id NOT IN (SELECT window.session_id FROM session_windows AS window WHERE window.session_key = ?))
        AND line.role IN ('user', 'assistant')
      ORDER BY bm25(session_transcript_fts)
      LIMIT ?
    `).all(
      terms.map((term) => `"${term}"*`).join(" OR "),
      ...visibleChats({ owner, isPrivate }),
      isPrivate ? 1 : 0,
      ownersFamilySession ?? "",
      MAX_ROWS,
    );
  } finally {
    database.close();
  }
  const seen = new Set();
  return rows
    .filter((row) => Number(row.at) < now - RECENT_MS)
    .map((row, rank) => ({ row, rank, shared: sharedTerms(terms, row.text) }))
    .filter(({ row, shared }) => {
      if (shared < needed) return false;
      const key = String(row.text).slice(0, 200);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((left, right) => right.shared - left.shared || left.rank - right.rank)
    .slice(0, limit)
    .map(({ row }) => ({
      at: Number(row.at),
      role: row.role,
      where: row.kind === "group" ? "the family group" : "a private chat",
      text: snippet(row.text, terms),
    }));
}
