// The Sunday night digest: one message of about ten lines, read once, from each parent's own
// assistant in their own thread: the week ahead, what is slipping, the litter's weight trend,
// the cart, the open promises and the two or three things that need a decision.
//
// A scheduled run writes it (scripts/openclaw-scheduled-jobs.py adds the job), and a run has
// every tool, so it never reads words someone else wrote into the household note: those are
// only shown, never handed to a model with a shell (notes.js prompt says why). So the run
// gives household_digest what only it can find, the week's calendar and the decisions, and
// this composes the rest from the note and the cart itself and posts the whole message. The
// tool answers the run with counts alone.
//
// The week is drawn the way the Overlord asked for the day snapshot on 22 October, clean
// rather than wordy: when the run gives the week's `events`, the message carries them as an
// agenda card, each day a calendar mark beside one row for each thing, in bold with its time
// (the app's AgendaCardView). A run that gives only `week` lines gets those lines, as before.

import { CLOSING, OPENING } from "./card-blocks.js";
import { isOwnTurn } from "./brief.js";

export const DIGEST_TOOL = "household_digest";
const MAX_WEEK = 4;
const MAX_DECIDE = 3;
const MAX_LINE = 120;
// What an agenda card draws at most (the app's AgendaCard): seven days, twelve things a day.
const MAX_EVENTS = 12;
const MAX_DAYS = 7;
const MAX_TITLE = 60;
// A start as the calendar gives it, with its offset, and an all-day thing's day.
const START = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(?::\d{2})?(?:Z|[+-]\d{2}:\d{2})$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const MAX_SLIPPING_SHOWN = 2;
// A log whose trend the digest gives: the litter's weigh-ins, or any other weight.
export const WEIGHTS = /weigh/i;
const NUMBER = /(-?\d+(?:\.\d+)?)\s*([\p{L}]{1,6})?/u;
const NOT_ONE_LINE = /[\p{Cc}\p{Zl}\p{Zp}]/u;
const DAY_MS = 86_400_000;

