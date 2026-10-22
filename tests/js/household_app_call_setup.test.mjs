// How a phone's call with the assistant came up, from
// deploy/openclaw/plugins/household-app/call-log.js: the setup the phone sends beside the
// call's end becomes one line in the gateway's log, numbers and the route only, and a
// setup that does not read never stops the call from being kept.
//
// Run with `node --test tests/js/household_app_call_setup.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { test } from "node:test";

import { callSetupLine } from "../../deploy/openclaw/plugins/household-app/call-log.js";
import { callEndSignedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { runningChannel } from "./fixtures/household-app-channel.mjs";

const STARTED_AT = Date.UTC(2026, 9, 17, 15, 31, 4, 678);
const CALL = { startedAt: STARTED_AT, endedAt: STARTED_AT + 21_077 };
const KEPT = { turnIds: ["d-00000001", "a-00000002"] };
const SETUP = { build: "18", route: "callkit", linkMs: 0, soundMs: 412, connectedMs: 412, firstReplyMs: 2310 };

test("a call's setup is one line of moments from the tap", () => {
  assert.equal(
    callSetupLine({ ...CALL, setup: SETUP }, KEPT),
    "household-app: call setup, build 18, callkit: link 0 ms, sound 412 ms, connected 412 ms, first reply 2310 ms; lasted 21.1 s, 2 turns",
  );
});

test("a moment the call never reached says never", () => {
  const { build, linkMs } = SETUP;
  assert.equal(
    callSetupLine({ ...CALL, setup: { build, route: "app refused 1", linkMs } }, { turnIds: [] }),
    "household-app: call setup, build 18, app refused 1: link 0 ms, sound never, connected never, first reply never; lasted 21.1 s, 0 turns",
  );
});

test("a phone from before the setup was sent says so", () => {
  assert.equal(callSetupLine(CALL, KEPT), "household-app: call setup not sent; lasted 21.1 s, 2 turns");
});

for (const [name, change] of [
  ["a build that carries words", { build: "18; rm -rf" }],
  ["a route it does not know", { route: "callkit, and more" }],
  ["a negative moment", { soundMs: -1 }],
  ["a fractional moment", { connectedMs: 1.5 }],
  ["a moment longer than any call", { firstReplyMs: 7 * 3_600_000 }],
  ["a moment that is not a number", { linkMs: "0" }],
]) {
  test(`a setup with ${name} is unreadable and nothing of it is logged`, () => {
    const line = callSetupLine({ ...CALL, setup: { ...SETUP, ...change } }, KEPT);
    assert.equal(line, "household-app: call setup unreadable; lasted 21.1 s, 2 turns");
  });
}

test("a setup that is not an object is unreadable", () => {
  assert.match(callSetupLine({ ...CALL, setup: null }, KEPT), /call setup unreadable/);
});

test("ending a call keeps it and logs how it came up, and an unreadable setup still keeps it", async () => {
  // Arrange
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const phoneKey = publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url");
  const channel = await runningChannel({
    channels: {
      household: {
        owner: { id: "franco", name: "Franco", deviceKeys: [phoneKey] },
        assistant: { id: "corey", name: "Corey" },
        peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
      },
    },
  });
  const ended = (setup) => {
    const call = { callId: randomUUID(), startedAt: Date.now() - 21_077, endedAt: Date.now(), turns: [] };
    return { ...call, setup, signature: sign(null, Buffer.from(callEndSignedText(call), "utf8"), privateKey).toString("base64url") };
  };

  try {
    // Act
    const kept = await channel.call("household-app.call.end", ended(SETUP));
    const unreadable = await channel.call("household-app.call.end", ended({ ...SETUP, route: "who knows" }));

    // Assert
    assert.equal(kept.ok, true);
    assert.equal(unreadable.ok, true, "the call is kept whatever its setup says");
    const lines = channel.logs.filter((line) => line.startsWith("household-app: call setup"));
    assert.deepEqual(lines, [
      "household-app: call setup, build 18, callkit: link 0 ms, sound 412 ms, connected 412 ms, first reply 2310 ms; lasted 21.1 s, 0 turns",
      "household-app: call setup unreadable; lasted 21.1 s, 0 turns",
    ]);
  } finally {
    await channel.stop();
  }
});
