// What a phone sets on this gateway that OpenClaw's own config does not hold: how the
// assistant talks and how long it answers, each phone's notification choices, the newest
// settings change accepted, what Talk spoke each day and what the assistant's answers
// cost each day. The assistant's brief for today is kept here too (brief.js).
//
// Its own SQLite file beside room.sqlite, opened for the plugin rather than for the
// channel: the standing instruction reaches every turn, Telegram's included, whether the
// app's channel is running or not, and a rename restarts the channel in the middle of the
// request that made it. The newest accepted change is here so a restart cannot reopen a
// replay.

import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS notifications (
    phone TEXT NOT NULL,
    conversation TEXT NOT NULL,
    choice TEXT NOT NULL,
    PRIMARY KEY (phone, conversation)
  );
  CREATE TABLE IF NOT EXISTS talk (
    day TEXT PRIMARY KEY,
    characters INTEGER NOT NULL
  );
`;

const NEWEST_AT = "newestChangeAt";

// The day a count is kept under: the container's own, which the compose file sets to the
// household's.
export function dayOf(time) {
  const date = new Date(time);
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-");
}

export function openSettingsStore(file) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
  db.exec(SCHEMA);

  const statements = {
    value: db.prepare("SELECT value FROM settings WHERE key = ?"),
    setValue: db.prepare("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)"),
    notifications: db.prepare("SELECT conversation, choice FROM notifications WHERE phone = ? ORDER BY conversation"),
    setNotification: db.prepare("INSERT OR REPLACE INTO notifications (phone, conversation, choice) VALUES (?, ?, ?)"),
    talkSpent: db.prepare("SELECT characters FROM talk WHERE day = ?"),
    chargeTalk: db.prepare(
      "INSERT INTO talk (day, characters) VALUES (?, ?) ON CONFLICT (day) DO UPDATE SET characters = characters + excluded.characters",
    ),
    talkSince: db.prepare("SELECT day, characters FROM talk WHERE day >= ? ORDER BY day"),
  };

  const value = (key) => statements.value.get(key)?.value ?? null;

  return {
    value,

    setValue(key, text) {
      statements.setValue.run(key, text);
    },

    // True when `at` is later than every change accepted before, and is now the newest.
    acceptChangeAt(at) {
      const newest = Number(value(NEWEST_AT) ?? 0);
      if (at <= newest) return false;
      statements.setValue.run(NEWEST_AT, String(at));
      return true;
    },

    // One phone's choices by conversation, only those it made.
    notifications(phone) {
      return Object.fromEntries(statements.notifications.all(phone).map(({ conversation, choice }) => [conversation, choice]));
    },

    setNotification(phone, conversation, choice) {
      statements.setNotification.run(phone, conversation, choice);
    },

    talkSpent(day) {
      return Number(statements.talkSpent.get(day)?.characters ?? 0);
    },

    chargeTalk(day, characters) {
      statements.chargeTalk.run(day, characters);
    },

    talkSince(day) {
      return statements.talkSince.all(day).map((row) => ({ day: row.day, characters: Number(row.characters) }));
    },

    close() {
      db.close();
    },
  };
}
