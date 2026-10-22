// Connect Notion from the Steward app: the gateway's half.
//
// Two ways in, one account per gateway, the owner's own:
// - a pasted internal integration token, from notion.so/profile/integrations, which the
//   gateway checks against Notion before it keeps it, and which works from the start;
// - OAuth through the household's public Notion connection, once its client id, secret and
//   redirect are in the gateway's env (NOTION_OAUTH_CLIENT_ID, NOTION_OAUTH_CLIENT_SECRET,
//   NOTION_OAUTH_REDIRECT_URI). Notion has no PKCE and its code exchange needs the client
//   secret, so the code is exchanged here and the secret never leaves the gateway.
// The token is kept sealed with the gateway's keyring password, as google-connect.js keeps
// Google's, and the notion skill gets it as NOTION_API_TOKEN (connect.js).

import path from "node:path";

import { createSealedFile } from "./sealed-file.js";

export const NOTION_VERSION = "2026-03-11";
const API = "https://api.notion.com/v1";
const AUTHORIZE_URL = `${API}/oauth/authorize?owner=user`;
const TOKEN = /^[A-Za-z0-9_-]{20,256}$/;
const MAX_CODE = 4096;

function refuse(message, detailCode = "BAD_VALUE") {
  throw Object.assign(new Error(message), { code: "INVALID_REQUEST", detailCode });
}

const text = (value) => (typeof value === "string" && value ? value : null);

export function createNotionConnector({ directory, keyringPassword, clientId, clientSecret, redirectUri, fetch = globalThis.fetch, now = Date.now }) {
  const file = createSealedFile(path.join(directory, "notion.json"), keyringPassword);
  const isRegistered = Boolean(clientId && clientSecret && redirectUri);

  async function call(url, init) {
    const response = await fetch(url, { ...init, headers: { "Notion-Version": NOTION_VERSION, Accept: "application/json", ...init.headers } });
    const body = await response.json().catch(() => ({}));
    return { ok: response.ok, status: response.status, body };
  }

  const providerRefused = (status, body) =>
    refuse(`Notion refused the sign-in (${status}${typeof body.code === "string" ? `, ${body.code}` : ""})`, "PROVIDER_REFUSED");

  return {
    kind: () => (isRegistered ? "oauth" : "token"),

    oauth: () => (isRegistered
      ? { provider: "notion", clientId, authorizeUrl: AUTHORIZE_URL, scopes: [], redirectUri, usesPkce: false }
      : null),

    // A pasted internal integration token, kept only once Notion answers to it.
    async connectToken(token) {
      if (typeof token !== "string" || !TOKEN.test(token)) refuse("that is not a Notion integration token");
      const { ok, status, body } = await call(`${API}/users/me`, { method: "GET", headers: { Authorization: `Bearer ${token}` } });
      if (!ok) providerRefused(status, body);
      await file.write({
        kind: "token",
        name: text(body?.bot?.workspace_name) ?? text(body?.name),
        email: null,
        workspace: text(body?.bot?.workspace_name),
        connectedAt: now(),
        accessToken: file.seal(token),
      });
    },

    async connectCode({ code, redirectUri: given }) {
      if (!isRegistered) refuse("Notion sign-in is not set up on this gateway", "SIGNIN_NOT_SET_UP");
      if (typeof code !== "string" || !code || code.length > MAX_CODE) refuse("bad authorization code");
      if (given !== redirectUri) refuse("not this app's redirect");
      const { ok, status, body } = await call(`${API}/oauth/token`, {
        method: "POST",
        headers: {
          Authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString("base64")}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ grant_type: "authorization_code", code, redirect_uri: redirectUri }),
      });
      if (!ok || typeof body.access_token !== "string" || !body.access_token) providerRefused(status, body);
      const person = body.owner?.type === "user" ? body.owner.user : null;
      await file.write({
        kind: "oauth",
        name: text(person?.name) ?? text(body.workspace_name),
        email: text(person?.person?.email),
        workspace: text(body.workspace_name),
        connectedAt: now(),
        accessToken: file.seal(body.access_token),
        ...(text(body.refresh_token) ? { refreshToken: file.seal(body.refresh_token) } : {}),
      });
    },

    // The kept account, with no token in it.
    async status() {
      const record = await file.read();
      if (!record) return { connected: false };
      return { connected: true, name: record.name, email: record.email, workspace: record.workspace, connectedAt: record.connectedAt };
    },

    async token() {
      const record = await file.read();
      return record ? file.open(record.accessToken) : null;
    },

    // Notion has no revoke endpoint: the person removes the connection in Notion itself.
    disconnect: () => file.remove(),
  };
}
