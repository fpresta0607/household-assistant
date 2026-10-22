// Connect Google from the Steward app, the gateway's half, from
// deploy/openclaw/plugins/household-app/google-connect.js.
//
// Google's token endpoint is a stand-in, so nothing here reaches Google.
// Run with `node --test tests/js/household_app_google_connect.test.mjs`.

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import {
  GOOGLE_SCOPES,
  createGoogleConnector,
  googleAbilities,
  listGogAccounts,
  redirectUriFor,
  removeGogAccount,
} from "../../deploy/openclaw/plugins/household-app/google-connect.js";

const CLIENT_ID = "123456789012-abc123def456.apps.googleusercontent.com";
const VERIFIER = "v".repeat(43);
const REFRESH = "1//refresh-token-from-google";
const START = Date.UTC(2026, 9, 15, 14, 0);

function idToken(claims) {
  const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "RS256" })}.${part(claims)}.signature`;
}

function fakeGoogle({ grant = {}, refresh = {}, status = 200 } = {}) {
  const calls = [];
  return {
    calls,
    async fetch(url, init) {
      const form = Object.fromEntries(new URLSearchParams(init.body));
      calls.push({ url: String(url), form });
      if (String(url).endsWith("/revoke")) return { ok: true, status: 200, json: async () => ({}) };
      const body = form.grant_type === "authorization_code"
        ? {
            access_token: "access-1", expires_in: 3599, refresh_token: REFRESH,
            scope: `openid ${GOOGLE_SCOPES.gmail} ${GOOGLE_SCOPES.calendar} https://www.googleapis.com/auth/userinfo.email`,
            id_token: idToken({ email: "gia@example.com", email_verified: true, aud: CLIENT_ID }),
            ...grant,
          }
        : { access_token: `access-${calls.length}`, expires_in: 3599, ...refresh };
      return { ok: status === 200, status, json: async () => body };
    },
  };
}

async function connector(context, google = fakeGoogle(), clock = { now: START }) {
  const directory = await mkdtemp(path.join(tmpdir(), "google-connect-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const made = createGoogleConnector({
    directory, clientId: CLIENT_ID, keyringPassword: "keyring-password", fetch: google.fetch, now: () => clock.now,
  });
  return { ...made, directory, google, clock };
}

const request = { code: "4/0Acode", codeVerifier: VERIFIER, redirectUri: redirectUriFor(CLIENT_ID) };

test("the redirect is the iOS client's own reversed-id scheme", () => {
  assert.equal(redirectUriFor(CLIENT_ID), "com.googleusercontent.apps.123456789012-abc123def456:/oauthredirect");
});

test("a code from the app is exchanged once, with PKCE and no secret, and the person is connected", async (context) => {
  const setup = await connector(context);

  const answer = await setup.connect(request);

  assert.deepEqual(answer, { connected: true, email: "gia@example.com", services: ["gmail", "calendar"] });
  const [exchange] = setup.google.calls;
  assert.equal(exchange.url, "https://oauth2.googleapis.com/token");
  assert.deepEqual(exchange.form, {
    client_id: CLIENT_ID, code: "4/0Acode", code_verifier: VERIFIER,
    grant_type: "authorization_code", redirect_uri: redirectUriFor(CLIENT_ID),
  });
  assert.deepEqual(await setup.status(), {
    connected: true, email: "gia@example.com", name: null, services: ["gmail", "calendar"], connectedAt: START, problem: null,
  });
});

test("the refresh token is kept encrypted, readable only by the gateway's user", async (context) => {
  const setup = await connector(context);
  await setup.connect(request);

  const file = path.join(setup.directory, "google.json");
  const kept = await readFile(file, "utf8");
  assert.doesNotMatch(kept, /refresh-token-from-google/);
  if (process.platform !== "win32") assert.equal((await stat(file)).mode & 0o777, 0o600);
});

test("an access token is minted from the kept refresh token and reused until it nearly expires", async (context) => {
  const setup = await connector(context);
  await setup.connect(request);

  const first = await setup.accessToken();
  assert.equal(await setup.accessToken(), first);
  setup.clock.now += 3600_000;
  const second = await setup.accessToken();

  assert.notEqual(second, first);
  const refreshes = setup.google.calls.filter((call) => call.form.grant_type === "refresh_token");
  assert.equal(refreshes.length, 2);
  assert.deepEqual(refreshes[0].form, { client_id: CLIENT_ID, grant_type: "refresh_token", refresh_token: REFRESH });
});

