// Gift and wishlist memory: something a person says they want, in passing, kept with who and
// when, and handed to the right parent three weeks before that person's birthday or
// Christmas. A gift for one parent is never shown to that parent.
//
// So a wish never goes in the household note or on the two assistants' line, which both
// parents read. Each gateway keeps the wishes it hands to its own person, in its own SQLite
// file, and where a wish is kept depends on whom it is for:
//
// - A wish of this gateway's own person goes to the other gateway only, as a step of the
//   relay's `wishes` log, and is kept there for the other parent. Once the other side says it
//   has it, this side deletes the step, so the words leave the person's own side.
// - A wish of the other parent is kept here, for this gateway's own person, and never sent.
// - Anyone else's, a child's or a grandparent's, is kept here and sent to the other side too,
//   so both parents get it.
//
// Birthdays are no secret: either assistant keeps one, and it crosses to the other side.
// Every hour, and as the channel starts, the gateway posts its own person, with no model, the
// wishes of each person whose birthday or Christmas is three weeks away or less, once a year
// for each.

import { randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const MAX_WHO = 40;
const MAX_WORDS = 200;
const MAX_KEPT = 500;
const HAND_DAYS = 21;
// What a handover lists: the wishes of the last year, newest first, at most this many.
const MAX_HANDED = 12;
const YEAR_MS = 365 * 86_400_000;
const MAX_PEER_STEPS = 10_000;
const MAX_PEER_AHEAD_MS = 5 * 60_000;
const STEP_ID = /^ws-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MONTH_DAY = /^(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;
const CHRISTMAS = "12-25";

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS steps (id TEXT PRIMARY KEY, at INTEGER NOT NULL, body TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS kept (id TEXT PRIMARY KEY, who TEXT NOT NULL, words TEXT NOT NULL, said_at INTEGER NOT NULL);
  CREATE TABLE IF NOT EXISTS seen (id TEXT PRIMARY KEY);
  CREATE TABLE IF NOT EXISTS birthdays (who TEXT PRIMARY KEY, day TEXT NOT NULL, at INTEGER NOT NULL);
  CREATE TABLE IF NOT EXISTS handed (who TEXT NOT NULL, occasion TEXT NOT NULL, year INTEGER NOT NULL, PRIMARY KEY (who, occasion, year));
`;

export class WishError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const oneLine = (value) => (typeof value === "string" ? value.replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/g, " ").trim() : "");
const isWords = (value, most) => typeof value === "string" && value.length > 0 && value.length <= most && oneLine(value) === value;
const whoKey = (who) => who.toLowerCase();

// `people` are this gateway's own person and the other parent, `{ id, name }`; `timeZone`
// is for tests: the gateway counts days in its own zone.
export function createWishes({ file, assistant, peerAssistant, owner, peerPerson, now = Date.now, newId = randomUUID, changed = () => {}, timeZone }) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
  db.exec(SCHEMA);
  const statements = {
    step: db.prepare("INSERT OR IGNORE INTO steps (id, at, body) VALUES (?, ?, ?)"),
    steps: db.prepare("SELECT body FROM steps ORDER BY at, id"),
    dropStep: db.prepare("DELETE FROM steps WHERE id = ?"),
    keep: db.prepare("INSERT OR IGNORE INTO kept (id, who, words, said_at) VALUES (?, ?, ?, ?)"),
    kept: db.prepare("SELECT id, who, words, said_at FROM kept ORDER BY said_at DESC"),
    keptCount: db.prepare("SELECT COUNT(*) AS n FROM kept"),
    see: db.prepare("INSERT OR IGNORE INTO seen (id) VALUES (?)"),
    birthday: db.prepare("INSERT INTO birthdays (who, day, at) VALUES (?, ?, ?) ON CONFLICT (who) DO UPDATE SET day = excluded.day, at = excluded.at WHERE excluded.at > birthdays.at"),
    birthdays: db.prepare("SELECT who, day FROM birthdays"),
    hand: db.prepare("INSERT OR IGNORE INTO handed (who, occasion, year) VALUES (?, ?, ?)"),
  };

  // Whom a name means: this gateway's own person, the other parent, or someone else by name.
  function personOf(value) {
    const who = oneLine(value);
    if (!who || who.length > MAX_WHO) throw new WishError("invalid_wish", `Say whose wish it is, in at most ${MAX_WHO} characters.`);
    const found = [owner, peerPerson].find((person) => [person.id, person.name.toLowerCase()].includes(who.toLowerCase()));
    return found ? { kind: found === owner ? "owner" : "peer", name: found.name } : { kind: "other", name: who };
  }

  function take(fields) {
    const step = { id: `ws-${newId()}`, at: now(), author: assistant.id, ...fields };
    statements.step.run(step.id, step.at, JSON.stringify(step));
    return step;
  }

  const today = () => new Date(now()).toLocaleDateString("en-CA", { timeZone });
  const dateWords = (date) => new Date(`${date}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  const daysBetween = (from, to) => Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
  // The next time a month and day comes, today included, as YYYY-MM-DD; 29 February is the
  // 28th in a year without one.
  function nextOn(monthDay, from) {
    const year = Number(from.slice(0, 4));
    for (const candidate of [year, year + 1]) {
      const [month, day] = monthDay.split("-").map(Number);
      const last = new Date(Date.UTC(candidate, month, 0)).getUTCDate();
      const date = `${candidate}-${String(month).padStart(2, "0")}-${String(Math.min(day, last)).padStart(2, "0")}`;
      if (date >= from) return date;
    }
    return null;
  }

  return {
    // A wish someone said, for whoever it is, kept and sent where it belongs. Answers where
    // it went, in words that name no wish.
    wish({ who, words, saidAt = now() }) {
      const person = personOf(who);
      const said = oneLine(words);
      if (!said || said.length > MAX_WORDS) throw new WishError("invalid_wish", `Say what they want in at most ${MAX_WORDS} characters.`);
      if (Number(statements.keptCount.get().n) >= MAX_KEPT) throw new WishError("full", "The wishlist is full.");
      const id = `wk-${newId()}`;
      if (person.kind !== "owner") statements.keep.run(id, person.name, said, saidAt);
      if (person.kind !== "peer") take({ kind: "wish", wish: id, who: person.name, words: said, saidAt });
      changed();
      return {
        kept: person.kind === "owner" ? `for ${peerPerson.name}'s side only` : person.kind === "peer" ? `for ${owner.name} only` : `for ${owner.name} and ${peerPerson.name}`,
      };
    },

    // Someone's birthday, as MM-DD or YYYY-MM-DD, on both sides.
    birthday({ who, date }) {
      const person = personOf(who);
      const day = typeof date === "string" ? date.slice(-5) : "";
      if (!MONTH_DAY.test(day) || (date.length !== 5 && !/^\d{4}-/.test(date))) throw new WishError("invalid_wish", "A birthday is MM-DD, or YYYY-MM-DD.");
      const step = take({ kind: "birthday", who: person.name, day });
      statements.birthday.run(whoKey(person.name), day, step.at);
      changed();
      return { birthday: `${person.name}, ${day}` };
    },

    // The wishes kept here, for this gateway's own person, newest first: never one of theirs.
    view() {
      return statements.kept.all().map((row) => ({ who: row.who, wants: row.words, said: dateWords(new Date(Number(row.said_at)).toLocaleDateString("en-CA", { timeZone })) }));
    },

    // Each handover due now, once a year for each person and occasion: its words, for this
    // gateway's own person.
    due() {
      const on = today();
      const birthdays = new Map(statements.birthdays.all().map((row) => [row.who, row.day]));
      const byWho = new Map();
      for (const row of statements.kept.all()) {
        if (now() - Number(row.said_at) > YEAR_MS) continue;
        if (!byWho.has(whoKey(row.who))) byWho.set(whoKey(row.who), { who: row.who, wishes: [] });
        byWho.get(whoKey(row.who)).wishes.push(row);
      }
      const handovers = [];
      for (const [key, { who, wishes }] of byWho) {
        for (const [occasion, monthDay] of [["birthday", birthdays.get(key)], ["Christmas", CHRISTMAS]]) {
          if (!monthDay) continue;
          const date = nextOn(monthDay, on);
          const days = date && daysBetween(on, date);
          if (date === null || days > HAND_DAYS || statements.hand.run(key, occasion, Number(date.slice(0, 4))).changes === 0) continue;
          const shown = wishes.slice(0, MAX_HANDED);
          handovers.push([
            `${occasion === "birthday" ? `${who}'s birthday` : "Christmas"} is ${days === 0 ? "today" : `in ${days} ${days === 1 ? "day" : "days"}`}, ${dateWords(date)}. Things ${who} said they wanted:`,
            ...shown.map((row) => `- ${row.words} (said ${dateWords(new Date(Number(row.said_at)).toLocaleDateString("en-CA", { timeZone }))})`),
            ...(wishes.length > shown.length ? [`- and ${wishes.length - shown.length} more`] : []),
          ].join("\n"));
        }
      }
      return handovers;
    },

    outbox() {
      return { wishes: statements.steps.all().map(({ body }) => JSON.parse(body)) };
    },

    // The other gateway's steps: a wish kept here for this gateway's person, and said so with
    // a seen step; a seen step for a wish of this side's, whose words this side then deletes;
    // a birthday, the later one winning.
    acceptPeer(batch) {
      const steps = batch?.wishes;
      if (!Array.isArray(steps)) return { accepted: 0, refused: 0 };
      if (steps.length > MAX_PEER_STEPS) return { accepted: 0, refused: steps.length };
      let accepted = 0;
      let refused = 0;
      let isChanged = false;
      const mine = new Map(statements.steps.all().map(({ body }) => JSON.parse(body)).filter((step) => step.kind === "wish").map((step) => [step.id, step]));
      for (const raw of steps) {
        const isStep = raw && typeof raw === "object" && typeof raw.id === "string" && STEP_ID.test(raw.id) && raw.author === peerAssistant.id &&
          Number.isSafeInteger(raw.at) && raw.at <= now() + MAX_PEER_AHEAD_MS;
        if (isStep && raw.kind === "wish" && typeof raw.wish === "string" && /^wk-/.test(raw.wish) && isWords(raw.who, MAX_WHO) && isWords(raw.words, MAX_WORDS) && Number.isSafeInteger(raw.saidAt)) {
          if (statements.see.run(raw.id).changes > 0) {
            statements.keep.run(raw.wish, raw.who, raw.words, raw.saidAt);
            take({ kind: "seen", step: raw.id });
            isChanged = true;
          }
          accepted += 1;
        } else if (isStep && raw.kind === "seen" && typeof raw.step === "string") {
          if (mine.has(raw.step)) {
            statements.dropStep.run(raw.step);
            isChanged = true;
          }
          accepted += 1;
        } else if (isStep && raw.kind === "birthday" && isWords(raw.who, MAX_WHO) && typeof raw.day === "string" && MONTH_DAY.test(raw.day)) {
          statements.birthday.run(whoKey(raw.who), raw.day, raw.at);
          accepted += 1;
        } else {
          refused += 1;
        }
      }
      if (isChanged) changed();
      return { accepted, refused };
    },

    close() {
      db.close();
    },
  };
}
