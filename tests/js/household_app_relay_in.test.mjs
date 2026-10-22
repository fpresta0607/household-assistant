// The receiving end of the family room's relay, from deploy/openclaw/plugins/household-app:
// what the host relay pipes into the other gateway's container.
//
// Run with `node --test tests/js/household_app_relay_in.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdtemp, readFile, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const SCRIPT = fileURLToPath(new URL("../../deploy/openclaw/plugins/household-app/relay-in.mjs", import.meta.url));
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

async function stateDirectory() {
  return mkdtemp(path.join(tmpdir(), "household-app-relay-in-"));
}

function relayIn(state, input) {
  return spawnSync(process.execPath, [SCRIPT], {
    input: typeof input === "string" ? input : JSON.stringify(input),
    env: { ...process.env, OPENCLAW_STATE_DIR: state },
    encoding: "utf8",
    timeout: 30_000,
  });
}

const BATCH = {
  entries: [{ kind: "message", id: "m-00000001", author: "franco", conversation: "family", at: 1, text: "hi", media: [] }],
  typing: {},
  identity: { assistant: { id: "corey", name: "Corey" } },
};

test("a batch lands in the inbox as one file the plugin picks up", async () => {
  const state = await stateDirectory();
  const result = relayIn(state, { from: "corey", batch: BATCH, media: {} });
  assert.equal(result.status, 0, result.stderr);
  const inbox = path.join(state, "household-app", "inbox");
  const files = await readdir(inbox);
  assert.equal(files.length, 1);
  assert.match(files[0], /^\d{13}-[0-9a-f-]{36}\.json$/);
  assert.deepEqual(JSON.parse(await readFile(path.join(inbox, files[0]), "utf8")), { from: "corey", batch: BATCH });
  assert.deepEqual(JSON.parse(result.stdout), { ok: true, entries: 1, media: 0 });
});

test("an attachment is written under its hash before the batch that names it", async () => {
  const state = await stateDirectory();
  const bytes = randomBytes(2048);
  const result = relayIn(state, { from: "corey", batch: BATCH, media: { [sha256(bytes)]: bytes.toString("base64") } });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(await readFile(path.join(state, "household-app", "media", sha256(bytes))), bytes);
  assert.deepEqual(JSON.parse(result.stdout), { ok: true, entries: 1, media: 1 });
});

test("an attachment that does not match its hash refuses the whole batch", async () => {
  const state = await stateDirectory();
  const result = relayIn(state, { from: "corey", batch: BATCH, media: { ["a".repeat(64)]: randomBytes(10).toString("base64") } });
  assert.notEqual(result.status, 0);
  await assert.rejects(readdir(path.join(state, "household-app", "inbox")), { code: "ENOENT" });
});

for (const [name, input] of [
  ["input that is not JSON", "not json"],
  ["a batch with no entries list", { from: "corey", batch: {}, media: {} }],
  ["an unknown sender", { from: "../etc", batch: BATCH, media: {} }],
  ["a media id that is not a hash", { from: "corey", batch: BATCH, media: { "../x": "" } }],
]) {
  test(`${name} is refused`, async () => {
    const state = await stateDirectory();
    const result = relayIn(state, input);
    assert.notEqual(result.status, 0);
    await assert.rejects(readdir(path.join(state, "household-app", "inbox")), { code: "ENOENT" });
  });
}
