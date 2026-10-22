// Connect Google from the Steward app: the gateway's half.
//
// The app signs in to Google with the household's iOS OAuth client and PKCE, and hands
// this gateway the authorization code over its signed channel. The code is exchanged
// here, so the long-lived refresh token never reaches the phone. An iOS client has no
// secret, and gog refuses a client without one, so the refresh token is kept here,
// sealed with the gateway's own keyring password, and gog is handed short-lived access
// tokens (GOG_ACCESS_TOKEN) instead. One person per gateway: the owner's own account.

import { execFile } from "node:child_process";
import path from "node:path";

import { createSealedFile } from "./sealed-file.js";

export const GOOGLE_SCOPES = {
  gmail: "https://www.googleapis.com/auth/gmail.readonly",
  calendar: "https://www.googleapis.com/auth/calendar",
};
const SERVICES = Object.keys(GOOGLE_SCOPES);
const AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const CLIENT_ID = /^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$/;
// RFC 7636: 43 to 128 unreserved characters.
const VERIFIER = /^[A-Za-z0-9\-._~]{43,128}$/;
const MAX_CODE = 4096;
// An access token is used until a minute before Google says it expires.
const EARLY_MS = 60_000;

function refuse(message, detailCode = "BAD_VALUE") {
  throw Object.assign(new Error(message), { code: "INVALID_REQUEST", detailCode });
}

// The redirect Google allows an iOS client: its own client id, reversed, as a scheme.
export function redirectUriFor(clientId) {
  return `com.googleusercontent.apps.${clientId.split(".")[0]}:/oauthredirect`;
}

// What the assistant can do with a Google account, in plain words, from the scopes it
// was granted. A scope with no words here, such as the profile's, says nothing.
const ABILITIES = [
  [/\/auth\/gmail\.(?:modify)$|^https:\/\/mail\.google\.com\/$/, "Reads and sorts your Gmail"],
  [/\/auth\/gmail\.readonly$/, "Reads your Gmail"],
  [/\/auth\/gmail\.(?:send|compose)$/, "Sends mail you ask it to send"],
  [/\/auth\/calendar(?:\.events)?$/, "Reads and adds events in Google Calendar"],
  [/\/auth\/calendar\.readonly$/, "Reads your Google Calendar"],
  [/\/auth\/drive$/, "Reads and changes files in Google Drive"],
  [/\/auth\/drive\.(?:readonly|file)$/, "Reads your Google Drive"],
  [/\/auth\/contacts(?:\.readonly)?$/, "Reads your contacts"],
  [/\/auth\/tasks(?:\.readonly)?$/, "Reads and adds Google Tasks"],
  [/\/auth\/(?:documents|spreadsheets)(?:\.readonly)?$/, "Reads your Google Docs and Sheets"],
];

export function googleAbilities(scopes) {
  const words = [];
  for (const [rule, line] of ABILITIES) {
    if ((scopes ?? []).some((scope) => rule.test(scope)) && !words.includes(line)) words.push(line);
  }
  return words;
}

function claimsOf(idToken) {
  // The token came straight from Google's token endpoint over TLS, which OpenID Connect
  // accepts in place of checking its signature.
  try {
    return JSON.parse(Buffer.from(String(idToken).split(".")[1], "base64url").toString("utf8"));
  } catch {
    return {};
  }
}

