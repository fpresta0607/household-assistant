// The kept list: one JSON file of everything a family member asked this assistant to
// keep. Nothing here removes a record. Forgetting one sets `doneAt`, which takes it out
// of the prompt and leaves it on disk, and a full list refuses a new record rather than
// dropping an old one. Every change goes through `change`, one at a time, and lands with
// a rename, so a reader never sees half a file.
//
// A record names who asked by `who`, the name it is shown under, and `person`, their
// household person id. Records kept while the family used Telegram carry `whoId`, a
// Telegram id, in place of `person`. Nothing reads either id, so both kinds load and are
// shown as they are.

import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

// Far more than a family asks for in years. Past it a request is refused and the
// assistant says so, so a runaway capture cannot crowd out what is already kept.
export const MAX_RECORDS = 2000;
export const MAX_TEXT = 600;

function isRecord(record) {
  return record && Number.isSafeInteger(record.id) && Number.isFinite(record.at) &&
    typeof record.text === "string" && ["private", "family"].includes(record.scope);
}

export function normalized(text) {
  return String(text ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

export function createKept(file, { now }) {
  let queue = Promise.resolve();

  async function read() {
    let records;
    try {
      records = JSON.parse(await readFile(file, "utf8"));
    } catch (error) {
      if (error.code === "ENOENT") return [];
      // A file that cannot be read or parsed is never treated as empty: writing over it
      // would lose everything kept.
      throw new Error(`the kept list at ${file} cannot be read: ${error.message}`);
    }
    if (!Array.isArray(records)) throw new Error(`the kept list at ${file} is not a list`);
    return records.filter(isRecord);
  }

  async function write(records) {
    await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
    const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(temporary, JSON.stringify(records), { mode: 0o600 });
    await rename(temporary, file);
  }

  function change(update) {
    const next = queue.then(async () => {
      const records = await read();
      const { records: changed, result } = update(records);
      if (changed) await write(changed);
      return result;
    });
    queue = next.catch(() => undefined);
    return next;
  }

  // Keeps one request, or finds it already kept: a retried turn builds its prompt again.
  function keep({ who, person, where, scope, text, at = now() }) {
    const clipped = String(text).replace(/\s+/g, " ").trim().slice(0, MAX_TEXT);
    return change((records) => {
      const same = records.find((record) =>
        record.doneAt === undefined && record.scope === scope && normalized(record.text) === normalized(clipped));
      if (same) return { records: null, result: { kept: same, isNew: false } };
      if (records.length >= MAX_RECORDS) return { records: null, result: { full: true } };
      const id = records.reduce((highest, record) => Math.max(highest, record.id), 0) + 1;
      const kept = { id, at, who, person, where, scope, text: clipped };
      return { records: [...records, kept], result: { kept, isNew: true } };
    });
  }

  function forget(id, scopes) {
    return change((records) => {
      const index = records.findIndex((record) =>
        record.id === id && record.doneAt === undefined && scopes.includes(record.scope));
      if (index < 0) return { records: null, result: null };
      const done = { ...records[index], doneAt: now() };
      return { records: records.with(index, done), result: done };
    });
  }

  const list = () => change((records) => ({ records: null, result: records }));

  return { keep, forget, list };
}