const dateWords = (date) => new Date(`${date}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });

// A log's trend: the latest day's rows, their average, and the change since the day logged
// before it, or null when the log holds no numbers.
export function trendOf(log) {
  if (!log) return null;
  const byDay = new Map();
  let unit;
  for (const row of log.rows) {
    const found = NUMBER.exec(row.text);
    if (!found) continue;
    unit ??= found[2];
    if (!byDay.has(row.day)) byDay.set(row.day, []);
    byDay.get(row.day).push(Number(found[1]));
  }
  const days = [...byDay.keys()].sort();
  if (days.length === 0) return null;
  const average = (day) => Math.round(byDay.get(day).reduce((sum, value) => sum + value, 0) / byDay.get(day).length);
  const latest = days.at(-1);
  const before = days.at(-2);
  const unitWords = unit ? ` ${unit}` : "";
  const change = before === undefined ? "" : (() => {
    const difference = average(latest) - average(before);
    return `, ${difference === 0 ? "level" : `${difference > 0 ? "up" : "down"} ${Math.abs(difference)}${unitWords}`} since ${dateWords(before)}`;
  })();
  return `${log.topic}: ${byDay.get(latest).length} on ${dateWords(latest)}, average ${average(latest)}${unitWords}${change}.`;
}

// The Monday the coming week starts on, as words, from `now` in the gateway's zone.
function weekOf(now, timeZone) {
  const today = new Date(now).toLocaleDateString("en-CA", { timeZone });
  const weekday = new Date(`${today}T12:00:00Z`).getUTCDay();
  const monday = new Date(Date.parse(`${today}T12:00:00Z`) + ((8 - weekday) % 7 || 7) * DAY_MS).toISOString().slice(0, 10);
  return dateWords(monday);
}

const quoted = (line) => `"${line.text}"${line.topic ? ` (${line.topic})` : ""}`;

// "9:00 AM", on the clock the calendar gave the start in.
function clock(start) {
  const [, , hour, minute] = START.exec(start);
  return `${Number(hour) % 12 || 12}:${minute} ${Number(hour) < 12 ? "AM" : "PM"}`;
}

// The week's events as an agenda card's lines: each day once, the soonest first, something all
// day before the timed things of its day, at most seven days.
export function agendaLines(events) {
  const sorted = events
    .map((event) => (event.start
      ? { day: START.exec(event.start)[1], sort: event.start.slice(11, 16), row: { title: event.title, time: clock(event.start) } }
      : { day: event.day, sort: "", row: { title: event.title } }))
    .sort((left, right) => left.day.localeCompare(right.day) || left.sort.localeCompare(right.sort));
  const days = [];
  for (const { day, row } of sorted) {
    if (days.at(-1)?.date !== day) days.push({ date: day, events: [] });
    days.at(-1).events.push(row);
  }
  return [OPENING, JSON.stringify({ type: "agenda", title: "The week ahead", skill: "calendar", days: days.slice(0, MAX_DAYS) }), CLOSING];
}

// The digest as its lines, from what the run found and what the note and the cart hold.
export function composeDigest({ week, events = [], decide, due, log, cartItems, now, timeZone }) {
  const slipping = [...due.overdue, ...due.promises.filter((line) => line.standing === "overdue")];
  const open = due.promises.length;
  const trend = trendOf(log);
  return [
    `Sunday digest, the week of ${weekOf(now, timeZone)}`,
    ...(events.length > 0 ? agendaLines(events) : week.length > 0 ? week.map((line) => `- ${line}`) : ["- Nothing on the calendar."]),
    slipping.length === 0
      ? "Slipping: nothing."
      : `Slipping: ${slipping.slice(0, MAX_SLIPPING_SHOWN).map(quoted).join(", ")}${slipping.length > MAX_SLIPPING_SHOWN ? ` and ${slipping.length - MAX_SLIPPING_SHOWN} more` : ""}.`,
    ...(trend ? [trend] : []),
    cartItems === 0 ? "Cart: empty." : `Cart: ${cartItems} ${cartItems === 1 ? "item" : "items"} waiting to be ordered.`,
    open === 0 ? "Promises: none open." : `Promises: ${open} open, first ${quoted(due.promises[0])}${due.promises[0].owner ? `, ${due.promises[0].owner}` : ""}.`,
    ...(decide.length > 0 ? ["To decide:", ...decide.map((line) => `- ${line}`)] : []),
  ];
}

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

// The tool, in the owner's own turns and a scheduled run, or null. `post(week, decide,
// events)` composes and posts the digest, and answers how many lines it posted.
export function createDigestTool({ context, owner, post }) {
  if (!isOwnTurn({ context, owner })) return null;
  const lines = (value, most) => Array.isArray(value) && value.length <= most &&
    value.every((line) => typeof line === "string" && line.trim() && line.length <= MAX_LINE && !NOT_ONE_LINE.test(line));
  const isEvent = (event) => Boolean(event) && typeof event === "object" && !Array.isArray(event) &&
    Object.keys(event).every((key) => ["title", "start", "day"].includes(key)) &&
    typeof event.title === "string" && event.title.trim() !== "" && event.title.length <= MAX_TITLE && !NOT_ONE_LINE.test(event.title) &&
    (event.start === undefined) !== (event.day === undefined) &&
    (event.start === undefined || (typeof event.start === "string" && START.test(event.start))) &&
    (event.day === undefined || (typeof event.day === "string" && DAY.test(event.day)));
  const isEvents = (value) => value === undefined || (Array.isArray(value) && value.length <= MAX_EVENTS && value.every(isEvent));
  return {
    name: DIGEST_TOOL,
    label: "Sunday digest",
    description:
      "Posts the Sunday night digest in your person's own chat in the Steward app: about ten lines, read once. Give `events`, the coming week's main events " +
      `from the family's shared calendar and your person's own, at most ${MAX_EVENTS}, each its \`title\` and its \`start\` as the calendar gives it, with its offset, ` +
      "or its `day` when it is all day: the app draws them as the week at a glance. Without `events`, `week` gives at most four short lines, each with its day and time. " +
      "Give `decide`, the two or three " +
      "things that need your person's decision this week, each one short line, or none. The digest adds what is slipping, the litter's weight trend, " +
      "the cart and the open promises from the household note itself. Call it once.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["decide"],
      properties: {
        events: {
          type: "array",
          maxItems: MAX_EVENTS,
          items: {
            type: "object",
            additionalProperties: false,
            required: ["title"],
            properties: {
              title: { type: "string", minLength: 1, maxLength: MAX_TITLE },
              start: { type: "string", description: "When it starts, as the calendar gives it, such as 2026-10-26T09:00:00-05:00." },
              day: { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$", description: "Its day, YYYY-MM-DD, only when it is all day." },
            },
          },
        },
        week: { type: "array", maxItems: MAX_WEEK, items: { type: "string", minLength: 1, maxLength: MAX_LINE } },
        decide: { type: "array", maxItems: MAX_DECIDE, items: { type: "string", minLength: 1, maxLength: MAX_LINE } },
      },
    },
    async execute(_id, args) {
      const week = args?.week ?? (args?.events === undefined ? null : []);
      if (!lines(week, MAX_WEEK) || !lines(args?.decide, MAX_DECIDE) || !isEvents(args?.events)) {
        return result({
          code: "invalid_arguments",
          message: `Give events, at most ${MAX_EVENTS}, each a title and a start with its offset or an all-day day, or week, at most ${MAX_WEEK} lines; ` +
            `and decide, at most ${MAX_DECIDE}, each one line of at most ${MAX_LINE} characters.`,
        }, true);
      }
      const events = (args.events ?? []).map((event) => ({ ...event, title: event.title.trim() }));
      const posted = await post(week.map((line) => line.trim()), args.decide.map((line) => line.trim()), events);
      return result({ posted: true, lines: posted });
    },
  };
}
