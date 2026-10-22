// Connect Outlook from the Steward app, the gateway's half, from
// deploy/openclaw/plugins/household-app/microsoft-connect.js.
//
// Microsoft's token endpoint is a stand-in, so nothing here reaches Microsoft.
// Run with `node --test tests/js/household_app_microsoft_connect.test.mjs`.

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import {
  MICROSOFT_ENV,
  MICROSOFT_REDIRECT,
  MICROSOFT_SCOPES,
  createMicrosoftConnector,
  microsoftAbilities,
} from "../../deploy/openclaw/plugins/household-app/microsoft-connect.js";

const CLIENT = "00000000-1111-2222-3333-444444444444";
const TENANT = "55555555-6666-7777-8888-999999999999";
const VERIFIER = "v".repeat(43);
const START = Date.UTC(2026, 9, 15, 23, 0);
const STAND_IN = "fixture-lasting-value-0001";
// The env name the assistant reads its lasting sign-in from, named once apart from any value.
const [LASTING_VARIABLE] = MICROSOFT_ENV;

function idToken(claims) {
  const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "RS256" })}.${part(claims)}.signature`;
}

function fakeMicrosoft({ status = 200, grant = {} } = {}) {
  const calls = [];
  return {
    calls,
    async fetch(url, init) {
      calls.push({ url: String(url), form: Object.fromEntries(new URLSearchParams(init.body)) });
      const body = {
        token_type: "Bearer", expires_in: 3599, access_token: "graph-access", refresh_token: STAND_IN,
        scope: "openid email profile offline_access User.Read Mail.Read Calendars.ReadWrite",
        id_token: idToken({ name: "Franco Marlowe", preferred_username: "franco@example.com" }),
        ...grant,
      };
      return { ok: status === 200, status, json: async () => (status === 200 ? body : { error: "invalid_grant" }) };
    },
  };
}

async function connector(context, { microsoft = fakeMicrosoft(), clientId = CLIENT, tenantId = TENANT } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "microsoft-connect-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const made = createMicrosoftConnector({ directory, clientId, tenantId, keyringPassword: "keyring-password", fetch: microsoft.fetch, now: () => START });
  return { ...made, directory, microsoft };
}

const request = { code: "M.code", codeVerifier: VERIFIER, redirectUri: MICROSOFT_REDIRECT };

test("the app is told how to start an Outlook sign-in with the household's Microsoft app, with PKCE and no secret", async (context) => {
  const setup = await connector(context);
  assert.deepEqual(setup.oauth(), {
    provider: "microsoft",
    clientId: CLIENT,
    authorizeUrl: `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/authorize`,
    scopes: MICROSOFT_SCOPES,
    redirectUri: "steward://connector/outlook",
    usesPkce: true,
  });
  assert.ok(MICROSOFT_SCOPES.includes("offline_access"));
});

test("a gateway without the Microsoft app offers no sign-in and refuses one plainly", async (context) => {
  const setup = await connector(context, { clientId: null });
  assert.equal(setup.oauth(), null);
  await assert.rejects(setup.connect(request), (error) => error.detailCode === "SIGNIN_NOT_SET_UP");
  assert.equal(setup.microsoft.calls.length, 0);
});

test("a code is exchanged once with its verifier and no secret, and the account is kept with no token in the clear", async (context) => {
  const setup = await connector(context);

  await setup.connect(request);

  const [exchange] = setup.microsoft.calls;
  assert.equal(exchange.url, `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token`);
  assert.deepEqual(exchange.form, {
    client_id: CLIENT, grant_type: "authorization_code", code: "M.code", redirect_uri: MICROSOFT_REDIRECT, code_verifier: VERIFIER,
    scope: MICROSOFT_SCOPES.join(" "),
  });
  assert.deepEqual(await setup.status(), {
    connected: true, email: "franco@example.com", name: "Franco Marlowe",
    scopes: ["openid", "email", "profile", "offline_access", "User.Read", "Mail.Read", "Calendars.ReadWrite"], connectedAt: START,
  });
  assert.doesNotMatch(await readFile(path.join(setup.directory, "microsoft.json"), "utf8"), new RegExp(STAND_IN));
});

test("the assistant's environment gets the kept sign-in with the same app's client and tenant", async (context) => {
  const setup = await connector(context);
  await setup.connect(request);

  const environment = await setup.environment();

  assert.deepEqual(Object.keys(environment), MICROSOFT_ENV);
  assert.equal(environment[LASTING_VARIABLE], STAND_IN);
  assert.equal(environment.MS_GRAPH_CLIENT_ID, CLIENT);
  assert.equal(environment.MS_GRAPH_TENANT_ID, TENANT);
});

for (const [why, microsoft, given, detailCode] of [
  ["Microsoft refuses the code", fakeMicrosoft({ status: 400 }), request, "PROVIDER_REFUSED"],
  ["no mail access was granted", fakeMicrosoft({ grant: { scope: "openid offline_access Calendars.ReadWrite" } }), request, "SCOPES_MISSING"],
  ["no email names the account", fakeMicrosoft({ grant: { id_token: idToken({ name: "Franco" }) } }), request, "PROVIDER_REFUSED"],
  ["the redirect is not the app's", fakeMicrosoft(), { ...request, redirectUri: "https://elsewhere.example/cb" }, "BAD_VALUE"],
  ["the verifier is too short", fakeMicrosoft(), { ...request, codeVerifier: "short" }, "BAD_VALUE"],
]) {
  test(`a sign-in is refused and nothing is kept when ${why}`, async (context) => {
    const setup = await connector(context, { microsoft });
    await assert.rejects(setup.connect(given), (error) => error.code === "INVALID_REQUEST" && error.detailCode === detailCode);
    assert.deepEqual(await setup.status(), { connected: false });
  });
}

test("disconnecting forgets the kept sign-in", async (context) => {
  const setup = await connector(context);
  await setup.connect(request);

  await setup.disconnect();

  assert.deepEqual(await setup.status(), { connected: false });
  assert.equal(await setup.environment(), null);
});

for (const [scopes, words] of [
  [["Mail.Read", "Calendars.ReadWrite", "offline_access"], ["Reads your Outlook mail", "Reads and changes your Outlook calendar"]],
  [["https://graph.microsoft.com/Mail.ReadWrite", "Mail.Send"], ["Reads your Outlook mail and writes drafts", "Sends mail you ask it to send"]],
  [["openid", "User.Read"], []],
]) {
  test(`a Microsoft grant reads as plain words: ${words.join(", ") || "none"}`, () => {
    assert.deepEqual(microsoftAbilities(scopes), words);
  });
}
