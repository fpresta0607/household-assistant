// The document and deadline vault: a passport, an insurance policy, a car registration, a
// warranty, a subscription or a license, photographed once in the owner's own thread, kept
// with the day it expires or renews, and brought up thirty days before that day.
//
// The pictures never move. A photo or a scan the owner sends in their own thread is kept by
// the media store under its hash on this gateway alone (media.js): the owner's thread is
// shared with nobody (room.js), the relay carries none of it, and the other person's phones
// never pair with this gateway. The vault keeps only which of those files a document is,
// what it is and its day, in its own SQLite file beside the room, and no log line names any
// of it.
//
// The day goes into the household note too, the family's shared tracker (notes.js), as a
// line of the "Renewals" topic due on that day, unless the owner asks to keep it to
// themselves (vault-tool.js). The note line names the document and its day, never anything
// read off the picture.
//
// Every hour, and as the channel starts, the gateway posts its owner, with no model, each
// document whose day is thirty days away or less, once for that day. One kept with less than
// thirty days left is said in the turn that kept it instead.

import { randomBytes } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

export const KINDS = ["passport", "insurance", "registration", "warranty", "subscription", "license", "other"];
export const DATE_KINDS = ["expires", "renews"];
export const MAX_WHAT = 60;
export const NOTICE_DAYS = 30;
// Far more documents than a household keeps.
const MAX_DOCUMENTS = 200;
const MAX_PICTURES = 10;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const DOCUMENT_ID = /^dv-[0-9a-f]{8}$/;
const MEDIA_ID = /^[0-9a-f]{64}$/;

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    what TEXT NOT NULL,
    kind TEXT NOT NULL,
    date TEXT NOT NULL,
    date_kind TEXT NOT NULL,
    pictures TEXT NOT NULL,
    line TEXT,
    noticed TEXT,
    kept_at INTEGER NOT NULL
  );
`;

export class VaultError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const oneLine = (value) => (typeof value === "string" ? value.replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/g, " ").trim() : "");

// A calendar day as YYYY-MM-DD, and only one that exists.
function isDay(value) {
  if (typeof value !== "string" || !DATE.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().startsWith(value);
}

const daysBetween = (from, to) => Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
export const dateWords = (date) =>
  new Date(`${date}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });

