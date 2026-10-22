// The household's scheduled jobs from household-app's side (automations.js): a reminder someone
// made that announces straight to the app is pushed Time Sensitive while it runs, as the job
// mirror's copies of it were before Telegram went off (issue #6), and nothing else is.
//
// Run with `node --test tests/js/household_app_automations.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { test } from "node:test";

import { createReminderPushes } from "../../deploy/openclaw/plugins/household-app/automations.js";

const job = (id, to, extra = {}) => ({ id, enabled: true, delivery: { mode: "announce", channel: "household", to }, ...extra });

test("a reminder announcing to the app marks its own conversation Time Sensitive from its start to its finish", () => {
  // Arrange
  let clock = 0;
  const pushes = createReminderPushes({ now: () => clock });
  pushes.know([
    job("bins", "household:franco"),
    job("today", "household:franco", { declarationKey: "household-app:daily-brief" }),
    job("room", "household:family"),
  ]);

  // Act and Assert
  assert.equal(pushes.isTimeSensitive("franco"), false, "nothing runs yet");
  pushes.observe({ action: "started", jobId: "today" });
  assert.equal(pushes.isTimeSensitive("franco"), false, "a job our scripts declared is no reminder");
  pushes.observe({ action: "started", jobId: "bins" });
  assert.equal(pushes.isTimeSensitive("franco"), true);
  assert.equal(pushes.isTimeSensitive("family"), false, "only its own conversation");
  pushes.observe({ action: "finished", jobId: "bins" });
  assert.equal(pushes.isTimeSensitive("franco"), false);
});

test("a run that never says it finished stops marking after ten minutes", () => {
  let clock = 0;
  const pushes = createReminderPushes({ now: () => clock });
  pushes.know([job("room", "household:family")]);
  pushes.observe({ action: "started", jobId: "room" });
  clock = 10 * 60_000 - 1;
  assert.equal(pushes.isTimeSensitive("family"), true);
  clock = 10 * 60_000;
  assert.equal(pushes.isTimeSensitive("family"), false);
});

test("a job that delivers anywhere but the app, or nowhere, is never a pushed reminder", () => {
  const pushes = createReminderPushes();
  pushes.know([
    { id: "tg", delivery: { mode: "announce", channel: "telegram", to: "7100000001" } },
    { id: "quiet", delivery: { mode: "none" } },
    { id: "bare" },
  ]);
  for (const jobId of ["tg", "quiet", "bare", "unknown"]) pushes.observe({ action: "started", jobId });
  assert.equal(pushes.isTimeSensitive("franco"), false);
});
