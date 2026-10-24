// Connector sign-ins from the phone, the gateway's half, from
// deploy/openclaw/plugins/household-app/connect.js: what the phone signs, who may sign
// in, the replay guard it shares with settings changes, and the linked accounts it reads
// back, which carry no token, secret or expiry.
//
// Run with `node --test tests/js/household_app_connect.test.mjs`.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { CONNECT_VERSION, connectText, createConnect } from "../../deploy/openclaw/plugins/household-app/connect.js";
import { connectorsFor } from "../../deploy/openclaw/plugins/household-app/connectors.js";
import { openSettingsStore } from "../../deploy/openclaw/plugins/household-app/settings-store.js";

const NOW = Date.UTC(2026, 9, 15, 17, 0);
const MINUTE = 60_000;
const VERIFIER = "v".repeat(43);
const REDIRECT = "com.googleusercontent.apps.123456789012-abc:/oauthredirect";
const NOTION_TOKEN = "fixture-token-not-a-real-one-0001";
const GMAIL = "https://www.googleapis.com/auth/gmail.readonly";
const BOX_ACCOUNT = { email: "franco.work@example.com", scopes: [GMAIL], createdAt: NOW - 86_400_000 };
const BOX_ID = "gog:box:" + "0".repeat(8);
// The env names the skills read their sign-ins from, each named once apart from any value.
const ICLOUD_VARIABLE = "APPLECAL_PASSWORD";
const YAHOO_VARIABLE = "YAHOO_APP_PASSWORD_GIA";

function phone() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    key: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url"),
    sign: (signed) => sign(null, Buffer.from(connectText(signed), "utf8"), privateKey).toString("base64url"),
  };
}
const GIA = phone();
const FRANCO = phone();

