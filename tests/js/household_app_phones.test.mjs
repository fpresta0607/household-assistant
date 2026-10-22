// The owner's iPhones on Account, from deploy/openclaw/plugins/household-app/phones.js:
// which are paired, removing one, and a setup code for a new one, each signed by one of
// the owner's phones and none of it ever a key or a token.
//
// Run with `node --test tests/js/household_app_phones.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { APP_CLIENT, phoneKeysFrom } from "../../deploy/openclaw/plugins/household-app/pairing.js";
import {
  PHONE_VERSION,
  createPhones,
  phoneText,
  removeThroughOpenClaw,
} from "../../deploy/openclaw/plugins/household-app/phones.js";
import { openSettingsStore } from "../../deploy/openclaw/plugins/household-app/settings-store.js";

const NOW = Date.UTC(2026, 9, 15, 17, 0);
const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const LINK = "https://household.example.ts.net:18789/household-app/pair#c2V0dXAtY29kZQ";

function phone() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    key: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url"),
    sign: (text) => sign(null, Buffer.from(text, "utf8"), privateKey).toString("base64url"),
  };
}

const THIS_IPHONE = phone();
const IPAD = phone();
const GIA = phone();

// Franco's gateway's device list as OpenClaw answers it: this iPhone, paired by setup
// code, his iPad with a label from the box, the Control UI, and a phone still waiting.
// The tokens and keys are what the phone must never see.
function onTheBox() {
  return {
    pending: [{ requestId: "req-1", deviceId: "waiting-phone", clientId: APP_CLIENT, role: "operator", publicKey: phone().key }],
    paired: [
      {
        deviceId: "this-iphone",
        publicKey: THIS_IPHONE.key,
        displayName: "Steward AI on iPhone",
        platform: "ios",
        deviceFamily: "iphone",
        clientId: APP_CLIENT,
        clientMode: "node",
        role: "node",
        roles: ["node", "operator"],
        scopes: ["operator.read", "operator.write"],
        tokens: { operator: { token: "operator-token-of-this-iphone" }, node: { token: "node-token-of-this-iphone" } },
        remoteIp: "100.64.0.30",
        createdAtMs: NOW - 30 * DAY,
        approvedAtMs: NOW - 30 * DAY,
        lastSeenAtMs: NOW - MINUTE,
        lastSeenReason: "connect",
      },
      {
        deviceId: "franco-ipad",
        publicKey: IPAD.key,
        displayName: "Steward AI on iPhone",
        operatorLabel: "Franco's iPad",
        platform: "ios",
        deviceFamily: "ipad",
        clientId: APP_CLIENT,
        role: "operator",
        tokens: { operator: { token: "operator-token-of-the-ipad" } },
        createdAtMs: NOW - 9 * DAY,
        approvedAtMs: NOW - 9 * DAY,
        lastSeenAtMs: NOW - DAY,
      },
      {
        deviceId: "control-ui",
        publicKey: phone().key,
        displayName: "Control UI",
        clientId: "openclaw-control-ui",
        role: "operator",
        tokens: { operator: { token: "operator-token-of-the-control-ui" } },
        createdAtMs: NOW - 60 * DAY,
        approvedAtMs: NOW - 60 * DAY,
      },
    ],
  };
}

// Every key and token in a device list, which no answer may carry.
function secretsOf(devices) {
  return [...devices.pending, ...devices.paired].flatMap((row) => [
    row.publicKey,
    ...Object.values(row.tokens ?? {}).map((entry) => entry.token),
  ]);
}

async function setup({ devices = onTheBox(), removePairing } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-phones-"));
  const store = openSettingsStore(path.join(directory, "settings.sqlite"));
  let listing = devices;
  const removed = [];
  const forgotten = [];
  const issued = [];
  const changes = [];
  const phones = createPhones({
    devices: async () => listing,
    phoneKeys: async () => phoneKeysFrom(listing),
    store,
    removePairing: removePairing ?? (async (device) => {
      removed.push(device);
      listing = { ...listing, paired: listing.paired.filter((row) => row.deviceId !== device) };
    }),
    forgetPush: (device) => forgotten.push(device),
    issueCode: async () => {
      issued.push(NOW);
      return { setupCode: "c2V0dXAtY29kZQ", link: LINK, expiresAtMs: NOW + 10 * MINUTE };
    },
    changed: async () => changes.push(NOW),
    now: () => NOW,
  });
  return { phones, store, removed, forgotten, issued, changes, listing: () => listing };
}