// `timeZone` is for tests: the gateway counts days in its own zone.
export function createVault({ file, now = Date.now, newId = () => randomBytes(4).toString("hex"), timeZone }) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
  db.exec(SCHEMA);
  const statements = {
    keep: db.prepare("INSERT INTO documents (id, what, kind, date, date_kind, pictures, line, noticed, kept_at) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)"),
    all: db.prepare("SELECT * FROM documents ORDER BY date, id"),
    one: db.prepare("SELECT * FROM documents WHERE id = ?"),
    count: db.prepare("SELECT COUNT(*) AS n FROM documents"),
    update: db.prepare("UPDATE documents SET what = ?, date = ?, date_kind = ?, pictures = ?, noticed = ? WHERE id = ?"),
    line: db.prepare("UPDATE documents SET line = ? WHERE id = ?"),
    noticed: db.prepare("UPDATE documents SET noticed = ? WHERE id = ?"),
    remove: db.prepare("DELETE FROM documents WHERE id = ?"),
  };

  const today = () => new Date(now()).toLocaleDateString("en-CA", { timeZone });

  // How far off a document's day is, in the words a reply or a notice uses.
  function when(row) {
    const days = daysBetween(today(), row.date);
    if (days < 0) return `${row.date_kind === "expires" ? "expired" : "was due to renew"} ${dateWords(row.date)}`;
    const count = days === 0 ? "today" : days === 1 ? "tomorrow" : `in ${days} days`;
    return `${row.date_kind} ${count}, ${dateWords(row.date)}`;
  }

  // A document as the owner's turns see it: never its pictures' ids, only how many.
  function viewed(row) {
    return { document: row.id, what: row.what, kind: row.kind, [row.date_kind]: row.date, when: when(row), pictures: JSON.parse(row.pictures).length, isShared: row.line !== null };
  }

  function document(id) {
    const row = typeof id === "string" && DOCUMENT_ID.test(id) ? statements.one.get(id) : undefined;
    if (!row) throw new VaultError("unknown_document", "That document is not in the vault. View the vault for its documents' ids.");
    return row;
  }

  function cleaned({ what, kind, date, dateKind, pictures }) {
    const words = oneLine(what);
    if (!words || words.length > MAX_WHAT) throw new VaultError("invalid_document", `Say what the document is in at most ${MAX_WHAT} characters.`);
    if (!KINDS.includes(kind)) throw new VaultError("invalid_document", `A document's kind is one of ${KINDS.join(", ")}.`);
    if (!isDay(date)) throw new VaultError("invalid_document", "The date is a day that exists, YYYY-MM-DD, as the document shows it.");
    if (!DATE_KINDS.includes(dateKind)) throw new VaultError("invalid_document", `The date is the day it ${DATE_KINDS.join(" or ")}.`);
    if (!Array.isArray(pictures) || pictures.length === 0 || pictures.length > MAX_PICTURES || !pictures.every((id) => MEDIA_ID.test(id))) {
      throw new VaultError("no_picture", "A document is kept from a photo or a scan of it in the owner's own thread.");
    }
    return { what: words, kind, date, dateKind, pictures: JSON.stringify([...new Set(pictures)]) };
  }

  // A notice is due once the day is this close; one kept or changed already this close is said
  // in that turn's reply, so it is marked noticed as it is written.
  const isClose = (date) => {
    const days = daysBetween(today(), date);
    return days >= 0 && days <= NOTICE_DAYS;
  };

  // One document, or every document, soonest day first.
  function view(id) {
    if (id !== undefined) {
      const row = document(id);
      const shown = viewed(row);
      return daysBetween(today(), row.date) <= NOTICE_DAYS ? { ...shown, tell: `It ${when(row)}: say so in your reply.` } : shown;
    }
    return { documents: statements.all.all().map(viewed) };
  }

  return {
    // A document from its pictures (media ids of the owner's photo or scan), what it is, its
    // kind and the day it expires or renews. Answers the document and, when the day is thirty
    // days away or less or already past, says so for the turn's reply.
    keep(fields) {
      const row = cleaned(fields);
      if (Number(statements.count.get().n) >= MAX_DOCUMENTS) throw new VaultError("full", `The vault holds at most ${MAX_DOCUMENTS} documents.`);
      const id = `dv-${newId()}`;
      statements.keep.run(id, row.what, row.kind, row.date, row.dateKind, row.pictures, isClose(row.date) ? row.date : null, now());
      return view(id);
    },

    // A document renewed or misread: a new day, a new name, or new pictures, the rest as it
    // was. A new day is noticed again thirty days before it.
    update(id, { what, date, dateKind, pictures }) {
      const row = document(id);
      const next = cleaned({
        what: what ?? row.what,
        kind: row.kind,
        date: date ?? row.date,
        dateKind: dateKind ?? row.date_kind,
        pictures: pictures ?? JSON.parse(row.pictures),
      });
      const noticed = next.date === row.date ? row.noticed : isClose(next.date) ? next.date : null;
      statements.update.run(next.what, next.date, next.dateKind, next.pictures, noticed, row.id);
      return view(row.id);
    },

    // The household note's line for a document, once it has one (vault-tool.js).
    setLine(id, line) {
      statements.line.run(line, document(id).id);
    },

    line(id) {
      return document(id).line;
    },

    remove(id) {
      const row = document(id);
      statements.remove.run(row.id);
      return { what: row.what, line: row.line };
    },

    view,

    // Each notice due now, for the owner's own thread, each once for its day.
    due() {
      const notices = [];
      for (const row of statements.all.all()) {
        if (row.noticed === row.date || !isClose(row.date)) continue;
        statements.noticed.run(row.date, row.id);
        notices.push(`Your ${row.what} ${when(row)}. It is in your vault in Steward.`);
      }
      return notices;
    },

    // How many documents are kept, for a log line that names none of them.
    count() {
      return Number(statements.count.get().n);
    },

    close() {
      db.close();
    },
  };
}
