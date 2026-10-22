// The receiving end of the box's spend job, from deploy/openclaw/plugins/household-app:
// what scripts/household-spend.py pipes into each gateway's container.
//
// Run with `node --test tests/js/household_app_spend_in.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, readdir, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const SCRIPT = fileURLToPath(new URL("../../deploy/openclaw/plugins/household-app/spend-in.mjs", import.meta.url));

const REPORT = {
  month: "2026-10",
  at: 1792258306254,
  total: 32.45,
  days: [{ day: "2026-10-01", spent: 1.2 }],
  lines: [
    { id: "corey", name: "Corey", amount: 5.48 },
    { id: "denise", name: "Denise", amount: 17.72 },
    { id: "other", name: "Other use of the key", amount: 9.25 },
  ],
  resetsOn: "2026-11-01",
};

function spendIn(state, input) {
  return spawnSync(process.execPath, [SCRIPT], {
    input: typeof input === "string" ? input : JSON.stringify(input),
    env: { ...process.env, OPENCLAW_STATE_DIR: state },
    encoding: "utf8",
    timeout: 30_000,
  });
}

test("the month lands in household-app/spend.json, readable by the gateway's user only", async () => {
  const state = await mkdtemp(path.join(tmpdir(), "household-app-spend-in-"));
  const result = spendIn(state, REPORT);
  assert.equal(result.status, 0, result.stderr);
  const file = path.join(state, "household-app", "spend.json");
  assert.deepEqual(JSON.parse(await readFile(file, "utf8")), REPORT);
  if (process.platform !== "win32") assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.deepEqual(await readdir(path.join(state, "household-app")), ["spend.json"]);
  assert.deepEqual(JSON.parse(result.stdout), { ok: true, month: "2026-10", at: REPORT.at });
});

test("a newer month replaces the one before", async () => {
  const state = await mkdtemp(path.join(tmpdir(), "household-app-spend-in-"));
  spendIn(state, REPORT);
  const newer = { ...REPORT, at: REPORT.at + 600_000, total: 32.5, lines: [...REPORT.lines.slice(0, 2), { id: "other", name: "Other use of the key", amount: 9.3 }] };
  assert.equal(spendIn(state, newer).status, 0);
  assert.equal(JSON.parse(await readFile(path.join(state, "household-app", "spend.json"), "utf8")).total, 32.5);
});

test("a month whose lines do not add up is refused and the last one stays", async () => {
  const state = await mkdtemp(path.join(tmpdir(), "household-app-spend-in-"));
  spendIn(state, REPORT);
  const result = spendIn(state, { ...REPORT, total: 40 });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /do not add up/);
  assert.equal(JSON.parse(await readFile(path.join(state, "household-app", "spend.json"), "utf8")).total, 32.45);
});

test("input that is not JSON writes nothing", async () => {
  const state = await mkdtemp(path.join(tmpdir(), "household-app-spend-in-"));
  const result = spendIn(state, "not json");
  assert.equal(result.status, 1);
  await assert.rejects(readdir(path.join(state, "household-app")));
});

test("input over its size bound writes nothing", async () => {
  const state = await mkdtemp(path.join(tmpdir(), "household-app-spend-in-"));
  const result = spendIn(state, JSON.stringify({ ...REPORT, padding: "x".repeat(70 * 1024) }));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /size bound/);
});
