// What iOS measured of the app on the owner's iPhone, from
// deploy/openclaw/plugins/household-app/phone-metrics.js: one log line per report, numbers
// only, and a refusal for anything that is not a plain figure.
//
// Run with `node --test tests/js/household_app_phone_metrics.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { test } from "node:test";

import { phoneMetricsLine } from "../../deploy/openclaw/plugins/household-app/phone-metrics.js";

const DAY = {
  from: Date.UTC(2026, 9, 16, 0, 0),
  to: Date.UTC(2026, 9, 17, 0, 0),
  appVersion: "1.0",
  build: "14",
  scrollHitchMsPerSecond: 4.25,
  hangCount: 3,
  hangSeconds: 1.75,
};

test("a day's report is one line of figures for the build", () => {
  assert.equal(
    phoneMetricsLine(DAY),
    "household-app: iPhone metrics, build 14 (1.0), 2026-10-16T00:00:00.000Z to 2026-10-17T00:00:00.000Z: scroll hitches 4.3 ms/s, 3 hangs, 1.8 s hanging",
  );
});

test("a day with no scrolling says so", () => {
  assert.match(phoneMetricsLine({ ...DAY, scrollHitchMsPerSecond: null }), /no scrolling measured, 3 hangs/);
});

for (const [name, change, reason] of [
  ["an end before its start", { to: DAY.from - 1 }, /bad metrics window/],
  ["a window longer than a month", { to: DAY.from + 32 * 24 * 60 * 60 * 1000 }, /bad metrics window/],
  ["a version that carries words", { appVersion: "1.0; rm -rf" }, /bad app version/],
  ["a build that is not a string", { build: 14 }, /bad app version/],
  ["a negative hitch ratio", { scrollHitchMsPerSecond: -1 }, /bad scroll hitch ratio/],
  ["an impossible hitch ratio", { scrollHitchMsPerSecond: 1001 }, /bad scroll hitch ratio/],
  ["a hitch ratio that is not a number", { scrollHitchMsPerSecond: "4" }, /bad scroll hitch ratio/],
  ["a fractional hang count", { hangCount: 1.5 }, /bad hang figures/],
  ["a negative hang time", { hangSeconds: -2 }, /bad hang figures/],
  ["nothing at all", null, /bad metrics window/],
]) {
  test(`a report with ${name} is refused`, () => {
    const params = change === null ? null : { ...DAY, ...change };
    assert.throws(() => phoneMetricsLine(params), (error) => error.code === "INVALID_REQUEST" && reason.test(error.message));
  });
}
