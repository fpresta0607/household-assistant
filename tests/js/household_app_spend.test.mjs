// The Spend page's month and the figures the box builds it from, from
// deploy/openclaw/plugins/household-app/spend.js. OpenRouter is a fake that records what
// it was asked, and the key in it is made up here.
//
// Run with `node --test tests/js/household_app_spend.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { openSettingsStore } from "../../deploy/openclaw/plugins/household-app/settings-store.js";
import { KEY_URL, cleanReport, createSpend, mediaSpentSince } from "../../deploy/openclaw/plugins/household-app/spend.js";

const NOW = new Date(2026, 9, 15, 17, 0).getTime();
const MADE_UP_KEY = `test-${randomBytes(12).toString("hex")}`;

const REPORT = {
  month: "2026-10",
  at: NOW,
  total: 32.45,
  days: [{ day: "2026-10-01", spent: 1.2 }, { day: "2026-10-02", spent: 3.4 }],
  lines: [
    { id: "corey", name: "Corey", amount: 5.48 },
    { id: "denise", name: "Denise", amount: 17.72 },
    { id: "other", name: "Other use of the key", amount: 9.25 },
  ],
  resetsOn: "2026-11-01",
};

function fakeOpenRouter({ status = 200, data = { usage: 44.851942439, usage_daily: 0.77267549, usage_weekly: 6.757105499, usage_monthly: 32.446356204 } } = {}) {
  const asked = [];
  return {
    asked,
    fetchFn: async (url, init) => {
      asked.push({ url, init });
      return { ok: status === 200, status, json: async () => ({ data }) };
    },
  };
}

async function setup({ key = MADE_UP_KEY, openRouter = fakeOpenRouter(), speechPrice = 0.00002, mediaSpent = async () => 0 } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-spend-"));
  const store = openSettingsStore(path.join(directory, "settings.sqlite"));
  const reportFile = path.join(directory, "spend.json");
  const clock = { now: NOW };
  const priced = [];
  const spend = createSpend({
    store,
    catalog: { speechPrice: async (model) => { priced.push(model); return speechPrice; } },
    apiKey: () => key,
    speechModel: () => "elevenlabs/eleven-v4-turbo",
    assistantName: () => "Corey",
    mediaSpent,
    reportFile,
    fetchFn: openRouter.fetchFn,
    now: () => clock.now,
  });
  return { spend, store, clock, openRouter, priced, reportFile };
}

test("the figures carry the key's usage as OpenRouter reports it, in dollars", async () => {
  const { spend, openRouter } = await setup();
  const figures = await spend.figures();
  assert.deepEqual(figures.key, {
    id: createHash("sha256").update(MADE_UP_KEY).digest("hex").slice(0, 12),
    usage: 44.851942439,
    daily: 0.77267549,
    weekly: 6.757105499,
    monthly: 32.446356204,
  });
  assert.equal(figures.at, NOW);
  assert.equal(figures.month, "2026-10");
  assert.equal(figures.assistant, "Corey");
  assert.equal(openRouter.asked[0].url, KEY_URL);
  assert.equal(KEY_URL, "https://openrouter.ai/api/v1/key");
  assert.equal(openRouter.asked[0].init.headers.Authorization, `Bearer ${MADE_UP_KEY}`);
  assert.ok(openRouter.asked[0].init.signal instanceof AbortSignal, "a stalled OpenRouter cannot hold the reading");
});

test("the figures name the gateway's own time zone, which the box counts days in", async () => {
  const { spend } = await setup();
  assert.equal((await spend.figures()).timeZone, Intl.DateTimeFormat().resolvedOptions().timeZone);
});

test("the key never reaches the figures", async () => {
  const { spend } = await setup();
  assert.equal(JSON.stringify(await spend.figures()).includes(MADE_UP_KEY), false);
});

test("the voice is this month's Talk characters at OpenRouter's rate for the speech model", async () => {
  const { spend, store, priced } = await setup();
  store.chargeTalk("2026-09-30", 90_000);
  store.chargeTalk("2026-10-14", 50_000);
  store.chargeTalk("2026-10-15", 5_000);
  assert.equal(Math.round((await spend.figures()).voice * 1e6) / 1e6, 1.1);
  assert.deepEqual(priced, ["elevenlabs/eleven-v4-turbo"]);
});

test("a month with no Talk asks for no speech price", async () => {
  const { spend, priced } = await setup();
  assert.equal((await spend.figures()).voice, 0);
  assert.deepEqual(priced, []);
});

