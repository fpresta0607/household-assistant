// A notification on the person's phone for each new message,
// through Apple's push service without Apple ever reading a family message.
//
// Apple is a service the gateways did not use before the app, so nothing said in the
// family reaches it. The alert Apple sees says only "New message". Who said what is
// sealed with AES-256-GCM under a key the phone made and handed this gateway over its
// own authenticated connection, and the phone's notification extension opens it and
// shows it in place of the plain alert. A phone that cannot open it still shows that
// there is a new message, which is the right failure.
//
// In the clear go only how to show it: mutable-content so the extension runs, the thread
// so notifications stack by conversation, the category that offers a reply and a few
// reactions, and for a scheduled reminder that it is time sensitive, which the app's Time
// Sensitive entitlement lets through a Focus. Who wrote it is sealed with the words; the
// extension finds their face by it.
//
// Apple authenticates the sender with a short JSON web token signed by the team's push
// key (ES256). Apple wants it made again between twenty and sixty minutes, so it is
// kept for forty.

import { createCipheriv, createDecipheriv, createPrivateKey, randomBytes, sign } from "node:crypto";
import http2 from "node:http2";

import { isMentioned } from "./mentions.js";

const HOSTS = { production: "api.push.apple.com", sandbox: "api.sandbox.push.apple.com" };
const TOKEN_LIFETIME_MS = 40 * 60_000;
const MAX_BODY = 180;
const GONE = new Set(["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"]);
const REQUEST_TIMEOUT_MS = 10_000;

function clip(text) {
  const flat = String(text ?? "").replace(/\s+/g, " ").trim();
  return flat.length > MAX_BODY ? `${flat.slice(0, MAX_BODY)}…` : flat;
}

function deviceKey(key) {
  const bytes = typeof key === "string" ? Buffer.from(key, "base64") : null;
  return bytes && bytes.length === 32 ? bytes : null;
}

// What the phone chose for the message's conversation in Settings: every message, only
// those that mention its person or their assistant (`note.mentions`, see mentions.js), or
// none. A conversation it never chose for is every message.
export function isWanted(device, note) {
  const choice = device.notifications?.[note.conversation] ?? "all";
  if (choice === "off") return false;
  if (choice === "mentions") return note.mentions.some((name) => isMentioned(String(note.body ?? ""), name));
  return true;
}

export function sealPayload(value, key) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const sealed = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()]);
  return Buffer.concat([nonce, sealed, cipher.getAuthTag()]).toString("base64");
}

export function decryptPayload(sealed, key) {
  const bytes = Buffer.from(sealed, "base64");
  const decipher = createDecipheriv("aes-256-gcm", deviceKey(key), bytes.subarray(0, 12));
  decipher.setAuthTag(bytes.subarray(bytes.length - 16));
  const opened = Buffer.concat([decipher.update(bytes.subarray(12, bytes.length - 16)), decipher.final()]);
  return JSON.parse(opened.toString("utf8"));
}

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

export function createPush({ keyId, teamId, privateKey, topic, transport, now = Date.now }) {
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

  async function notifyOne(device, note) {
    const key = deviceKey(device.key);
    if (!key) return { token: device.token, ok: false, gone: true, reason: "bad device key" };
    const body = JSON.stringify({
      aps: {
        alert: { title: "Steward AI", body: "New message" },
        sound: "default",
        "mutable-content": 1,
        "thread-id": note.conversation,
        category: `${note.conversation}-message`,
        ...(note.isTimeSensitive ? { "interruption-level": "time-sensitive" } : {}),
      },
      e: sealPayload(
        {
          conversation: note.conversation,
          messageId: note.messageId,
          sender: note.sender,
          title: clip(note.title),
          body: clip(note.body),
        },
        key,
      ),
    });
    try {
      const answer = await transport.send({
        host: HOSTS[device.environment] ?? HOSTS.production,
        path: `/3/device/${device.token}`,
        headers: {
          authorization: `bearer ${bearer()}`,
          "apns-topic": topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-collapse-id": String(note.messageId).slice(0, 64),
        },
        body,
      });
      if (answer.status === 200) return { token: device.token, ok: true };
      let reason = `HTTP ${answer.status}`;
      try {
        reason = JSON.parse(answer.body).reason ?? reason;
      } catch {
        // Apple answers with JSON; anything else keeps the status as the reason.
      }
      return { token: device.token, ok: false, gone: answer.status === 410 || GONE.has(reason), reason };
    } catch (error) {
      return { token: device.token, ok: false, gone: false, reason: error.message };
    }
  }

  return {
    notify(devices, note) {
      return Promise.all(devices.filter((device) => isWanted(device, note)).map((device) => notifyOne(device, note)));
    },
  };
}