test("a connector opened again with the same keyring password reads what was kept", async (context) => {
  const setup = await connector(context);
  await setup.connect(request);

  const again = createGoogleConnector({
    directory: setup.directory, clientId: CLIENT_ID, keyringPassword: "keyring-password", fetch: setup.google.fetch, now: () => START,
  });
  assert.equal((await again.status()).connected, true);
  assert.ok(await again.accessToken());
  const wrong = createGoogleConnector({
    directory: setup.directory, clientId: CLIENT_ID, keyringPassword: "another", fetch: setup.google.fetch, now: () => START,
  });
  await assert.rejects(wrong.accessToken(), /cannot be opened/);
});

for (const [why, change] of [
  ["no code", { code: "" }],
  ["an oversized code", { code: "x".repeat(4097) }],
  ["a verifier PKCE does not allow", { codeVerifier: "short" }],
  ["another app's redirect", { redirectUri: "com.example.other:/oauthredirect" }],
]) {
  test(`a request with ${why} is refused before Google is asked`, async (context) => {
    const setup = await connector(context);

    await assert.rejects(setup.connect({ ...request, ...change }), (error) => error.code === "INVALID_REQUEST");
    assert.equal(setup.google.calls.length, 0);
  });
}

for (const [why, grant] of [
  ["no refresh token", { refresh_token: undefined }],
  ["Gmail not granted", { scope: `openid ${GOOGLE_SCOPES.calendar}` }],
  ["Calendar not granted", { scope: `openid ${GOOGLE_SCOPES.gmail}` }],
  ["an unverified email", { id_token: idToken({ email: "gia@example.com", email_verified: false }) }],
]) {
  test(`Google's answer with ${why} connects nothing`, async (context) => {
    const setup = await connector(context, fakeGoogle({ grant }));

    await assert.rejects(setup.connect(request), (error) => error.code === "INVALID_REQUEST");
    assert.deepEqual(await setup.status(), { connected: false });
  });
}

test("a refused exchange says so without echoing Google's answer", async (context) => {
  const setup = await connector(context, fakeGoogle({ status: 400 }));

  await assert.rejects(setup.connect(request), (error) => error.code === "INVALID_REQUEST" && !/refresh-token/.test(error.message));
});

test("disconnecting revokes the token at Google and forgets it", async (context) => {
  const setup = await connector(context);
  await setup.connect(request);

  assert.deepEqual(await setup.disconnect(), { connected: false });

  const revoke = setup.google.calls.find((call) => call.url.endsWith("/revoke"));
  assert.deepEqual(revoke.form, { token: REFRESH });
  assert.deepEqual(await setup.status(), { connected: false });
  await assert.rejects(setup.accessToken(), /not connected/);
});

test("nothing is connected before the first sign-in", async (context) => {
  const setup = await connector(context);
  assert.deepEqual(await setup.status(), { connected: false });
  await assert.rejects(setup.accessToken(), /not connected/);
});

