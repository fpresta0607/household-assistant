// Connect Notion from the Steward app, the gateway's half, from
// deploy/openclaw/plugins/household-app/notion-connect.js.
//
// Notion's API is a stand-in, so nothing here reaches Notion.
// Run with `node --test tests/js/household_app_notion_connect.test.mjs`.

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { NOTION_VERSION, createNotionConnector } from "../../deploy/openclaw/plugins/household-app/notion-connect.js";

const START = Date.UTC(2026, 9, 15, 22, 0);
const TOKEN = "fixture-token-not-a-real-one-0001";
const REDIRECT = "steward://connector/notion";
// The registration's secret field, named once apart from its stand-in value.
const SECRET_FIELD = "clientSecret";
const REGISTERED = { clientId: "notion-client", [SECRET_FIELD]: "fixture-not-a-secret", redirectUri: REDIRECT };

function fakeNotion({ status = 200, me = { object: "user", type: "bot", name: "Steward", bot: { workspace_name: "Gia's Notion" } }, grant = {} } = {}) {
  const calls = [];
  return {
    calls,
    async fetch(url, init) {
      calls.push({ url: String(url), method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : undefined });
      const body = String(url).endsWith("/users/me")
        ? me
        : {
          access_token: "oauth-access", token_type: "bearer", refresh_token: "oauth-refresh", bot_id: "b", workspace_id: "w",
          workspace_name: "Gia's Notion", workspace_icon: null, duplicated_template_id: null,
          owner: { type: "user", user: { object: "user", id: "u", name: "Gia", type: "person", person: { email: "gia@example.com" } } },
          ...grant,
        };
      return { ok: status === 200, status, json: async () => (status === 200 ? body : { code: "unauthorized" }) };
    },
  };
}

async function connector(context, { notion = fakeNotion(), registration = {} } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "notion-connect-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const made = createNotionConnector({ directory, keyringPassword: "keyring-password", fetch: notion.fetch, now: () => START, ...registration });
  return { ...made, directory, notion };
}

test("with no public connection registered, Notion signs in by a pasted token and offers no OAuth", async (context) => {
  const setup = await connector(context);
  assert.equal(setup.kind(), "token");
  assert.equal(setup.oauth(), null);
});

test("a pasted token is kept only after Notion answers to it, sealed, and the workspace names the account", async (context) => {
  const setup = await connector(context);

  await setup.connectToken(TOKEN);

  const [check] = setup.notion.calls;
  assert.equal(check.url, "https://api.notion.com/v1/users/me");
  assert.equal(check.headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(check.headers["Notion-Version"], NOTION_VERSION);
  assert.deepEqual(await setup.status(), { connected: true, name: "Gia's Notion", email: null, workspace: "Gia's Notion", connectedAt: START });
  assert.doesNotMatch(await readFile(path.join(setup.directory, "notion.json"), "utf8"), /fixture-token/);
  assert.equal(await setup.token(), TOKEN);
});

for (const [why, token] of [["an empty token", ""], ["a token with a space", "fixture token not a real one"], ["a token too short", "fixture"]]) {
  test(`${why} is refused before Notion is asked`, async (context) => {
    const setup = await connector(context);
    await assert.rejects(setup.connectToken(token), (error) => error.detailCode === "BAD_VALUE");
    assert.equal(setup.notion.calls.length, 0);
  });
}

test("a token Notion refuses is not kept and says Notion refused it", async (context) => {
  const setup = await connector(context, { notion: fakeNotion({ status: 401 }) });

  await assert.rejects(setup.connectToken(TOKEN), (error) => error.detailCode === "PROVIDER_REFUSED" && /Notion refused the sign-in \(401, unauthorized\)/.test(error.message));
  assert.deepEqual(await setup.status(), { connected: false });
});

test("with the public connection registered, the app is told how to start, and a code is exchanged with the secret", async (context) => {
  const setup = await connector(context, { registration: REGISTERED });
  assert.equal(setup.kind(), "oauth");
  assert.deepEqual(setup.oauth(), {
    provider: "notion",
    clientId: "notion-client",
    authorizeUrl: "https://api.notion.com/v1/oauth/authorize?owner=user",
    scopes: [],
    redirectUri: REDIRECT,
    usesPkce: false,
  });

  await setup.connectCode({ code: "notion-code", redirectUri: REDIRECT });

  const [exchange] = setup.notion.calls;
  assert.equal(exchange.url, "https://api.notion.com/v1/oauth/token");
  assert.equal(exchange.method, "POST");
  assert.equal(exchange.headers.Authorization, `Basic ${Buffer.from("notion-client:fixture-not-a-secret").toString("base64")}`);
  assert.deepEqual(exchange.body, { grant_type: "authorization_code", code: "notion-code", redirect_uri: REDIRECT });
  assert.deepEqual(await setup.status(), { connected: true, name: "Gia", email: "gia@example.com", workspace: "Gia's Notion", connectedAt: START });
  const kept = await readFile(path.join(setup.directory, "notion.json"), "utf8");
  assert.doesNotMatch(kept, /oauth-access|oauth-refresh|fixture-not-a-secret/);
  assert.equal(await setup.token(), "oauth-access");
});

test("a code is refused plainly when no connection is registered or the redirect is not this app's", async (context) => {
  const unregistered = await connector(context);
  await assert.rejects(unregistered.connectCode({ code: "c", redirectUri: REDIRECT }), (error) => error.detailCode === "SIGNIN_NOT_SET_UP");
  const registered = await connector(context, { registration: REGISTERED });
  await assert.rejects(registered.connectCode({ code: "c", redirectUri: "https://elsewhere.example/cb" }), /not this app's redirect/);
  assert.equal(registered.notion.calls.length + unregistered.notion.calls.length, 0);
});

test("disconnecting forgets the token", async (context) => {
  const setup = await connector(context);
  await setup.connectToken(TOKEN);

  await setup.disconnect();

  assert.deepEqual(await setup.status(), { connected: false });
  assert.equal(await setup.token(), null);
});
