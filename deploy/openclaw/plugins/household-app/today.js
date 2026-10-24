// The assistant's day at a glance at the top of Chats in the Steward AI app (CFO notes
// section 21c): household_today, the tool it writes it with, and the newest one for
// household-app.today and the `today` event.
//
// The tool is offered in the same turns as household_brief (brief.js): the owner's own
// thread, a family-room turn the owner started, and a scheduled run, which is how the
// morning's and the evening's are written (scripts/openclaw-household-app.py adds that
// job). Never in anyone else's family-room turn: it comes from the owner's own day and
// shows on the owner's phones alone.
//
// Only the newest is kept, not one a day: the evening's carries tomorrow morning, and the
// phone picks what is still ahead by its own clock. A write with no verse keeps the verse
// already kept for the same day, so the evening need not find it again. Every write also
// writes today's brief from the first things still ahead today, which the phones from
// before the card still show.

import { isOwnTurn, MAX_BRIEF_CHARACTERS } from "./brief.js";
import { dayOf } from "./settings-store.js";

export const TODAY_TOOL = "household_today";
export const MOST_ITEMS = 8;
export const MAX_TITLE = 60;
export const MAX_DETAIL = 90;
export const MAX_VERSE = 240;
export const MAX_REFERENCE = 40;
const KEY = "today";
// What is still ahead in the brief written beside it: begun at most this long ago.
const STILL_AHEAD_MS = 15 * 60 * 1000;
// A line break, a tab or any other control character: the phone draws plain lines.
const NOT_ONE_LINE = /[\p{Cc}\p{Zl}\p{Zp}]/u;
// ISO 8601 to the minute or the second, with its offset, as the phone reads it.
const START = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(:\d{2})?(Z|[+-]\d{2}:\d{2})$/;
// The scripture tool's links, which open the passage in the Bible app.
const BIBLE_LINK = /^https:\/\/www\.bible\.com\/[^\s]+$/;

// `brief` is the brief it writes beside it, and `changed` is told each new one.
export function createToday({ store, brief, now = Date.now, changed = () => {} }) {
  const latest = () => {
    const kept = store.value(KEY);
    return kept === null ? null : JSON.parse(kept);
  };
  return {
    latest,

    write({ items, verse }) {
      const at = now();
      const day = dayOf(at);
      const kept = latest();
      const dayVerse = verse ?? (kept?.day === day ? kept.verse : undefined);
      const today = { day, at, items, ...(dayVerse ? { verse: dayVerse } : {}) };
      store.setValue(KEY, JSON.stringify(today));
      brief.write(briefLine(items, day, at));
      changed(today);
      return today;
    },
  };
}

// "Dentist at 9:00. Soccer pickup at 5:45.": the first things still ahead today, something
// all day for the whole of it, on the clock they were written in, as one line no longer
// than a brief.
function briefLine(items, day, at) {
  const ahead = items.filter((item) =>
    item.start.slice(0, 10) === day && (item.allDay || Date.parse(item.start) > at - STILL_AHEAD_MS));
  const sentences = ahead.slice(0, 2).map((item) => {
    if (item.allDay) return `${item.title}.`;
    const [, , hour, minute] = START.exec(item.start);
    return `${item.title} at ${Number(hour) % 12 || 12}:${minute}.`;
  });
  while (sentences.length > 1 && [...sentences.join(" ")].length > MAX_BRIEF_CHARACTERS) sentences.pop();
  const line = sentences.join(" ");
  return line.length > 0 && [...line].length <= MAX_BRIEF_CHARACTERS ? line : "Nothing else planned today.";
}

// Plain words trimmed, or null when they are not one line of 1 to `most` characters.
function oneLine(value, most) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  const characters = [...trimmed].length;
  return characters > 0 && characters <= most && !NOT_ONE_LINE.test(trimmed) ? trimmed : null;
}

const hasOnly = (value, keys) =>
  value !== null && typeof value === "object" && !Array.isArray(value) && Object.keys(value).every((key) => keys.includes(key));

// The start with its seconds, which the phone's reading needs, or null when it is no time.
function cleanStart(value) {
  const parts = typeof value === "string" ? START.exec(value) : null;
  if (parts === null) return null;
  const start = `${parts[1]}T${parts[2]}:${parts[3]}${parts[4] ?? ":00"}${parts[5]}`;
  return Number.isFinite(Date.parse(start)) ? start : null;
}