test("a gateway with no iOS client id reads as not connected and refuses a sign-in plainly", async (context) => {
  const directory = await mkdtemp(path.join(tmpdir(), "google-connect-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const google = fakeGoogle();
  const unset = createGoogleConnector({ directory, clientId: undefined, keyringPassword: undefined, fetch: google.fetch });

  assert.deepEqual(await unset.status(), { connected: false });
  await assert.rejects(unset.connect(request), (error) => error.code === "INVALID_REQUEST" && /not set up/.test(error.message));
  assert.equal(google.calls.length, 0);
});

test("the person's Google name is kept with the account when Google gives one", async (context) => {
  const setup = await connector(context, fakeGoogle({ grant: { id_token: idToken({ email: "gia@example.com", email_verified: true, name: "Gia Marlowe" }) } }));

  await setup.connect(request);

  assert.equal((await setup.status()).name, "Gia Marlowe");
});

test("a renewal Google refuses marks the account expired, any other failure failing, and a success clears it", async (context) => {
  const answers = [];
  const google = {
    calls: [],
    async fetch(url, init) {
      const form = Object.fromEntries(new URLSearchParams(init.body));
      if (form.grant_type === "authorization_code") return fakeGoogle().fetch(url, init);
      const [status, body] = answers.shift();
      return { ok: status === 200, status, json: async () => body };
    },
  };
  const setup = await connector(context, google);
  await setup.connect(request);

  answers.push([400, { error: "invalid_grant" }]);
  await assert.rejects(setup.accessToken(), /refused to refresh/);
  assert.equal((await setup.status()).problem, "expired");
  answers.push([503, {}]);
  await assert.rejects(setup.accessToken(), /refused to refresh/);
  assert.equal((await setup.status()).problem, "failing");
  answers.push([200, { access_token: "access-9", expires_in: 3599 }]);
  assert.equal(await setup.accessToken(), "access-9");
  assert.equal((await setup.status()).problem, null);
});

test("the app is told how to start a Google sign-in, and nothing when the gateway has no iOS client", async (context) => {
  const setup = await connector(context);
  assert.deepEqual(setup.oauth(), {
    provider: "google",
    clientId: CLIENT_ID,
    authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    scopes: ["openid", "email", "profile", GOOGLE_SCOPES.gmail, GOOGLE_SCOPES.calendar],
    redirectUri: redirectUriFor(CLIENT_ID),
    usesPkce: true,
  });
  const unset = createGoogleConnector({ directory: setup.directory, clientId: undefined, keyringPassword: undefined });
  assert.equal(unset.oauth(), null);
});

for (const [scopes, words] of [
  [[GOOGLE_SCOPES.gmail, GOOGLE_SCOPES.calendar], ["Reads your Gmail", "Reads and adds events in Google Calendar"]],
  [["email", GOOGLE_SCOPES.gmail, "https://www.googleapis.com/auth/userinfo.email"], ["Reads your Gmail"]],
  [["https://www.googleapis.com/auth/calendar.readonly", "https://www.googleapis.com/auth/gmail.send"], ["Sends mail you ask it to send", "Reads your Google Calendar"]],
  [["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/contacts.readonly"], ["Reads your Google Drive", "Reads your contacts"]],
  [[], []],
]) {
  test(`a Google grant reads as plain words: ${words.join(", ") || "none"}`, () => {
    assert.deepEqual(googleAbilities(scopes), words);
  });
}

test("gog's own accounts are listed by email, scopes and added time, and none when gog cannot answer", async () => {
  const listed = JSON.stringify({ accounts: [
    { email: "franco@example.com", scopes: [GOOGLE_SCOPES.gmail], created_at: "2026-10-15T15:00:00Z", auth: "oauth", client: "default" },
    { email: "", scopes: [] },
  ] });
  const ran = [];
  const accounts = await listGogAccounts({ run: (command, args, options, done) => { ran.push([command, ...args]); done(null, listed); }, now: () => 1 });
  assert.deepEqual(ran, [["gog", "auth", "list", "--json"]]);
  assert.deepEqual(accounts, [{ email: "franco@example.com", scopes: [GOOGLE_SCOPES.gmail], createdAt: Date.UTC(2026, 9, 15, 15, 0) }]);
  assert.deepEqual(await listGogAccounts({ run: () => assert.fail("read again within the minute"), now: () => 2 }), accounts);
  assert.deepEqual(await listGogAccounts({ run: (command, args, options, done) => done(new Error("no keyring")), now: () => 120_000 }), []);
});

test("an account gog holds is removed by its email without a prompt, and the list is read again after", async () => {
  const ran = [];
  await removeGogAccount("franco@example.com", { run: (command, args, options, done) => { ran.push([command, ...args]); done(null); } });
  assert.deepEqual(ran, [["gog", "auth", "remove", "franco@example.com", "--force", "--no-input"]]);
  await assert.rejects(removeGogAccount("x@example.com", { run: (command, args, options, done) => done(new Error("boom")) }), /could not remove/);
  let read = 0;
  await listGogAccounts({ run: (command, args, options, done) => { read += 1; done(null, "{\"accounts\":[]}"); }, now: () => 3 });
  assert.equal(read, 1);
});
