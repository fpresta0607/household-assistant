// Connector sign-ins from the owner's phone: the gateway's half of
// household-app.connector.connect and .disconnect, and what household-app.settings shows
// of each connector's accounts.
//
// Each is signed by the phone's device key over household-app/connect/v1 and checked
// against the gateway owner's paired phones only, as a settings change is, and shares the
// settings replay guard, so neither can be played again or against the other. Google and
// Notion send an authorization code, which google-connect.js and notion-connect.js
// exchange here; Notion also takes a pasted integration token, and a typed sign-in (an
// Apple or mail app password) is kept sealed under the gateway's keyring password.
//
// What a phone reads back is each linked account the owner holds on this gateway: its
// name, email, linked time, status and what the assistant can do with it in plain words,
// which the owner asked to see on 15 October. Never a token, a secret or an expiry, and
// never the other person's accounts, which live on the other gateway. The code, verifier,
// token and secret are never logged or echoed, and the code and verifier are forgotten
// once used.

import { createHash } from "node:crypto";
import path from "node:path";

import { googleAbilities, GOOGLE_SCOPES } from "./google-connect.js";
import { MICROSOFT_ENV, microsoftAbilities } from "./microsoft-connect.js";
import { RoomError } from "./room-error.js";
import { createSealedFile } from "./sealed-file.js";
import { isTextSignedBy } from "./signature.js";

export const CONNECT_VERSION = "household-app/connect/v1";
const SIGNED_WITHIN_MS = 5 * 60_000;
const LINE = /^[^\r\n]*$/;
const LIMITS = { code: 4096, codeVerifier: 128, redirectUri: 200, username: 254, secret: 256, token: 256, account: 128 };
const SET_ON_THE_BOX = "Set up on the assistant's computer";

const refuse = (message, detailCode = "BAD_VALUE") => {
  throw new RoomError("INVALID_REQUEST", message, detailCode);
};

// The exact text the phone signs: one line each, no trailing newline.
export function connectText({ at, action, connector, values }) {
  return [CONNECT_VERSION, String(at), action, connector, ...values].join("\n");
}

function oneLine(value, limit) {
  return typeof value === "string" && value.length <= limit && LINE.test(value);
}

// How a connector signs in: Notion's depends on whether its OAuth is registered here, and
// Outlook has a sign-in only where the household's Microsoft app is.
function signInKindOf(connector, notion, microsoft) {
  if (connector.id === "notion") return notion().kind();
  if (connector.id === "outlook-hack") return microsoft().oauth() ? "oauth" : null;
  return connector.signInKind ?? connector.signIn ?? null;
}

const boxGoogleId = (email) => `gog:box:${createHash("sha256").update(email).digest("hex").slice(0, 8)}`;