function cleanItem(item) {
  if (!hasOnly(item, ["start", "title", "detail", "allDay"])) return null;
  const start = cleanStart(item.start);
  const title = oneLine(item.title, MAX_TITLE);
  const detail = item.detail === undefined ? undefined : oneLine(item.detail, MAX_DETAIL);
  const isAllDay = item.allDay === undefined ? false : item.allDay;
  if (start === null || title === null || detail === null || typeof isAllDay !== "boolean") return null;
  return { start, title, ...(detail ? { detail } : {}), ...(isAllDay ? { allDay: true } : {}) };
}

function cleanVerse(verse) {
  if (!hasOnly(verse, ["text", "reference", "link"])) return null;
  const text = oneLine(verse.text, MAX_VERSE);
  const reference = oneLine(verse.reference, MAX_REFERENCE);
  const link = typeof verse.link === "string" && BIBLE_LINK.test(verse.link) ? verse.link : null;
  return text === null || reference === null || link === null ? null : { text, reference, link };
}

// The card as kept, its things the soonest first, or null when anything is outside it.
export function cleanToday(args) {
  if (!hasOnly(args ?? {}, ["items", "verse"])) return null;
  const items = args?.items ?? [];
  if (!Array.isArray(items) || items.length > MOST_ITEMS) return null;
  const clean = items.map(cleanItem);
  if (clean.some((item) => item === null)) return null;
  const verse = args?.verse === undefined ? undefined : cleanVerse(args.verse);
  if (verse === null || (clean.length === 0 && verse === undefined)) return null;
  clean.sort((a, b) => Date.parse(a.start) - Date.parse(b.start));
  return { items: clean, ...(verse ? { verse } : {}) };
}

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

// The tool for this turn, or null.
export function createTodayTool({ context, owner, write }) {
  if (!isOwnTurn({ context, owner })) return null;
  return {
    name: TODAY_TOOL,
    label: "Today card",
    description:
      "Writes the Today card: what the owner sees at the top of their conversations in the Steward AI app, the " +
      "next thing first, two more, and a verse for the day at the bottom that opens in the Bible app. Give what is " +
      `still ahead from now until tomorrow noon, the soonest first, at most ${MOST_ITEMS}, each with its start as ` +
      'ISO 8601 with its offset, such as "2026-10-17T07:45:00-05:00", a short title of at most ' +
      `${MAX_TITLE} characters, and for the first one or two a detail of at most ${MAX_DETAIL} characters that ` +
      'helps, such as "Leave by 7:30, the roads are light". Mark something that lasts the whole day allDay. Use ' +
      "where someone is only from what they share with you in Steward right now, and another person's plans only " +
      "from what they told you or said in the family room. Give the verse with its words, its reference exactly as " +
      "the scripture tool prints it and the link of its card. Leave it out later in the day to keep the morning's. " +
      "Plain text, no Markdown. A new card replaces the last. It is shown in the app and messages nobody.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        items: {
          type: "array",
          maxItems: MOST_ITEMS,
          items: {
            type: "object",
            additionalProperties: false,
            required: ["start", "title"],
            properties: {
              start: { type: "string", description: "When it starts, ISO 8601 with its offset." },
              title: { type: "string", minLength: 1, maxLength: MAX_TITLE },
              detail: { type: "string", minLength: 1, maxLength: MAX_DETAIL },
              allDay: { type: "boolean" },
            },
          },
        },
        verse: {
          type: "object",
          additionalProperties: false,
          required: ["text", "reference", "link"],
          properties: {
            text: { type: "string", minLength: 1, maxLength: MAX_VERSE },
            reference: { type: "string", minLength: 1, maxLength: MAX_REFERENCE },
            link: { type: "string", description: "The bible.com link of the scripture tool's card for the passage." },
          },
        },
      },
    },
    async execute(_id, args) {
      const today = cleanToday(args);
      if (today === null) {
        return result({
          code: "invalid_arguments",
          message:
            `Give \`items\`, at most ${MOST_ITEMS}, each with \`start\` (ISO 8601 with its offset), \`title\` ` +
            `(one line, at most ${MAX_TITLE} characters), and if it helps \`detail\` (one line, at most ${MAX_DETAIL}) ` +
            "and `allDay`. Give `verse` with `text`, `reference` and a bible.com `link` in the morning, and leave it out later.",
        }, true);
      }
      return result({ today: write(today) });
    },
  };
}