const removal = (device, at = NOW - 1000) => ({ at, device });
const signedRemoval = (unsigned, by = THIS_IPHONE) => ({
  ...unsigned,
  signature: by.sign(phoneText({ at: unsigned.at, action: "remove", device: unsigned.device })),
});
const pairing = (at = NOW - 1000) => ({ at });
const signedPairing = (unsigned, by = THIS_IPHONE) => ({
  ...unsigned,
  signature: by.sign(phoneText({ at: unsigned.at, action: "pair", device: "" })),
});

// MARK: - What the phone signs

test("the shared vectors: a removal and a pairing each sign four lines and no trailing newline", () => {
  assert.equal(PHONE_VERSION, "household-app/phone/v1");
  assert.equal(
    phoneText({ at: 1760000000000, action: "remove", device: "device-2" }),
    "household-app/phone/v1\n1760000000000\nremove\ndevice-2",
  );
  assert.equal(phoneText({ at: 1760000000000, action: "pair", device: "" }), "household-app/phone/v1\n1760000000000\npair\n");
});

// MARK: - The list

test("the list is the app's paired phones as OpenClaw names them, the calling one marked", async () => {
  const { phones } = await setup();
  assert.deepEqual(await phones.view("this-iphone"), {
    phones: [
      { id: "this-iphone", name: "Steward AI on iPhone", model: "iphone", lastSeenAtMs: NOW - MINUTE, isThisPhone: true },
      { id: "franco-ipad", name: "Franco's iPad", model: "ipad", lastSeenAtMs: NOW - DAY, isThisPhone: false },
    ],
  });
});

test("a phone OpenClaw has no name, model or sighting for is listed by its client", async () => {
  const devices = onTheBox();
  devices.paired = [{ deviceId: "bare-phone", publicKey: phone().key, clientId: APP_CLIENT, role: "operator", createdAtMs: NOW, approvedAtMs: NOW }];
  const { phones } = await setup({ devices });
  assert.deepEqual((await phones.view("this-iphone")).phones, [
    { id: "bare-phone", name: APP_CLIENT, model: null, lastSeenAtMs: null, isThisPhone: false },
  ]);
});

test("a connection that is no paired phone sees every phone and none as its own", async () => {
  const { phones } = await setup();
  assert.deepEqual((await phones.view(undefined)).phones.map((one) => one.isThisPhone), [false, false]);
});

test("nothing in an answer is a key or a token", async () => {
  const devices = onTheBox();
  const { phones } = await setup({ devices });
  const secrets = secretsOf(devices);
  const answers = [await phones.view("this-iphone"), await phones.remove(signedRemoval(removal("franco-ipad")), "this-iphone")];
  for (const answer of answers) {
    const text = JSON.stringify(answer);
    for (const secret of secrets) assert.ok(!text.includes(secret), "an answer carried a key or a token");
    for (const one of answer.phones) assert.deepEqual(Object.keys(one), ["id", "name", "model", "lastSeenAtMs", "isThisPhone"]);
  }
});

// MARK: - Removing

test("removing the iPad unpairs it through OpenClaw, forgets its push registration and answers the list without it", async () => {
  const { phones, removed, forgotten, changes } = await setup();
  const answer = await phones.remove(signedRemoval(removal("franco-ipad")), "this-iphone");
  assert.deepEqual(removed, ["franco-ipad"]);
  assert.deepEqual(forgotten, ["franco-ipad"]);
  assert.equal(changes.length, 1, "the room is told its phones changed");
  assert.deepEqual(answer.phones.map((one) => one.id), ["this-iphone"]);
});

