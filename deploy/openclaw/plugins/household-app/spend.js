// The household's month on the Spend page, and the figures the box builds it from.
//
// Both gateways share one OpenRouter key with whatever else holds it (SIQsermon's backend
// does), so neither gateway can tell on its own what each assistant spent of it, and a
// plugin cannot ask OpenClaw's `usage.cost` for its own answers, since 2026.9.4 refuses an
// external plugin's in-process gateway request. The box's spend job
// (scripts/household-spend.py) asks both gateways every ten minutes, for `figures` and for
// `usage.cost`, adds the month up once and hands the same month to each gateway through
// spend-in.mjs, which writes it to household-app/spend.json. `view` is that file, so the
// page answers at once and both phones read the same numbers.
//
// `figures` is what only this gateway can tell: the key's usage as OpenRouter reports it,
// this assistant's name, what its voice cost, which OpenClaw never sees, at OpenRouter's
// price for the speech model, and what its pictures and videos cost, from
// household-pictures' ledger of OpenRouter's own costs. The key is the gateway's own
// OPENROUTER_API_KEY, from the root-only env file the compose file hands the container;
// it goes to OpenRouter only, and is never in an answer or a log. The box tells the
// gateways' keys apart by `key.id`, a short hash of it.

import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

import { dayOf } from "./settings-store.js";

export const KEY_URL = "https://openrouter.ai/api/v1/key";

const MONTH = /^\d{4}-(0[1-9]|1[0-2])$/;
const KEY_TIMEOUT_MS = 15_000;
const LINE_ID = /^[a-z][a-z0-9-]{0,31}$/;
const MAX_LINES = 8;
const MAX_NAME = 40;
const cents = (dollars) => Math.round(dollars * 100);
const isAmount = (value) => typeof value === "number" && Number.isFinite(value);

// What household-pictures' ledger holds from `firstDay` on, in dollars: nothing before
// its first picture, and an error for a file that is not its list of costs.
export async function mediaSpentSince(file, firstDay) {
  let entries;
  try {
    entries = JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return 0;
    throw error;
  }
  if (!Array.isArray(entries)) throw new Error(`${file} does not hold a list of costs`);
  return entries
    .filter((entry) => typeof entry?.day === "string" && entry.day >= firstDay && typeof entry.cost === "number")
    .reduce((sum, entry) => sum + entry.cost, 0);
}

// The month as the box handed it over, with only the fields the page reads, or an error
// naming what is wrong with it. Its lines must add up to its total to the cent, so a page
// can never show rows that disagree with the figure above them.
export function cleanReport(value) {
  const fail = (what) => {
    throw new Error(`the spend report ${what}`);
  };
  if (!value || typeof value !== "object") fail("is not an object");
  const { month, at, total, days, lines, resetsOn } = value;
  if (typeof month !== "string" || !MONTH.test(month)) fail("names no month");
  if (!Number.isSafeInteger(at) || at <= 0) fail("has no time");
  if (!isAmount(total)) fail("has no total");
  if (!Array.isArray(days) || days.length > 31) fail("has no days");
  if (!Array.isArray(lines) || lines.length === 0 || lines.length > MAX_LINES) fail("has no lines");
  if (typeof resetsOn !== "string" || !/^\d{4}-\d{2}-01$/.test(resetsOn)) fail("names no day it starts again");
  const cleanDays = days.map((entry, index) => {
    const day = `${month}-${String(index + 1).padStart(2, "0")}`;
    if (entry?.day !== day || !isAmount(entry.spent)) fail(`has a wrong day at ${day}`);
    return { day, spent: entry.spent };
  });
  const cleanLines = lines.map((line) => {
    const name = typeof line?.name === "string" ? line.name.trim() : "";
    if (!LINE_ID.test(line?.id ?? "") || !name || name.length > MAX_NAME || !isAmount(line.amount)) fail("has a wrong line");
    return { id: line.id, name, amount: line.amount };
  });
  if (new Set(cleanLines.map((line) => line.id)).size !== cleanLines.length) fail("names a line twice");
  if (cleanLines.reduce((sum, line) => sum + cents(line.amount), 0) !== cents(total)) fail("has lines that do not add up to its total");
  return { month, at, total, days: cleanDays, lines: cleanLines, resetsOn };
}

// `apiKey`, `speechModel` and `assistantName` read the gateway's environment and config as
// they are now, `mediaSpent` answers with what pictures and videos cost from a day on, and
// `reportFile` is where spend-in.mjs writes the box's month.
export function createSpend({ store, catalog, apiKey, speechModel, assistantName, mediaSpent, reportFile, fetchFn = fetch, now = Date.now }) {
  async function keyUsage() {
    const key = apiKey();
    if (!key) throw new Error("OPENROUTER_API_KEY is not in the gateway's environment");
    const answer = await fetchFn(KEY_URL, {
      headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
      signal: AbortSignal.timeout(KEY_TIMEOUT_MS),
    });
    if (!answer.ok) throw new Error(`OpenRouter answered ${answer.status} for the key's spend`);
    const data = (await answer.json())?.data;
    const usage = {
      id: createHash("sha256").update(key).digest("hex").slice(0, 12),
      usage: Number(data?.usage),
      daily: Number(data?.usage_daily),
      weekly: Number(data?.usage_weekly),
      monthly: Number(data?.usage_monthly),
    };
    if (![usage.usage, usage.daily, usage.weekly, usage.monthly].every((dollars) => dollars >= 0)) {
      throw new Error("OpenRouter gave no usage for the key");
    }
    return usage;
  }

  return {
    // For the box's spend job. `at` is when OpenRouter answered, the moment the key's
    // usage was true, and the voice and pictures are for that moment's month.
    async figures() {
      const key = await keyUsage();
      const at = now();
      const firstDay = `${dayOf(at).slice(0, 7)}-01`;
      const talk = store.talkSince(firstDay);
      const price = talk.length > 0 ? await catalog.speechPrice(speechModel()) : 0;
      return {
        at,
        month: firstDay.slice(0, 7),
        timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        assistant: assistantName(),
        key,
        voice: talk.reduce((sum, row) => sum + row.characters * price, 0),
        media: await mediaSpent(firstDay),
      };
    },

    // The page's answer: the month the box last handed over.
    async view() {
      let text;
      try {
        text = await readFile(reportFile, "utf8");
      } catch (error) {
        if (error?.code === "ENOENT") throw new Error("The box has not added up this month's spend yet");
        throw error;
      }
      return cleanReport(JSON.parse(text));
    },
  };
}
