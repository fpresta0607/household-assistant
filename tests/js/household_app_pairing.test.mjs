// One-tap pairing for the app, from deploy/openclaw/plugins/household-app/pairing.js:
// the setup code a person gets from /app, who may ask for one, and which paired phones
// speak for the owner.
//
// Run with `node --test tests/js/household_app_pairing.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { test } from "node:test";

import {
  APP_CLIENT,
  PAIR_PAGE,
  PAIR_PATH,
  isPhoneUrl,
  issueSetupCode,
  mayIssueSetupCode,
  pairLink,
  phoneKeysFrom,
  setupReply,
} from "../../deploy/openclaw/plugins/household-app/pairing.js";

const URL_FOR_PHONES = "wss://household.example.ts.net:18789";

function phoneKey() {
  const { publicKey } = generateKeyPairSync("ed25519");
  return publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url");
}

function decode(code) {
  return JSON.parse(Buffer.from(code, "base64url").toString("utf8"));
}

test("the setup code carries the phone address, OpenClaw's single-use token, and who it is for", async () => {
  const asked = [];
  const issue = async (request) => {
    asked.push(request);
    return { token: "bootstrap-token-1", expiresAtMs: 1_792_050_000_000 };
  };
  const profile = { roles: ["node", "operator"], scopes: ["operator.read", "operator.write"] };

  const { code, expiresAtMs } = await issueSetupCode({ url: URL_FOR_PHONES, person: "franco", assistant: "Corey", issue, profile });

  assert.deepEqual(asked, [{ profile }]);
  assert.equal(expiresAtMs, 1_792_050_000_000);
  assert.match(code, /^[A-Za-z0-9_-]+$/);
  assert.deepEqual(decode(code), {
    url: URL_FOR_PHONES,
    bootstrapToken: "bootstrap-token-1",
    expiresAtMs: 1_792_050_000_000,
    access: "limited",
    person: "franco",
    assistant: "Corey",
  });
});

test("the reply leads with a link that opens the app, and keeps the code to copy", () => {
  const link = "https://household.example.ts.net:18789/household-app/pair#abc_DEF-123";
  const lines = setupReply({ code: "abc_DEF-123", link }).split("\n");
  assert.ok(lines.includes(link));
  assert.ok(lines.includes("`abc_DEF-123`"));
  assert.ok(lines.indexOf(link) < lines.indexOf("`abc_DEF-123`"));
  assert.match(lines.join("\n"), /10 minutes/);
  assert.doesNotMatch(lines.join("\n"), /[—;]/);
});

test("the link is the gateway's own tailnet page, with the code only after the #", () => {
  assert.equal(
    pairLink("wss://household.example.ts.net:18790", "abc_DEF-123"),
    `https://household.example.ts.net:18790${PAIR_PATH}#abc_DEF-123`,
  );
});

test("the page hands the code from the # to the app and asks the server for nothing", () => {
  assert.match(PAIR_PAGE, /location\.hash/);
  assert.match(PAIR_PAGE, /steward:\/\/pair\?code=/);
  assert.doesNotMatch(PAIR_PAGE, /fetch\(|XMLHttpRequest|<link|src="http/);
});

for (const [name, ctx, expected] of [
  ["the owner in Telegram", { channel: "telegram", senderIsOwner: true }, true],
  ["someone else in Telegram", { channel: "telegram", senderIsOwner: false }, false],
  ["a sender OpenClaw says nothing about", { channel: "telegram" }, false],
  ["a gateway client with operator.admin", { channel: "webchat", gatewayClientScopes: ["operator.admin"] }, true],
  ["a gateway client with operator.pairing", { channel: "webchat", gatewayClientScopes: ["operator.pairing"] }, true],
  ["a gateway client with only chat scopes", { channel: "webchat", gatewayClientScopes: ["operator.read", "operator.write"] }, false],
]) {
  test(`${name} ${expected ? "may" : "may not"} ask for a setup code`, () => {
    assert.equal(mayIssueSetupCode(ctx), expected);
  });
}

for (const [url, expected] of [
  [URL_FOR_PHONES, true],
  ["wss://household.example.ts.net:18790", true],
  ["ws://household.example.ts.net:18789", false],
  ["https://household.example.ts.net:18789", false],
  ["wss://user:secret@household.example.ts.net:18789", false],
  ["not a url", false],
  [undefined, false],
]) {
  test(`${JSON.stringify(url)} ${expected ? "is" : "is not"} an address for phones`, () => {
    assert.equal(isPhoneUrl(url), expected);
  });
}

test("the app's paired phones are the ones that speak for the owner", () => {
  const byCode = phoneKey();
  const pinnedBefore = phoneKey();
  const keys = phoneKeysFrom({
    pending: [{ clientId: APP_CLIENT, role: "operator", publicKey: phoneKey() }],
    paired: [
      { clientId: APP_CLIENT, role: "node", roles: ["node", "operator"], publicKey: byCode },
      { clientId: APP_CLIENT, role: "operator", publicKey: pinnedBefore },
      { clientId: APP_CLIENT, role: "operator", publicKey: pinnedBefore },
      { clientId: APP_CLIENT, role: "node", roles: ["node"], publicKey: phoneKey() },
      { clientId: "openclaw-control-ui", role: "operator", publicKey: phoneKey() },
      { clientId: APP_CLIENT, role: "operator", publicKey: "not-a-key" },
      null,
    ],
  });
  assert.deepEqual(keys, [byCode, pinnedBefore]);
});

test("a listing without paired phones gives no keys", () => {
  assert.deepEqual(phoneKeysFrom({}), []);
  assert.deepEqual(phoneKeysFrom(null), []);
});
