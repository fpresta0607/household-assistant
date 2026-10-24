// The connectors a phone may switch for its own assistant, from
// deploy/openclaw/plugins/household-app/connectors.js: which ones each gateway shows,
// the one setting each switches, and the ones a phone is never offered.
//
// Run with `node --test tests/js/household_app_connectors.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  CATEGORIES,
  CONNECTORS,
  connectorView,
  connectorsFor,
  isConnectorOn,
  switchConnector,
} from "../../deploy/openclaw/plugins/household-app/connectors.js";

// Switching any of these off from a phone would cut the phone off, break the family
// room, or reach PocketPiggies' key holder or a model provider.
const NEVER_OFFERED = [
  "household-app",
  "household-family-room",
  "household-memory",
  "household-speech",
  "memory-core",
  "telegram",
  "device-pair",
  "pocketpiggies-keyholder",
  "openrouter",
  "openai",
  "anthropic",
  "google",
  "xai",
  "elevenlabs",
];
// The tools those plugins give the assistant.
const NEVER_DENIED = ["household_location", "family_history", "recall", "forget", "speak", "memory_search", "memory_get", "message"];
const LOGOS = [
  "anthropic", "apple", "brave", "deepseek", "duckduckgo", "elevenlabs", "gmail", "google", "googlecalendar",
  "googlegemini", "icloud", "notion", "openai", "openrouter", "perplexity", "telegram",
];

test("no connector is a household plugin, memory, Telegram, pairing, the key holder or a model provider", () => {
  for (const connector of CONNECTORS) {
    assert.equal(NEVER_OFFERED.includes(connector.id), false, connector.id);
    for (const skill of connector.skills ?? []) assert.equal(NEVER_OFFERED.includes(skill), false, skill);
    for (const tool of connector.tools ?? []) assert.equal(NEVER_DENIED.includes(tool), false, tool);
    assert.deepEqual(Object.keys(connector).filter((key) => !["id", "name", "category", "icon", "summary", "skills", "tools", "assistants", "signIn", "signInKind", "envSignIn", "envUsername", "capabilities"].includes(key)), []);
  }
});

test("every connector switches a skill or a tool and nothing else", () => {
  for (const connector of CONNECTORS) {
    assert.ok((connector.skills ?? []).length + (connector.tools ?? []).length > 0, connector.id);
  }
});

test("every connector has a category, a plain summary and an icon the app has", () => {
  assert.deepEqual(CATEGORIES, ["money", "faith", "calendar-and-mail", "notes", "web", "pictures-and-video", "everyday"]);
  for (const connector of CONNECTORS) {
    assert.ok(CATEGORIES.includes(connector.category), connector.id);
    assert.match(connector.summary, /^[A-Z][^\n;]{2,60}$/, connector.id);
    assert.equal(connector.summary.includes(String.fromCharCode(0x2014)), false, connector.id);
    assert.ok(
      LOGOS.includes(connector.icon) || ["pocketpiggies", "zai"].includes(connector.icon) || /^symbol:[a-z0-9.]+$/.test(connector.icon),
      `${connector.id}: ${connector.icon}`,
    );
  }
  assert.equal(new Set(CONNECTORS.map((connector) => connector.id)).size, CONNECTORS.length);
  const order = CONNECTORS.map((connector) => CATEGORIES.indexOf(connector.category));
  assert.deepEqual(order, order.toSorted((one, other) => one - other), "listed by category, as the phone groups them");
});

test("each gateway shows only the connectors it has, as read from both on 15 October", () => {
  const corey = connectorsFor("corey").map((connector) => connector.id);
  const denise = connectorsFor("denise").map((connector) => connector.id);
  for (const shared of ["pocket-piggies", "scripture", "icloud", "gog", "notion", "perplexity", "web-readability", "browser-automation", "weather", "image-generation", "video-generation"]) {
    assert.ok(corey.includes(shared) && denise.includes(shared), shared);
  }
  assert.ok(corey.includes("outlook-hack") && !denise.includes("outlook-hack"));
  assert.ok(denise.includes("himalaya") && !corey.includes("himalaya"));
});

test("scripture is the gateway's own Bible tool and PocketPiggies keeps the household's icon", () => {
  const byId = Object.fromEntries(CONNECTORS.map((connector) => [connector.id, connector]));
  assert.equal(byId.scripture.name, "Scripture");
  assert.equal(byId.scripture.icon, "symbol:book");
  assert.deepEqual(byId.scripture.tools, ["scripture"]);
  assert.equal(byId.scripture.signIn, undefined);
  assert.equal(byId["pocket-piggies"].icon, "pocketpiggies");
});

