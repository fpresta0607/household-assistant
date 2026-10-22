// The command gog's wrapper runs for an in-app Google sign-in, from
// deploy/openclaw/plugins/household-app/google-token.mjs: it prints a fresh access token,
// or nothing with its own exit code when this gateway holds no in-app sign-in.
//
// Run with `node --test tests/js/household_app_google_token.test.mjs`.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const SCRIPT = fileURLToPath(new URL("../../deploy/openclaw/plugins/household-app/google-token.mjs", import.meta.url));
const CLIENT_ID = "123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com";
// The keyring variable the script reads, and a stand-in value for it.
const KEYRING_VARIABLE = "GOG_KEYRING_PASSWORD";
const KEYRING = "test-fixture-not-a-secret";

async function gateway(context, { clientId = CLIENT_ID } = {}) {
  const state = await mkdtemp(path.join(tmpdir(), "household-app-google-token-"));
  context.after(() => rm(state, { recursive: true, force: true }));
  const household = clientId ? { googleClientId: clientId } : {};
  await writeFile(path.join(state, "openclaw.json"), JSON.stringify({ channels: { household } }));
  return state;
}

function run(state, env = {}) {
  return spawnSync(process.execPath, [SCRIPT], {
    env: { OPENCLAW_STATE_DIR: state, OPENCLAW_CONFIG_PATH: path.join(state, "openclaw.json"), [KEYRING_VARIABLE]: KEYRING, ...env },
    encoding: "utf8",
  });
}

test("with no in-app sign-in it prints nothing and says so by its exit code, without asking Google", async (context) => {
  const state = await gateway(context);

  const result = run(state);

  assert.equal(result.status, 3);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /no Google sign-in from the app/);
});

test("a sign-in it cannot open fails plainly and prints no token", async (context) => {
  const state = await gateway(context);
  await mkdir(path.join(state, "household-app", "connectors"), { recursive: true });
  await writeFile(path.join(state, "household-app", "connectors", "google.json"), JSON.stringify({ email: "gia@example.com", services: ["gmail"], refreshToken: "not.a.sealed.value" }));

  const result = run(state, { [KEYRING_VARIABLE]: "" });

  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /cannot be opened|keyring password/);
  assert.doesNotMatch(result.stderr, /gia@example\.com/);
});

test("a gateway with no iOS client id configured says so and prints no token", async (context) => {
  const state = await gateway(context, { clientId: null });
  await mkdir(path.join(state, "household-app", "connectors"), { recursive: true });
  await writeFile(path.join(state, "household-app", "connectors", "google.json"), "{}");

  const result = run(state);

  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /client id/);
});
