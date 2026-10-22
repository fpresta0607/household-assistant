// The steward-cards skill's own examples, deploy/openclaw/skills/steward-cards/SKILL.md:
// the model copies them, so each must read as a card, and each chart must be one the app
// can draw (apps/ios/HouseholdAssistant/Model/Cards/ChartCard.swift refuses a series
// without one value per label, and shows such a card as raw JSON).
//
// Run with `node --test tests/js/steward_cards_skill.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

import { OPENING, cardsIn } from "../../deploy/openclaw/plugins/household-app/card-blocks.js";

const SKILL = new URL("../../deploy/openclaw/skills/steward-cards/SKILL.md", import.meta.url);
const MAX_LABELS = 24;

const skill = await readFile(SKILL, "utf8");
const cards = cardsIn(skill);
const charts = cards.filter((card) => card.type === "chart");

test("the skill's one-line description fits what the catalog shows, and names charts", () => {
  // The skill catalog cuts a description at 220 characters, and it is the whole routing
  // signal the model sees before it opens the skill.
  const description = /^description: "(.*)"$/m.exec(skill)?.[1] ?? "";
  assert.ok(description.length > 0 && description.length <= 220, `${description.length} characters`);
  assert.match(description, /any chart or graph/);
});

test("every steward-card block the skill shows reads as one card", () => {
  const blocks = skill.split("\n").filter((line) => line.trim() === OPENING).length;
  assert.ok(blocks > 0);
  assert.equal(cards.length, blocks);
});

test("the skill shows a chart for spending, the thermostat, prices and a schedule, and two series side by side", () => {
  const units = new Set(charts.map((chart) => chart.unit));
  assert.ok(units.has("$") && units.has("°F") && units.has("h"));
  assert.ok(charts.some((chart) => chart.kind === "line"));
  assert.ok(charts.some((chart) => chart.series.length > 1));
});

test("each chart example is one the app draws: a kind, short labels and one number per label in every series", () => {
  for (const chart of charts) {
    const where = chart.title ?? JSON.stringify(chart);
    assert.ok(["bar", "line"].includes(chart.kind), where);
    assert.ok(Array.isArray(chart.x) && chart.x.length > 0 && chart.x.length <= MAX_LABELS, where);
    assert.ok(chart.x.every((label) => typeof label === "string" && label.length > 0 && label.length <= 12), where);
    assert.equal(new Set(chart.x).size, chart.x.length, `${where}: a label twice is one bar`);
    assert.ok(Array.isArray(chart.series) && chart.series.length >= 1 && chart.series.length <= 4, where);
    assert.equal(new Set(chart.series.map((series) => series.name)).size, chart.series.length, where);
    for (const series of chart.series) {
      assert.equal(typeof series.name, "string", where);
      assert.equal(series.values.length, chart.x.length, where);
      assert.ok(series.values.every((value) => typeof value === "number" && Number.isFinite(value)), where);
    }
    assert.ok(chart.unit === undefined || (typeof chart.unit === "string" && chart.unit.length <= 4), where);
  }
});