export function createGoogleConnector({ directory, clientId, keyringPassword, fetch = globalThis.fetch, now = Date.now }) {
  const file = createSealedFile(path.join(directory, "google.json"), keyringPassword);
  let cached = null;

  async function post(url, form) {
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(form).toString(),
    });
    const body = await response.json().catch(() => ({}));
    return { ok: response.ok, status: response.status, body };
  }

  // How the app starts a sign-in, or null when this gateway has no iOS client to take one.
  function oauth() {
    if (!CLIENT_ID.test(String(clientId))) return null;
    return {
      provider: "google",
      clientId,
      authorizeUrl: AUTHORIZE_URL,
      scopes: ["openid", "email", "profile", ...SERVICES.map((service) => GOOGLE_SCOPES[service])],
      redirectUri: redirectUriFor(clientId),
      usesPkce: true,
    };
  }

  async function connect({ code, codeVerifier, redirectUri }) {
    if (!CLIENT_ID.test(String(clientId))) refuse("Google sign-in is not set up on this gateway", "SIGNIN_NOT_SET_UP");
    if (typeof code !== "string" || !code || code.length > MAX_CODE) refuse("bad authorization code");
    if (typeof codeVerifier !== "string" || !VERIFIER.test(codeVerifier)) refuse("bad code verifier");
    if (redirectUri !== redirectUriFor(clientId)) refuse("not this app's redirect");
    const { ok, status, body } = await post(TOKEN_URL, {
      client_id: clientId, code, code_verifier: codeVerifier, grant_type: "authorization_code", redirect_uri: redirectUri,
    });
    if (!ok) refuse(`Google refused the sign-in (${status}${typeof body.error === "string" ? `, ${body.error}` : ""})`, "PROVIDER_REFUSED");
    if (typeof body.refresh_token !== "string" || !body.refresh_token) refuse("Google gave no lasting sign-in, so nothing was kept", "PROVIDER_REFUSED");
    const granted = new Set(String(body.scope ?? "").split(" "));
    const missing = SERVICES.filter((service) => !granted.has(GOOGLE_SCOPES[service]));
    if (missing.length > 0) refuse(`${missing.join(" and ")} access was not granted`, "SCOPES_MISSING");
    const claims = claimsOf(body.id_token);
    if (typeof claims.email !== "string" || claims.email_verified !== true) refuse("Google did not confirm the account's email", "PROVIDER_REFUSED");
    const name = typeof claims.name === "string" && claims.name ? claims.name : null;
    await file.write({ email: claims.email, name, services: SERVICES, connectedAt: now(), refreshToken: file.seal(body.refresh_token) });
    cached = null;
    return { connected: true, email: claims.email, services: SERVICES };
  }

  // The kept account, with no token in it. `problem` is "expired" once Google refused to
  // renew it, or "failing" after any other failed renewal, and goes on the next success.
  async function status() {
    const record = await file.read();
    if (!record) return { connected: false };
    return {
      connected: true,
      email: record.email,
      name: record.name ?? null,
      services: record.services,
      connectedAt: record.connectedAt ?? null,
      problem: record.problem ?? null,
    };
  }

  async function markProblem(record, problem) {
    if ((record.problem ?? null) === problem) return;
    const next = { ...record };
    delete next.problem;
    await file.write(problem ? { ...next, problem } : next);
  }

  async function accessToken() {
    if (cached && cached.until > now()) return cached.token;
    if (!CLIENT_ID.test(String(clientId))) throw new Error("the Google iOS client id is not configured on this gateway");
    const record = await file.read();
    if (!record) throw new Error("Google is not connected on this gateway");
    const { ok, status: code, body } = await post(TOKEN_URL, {
      client_id: clientId, grant_type: "refresh_token", refresh_token: file.open(record.refreshToken),
    });
    if (!ok || typeof body.access_token !== "string") {
      await markProblem(record, body?.error === "invalid_grant" ? "expired" : "failing");
      throw new Error(`Google refused to refresh the sign-in (${code})`);
    }
    await markProblem(record, null);
    cached = { token: body.access_token, until: now() + Number(body.expires_in ?? 0) * 1000 - EARLY_MS };
    return cached.token;
  }

  async function disconnect() {
    const record = await file.read();
    if (record) {
      await post(REVOKE_URL, { token: file.open(record.refreshToken) }).catch(() => undefined);
      await file.remove();
    }
    cached = null;
    return { connected: false };
  }

  return { oauth, connect, status, accessToken, disconnect };
}

// The Google accounts gog itself holds on this gateway, signed in on the box rather than
// from the app: Franco's on Corey's. Each is its email, its granted scopes and when it was
// added. Read at most once a minute, and none when gog cannot answer, so the settings page
// never waits on it.
const GOG_LIST_MS = 60_000;
let gogList = { at: -Infinity, accounts: [] };

export function listGogAccounts({ run = execFile, now = Date.now } = {}) {
  if (now() - gogList.at < GOG_LIST_MS) return Promise.resolve(gogList.accounts);
  return new Promise((resolve) => {
    run("gog", ["auth", "list", "--json"], { timeout: 10_000 }, (error, stdout) => {
      let accounts = [];
      if (!error) {
        try {
          const listed = JSON.parse(stdout).accounts;
          accounts = (Array.isArray(listed) ? listed : [])
            .filter((account) => typeof account?.email === "string" && account.email)
            .map((account) => ({
              email: account.email,
              scopes: Array.isArray(account.scopes) ? account.scopes.filter((scope) => typeof scope === "string") : [],
              createdAt: Number.isFinite(Date.parse(account.created_at)) ? Date.parse(account.created_at) : null,
            }));
        } catch {
          accounts = [];
        }
      }
      gogList = { at: now(), accounts };
      resolve(accounts);
    });
  });
}

// Takes one account gog holds off this gateway, for a phone's Disconnect.
export function removeGogAccount(email, { run = execFile } = {}) {
  return new Promise((resolve, reject) => {
    run("gog", ["auth", "remove", email, "--force", "--no-input"], { timeout: 20_000 }, (error) => {
      gogList = { at: -Infinity, accounts: [] };
      if (error) reject(new Error("gog could not remove that Google account"));
      else resolve();
    });
  });
}