test("the iPad may remove this iPhone: any of the owner's phones signs for the others", async () => {
  const { phones, removed } = await setup();
  await phones.remove(signedRemoval(removal("this-iphone"), IPAD), "franco-ipad");
  assert.deepEqual(removed, ["this-iphone"]);
});

for (const [label, params] of [
  ["unsigned", removal("franco-ipad")],
  ["with a signature that is not one", { ...removal("franco-ipad"), signature: "not-a-signature" }],
  ["signed by Gia's phone, which is not paired here", signedRemoval(removal("franco-ipad"), GIA)],
  ["whose device was changed after it was signed", { ...signedRemoval(removal("this-iphone"), IPAD), device: "franco-ipad" }],
  ["whose time was changed after it was signed", { ...signedRemoval(removal("franco-ipad")), at: NOW - 500 }],
  ["signed as a pairing", { ...removal("franco-ipad"), signature: signedPairing(pairing()).signature }],
]) {
  test(`a removal ${label} is refused and removes nothing`, async () => {
    const { phones, removed, forgotten } = await setup();
    await assert.rejects(phones.remove(params, "this-iphone"), { code: "INVALID_REQUEST", message: /signature/ });
    assert.deepEqual(removed, []);
    assert.deepEqual(forgotten, []);
  });
}

for (const [label, at] of [
  ["signed more than five minutes ago", NOW - 6 * MINUTE],
  ["signed more than five minutes ahead", NOW + 6 * MINUTE],
  ["whose time is not a whole number", NOW + 0.5],
]) {
  test(`a removal ${label} is refused`, async () => {
    const { phones, removed } = await setup();
    await assert.rejects(phones.remove(signedRemoval(removal("franco-ipad", at)), "this-iphone"), { code: "INVALID_REQUEST", message: /time/ });
    assert.deepEqual(removed, []);
  });
}

test("a removal played back once the iPad is paired again, or one older than the newest change, is refused", async () => {
  // The iPad pairs again with the same device identity, so it is listed again at once.
  const removed = [];
  const { phones } = await setup({ removePairing: async (device) => removed.push(device) });
  const first = signedRemoval(removal("franco-ipad", NOW - 2000));
  await phones.remove(first, "this-iphone");
  await assert.rejects(phones.remove(first, "this-iphone"), { code: "INVALID_REQUEST", message: /newer/ });
  await assert.rejects(phones.remove(signedRemoval(removal("franco-ipad", NOW - 3000)), "this-iphone"), /newer/);
  assert.deepEqual(removed, ["franco-ipad"]);
});

test("a removal shares the settings replay guard: neither can be played against the other", async () => {
  const { phones, store, removed } = await setup();
  assert.equal(store.acceptChangeAt(NOW - 500), true, "a settings change at NOW - 500");
  await assert.rejects(phones.remove(signedRemoval(removal("franco-ipad", NOW - 1000)), "this-iphone"), /newer/);
  await phones.remove(signedRemoval(removal("franco-ipad", NOW - 100)), "this-iphone");
  assert.equal(store.acceptChangeAt(NOW - 200), false, "a settings change older than the removal");
  assert.deepEqual(removed, ["franco-ipad"]);
});

for (const [label, device] of [
  ["the Control UI, which is no app phone", "control-ui"],
  ["a phone still waiting to be paired", "waiting-phone"],
  ["a device this gateway never paired", "somebody-elses-phone"],
  ["an empty device", ""],
  ["a device on two lines", "franco-ipad\nthis-iphone"],
  ["a device that is not text", 7],
]) {
  test(`removing ${label} is refused as no such iPhone`, async () => {
    const { phones, removed } = await setup();
    const unsigned = removal(device);
    const params = typeof device === "string" ? signedRemoval(unsigned) : { ...unsigned, signature: "c2ln" };
    await assert.rejects(phones.remove(params, "this-iphone"), { code: "INVALID_REQUEST", message: /no such iPhone/ });
    assert.deepEqual(removed, []);
  });
}

