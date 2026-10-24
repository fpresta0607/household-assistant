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
// Apple is reached one of two ways. A box that holds the app's push key sends straight to
// Apple (apple-push.js). Every other household's box holds a key of its own instead, an
// Ed25519 key the app's publisher knows by its public half, and hands each notification,
// already sealed, to the publisher's push relay (deploy/push-relay), which holds the
// app's key and passes it on. The relay sees what Apple sees and nothing more.

import { createCipheriv, createDecipheriv, createHash, createPrivateKey, randomBytes, sign } from "node:crypto";

import { createAppleSender, createHttp2Transport } from "./apple-push.js";
import { isMentioned } from "./mentions.js";

export { createHttp2Transport };

const DEFAULT_TOPIC = "com.siqstack.stewardai";
const MAX_BODY = 180;
const GONE = new Set(["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"]);
const RELAY_TIMEOUT_MS = 10_000;
// The plain alert every notification carries, the only words Apple or the relay sees.
export const PLAIN_ALERT = Object.freeze({ title: "Steward AI", body: "New message" });

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

// What Apple is handed for one note on one phone: the plain alert and how to show it, and
// who said what, sealed under the phone's key.
export function pushPayload(note, key) {
  return {
    aps: {
      alert: { ...PLAIN_ALERT },
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
  };
}

// The publisher's push relay in Apple's place. Each request is signed with the household's
// Ed25519 key over who it is, when, and the body's hash, so the relay knows which household
// sent it and that nobody changed it on the way. The relay answers with what Apple said,
// which is handed back as Apple's own; a refusal of the relay's own is marked as the relay's,
// so it never makes a phone count as gone.
export function createRelaySender({ url, household, privateKey, fetch = globalThis.fetch, now = Date.now, timeoutMs = RELAY_TIMEOUT_MS }) {
  const key = createPrivateKey(privateKey);
  if (key.asymmetricKeyType !== "ed25519") throw new Error("the push relay key is not an Ed25519 key");
  const base = String(url).replace(/\/+$/, "");

  async function post(path, value) {
    const text = JSON.stringify(value);
    const timestamp = String(now());
    const digest = createHash("sha256").update(text).digest("hex");
    const signature = sign(null, Buffer.from(`${household}\n${timestamp}\n${digest}`), key).toString("base64");
    const response = await fetch(`${base}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-household": household,
        "x-timestamp": timestamp,
        "x-signature": signature,
      },
      body: text,
      signal: AbortSignal.timeout(timeoutMs),
    });
    let answer = {};
    try {
      answer = await response.json();
    } catch {
      // A proxy's error page is not JSON; the status says enough.
    }
    return { response, answer: answer && typeof answer === "object" ? answer : {} };
  }

  return {
    async send({ token, environment, body, collapseId }) {
      const { response, answer } = await post("/v1/push", { token, environment, collapseId, payload: JSON.parse(body) });
      if (response.ok && Number.isInteger(answer.status)) {
        if (answer.status === 200) return { status: 200 };
        return { status: answer.status, reason: String(answer.reason ?? `HTTP ${answer.status}`) };
      }
      return { status: response.status, reason: `the push relay refused it: ${answer.reason ?? `HTTP ${response.status}`}`, fromRelay: true };
    },
    // Whether the relay knows this household's key, asked once as the channel starts, so a
    // household the publisher has not let in yet shows in the gateway's log, not as silence.
    async check() {
      try {
        const { response, answer } = await post("/v1/check", {});
        return response.ok ? { ok: true } : { ok: false, reason: String(answer.reason ?? `HTTP ${response.status}`) };
      } catch (error) {
        return { ok: false, reason: error?.message ?? String(error) };
      }
    },
  };
}

// `sender` is the relay's sender. Without one, the Apple sender is made from the push key's
// `keyId`, `teamId` and `privateKey`, the app's `topic`, and `transport`.
export function createPush({ sender, keyId, teamId, privateKey, topic, transport, now = Date.now }) {
  const out = sender ?? createAppleSender({ keyId, teamId, privateKey, topic, transport, now });

  async function notifyOne(device, note) {
    const key = deviceKey(device.key);
    if (!key) return { token: device.token, ok: false, gone: true, reason: "bad device key" };
    try {
      const answer = await out.send({
        token: device.token,
        environment: device.environment,
        body: JSON.stringify(pushPayload(note, key)),
        collapseId: String(note.messageId).slice(0, 64),
      });
      if (answer.status === 200) return { token: device.token, ok: true };
      const reason = answer.reason ?? `HTTP ${answer.status}`;
      const gone = !answer.fromRelay && (answer.status === 410 || GONE.has(reason));
      return { token: device.token, ok: false, gone, reason };
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

// How this gateway reaches Apple. With the app's push key in its environment, straight to
// Apple, as the first household's box does. With the household's relay key in its
// environment and the relay named in the channel (`push.relay`), through the publisher's
// relay. Otherwise not at all, which the log says once. A key's line breaks come escaped,
// as `\n`, since an env file holds one line per variable.
export function createPhonePush({ config, environment, log, fetch, transport }) {
  const unescaped = (key) => key.replaceAll("\\n", "\n");
  if (environment.HOUSEHOLD_APNS_KEY_ID && environment.HOUSEHOLD_APNS_TEAM_ID && environment.HOUSEHOLD_APNS_PRIVATE_KEY) {
    return createPush({
      keyId: environment.HOUSEHOLD_APNS_KEY_ID,
      teamId: environment.HOUSEHOLD_APNS_TEAM_ID,
      privateKey: unescaped(environment.HOUSEHOLD_APNS_PRIVATE_KEY),
      topic: config.push?.topic ?? DEFAULT_TOPIC,
      transport: transport ?? createHttp2Transport(),
    });
  }
  const relay = config.push?.relay;
  if (!relay?.url || !relay?.household) {
    log.info("household-app: no Apple push key in the environment, so phones are not notified");
    return null;
  }
  if (!environment.HOUSEHOLD_PUSH_RELAY_KEY) {
    log.warn(`household-app: the push relay at ${relay.url} is named but HOUSEHOLD_PUSH_RELAY_KEY is not in the environment, so phones are not notified`);
    return null;
  }
  let sender;
  try {
    sender = createRelaySender({
      url: relay.url,
      household: relay.household,
      privateKey: unescaped(environment.HOUSEHOLD_PUSH_RELAY_KEY),
      ...(fetch ? { fetch } : {}),
    });
  } catch (error) {
    log.warn(`household-app: the push relay key cannot be used, so phones are not notified: ${error?.message ?? error}`);
    return null;
  }
  void sender.check().then((result) => {
    if (result.ok) log.info(`household-app: phones are notified through the push relay at ${relay.url}`);
    else log.warn(`household-app: the push relay at ${relay.url} does not let in ${relay.household} yet (${result.reason}), so phones are not notified until its publisher adds the household's key`);
  });
  return createPush({ sender });
}