// `connectors` answers with this gateway's connectors, `store` is settings-store.js's (for
// the shared replay guard), `google`, `microsoft` and `notion` build this gateway's
// google-connect.js, microsoft-connect.js and notion-connect.js connectors, `gogAccounts` lists the Google accounts gog itself
// holds and `removeGogAccount` takes one off, `boxEnv` is the gateway's environment as the
// box started it, where a sign-in from its env file shows, and `env` is the live one, where
// each skill finds its sign-in: NOTION_API_TOKEN, or a typed sign-in's own names.
export function createConnect({
  connectors, store, phoneKeys, google, microsoft, notion, secretsDirectory, keyringPassword, gogAccounts, removeGogAccount, boxEnv, env, now = Date.now,
}) {
  const typed = (id) => createSealedFile(path.join(secretsDirectory, "connectors", `${id}.json`), keyringPassword);

  async function typedSignIn(id) {
    const file = typed(id);
    const kept = await file.read();
    return kept ? { username: file.open(kept.username), secret: file.open(kept.secret) } : null;
  }

  function connectorOf(id) {
    const connector = connectors().find((one) => one.id === id);
    if (!connector) refuse("no such connector on this gateway");
    if (!signInKindOf(connector, notion, microsoft)) refuse("that connector needs no sign-in");
    return connector;
  }

  async function checked(params, action, values) {
    const { at, connector: id, signature } = params ?? {};
    if (!Number.isSafeInteger(at) || Math.abs(at - now()) > SIGNED_WITHIN_MS) refuse("sign-in time out of range", "STALE");
    if (typeof id !== "string" || !oneLine(id, 64)) refuse("no such connector on this gateway");
    const connector = connectorOf(id);
    if (!isTextSignedBy(connectText({ at, action, connector: id, values }), signature, await phoneKeys())) {
      refuse("a sign-in must carry the signature of one of the owner's phones", "SIGNATURE");
    }
    if (!store.acceptChangeAt(at)) refuse("the gateway already has a newer change", "STALE");
    return connector;
  }

  async function readBack(connector) {
    const signInKind = signInKindOf(connector, notion, microsoft);
    if (!signInKind) return { signInKind: null, linkedAccounts: [], oauth: null, reason: null };
    if (connector.id === "gog") {
      const linkedAccounts = [];
      const inApp = await google().status();
      if (inApp.connected) {
        linkedAccounts.push({
          id: "gog:app",
          name: inApp.name ?? inApp.email,
          email: inApp.email,
          linkedAt: inApp.connectedAt,
          status: inApp.problem ?? "ok",
          abilities: googleAbilities(inApp.services.map((service) => GOOGLE_SCOPES[service])),
          canDisconnect: true,
        });
      }
      for (const account of await gogAccounts()) {
        linkedAccounts.push({
          id: boxGoogleId(account.email),
          name: account.email,
          email: account.email,
          linkedAt: account.createdAt,
          status: "ok",
          abilities: googleAbilities(account.scopes),
          canDisconnect: true,
        });
      }
      const oauth = google().oauth();
      const reason = !oauth && linkedAccounts.length === 0 ? "Google sign-in is not set up on this gateway yet" : null;
      return { signInKind, linkedAccounts, oauth, reason };
    }
    if (connector.id === "outlook-hack") {
      const kept = await microsoft().status();
      const linkedAccounts = [];
      if (kept.connected) {
        linkedAccounts.push({
          id: "outlook-hack:app",
          name: kept.name ?? kept.email,
          email: kept.email,
          linkedAt: kept.connectedAt,
          status: "ok",
          abilities: microsoftAbilities(kept.scopes),
          canDisconnect: true,
        });
      } else if (boxEnv.MS_GRAPH_REFRESH_TOKEN) {
        linkedAccounts.push({
          id: "outlook-hack:box", name: SET_ON_THE_BOX, email: null, linkedAt: null, status: "ok",
          abilities: [...connector.capabilities], canDisconnect: false,
        });
      }
      return { signInKind, linkedAccounts, oauth: microsoft().oauth(), reason: null };
    }
    if (connector.id === "notion") {
      const kept = await notion().status();
      const linkedAccounts = kept.connected
        ? [{
          id: "notion:app",
          name: kept.name ?? "Notion",
          email: kept.email,
          linkedAt: kept.connectedAt,
          status: "ok",
          abilities: kept.workspace ? [`Reads and edits the pages you share with it in ${kept.workspace}`] : [...connector.capabilities],
          canDisconnect: true,
        }]
        : [];
      return { signInKind, linkedAccounts, oauth: notion().oauth(), reason: null };
    }
    const file = typed(connector.id);
    const kept = await file.read();
    const linkedAccounts = [];
    if (kept) {
      const username = file.open(kept.username);
      linkedAccounts.push({
        id: `${connector.id}:app`,
        name: username,
        email: username.includes("@") ? username : null,
        linkedAt: kept.connectedAt ?? null,
        status: "ok",
        abilities: [...connector.capabilities],
        canDisconnect: true,
      });
    } else if (connector.envSignIn && boxEnv[connector.envSignIn]) {
      linkedAccounts.push({
        id: `${connector.id}:box`,
        name: SET_ON_THE_BOX,
        email: null,
        linkedAt: null,
        status: "ok",
        abilities: [...connector.capabilities],
        canDisconnect: false,
      });
    }
    return { signInKind, linkedAccounts, oauth: null, reason: null };
  }

  // Every command the assistant runs gets the gateway's environment, and each skill reads
  // its sign-in there: the notion skill NOTION_API_TOKEN, and a typed sign-in's skill the
  // names its connector gives. So a sign-in from the phone goes there, and on a disconnect
  // the box's own sign-in, if it had one, comes back.
  function put(name, value) {
    if (value) env[name] = value;
    else delete env[name];
  }

  async function exportEnv() {
    put("NOTION_API_TOKEN", await notion().token().catch(() => null));
    const outlook = await microsoft().environment().catch(() => null);
    for (const name of MICROSOFT_ENV) put(name, outlook?.[name] ?? boxEnv[name]);
    for (const connector of connectors().filter((one) => one.signIn === "password" && one.envSignIn)) {
      const kept = await typedSignIn(connector.id).catch(() => null);
      put(connector.envSignIn, kept?.secret ?? boxEnv[connector.envSignIn]);
      if (connector.envUsername) put(connector.envUsername, kept?.username ?? boxEnv[connector.envUsername]);
    }
  }

  // The account a Switch account or a Disconnect names, which must be one this phone may drop.
  async function accountOf(connector, accountId) {
    if (typeof accountId !== "string" || !oneLine(accountId, LIMITS.account)) refuse("bad account");
    const account = (await readBack(connector)).linkedAccounts.find((one) => one.id === accountId);
    if (!account) refuse("no such account on this gateway", "NO_SUCH_ACCOUNT");
    if (!account.canDisconnect) refuse("that sign-in is set up on the assistant's computer, not from a phone", "ACCOUNT_IS_ON_THE_BOX");
    return account;
  }

  async function drop(connector, account) {
    if (account.id === "gog:app") await google().disconnect();
    else if (account.id.startsWith("gog:box:")) await removeGogAccount(account.email);
    else if (account.id === "notion:app" || account.id === "outlook-hack:app") {
      await (account.id === "notion:app" ? notion() : microsoft()).disconnect();
      await exportEnv();
    } else {
      await typed(connector.id).remove();
      await exportEnv();
    }
  }

  // Signs one connector in. `replacing` names the account a Switch account takes off once
  // the new one is linked, and is the last signed value when there is one.
  async function connect(params) {
    const id = params?.connector;
    const connector = typeof id === "string" ? connectors().find((one) => one.id === id) : undefined;
    const kind = connector ? signInKindOf(connector, notion, microsoft) : null;
    const { replacing } = params ?? {};
    if (replacing !== undefined && replacing !== null && !oneLine(replacing, LIMITS.account)) refuse("bad account");
    const signed = (values) => (typeof replacing === "string" ? [...values, replacing] : values);
    const replaced = async () => (typeof replacing === "string" ? accountOf(connector, replacing) : null);
    if (id === "gog") {
      const { code, codeVerifier, redirectUri } = params;
      if (![code, codeVerifier, redirectUri].every((value) => typeof value === "string" && value)) refuse("a Google sign-in needs its code, verifier and redirect");
      if (!oneLine(code, LIMITS.code) || !oneLine(codeVerifier, LIMITS.codeVerifier) || !oneLine(redirectUri, LIMITS.redirectUri)) refuse("each value is one line");
      await checked(params, "connect", signed([code, codeVerifier, redirectUri]));
      const old = await replaced();
      await google().connect({ code, codeVerifier, redirectUri });
      if (old && old.id !== "gog:app") await drop(connector, old);
      return;
    }
    if (id === "outlook-hack" && kind === "oauth") {
      const { code, codeVerifier, redirectUri } = params;
      if (![code, codeVerifier, redirectUri].every((value) => typeof value === "string" && value)) refuse("an Outlook sign-in needs its code, verifier and redirect");
      if (!oneLine(code, LIMITS.code) || !oneLine(codeVerifier, LIMITS.codeVerifier) || !oneLine(redirectUri, LIMITS.redirectUri)) refuse("each value is one line");
      await checked(params, "connect", signed([code, codeVerifier, redirectUri]));
      await replaced();
      await microsoft().connect({ code, codeVerifier, redirectUri });
      await exportEnv();
      return;
    }
    if (id === "notion" && typeof params.code === "string") {
      const { code, redirectUri } = params;
      if (!code || typeof redirectUri !== "string" || !redirectUri) refuse("a Notion sign-in needs its code and redirect");
      if (!oneLine(code, LIMITS.code) || !oneLine(redirectUri, LIMITS.redirectUri)) refuse("each value is one line");
      await checked(params, "connect", signed([code, redirectUri]));
      await replaced();
      await notion().connectCode({ code, redirectUri });
      await exportEnv();
      return;
    }
    if (id === "notion") {
      const { token } = params;
      if (typeof token !== "string" || !token) refuse("a Notion sign-in needs its integration token");
      if (!oneLine(token, LIMITS.token)) refuse("each value is one line");
      await checked(params, "connect", signed([token]));
      await replaced();
      await notion().connectToken(token);
      await exportEnv();
      return;
    }
    if (kind === "password") {
      const { username, secret } = params;
      if (typeof username !== "string" || !username || typeof secret !== "string" || !secret) refuse("a sign-in needs a username and an app password");
      if (!oneLine(username, LIMITS.username) || !oneLine(secret, LIMITS.secret)) refuse("each value is one line");
      await checked(params, "connect", signed([username, secret]));
      const old = await replaced();
      const file = typed(connector.id);
      await file.write({ username: file.seal(username), secret: file.seal(secret), connectedAt: now() });
      if (old && old.id !== `${connector.id}:app`) await drop(connector, old);
      await exportEnv();
      return;
    }
    connectorOf(id);
  }

  // With no `accountId`, the connector's in-app sign-in, as build 13 asks. With one, that
  // account, which is then the one signed value.
  async function disconnect(params) {
    const { accountId } = params ?? {};
    if (accountId === undefined || accountId === null) {
      const connector = await checked(params, "disconnect", []);
      if (connector.id === "gog") await google().disconnect();
      else if (connector.id === "notion") await notion().disconnect();
      else if (connector.id === "outlook-hack") await microsoft().disconnect();
      else await typed(connector.id).remove();
      await exportEnv();
      return;
    }
    if (!oneLine(accountId, LIMITS.account)) refuse("bad account");
    const connector = await checked(params, "disconnect", [accountId]);
    await drop(connector, await accountOf(connector, accountId));
  }

  return {
    connect,
    disconnect,
    readBack,
    exportEnv,

    // A typed sign-in, opened for the tool that needs it on this gateway.
    secret: typedSignIn,
  };
}
