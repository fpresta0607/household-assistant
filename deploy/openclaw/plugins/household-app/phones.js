// The owner's iPhones, from one of them, for Account: which are paired to this gateway,
// removing one, and a setup code for a new one.
//
// The list is OpenClaw's own device list, read the way the room reads the owner's keys
// from it (pairing.js): each phone's device id, the name and model OpenClaw keeps for it,
// when it last connected, and whether it is the phone asking. Never a key or a token.
//
// Removing a phone and asking for a setup code are each signed by one of the owner's
// phones over household-app/phone/v1, as a settings change is, and share the settings
// replay guard (settings-store.js), so neither can be played again or against another
// change. A phone removes its own pairing with "Pair this iPhone again", never here, so
// nobody removes the phone in their hand by mistake. The removal is OpenClaw's own
// `devices remove`, which drops the device's tokens and closes its connections, and its
// push registration goes with it. A setup code is OpenClaw's own single-use bootstrap
// token, issued exactly as /app issues one.

import { execFile } from "node:child_process";

import { appPhonesFrom } from "./pairing.js";
import { RoomError } from "./room.js";
import { isTextSignedBy } from "./signature.js";

export const PHONE_VERSION = "household-app/phone/v1";
const SIGNED_WITHIN_MS = 5 * 60_000;
// A device id as OpenClaw names a phone's connection.
const DEVICE = /^[A-Za-z0-9._:-]{1,128}$/;
const REMOVE_MS = 30_000;

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

// The exact text the phone signs, one line each. A pairing names no device, so its last
// line is empty.
export function phoneText({ at, action, device }) {
  return [PHONE_VERSION, String(at), action, device].join("\n");
}

// OpenClaw's own `devices remove`, run from the gateway's own entry point in its own
// environment, the way the box runs it, so it reaches this gateway over loopback as the
// gateway's administrator.
export function removeThroughOpenClaw(device, { run = execFile, entry = process.argv[1] } = {}) {
  return new Promise((resolve, reject) => {
    run(process.execPath, [entry, "devices", "remove", device, "--json"], { timeout: REMOVE_MS }, (error) => {
      if (error) reject(error);
      else resolve();
    });
  });
}

// `devices` answers with OpenClaw's device list and `phoneKeys` with the owner's phones'
// keys, `store` is settings-store.js's (for the shared replay guard), `removePairing`
// removes one device's pairing and `forgetPush` its push registration, `issueCode`
// answers a setup code with its link, and `changed` is told once a phone is gone.
export function createPhones({ devices, phoneKeys, store, removePairing, forgetPush, issueCode, changed, now = Date.now }) {
  async function view(caller) {
    return {
      phones: appPhonesFrom(await devices()).map((row) => ({
        id: row.deviceId,
        // OpenClaw's own order for naming a device.
        name: row.operatorLabel ?? row.displayName ?? row.clientId,
        model: row.deviceFamily ?? null,
        lastSeenAtMs: row.lastSeenAtMs ?? null,
        isThisPhone: row.deviceId === caller,
      })),
    };
  }

  function checkTime(at) {
    if (!Number.isSafeInteger(at) || Math.abs(at - now()) > SIGNED_WITHIN_MS) refuse("request time out of range");
  }

  async function checkSignature({ at, signature }, action, device) {
    if (!isTextSignedBy(phoneText({ at, action, device }), signature, await phoneKeys())) {
      refuse("a change to the paired phones must carry the signature of one of the owner's phones");
    }
  }

  function accept(at) {
    if (!store.acceptChangeAt(at)) refuse("the gateway already has a newer change");
  }

  return {
    view,

    // `caller` is the asking phone's own device id, from its connection.
    async remove(params, caller) {
      const { at, device } = params ?? {};
      checkTime(at);
      if (typeof device !== "string" || !DEVICE.test(device)) refuse("no such iPhone is paired with this gateway");
      await checkSignature(params, "remove", device);
      if (!appPhonesFrom(await devices()).some((row) => row.deviceId === device)) refuse("no such iPhone is paired with this gateway");
      if (device === caller) refuse("an iPhone cannot remove itself here, use Pair this iPhone again");
      accept(at);
      await removePairing(device);
      forgetPush(device);
      await changed();
      return view(caller);
    },

    async pairCode(params) {
      const { at } = params ?? {};
      checkTime(at);
      await checkSignature(params, "pair", "");
      accept(at);
      return issueCode();
    },
  };
}
