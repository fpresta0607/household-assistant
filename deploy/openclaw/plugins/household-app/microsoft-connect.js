// Connect Outlook from the Steward app: the gateway's half.
//
// The app signs in to Microsoft in the iPhone's own sign-in sheet with the household's
// Microsoft app, a public client with no secret, and PKCE, and hands this gateway the
// authorization code over its signed channel. The code is exchanged here and the refresh
// token is kept sealed with the gateway's keyring password. The assistant already makes
// its Graph tokens from MS_GRAPH_REFRESH_TOKEN, MS_GRAPH_CLIENT_ID and MS_GRAPH_TENANT_ID
// in its environment (USER.md), so connect.js puts the kept refresh token there, with the
// same app's client and tenant, and the assistant's own steps work unchanged.
// One person per gateway: the owner's own account.

import path from "node:path";

import { createSealedFile } from "./sealed-file.js";

export const MICROSOFT_REDIRECT = "steward://connector/outlook";
// The names the assistant reads its Microsoft sign-in from.
export const MICROSOFT_ENV = ["MS_GRAPH_REFRESH_TOKEN", "MS_GRAPH_CLIENT_ID", "MS_GRAPH_TENANT_ID"];
// Mail to read and calendars to read and change, as the assistant has used them since
// 9 October, and a refresh token to keep.
export const MICROSOFT_SCOPES = ["openid", "email", "profile", "offline_access", "User.Read", "Mail.Read", "Calendars.ReadWrite"];
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// RFC 7636: 43 to 128 unreserved characters.
const VERIFIER = /^[A-Za-z0-9\-._~]{43,128}$/;
const MAX_CODE = 4096;

function refuse(message, detailCode = "BAD_VALUE") {
  throw Object.assign(new Error(message), { code: "INVALID_REQUEST", detailCode });
}

// What the assistant can do with a Microsoft account, in plain words, from its grant.
const ABILITIES = [
  [/^Mail\.ReadWrite$/i, "Reads your Outlook mail and writes drafts"],
  [/^Mail\.Read$/i, "Reads your Outlook mail"],
  [/^Mail\.Send$/i, "Sends mail you ask it to send"],
  [/^Calendars\.ReadWrite$/i, "Reads and changes your Outlook calendar"],
  [/^Calendars\.Read$/i, "Reads your Outlook calendar"],
  [/^Contacts\.Read(?:Write)?$/i, "Reads your Outlook contacts"],
  [/^Files\.Read(?:Write)?(?:\.All)?$/i, "Reads your OneDrive files"],
];

export function microsoftAbilities(scopes) {
  const words = [];
  for (const [rule, line] of ABILITIES) {
    if ((scopes ?? []).some((scope) => rule.test(String(scope).replace(/^https:\/\/graph\.microsoft\.com\//i, ""))) && !words.includes(line)) {
      words.push(line);
    }
  }
  return words;
}

function claimsOf(idToken) {
  // The token came straight from Microsoft's token endpoint over TLS, which OpenID Connect
  // accepts in place of checking its signature.
  try {
    return JSON.parse(Buffer.from(String(idToken).split(".")[1], "base64url").toString("utf8"));
  } catch {
    return {};
  }
}

export function createMicrosoftConnector({ directory, clientId, tenantId, keyringPassword, fetch = globalThis.fetch, now = Date.now }) {
  const file = createSealedFile(path.join(directory, "microsoft.json"), keyringPassword);
  const isRegistered = GUID.test(String(clientId)) && GUID.test(String(tenantId));
  const endpoint = (kind) => `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/${kind}`;

  return {
    // How the app starts a sign-in, or null when this gateway has no Microsoft app.
    oauth: () => (isRegistered
      ? { provider: "microsoft", clientId, authorizeUrl: endpoint("authorize"), scopes: MICROSOFT_SCOPES, redirectUri: MICROSOFT_REDIRECT, usesPkce: true }
      : null),

    async connect({ code, codeVerifier, redirectUri }) {
      if (!isRegistered) refuse("Outlook sign-in is not set up on this gateway", "SIGNIN_NOT_SET_UP");
      if (typeof code !== "string" || !code || code.length > MAX_CODE) refuse("bad authorization code");
      if (typeof codeVerifier !== "string" || !VERIFIER.test(codeVerifier)) refuse("bad code verifier");
      if (redirectUri !== MICROSOFT_REDIRECT) refuse("not this app's redirect");
      const response = await fetch(endpoint("token"), {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          client_id: clientId, grant_type: "authorization_code", code, redirect_uri: redirectUri, code_verifier: codeVerifier,
          scope: MICROSOFT_SCOPES.join(" "),
        }).toString(),
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) refuse(`Microsoft refused the sign-in (${response.status}${typeof body.error === "string" ? `, ${body.error}` : ""})`, "PROVIDER_REFUSED");
      if (typeof body.refresh_token !== "string" || !body.refresh_token) refuse("Microsoft gave no lasting sign-in, so nothing was kept", "PROVIDER_REFUSED");
      const granted = String(body.scope ?? "").split(" ").filter(Boolean);
      if (!granted.some((scope) => /Mail\.Read/i.test(scope))) refuse("mail access was not granted", "SCOPES_MISSING");
      const claims = claimsOf(body.id_token);
      const email = [claims.email, claims.preferred_username].find((value) => typeof value === "string" && value.includes("@"));
      if (!email) refuse("Microsoft did not name the account's email", "PROVIDER_REFUSED");
      await file.write({
        email,
        name: typeof claims.name === "string" && claims.name ? claims.name : null,
        scopes: granted,
        connectedAt: now(),
        refreshToken: file.seal(body.refresh_token),
      });
    },

    // The kept account, with no token in it.
    async status() {
      const record = await file.read();
      if (!record) return { connected: false };
      return { connected: true, email: record.email, name: record.name, scopes: record.scopes, connectedAt: record.connectedAt };
    },

    // What the assistant needs in its environment to make its own Graph tokens.
    async environment() {
      const record = await file.read();
      return record ? { MS_GRAPH_REFRESH_TOKEN: file.open(record.refreshToken), MS_GRAPH_CLIENT_ID: clientId, MS_GRAPH_TENANT_ID: tenantId } : null;
    },

    // Microsoft revokes a refresh token only by signing the user out everywhere, so the
    // kept one is forgotten here and its sessions end with the person's own sign-out.
    disconnect: () => file.remove(),
  };
}
