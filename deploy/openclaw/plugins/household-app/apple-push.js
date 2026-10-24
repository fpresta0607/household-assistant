// One notification handed to Apple's push service, already built and sealed (push.js).
//
// It is its own module because two programs send through it: a gateway that holds the
// app's push key itself, as the first household's box does, and the push relay
// (deploy/push-relay), which holds the key for every other household so that their boxes
// never do. Neither reads what it sends here: the words are sealed for the phone before
// they reach this module.
//
// Apple authenticates the sender with a short JSON web token signed by the team's push
// key (ES256). Apple wants it made again between twenty and sixty minutes, so it is
// kept for forty.

import { createPrivateKey, sign } from "node:crypto";
import http2 from "node:http2";

export const HOSTS = { production: "api.push.apple.com", sandbox: "api.sandbox.push.apple.com" };
const TOKEN_LIFETIME_MS = 40 * 60_000;
const REQUEST_TIMEOUT_MS = 10_000;

// Apple's HTTP/2 endpoint, one session per host, dropped when it errors or idles.
export function createHttp2Transport({ timeoutMs = REQUEST_TIMEOUT_MS } = {}) {
  const sessions = new Map();

  function session(host) {
    const existing = sessions.get(host);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const opened = http2.connect(`https://${host}`);
    opened.setTimeout(5 * 60_000, () => opened.close());
    opened.on("error", () => sessions.delete(host));
    opened.on("close", () => sessions.delete(host));
    sessions.set(host, opened);
    return opened;
  }

  return {
    send({ host, path, headers, body }) {
      return new Promise((resolve, reject) => {
        const request = session(host).request({ ":method": "POST", ":path": path, ...headers });
        const chunks = [];
        let status = 0;
        request.setTimeout(timeoutMs, () => request.close(http2.constants.NGHTTP2_CANCEL));
        request.on("response", (response) => { status = response[":status"]; });
        request.on("data", (chunk) => chunks.push(chunk));
        request.on("end", () => resolve({ status, body: Buffer.concat(chunks).toString("utf8") }));
        request.on("error", reject);
        request.on("close", () => {
          if (!status) reject(new Error("Apple closed the request without an answer"));
        });
        request.end(body);
      });
    },
    close() {
      for (const opened of sessions.values()) opened.close();
      sessions.clear();
    },
  };
}

// Sends one body to one phone's token and answers with Apple's status and, when Apple
// refused it, Apple's reason. A transport that fails throws.
export function createAppleSender({ keyId, teamId, privateKey, topic, transport, now = Date.now }) {
  const signingKey = createPrivateKey(privateKey);
  let token = null;

  function bearer() {
    if (token && now() - token.madeAt < TOKEN_LIFETIME_MS) return token.value;
    const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: keyId })).toString("base64url");
    const claims = Buffer.from(JSON.stringify({ iss: teamId, iat: Math.floor(now() / 1000) })).toString("base64url");
    const signature = sign("sha256", Buffer.from(`${header}.${claims}`), { key: signingKey, dsaEncoding: "ieee-p1363" });
    token = { value: `${header}.${claims}.${signature.toString("base64url")}`, madeAt: now() };
    return token.value;
  }

  return {
    async send({ token: deviceToken, environment, body, collapseId }) {
      const answer = await transport.send({
        host: HOSTS[environment] ?? HOSTS.production,
        path: `/3/device/${deviceToken}`,
        headers: {
          authorization: `bearer ${bearer()}`,
          "apns-topic": topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-collapse-id": String(collapseId).slice(0, 64),
        },
        body,
      });
      if (answer.status === 200) return { status: 200 };
      let reason = `HTTP ${answer.status}`;
      try {
        reason = JSON.parse(answer.body).reason ?? reason;
      } catch {
        // Apple answers with JSON; anything else keeps the status as the reason.
      }
      return { status: answer.status, reason };
    },
  };
}