test("a phone cannot remove itself this way, and is told to pair again instead", async () => {
  const { phones, removed, forgotten } = await setup();
  await assert.rejects(phones.remove(signedRemoval(removal("this-iphone")), "this-iphone"), {
    code: "INVALID_REQUEST",
    message: /itself.*Pair this iPhone again/,
  });
  assert.deepEqual(removed, []);
  assert.deepEqual(forgotten, []);
});

test("a refused removal does not use up its time, so the phone may sign again at once", async () => {
  const { phones, removed } = await setup();
  await assert.rejects(phones.remove(signedRemoval(removal("this-iphone", NOW - 2000)), "this-iphone"), /itself/);
  await assert.rejects(phones.remove(signedRemoval(removal("control-ui", NOW - 2000)), "this-iphone"), /no such iPhone/);
  await phones.remove(signedRemoval(removal("franco-ipad", NOW - 2000)), "this-iphone");
  assert.deepEqual(removed, ["franco-ipad"]);
});

test("when OpenClaw cannot remove the pairing, its push registration stays and the room is not told", async () => {
  const { phones, forgotten, changes } = await setup({
    removePairing: async () => {
      throw new Error("gateway closed");
    },
  });
  await assert.rejects(phones.remove(signedRemoval(removal("franco-ipad")), "this-iphone"), /gateway closed/);
  assert.deepEqual(forgotten, []);
  assert.deepEqual(changes, []);
});

// MARK: - A setup code for a new phone

test("a signed pairing answers with OpenClaw's setup code and its link, issued once", async () => {
  const { phones, issued } = await setup();
  assert.deepEqual(await phones.pairCode(signedPairing(pairing())), {
    setupCode: "c2V0dXAtY29kZQ",
    link: LINK,
    expiresAtMs: NOW + 10 * MINUTE,
  });
  assert.equal(issued.length, 1);
});

for (const [label, params] of [
  ["unsigned", pairing()],
  ["signed by Gia's phone", signedPairing(pairing(), GIA)],
  ["signed as a removal with no device", { ...pairing(), signature: signedRemoval(removal("")).signature }],
  ["whose time was changed after it was signed", { ...signedPairing(pairing()), at: NOW - 500 }],
]) {
  test(`a pairing ${label} is refused and issues no code`, async () => {
    const { phones, issued } = await setup();
    await assert.rejects(phones.pairCode(params), { code: "INVALID_REQUEST", message: /signature/ });
    assert.deepEqual(issued, []);
  });
}

test("a pairing out of time, played back, or older than the newest change is refused", async () => {
  const { phones, issued } = await setup();
  await assert.rejects(phones.pairCode(signedPairing(pairing(NOW - 6 * MINUTE))), /time/);
  const first = signedPairing(pairing(NOW - 2000));
  await phones.pairCode(first);
  await assert.rejects(phones.pairCode(first), /newer/);
  await assert.rejects(phones.pairCode(signedPairing(pairing(NOW - 3000))), /newer/);
  assert.equal(issued.length, 1);
});

// MARK: - OpenClaw's own removal

test("a pairing is removed by OpenClaw's own devices remove, run from the gateway's own entry point", async () => {
  const runs = [];
  const run = (file, args, options, done) => {
    runs.push({ file, args, timeout: options.timeout });
    done(null, '{"deviceId":"franco-ipad"}', "");
  };
  await removeThroughOpenClaw("franco-ipad", { run, entry: "/app/dist/index.js" });
  assert.deepEqual(runs, [
    { file: process.execPath, args: ["/app/dist/index.js", "devices", "remove", "franco-ipad", "--json"], timeout: 30_000 },
  ]);
});

test("a removal OpenClaw refuses is a failure, never taken as done", async () => {
  const run = (file, args, options, done) => done(Object.assign(new Error("exit 1"), { code: 1 }), "", "unknown deviceId");
  await assert.rejects(removeThroughOpenClaw("franco-ipad", { run, entry: "/app/dist/index.js" }), /exit 1/);
});