function fakeGoogle() {
  const calls = [];
  let kept = null;
  return {
    calls,
    connector: {
      oauth: () => ({ provider: "google", clientId: "client", authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth", scopes: [GMAIL], redirectUri: REDIRECT, usesPkce: true }),
      async connect(request) {
        calls.push(["connect", request]);
        kept = { connected: true, email: "gia@example.com", name: "Gia", services: ["gmail", "calendar"], connectedAt: NOW, problem: null };
        return { connected: true, email: "gia@example.com", services: ["gmail", "calendar"] };
      },
      async disconnect() { calls.push(["disconnect"]); kept = null; return { connected: false }; },
      async status() { return kept ?? { connected: false }; },
    },
  };
}

function fakeNotion({ registered = false } = {}) {
  const calls = [];
  let kept = null;
  return {
    calls,
    connector: {
      kind: () => (registered ? "oauth" : "token"),
      oauth: () => (registered ? { provider: "notion", clientId: "notion-client", authorizeUrl: "https://api.notion.com/v1/oauth/authorize?owner=user", scopes: [], redirectUri: "steward://connector/notion", usesPkce: false } : null),
      async connectToken(token) { calls.push(["token", token]); kept = { token, name: "Gia's Notion", email: null, workspace: "Gia's Notion" }; },
      async connectCode(request) { calls.push(["code", request]); kept = { token: "oauth-access", name: "Gia", email: "gia@example.com", workspace: "Gia's Notion" }; },
      async status() { return kept ? { connected: true, name: kept.name, email: kept.email, workspace: kept.workspace, connectedAt: NOW } : { connected: false }; },
      async token() { return kept?.token ?? null; },
      async disconnect() { calls.push(["disconnect"]); kept = null; },
    },
  };
}

// The household's Microsoft app, as Corey's gateway has it: a lasting sign-in kept in the
// env file under MICROSOFT_LASTING, whose value only Microsoft and the gateway hold.
const MICROSOFT_LASTING = "MS_GRAPH_REFRESH_TOKEN";

function fakeMicrosoft({ registered = true } = {}) {
  const calls = [];
  let kept = null;
  return {
    calls,
    connector: {
      oauth: () => (registered ? { provider: "microsoft", clientId: "client", authorizeUrl: "https://login.microsoftonline.com/t/oauth2/v2.0/authorize", scopes: ["offline_access"], redirectUri: "steward://connector/outlook", usesPkce: true } : null),
      async connect(request) {
        calls.push(["connect", request]);
        kept = { email: "franco@example.com", name: "Franco", scopes: ["Mail.Read", "Calendars.ReadWrite"], connectedAt: NOW };
      },
      async status() { return kept ? { connected: true, ...kept } : { connected: false }; },
      async environment() { return kept ? { [MICROSOFT_LASTING]: "app-lasting-value", MS_GRAPH_CLIENT_ID: "client", MS_GRAPH_TENANT_ID: "t" } : null; },
      async disconnect() { calls.push(["disconnect"]); kept = null; },
    },
  };
}

async function setup(context, { env = {}, boxAccounts = [], assistant = "denise", notionRegistered = false, microsoftRegistered = true } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-connect-"));
  const store = openSettingsStore(path.join(directory, "settings.sqlite"));
  context.after(() => {
    store.close();
    return rm(directory, { recursive: true, force: true });
  });
  const google = fakeGoogle();
  const notion = fakeNotion({ registered: notionRegistered });
  const microsoft = fakeMicrosoft({ registered: microsoftRegistered });
  const removed = [];
  let held = [...boxAccounts];
  const connect = createConnect({
    connectors: () => connectorsFor(assistant),
    store,
    phoneKeys: async () => [GIA.key],
    google: () => google.connector,
    microsoft: () => microsoft.connector,
    notion: () => notion.connector,
    secretsDirectory: directory,
    keyringPassword: "keyring-password",
    gogAccounts: async () => held,
    removeGogAccount: async (email) => {
      removed.push(email);
      held = held.filter((account) => account.email !== email);
    },
    boxEnv: { ...env },
    env,
    now: () => NOW,
  });
  const byId = (id) => connectorsFor(assistant).find((one) => one.id === id);
  return { connect, store, google, microsoft, notion, removed, directory, env, byId };
}

// A signed request as the phone sends it: the named values, `replacing` and the
// signature over them all.
function asParams({ at = NOW - 1000, action = "connect", connector, named = {}, replacing, accountId }, by = GIA) {
  const values = [...Object.values(named), ...(replacing ? [replacing] : []), ...(accountId ? [accountId] : [])];
  return {
    at,
    connector,
    ...named,
    ...(replacing ? { replacing } : {}),
    ...(accountId ? { accountId } : {}),
    signature: by.sign({ at, action, connector, values }),
  };
}
const googleIn = (extra = {}) => ({ connector: "gog", named: { code: "4/0Acode", codeVerifier: VERIFIER, redirectUri: REDIRECT }, ...extra });
const accountIds = async (setup1, id) => (await setup1.connect.readBack(setup1.byId(id))).linkedAccounts.map((account) => account.id);

test("the shared vector: a Google connect signs its lines in order with no trailing newline", () => {
  assert.equal(CONNECT_VERSION, "household-app/connect/v1");
  assert.equal(
    connectText({ at: 1760000000000, action: "connect", connector: "gog", values: ["c", "v", "r"] }),
    "household-app/connect/v1\n1760000000000\nconnect\ngog\nc\nv\nr",
  );
  assert.equal(
    connectText({ at: 1760000000000, action: "disconnect", connector: "gog", values: [] }),
    "household-app/connect/v1\n1760000000000\ndisconnect\ngog",
  );
});

test("Gia's phone connects Google: the code goes to the exchange once, and her account reads back with what the assistant can do", async (context) => {
  const setup1 = await setup(context);

  await setup1.connect.connect(asParams(googleIn()));

  assert.deepEqual(setup1.google.calls, [["connect", { code: "4/0Acode", codeVerifier: VERIFIER, redirectUri: REDIRECT }]]);
  const google = await setup1.connect.readBack(setup1.byId("gog"));
  assert.equal(google.signInKind, "oauth");
  assert.equal(google.oauth.provider, "google");
  assert.equal(google.reason, null);
  assert.deepEqual(google.linkedAccounts, [{
    id: "gog:app",
    name: "Gia",
    email: "gia@example.com",
    linkedAt: NOW,
    status: "ok",
    abilities: ["Reads your Gmail", "Reads and adds events in Google Calendar"],
    canDisconnect: true,
  }]);
});

test("Google accounts gog holds on the box read back too, each with its own grant and a stable id", async (context) => {
  const setup1 = await setup(context, { boxAccounts: [BOX_ACCOUNT], assistant: "corey" });

  const [account] = (await setup1.connect.readBack(setup1.byId("gog"))).linkedAccounts;

  assert.match(account.id, /^gog:box:[0-9a-f]{8}$/);
  assert.deepEqual({ ...account, id: BOX_ID }, {
    id: BOX_ID, name: BOX_ACCOUNT.email, email: BOX_ACCOUNT.email, linkedAt: BOX_ACCOUNT.createdAt,
    status: "ok", abilities: ["Reads your Gmail"], canDisconnect: true,
  });
  assert.deepEqual(await accountIds(setup1, "gog"), [account.id], "the same id on every read");
});

test("an Apple or mail app password is kept sealed, and reads back as the account it signs in", async (context) => {
  const setup1 = await setup(context);

  await setup1.connect.connect(asParams({ connector: "himalaya", named: { username: "gia@example.com", secret: "abcd-efgh-ijkl-mnop" } }));

  const kept = await readFile(path.join(setup1.directory, "connectors", "himalaya.json"), "utf8");
  assert.doesNotMatch(kept, /abcd-efgh-ijkl-mnop|gia@example\.com/);
  const mail = await setup1.connect.readBack(setup1.byId("himalaya"));
  assert.equal(mail.signInKind, "password");
  assert.deepEqual(mail.linkedAccounts, [{
    id: "himalaya:app", name: "gia@example.com", email: "gia@example.com", linkedAt: NOW, status: "ok",
    abilities: ["Reads your inbox", "Sends mail you ask it to send"], canDisconnect: true,
  }]);
  assert.deepEqual(await setup1.connect.secret("himalaya"), { username: "gia@example.com", secret: "abcd-efgh-ijkl-mnop" });
});

test("a sign-in the box holds through its env file reads back as set on the box, which a phone cannot remove", async (context) => {
  const setup1 = await setup(context, { env: { [ICLOUD_VARIABLE]: "set" } });

  const icloud = await setup1.connect.readBack(setup1.byId("icloud"));

  assert.deepEqual(icloud.linkedAccounts, [{
    id: "icloud:box", name: "Set up on the assistant's computer", email: null, linkedAt: null, status: "ok",
    abilities: ["Reads your iCloud calendars", "Adds and changes events and reminders"], canDisconnect: false,
  }]);
  await assert.rejects(
    setup1.connect.disconnect(asParams({ action: "disconnect", connector: "icloud", accountId: "icloud:box" })),
    (error) => error.detailCode === "ACCOUNT_IS_ON_THE_BOX",
  );
});

test("a connector with no sign-in reads back none", async (context) => {
  const setup1 = await setup(context);
  assert.deepEqual(await setup1.connect.readBack(setup1.byId("weather")), { signInKind: null, linkedAccounts: [], oauth: null, reason: null });
});

test("Notion takes a pasted token, signed as one value, and the notion skill finds it as NOTION_API_TOKEN", async (context) => {
  const setup1 = await setup(context);
  const notion = await setup1.connect.readBack(setup1.byId("notion"));
  assert.equal(notion.signInKind, "token");
  assert.equal(notion.oauth, null);

  await setup1.connect.connect(asParams({ connector: "notion", named: { token: NOTION_TOKEN } }));

  assert.deepEqual(setup1.notion.calls, [["token", NOTION_TOKEN]]);
  assert.equal(setup1.env.NOTION_API_TOKEN, NOTION_TOKEN);
  assert.deepEqual((await setup1.connect.readBack(setup1.byId("notion"))).linkedAccounts, [{
    id: "notion:app", name: "Gia's Notion", email: null, linkedAt: NOW, status: "ok",
    abilities: ["Reads and edits the pages you share with it in Gia's Notion"], canDisconnect: true,
  }]);
});

test("with Notion's public connection registered, a code and redirect are signed and exchanged on the gateway", async (context) => {
  const setup1 = await setup(context, { notionRegistered: true });
  const notion = await setup1.connect.readBack(setup1.byId("notion"));
  assert.equal(notion.signInKind, "oauth");
  assert.equal(notion.oauth.usesPkce, false);

  await setup1.connect.connect(asParams({ connector: "notion", named: { code: "notion-code", redirectUri: "steward://connector/notion" } }));

  assert.deepEqual(setup1.notion.calls, [["code", { code: "notion-code", redirectUri: "steward://connector/notion" }]]);
  assert.equal(setup1.env.NOTION_API_TOKEN, "oauth-access");
});

test("disconnecting Notion by its account forgets the token and takes it out of the environment", async (context) => {
  const setup1 = await setup(context);
  await setup1.connect.connect(asParams({ at: NOW - 2000, connector: "notion", named: { token: NOTION_TOKEN } }));

  await setup1.connect.disconnect(asParams({ action: "disconnect", connector: "notion", accountId: "notion:app" }));

  assert.deepEqual(setup1.notion.calls.at(-1), ["disconnect"]);
  assert.equal("NOTION_API_TOKEN" in setup1.env, false);
  assert.deepEqual(await accountIds(setup1, "notion"), []);
});

test("the token kept from an earlier sign-in is put back in the environment when the gateway starts", async (context) => {
  const setup1 = await setup(context);
  await setup1.connect.connect(asParams({ connector: "notion", named: { token: NOTION_TOKEN } }));
  delete setup1.env.NOTION_API_TOKEN;

  await setup1.connect.exportEnv();

  assert.equal(setup1.env.NOTION_API_TOKEN, NOTION_TOKEN);
});

test("disconnecting with no account keeps build 13's meaning: the connector's in-app sign-in", async (context) => {
  const setup1 = await setup(context);
  await setup1.connect.connect(asParams(googleIn({ at: NOW - 2000 })));

  await setup1.connect.disconnect(asParams({ action: "disconnect", connector: "gog" }));

  assert.deepEqual(setup1.google.calls.at(-1), ["disconnect"]);
  assert.deepEqual(await accountIds(setup1, "gog"), []);
});

test("a Google account gog holds is disconnected by its id, through gog, and nothing else goes", async (context) => {
  const setup1 = await setup(context, { boxAccounts: [BOX_ACCOUNT], assistant: "corey" });
  const [id] = await accountIds(setup1, "gog");

  await setup1.connect.disconnect(asParams({ action: "disconnect", connector: "gog", accountId: id }));

  assert.deepEqual(setup1.removed, [BOX_ACCOUNT.email]);
  assert.deepEqual(setup1.google.calls, []);
  assert.deepEqual(await accountIds(setup1, "gog"), []);
});

test("Switch account: the new Google account is linked first, then the one it replaces goes", async (context) => {
  const setup1 = await setup(context, { boxAccounts: [BOX_ACCOUNT], assistant: "corey" });
  const [old] = await accountIds(setup1, "gog");

  await setup1.connect.connect(asParams(googleIn({ replacing: old })));

  assert.deepEqual(setup1.google.calls.map(([call]) => call), ["connect"]);
  assert.deepEqual(setup1.removed, [BOX_ACCOUNT.email]);
  assert.deepEqual(await accountIds(setup1, "gog"), ["gog:app"]);
});

test("the account a switch replaces is signed: a request that names another one does not verify", async (context) => {
  const setup1 = await setup(context, { boxAccounts: [BOX_ACCOUNT], assistant: "corey" });
  const [old] = await accountIds(setup1, "gog");
  const params = asParams(googleIn({ replacing: old }));

  await assert.rejects(setup1.connect.connect({ ...params, replacing: "gog:app" }), (error) => error.detailCode === "SIGNATURE");
  const withoutReplacing = { ...params };
  delete withoutReplacing.replacing;
  await assert.rejects(setup1.connect.connect(withoutReplacing), (error) => error.detailCode === "SIGNATURE");
  assert.deepEqual(setup1.google.calls, []);
  assert.deepEqual(setup1.removed, []);
});

for (const [why, replacing, detailCode] of [
  ["an account the gateway does not hold", "gog:box:ffffffff", "NO_SUCH_ACCOUNT"],
  ["a sign-in set on the box", "icloud:box", "ACCOUNT_IS_ON_THE_BOX"],
]) {
  test(`a switch that would replace ${why} is refused before anything is exchanged`, async (context) => {
    const setup1 = await setup(context, { env: { [ICLOUD_VARIABLE]: "set" } });
    const connector = replacing.startsWith("icloud") ? "icloud" : "gog";
    const named = connector === "icloud" ? { username: "gia@icloud.example", secret: "abcd-efgh-ijkl-mnop" } : googleIn().named;

    await assert.rejects(setup1.connect.connect(asParams({ connector, named, replacing })), (error) => error.detailCode === detailCode);
    assert.deepEqual(setup1.google.calls, []);
  });
}

test("only the owner's phones may sign in, and nothing reaches Google otherwise", async (context) => {
  const setup1 = await setup(context);

  await assert.rejects(setup1.connect.connect(asParams(googleIn(), FRANCO)), /signature of one of the owner's phones/);
  await assert.rejects(setup1.connect.connect({ ...asParams(googleIn()), code: "4/0Aother" }), /signature/);
  assert.deepEqual(setup1.google.calls, []);
});

test("a disconnect by account is signed over that account, so one signed for nothing does not verify", async (context) => {
  const setup1 = await setup(context, { boxAccounts: [BOX_ACCOUNT], assistant: "corey" });
  const [id] = await accountIds(setup1, "gog");
  const unsigned = asParams({ action: "disconnect", connector: "gog" });

  await assert.rejects(setup1.connect.disconnect({ ...unsigned, accountId: id }), (error) => error.detailCode === "SIGNATURE");
  assert.deepEqual(setup1.removed, []);
});

test("a sign-in shares the settings replay guard: neither can be played again or against the other", async (context) => {
  const setup1 = await setup(context);
  assert.equal(setup1.store.acceptChangeAt(NOW - 500), true, "a settings change at NOW - 500");

  await assert.rejects(setup1.connect.connect(asParams(googleIn({ at: NOW - 1000 }))), /newer/);
  await setup1.connect.connect(asParams(googleIn({ at: NOW - 100 })));
  await assert.rejects(setup1.connect.connect(asParams(googleIn({ at: NOW - 100 }))), (error) => error.detailCode === "STALE");
  assert.equal(setup1.store.acceptChangeAt(NOW - 200), false, "a settings change older than the sign-in");
  assert.equal(setup1.google.calls.length, 1);
});

for (const [why, signed, rule, detailCode] of [
  ["a time out of range", googleIn({ at: NOW - 6 * MINUTE }), /time out of range/, "STALE"],
  ["an unknown connector", { connector: "dropbox", named: { username: "a", secret: "b" } }, /no such connector/, "BAD_VALUE"],
  ["a connector with no sign-in", { connector: "weather", named: { username: "a", secret: "b" } }, /needs no sign-in/, "BAD_VALUE"],
  ["Outlook, which is Corey's only", { connector: "outlook-hack", named: { username: "a", secret: "b" } }, /no such connector/, "BAD_VALUE"],
  ["a value over two lines", { connector: "himalaya", named: { username: "gia@example.com", secret: "one\ntwo" } }, /one line/, "BAD_VALUE"],
  ["an empty app password", { connector: "himalaya", named: { username: "gia@example.com", secret: "" } }, /username and an app password/, "BAD_VALUE"],
  ["a Google sign-in with no verifier", { connector: "gog", named: { code: "4/0Acode", codeVerifier: "", redirectUri: REDIRECT } }, /code, verifier and redirect/, "BAD_VALUE"],
  ["a Notion sign-in with no token", { connector: "notion", named: { token: "" } }, /integration token/, "BAD_VALUE"],
]) {
  test(`a sign-in with ${why} is refused with its detail code, saying only which rule failed`, async (context) => {
    const setup1 = await setup(context);

    await assert.rejects(setup1.connect.connect(asParams(signed)), (error) => {
      assert.equal(error.code, "INVALID_REQUEST");
      assert.equal(error.detailCode, detailCode);
      assert.match(error.message, rule);
      assert.doesNotMatch(error.message, /4\/0Acode|v{43}|abcd/);
      return true;
    });
    assert.deepEqual(setup1.google.calls, []);
    assert.deepEqual(setup1.notion.calls, []);
  });
}

test("nothing read back for any connector carries a token, a secret or an expiry", async (context) => {
  const setup1 = await setup(context, { env: { [ICLOUD_VARIABLE]: "set" }, boxAccounts: [BOX_ACCOUNT] });
  await setup1.connect.connect(asParams(googleIn({ at: NOW - 3000 })));
  await setup1.connect.connect(asParams({ at: NOW - 2000, connector: "notion", named: { token: NOTION_TOKEN } }));
  await setup1.connect.connect(asParams({ connector: "himalaya", named: { username: "gia@example.com", secret: "abcd-efgh-ijkl-mnop" } }));

  const everything = JSON.stringify(await Promise.all(connectorsFor("denise").map((connector) => setup1.connect.readBack(connector))));

  assert.doesNotMatch(everything, /fixture-token|abcd-efgh|oauth-access|"(?:access|refresh)?token":|"secret":|expir/i);
});

test("an iCloud app password typed on the phone goes where the calendar skill reads it, and the box's comes back on a disconnect", async (context) => {
  const setup1 = await setup(context, { env: { [ICLOUD_VARIABLE]: "box-value" } });

  await setup1.connect.connect(asParams({ at: NOW - 2000, connector: "icloud", named: { username: "gia@icloud.example", secret: "abcd-efgh-ijkl-mnop" } }));

  assert.equal(setup1.env[ICLOUD_VARIABLE], "abcd-efgh-ijkl-mnop");
  assert.deepEqual(await accountIds(setup1, "icloud"), ["icloud:app"]);
  await setup1.connect.disconnect(asParams({ action: "disconnect", connector: "icloud", accountId: "icloud:app" }));
  assert.equal(setup1.env[ICLOUD_VARIABLE], "box-value");
  assert.deepEqual(await accountIds(setup1, "icloud"), ["icloud:box"]);
});

test("scripture needs no sign-in: it reads the Bible in the gateway", async (context) => {
  const setup1 = await setup(context);

  assert.equal((await setup1.connect.readBack(setup1.byId("scripture"))).signInKind, null);
  assert.equal("SIQSERMON_USERNAME" in setup1.env || "SIQSERMON_PASSWORD" in setup1.env, false);
});

test("a typed sign-in kept from before is put back where its skill reads it when the gateway starts", async (context) => {
  const setup1 = await setup(context);
  await setup1.connect.connect(asParams({ connector: "himalaya", named: { username: "gia@example.com", secret: "abcd-efgh-ijkl-mnop" } }));
  delete setup1.env[YAHOO_VARIABLE];

  await setup1.connect.exportEnv();

  assert.equal(setup1.env[YAHOO_VARIABLE], "abcd-efgh-ijkl-mnop");
});

test("Outlook on Corey's gateway reads its box sign-in until the phone signs in, which then goes where the assistant reads it", async (context) => {
  const setup1 = await setup(context, { assistant: "corey", env: { [MICROSOFT_LASTING]: "box-lasting-value", MS_GRAPH_CLIENT_ID: "client", MS_GRAPH_TENANT_ID: "t" } });
  const before = await setup1.connect.readBack(setup1.byId("outlook-hack"));
  assert.equal(before.signInKind, "oauth");
  assert.equal(before.oauth.provider, "microsoft");
  assert.deepEqual(before.linkedAccounts.map((account) => [account.id, account.canDisconnect]), [["outlook-hack:box", false]]);

  await setup1.connect.connect(asParams({ at: NOW - 2000, connector: "outlook-hack", named: { code: "M.code", codeVerifier: VERIFIER, redirectUri: "steward://connector/outlook" } }));

  assert.deepEqual(setup1.microsoft.calls, [["connect", { code: "M.code", codeVerifier: VERIFIER, redirectUri: "steward://connector/outlook" }]]);
  assert.equal(setup1.env[MICROSOFT_LASTING], "app-lasting-value");
  assert.deepEqual((await setup1.connect.readBack(setup1.byId("outlook-hack"))).linkedAccounts, [{
    id: "outlook-hack:app", name: "Franco", email: "franco@example.com", linkedAt: NOW, status: "ok",
    abilities: ["Reads your Outlook mail", "Reads and changes your Outlook calendar"], canDisconnect: true,
  }]);

  await setup1.connect.disconnect(asParams({ action: "disconnect", connector: "outlook-hack", accountId: "outlook-hack:app" }));
  assert.equal(setup1.env[MICROSOFT_LASTING], "box-lasting-value", "the box's own sign-in comes back");
});

test("Outlook offers no sign-in on a gateway without the household's Microsoft app", async (context) => {
  const setup1 = await setup(context, { assistant: "corey", microsoftRegistered: false });
  assert.deepEqual(await setup1.connect.readBack(setup1.byId("outlook-hack")), { signInKind: null, linkedAccounts: [], oauth: null, reason: null });
});
