// What each person's pictures and videos cost, one line per thing made, in one JSON file
// in this plugin's own directory under the gateway's state. The file lands with a rename,
// so a reader never sees half of it, and keeps the last LEDGER_DAYS days, which the
// Spend page's month needs and no more.
//
// The day is the container's own, which the compose file sets to the household's. A cost
// OpenRouter did not report is kept as null, and a day holding one reads as having
// reached its ceiling: a ceiling that cannot be counted must not read as unspent.

import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export const KINDS = ["picture", "video"];
const LEDGER_DAYS = 62;
const DAY_MS = 24 * 3_600_000;

export function dayOf(at) {
  const date = new Date(at);
  return [date.getFullYear(), date.getMonth() + 1, date.getDate()].map((part) => String(part).padStart(2, "0")).join("-");
}

function isEntry(entry) {
  return typeof entry?.day === "string" && typeof entry.person === "string" && KINDS.includes(entry.kind) &&
    typeof entry.model === "string" && (entry.cost === null || (typeof entry.cost === "number" && entry.cost >= 0));
}

export function createLedger(file, { now = Date.now } = {}) {
  async function entries() {
    let kept;
    try {
      kept = JSON.parse(await readFile(file, "utf8"));
    } catch (error) {
      if (error?.code === "ENOENT") return [];
      throw error;
    }
    if (!Array.isArray(kept) || !kept.every(isEntry)) throw new Error(`${file} does not hold a list of costs`);
    return kept;
  }

  return {
    // Today's spend on one kind by one person: the dollars, and whether any of it went
    // uncounted.
    async today(person, kind) {
      const day = dayOf(now());
      const mine = (await entries()).filter((entry) => entry.day === day && entry.person === person && entry.kind === kind);
      return {
        dollars: mine.reduce((sum, entry) => sum + (entry.cost ?? 0), 0),
        isUncounted: mine.some((entry) => entry.cost === null),
      };
    },

    async record({ person, kind, model, cost }) {
      const at = now();
      const oldest = dayOf(at - LEDGER_DAYS * DAY_MS);
      const kept = (await entries()).filter((entry) => entry.day >= oldest);
      const next = [...kept, { day: dayOf(at), at, person, kind, model, cost }];
      await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
      const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
      await writeFile(temporary, JSON.stringify(next), { mode: 0o600 });
      await rename(temporary, file);
    },
  };
}