test("a connector is on until its skill is switched off or its tool is denied", () => {
  const byId = Object.fromEntries(CONNECTORS.map((connector) => [connector.id, connector]));
  assert.equal(isConnectorOn(byId.notion, {}), true);
  assert.equal(isConnectorOn(byId.notion, { skills: { entries: { notion: { enabled: false } } } }), false);
  assert.equal(isConnectorOn(byId.notion, { skills: { entries: { notion: { enabled: true } } } }), true);
  assert.equal(isConnectorOn(byId.perplexity, { tools: { deny: ["web_search"] } }), false);
  assert.equal(isConnectorOn(byId["browser-automation"], { tools: { deny: ["browser"] } }), false);
});

test("switching off writes every gate of the connector, and switching on undoes only those", () => {
  const byId = Object.fromEntries(CONNECTORS.map((connector) => [connector.id, connector]));
  const draft = { skills: { entries: { weather: { enabled: false } } }, tools: { deny: ["codex"] } };
  switchConnector(draft, byId["browser-automation"], false);
  assert.deepEqual(draft.skills.entries["browser-automation"], { enabled: false });
  assert.deepEqual(draft.tools.deny, ["codex", "browser"]);
  switchConnector(draft, byId["browser-automation"], false);
  assert.deepEqual(draft.tools.deny, ["codex", "browser"], "switching off twice adds nothing twice");
  switchConnector(draft, byId["browser-automation"], true);
  assert.deepEqual(draft.skills.entries["browser-automation"], { enabled: true });
  assert.deepEqual(draft.tools.deny, ["codex"]);
  assert.deepEqual(draft.skills.entries.weather, { enabled: false }, "another skill stays as it was");
});

test("PocketPiggies is switched by its three tools, which its own guard leaves alone", () => {
  const draft = {};
  switchConnector(draft, CONNECTORS.find((connector) => connector.id === "pocket-piggies"), false);
  assert.deepEqual(draft.tools.deny, ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]);
  assert.equal(draft.plugins, undefined, "the plugin and its key holder are never touched");
});

test("every connector says in 1 to 5 plain lines what the assistant can do with it", () => {
  for (const connector of CONNECTORS) {
    assert.ok(connector.capabilities.length >= 1 && connector.capabilities.length <= 5, connector.id);
    for (const line of connector.capabilities) {
      assert.match(line, /^[A-Z][^\n;]{2,70}$/, `${connector.id}: ${line}`);
      assert.equal(line.includes(String.fromCharCode(0x2014)), false, connector.id);
    }
  }
});

test("build 13's signIn keeps its two values, and Notion's sign-in shows only in signInKind", () => {
  for (const connector of CONNECTORS) assert.ok([undefined, "oauth", "password"].includes(connector.signIn), connector.id);
  const notion = CONNECTORS.find((connector) => connector.id === "notion");
  assert.equal(connectorView(notion, {}, { signInKind: "token" }).signIn, null);
  assert.equal(connectorView(notion, {}, { signInKind: "token" }).signInKind, "token");
});

const ACCOUNT = { id: "gog:app", name: "Gia", email: "gia@example.com", linkedAt: 1, status: "ok", abilities: ["Reads your Gmail"], canDisconnect: true };
const byId = (id) => CONNECTORS.find((connector) => connector.id === id);

for (const [why, connector, readBack, state] of [
  ["a sign-in with an account linked", "gog", { signInKind: "oauth", linkedAccounts: [ACCOUNT] }, "connected"],
  ["a sign-in with none linked", "gog", { signInKind: "oauth", linkedAccounts: [] }, "available"],
  ["a connector that needs no sign-in", "weather", {}, "connected"],
  ["a connector this gateway does not have", "outlook-hack", { reason: "Not on this assistant" }, "unavailable"],
]) {
  test(`${why} reads as ${state}`, () => {
    assert.equal(connectorView(byId(connector), {}, readBack).state, state);
  });
}

test("a connector reads back today's fields for build 13 and the new ones for build 14, and an unavailable one offers no sign-in", () => {
  const here = connectorView(byId("gog"), {}, { signInKind: "oauth", linkedAccounts: [ACCOUNT], oauth: { provider: "google" } });
  assert.deepEqual(Object.keys(here).sort(), [
    "accounts", "capabilities", "category", "icon", "id", "isOn", "linkedAccounts", "name", "oauth", "reason", "signIn", "signInKind", "state", "summary",
  ]);
  assert.equal(here.accounts, 1);
  assert.equal(here.signIn, "oauth");
  assert.equal(here.reason, null);

  const elsewhere = connectorView(byId("himalaya"), {}, { reason: "Not on this assistant" });
  assert.deepEqual(
    [elsewhere.state, elsewhere.reason, elsewhere.signIn, elsewhere.signInKind, elsewhere.oauth, elsewhere.accounts],
    ["unavailable", "Not on this assistant", null, null, null, 0],
  );
});