test("pictures and videos are what household-pictures' ledger holds for this month", async () => {
  const asked = [];
  const { spend } = await setup({ mediaSpent: async (firstDay) => { asked.push(firstDay); return 0.4567; } });
  assert.equal((await spend.figures()).media, 0.4567);
  assert.deepEqual(asked, ["2026-10-01"]);
});

test("each reading asks OpenRouter again, for the box to keep", async () => {
  const { spend, openRouter } = await setup();
  await spend.figures();
  await spend.figures();
  assert.equal(openRouter.asked.length, 2);
});

test("with no key in the gateway's environment there are no figures to give", async () => {
  const { spend, openRouter } = await setup({ key: null });
  await assert.rejects(spend.figures(), /OPENROUTER_API_KEY/);
  assert.equal(openRouter.asked.length, 0);
});

test("a refusal from OpenRouter is an error that carries no key", async () => {
  const { spend } = await setup({ openRouter: fakeOpenRouter({ status: 401 }) });
  await assert.rejects(spend.figures(), (error) => /401/.test(error.message) && !error.message.includes(MADE_UP_KEY));
});

test("an answer with no usage in it is an error, not a zero", async () => {
  const { spend } = await setup({ openRouter: fakeOpenRouter({ data: { usage_monthly: 3 } }) });
  await assert.rejects(spend.figures(), /no usage/);
});

test("the page reads the month the box handed over", async () => {
  const { spend, reportFile } = await setup();
  await writeFile(reportFile, JSON.stringify({ ...REPORT, extra: "dropped" }));
  assert.deepEqual(await spend.view(), REPORT);
});

test("before the box's first month the page is told so", async () => {
  const { spend } = await setup();
  await assert.rejects(spend.view(), /has not added up this month's spend yet/);
});

test("a month whose lines do not add up to its total is refused", () => {
  const lines = [...REPORT.lines.slice(0, 2), { id: "other", name: "Other use of the key", amount: 9.26 }];
  assert.throws(() => cleanReport({ ...REPORT, lines }), /do not add up/);
});

test("lines that add up only after rounding each to the cent are kept", () => {
  const lines = [
    { id: "corey", name: "Corey", amount: 0.1 },
    { id: "denise", name: "Denise", amount: 0.2 },
    { id: "other", name: "Other use of the key", amount: 0 },
  ];
  assert.equal(cleanReport({ ...REPORT, total: 0.3, lines }).total, 0.3);
});

for (const [what, change, refusal] of [
  ["a month that is not one", { month: "2026-13" }, /names no month/],
  ["no time", { at: 0 }, /has no time/],
  ["a total that is not a number", { total: "32" }, /has no total/],
  ["a day out of order", { days: [{ day: "2026-10-02", spent: 1 }] }, /wrong day at 2026-10-01/],
  ["more days than a month has", { days: Array.from({ length: 32 }, (_, index) => ({ day: `2026-10-${index + 1}`, spent: 0 })) }, /has no days/],
  ["no lines", { lines: [] }, /has no lines/],
  ["a line with no name", { lines: [{ id: "corey", name: " ", amount: 32.45 }] }, /wrong line/],
  ["a line named twice", { lines: [{ id: "corey", name: "Corey", amount: 32 }, { id: "corey", name: "Corey", amount: 0.45 }] }, /twice/],
  ["no day it starts again", { resetsOn: "2026-11-02" }, /starts again/],
]) {
  test(`a report with ${what} is refused`, () => {
    assert.throws(() => cleanReport({ ...REPORT, ...change }), refusal);
  });
}

test("the ledger's month counts only reported costs from the 1st on, and no ledger is nothing yet", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-spend-media-"));
  const file = path.join(directory, "ledger.json");
  assert.equal(await mediaSpentSince(file, "2026-10-01"), 0);
  await writeFile(file, JSON.stringify([
    { day: "2026-09-30", person: "franco", kind: "picture", model: "m", cost: 0.5 },
    { day: "2026-10-01", person: "franco", kind: "picture", model: "m", cost: 0.04 },
    { day: "2026-10-17", person: "gia", kind: "video", model: "m", cost: 0.6 },
    { day: "2026-10-17", person: "gia", kind: "picture", model: "m", cost: null },
  ]));
  assert.equal(Math.round((await mediaSpentSince(file, "2026-10-01")) * 1000) / 1000, 0.64);
  await writeFile(file, JSON.stringify({ day: "2026-10-01" }));
  await assert.rejects(mediaSpentSince(file, "2026-10-01"), /does not hold a list of costs/);
});
