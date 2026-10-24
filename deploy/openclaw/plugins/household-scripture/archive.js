// The household's own sermons and study plans: what an assistant was asked to keep, and
// what SIQsermon held before it was retired. One archive for the household, as SIQsermon's
// was, kept in the gateway's state so the nightly backup carries it.
//
// Something to bring in from elsewhere, such as scripts/siqsermon-export.py writes, is a
// JSON file dropped in `import/` beside the archive: each one is read once, kept, and
// moved to `import/done/`, and one already kept (the same source and id) is not kept twice.

import { mkdirSync, readFileSync, readdirSync, renameSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

export const KINDS = ["sermon", "plan"];
const MAX_TITLE = 200;
const MAX_DETAIL = 200;
const MAX_BODY = 200_000;
const MAX_IMPORT_FILE = 2 * 1024 * 1024;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS items (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('sermon', 'plan')),
  title TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  source TEXT NOT NULL,
  origin_id TEXT,
  UNIQUE (source, origin_id)
);
`;

const oneLine = (value, max) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, max);

export function openArchive(directory, { now = () => new Date() } = {}) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(path.join(directory, "archive.sqlite"));
  db.exec("PRAGMA journal_mode = WAL");
  db.exec(SCHEMA);
  const insert = db.prepare(
    "INSERT OR IGNORE INTO items (kind, title, detail, body, created_at, source, origin_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
  );

  function keep({ kind, title, detail = "", body, createdAt, source = "assistant", originId = null }) {
    if (!KINDS.includes(kind)) throw new Error(`kind is one of ${KINDS.join(", ")}`);
    const cleanTitle = oneLine(title, MAX_TITLE);
    const text = String(body ?? "").trim();
    if (!cleanTitle) throw new Error("a title is needed");
    if (!text) throw new Error("there is nothing to keep");
    if (text.length > MAX_BODY) throw new Error(`it is longer than ${MAX_BODY} characters`);
    const created = createdAt && !Number.isNaN(Date.parse(createdAt)) ? new Date(createdAt).toISOString() : now().toISOString();
    const result = insert.run(kind, cleanTitle, oneLine(detail, MAX_DETAIL), text, created, oneLine(source, 40) || "assistant", originId === null ? null : String(originId));
    return result.changes > 0 ? Number(result.lastInsertRowid) : null;
  }

  // Each JSON file waiting in import/, kept and moved aside. A file that is not one item or
  // a list of items is moved to import/refused/ and named in what this returns.
  function importWaiting() {
    const inbox = path.join(directory, "import");
    let names;
    try {
      names = readdirSync(inbox).filter((name) => name.endsWith(".json")).sort();
    } catch {
      return { kept: 0, refused: [] };
    }
    let kept = 0;
    const refused = [];
    for (const name of names) {
      const file = path.join(inbox, name);
      let destination = "done";
      try {
        const raw = readFileSync(file);
        if (raw.length > MAX_IMPORT_FILE) throw new Error("too large");
        const parsed = JSON.parse(raw.toString("utf8"));
        for (const item of Array.isArray(parsed) ? parsed : [parsed]) {
          if (keep(item) !== null) kept += 1;
        }
      } catch {
        destination = "refused";
        refused.push(name);
      }
      mkdirSync(path.join(inbox, destination), { recursive: true, mode: 0o700 });
      renameSync(file, path.join(inbox, destination, name));
    }
    return { kept, refused };
  }

  return {
    keep,
    importWaiting,
    list(kind) {
      return db.prepare("SELECT id, title, detail, created_at FROM items WHERE kind = ? ORDER BY created_at, id").all(kind);
    },
    read(kind, id) {
      return db.prepare("SELECT id, title, detail, body, created_at, source FROM items WHERE kind = ? AND id = ?").get(kind, id) ?? null;
    },
    close() {
      db.close();
    },
  };
}
