import assert from "node:assert/strict";
import test from "node:test";
import * as plugin from "../../deploy/openclaw/plugins/pocket-piggies/index.mjs";
import { FAMILY_GROUP, FINANCE_SAFE_GATEWAY_CONFIG, OWNER } from "./fixtures/gateway.mjs";

const CONFIG = { ownerTelegramId: OWNER, accountLabel: "corey" };
const PRIVATE_COMMAND = {
  channel: "telegram",
  senderId: "123456",
  from: "telegram:123456",
  to: "telegram:123456",
  isAuthorizedSender: true,
  sessionKey: "agent:main:telegram:direct:123456",
};

test("connection commands require the authorized owner and a matching private conversation", () => {
  assert.equal(typeof plugin.authorizedPrivateCommand, "function");
  assert.equal(plugin.authorizedPrivateCommand(PRIVATE_COMMAND, CONFIG), true);
  for (const change of [
    { senderId: "789000" },
    { senderId: undefined },
    { from: "telegram:-1001" },
    { to: "telegram:-1001" },
    { to: "telegram:789000" },
    { from: undefined },
    { to: undefined },
    { isAuthorizedSender: false },
    { isAuthorizedSender: undefined },
    { channel: "webchat" },
    { sessionKey: "agent:main:main" },
    { sessionKey: "agent:main:telegram:group:123456" },
    { sessionKey: "agent:main:subagent:123456" },
    { sessionKey: "agent:main:telegram:direct:789000" },
    { sessionKey: undefined },
    { messageThreadId: 1 },
  ]) {
    assert.equal(
      plugin.authorizedPrivateCommand({ ...PRIVATE_COMMAND, ...change }, CONFIG),
      false,
      JSON.stringify(change),
    );
  }
  assert.equal(plugin.authorizedPrivateCommand(PRIVATE_COMMAND, {
    ...CONFIG, ownerTelegramId: "789000",
  }), false);
});

test("finance requires owner-only private messages and groups without file, shell or session tools", () => {
  const owner = OWNER;
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(FINANCE_SAFE_GATEWAY_CONFIG, owner), true);
  const telegram = FINANCE_SAFE_GATEWAY_CONFIG.channels.telegram;
  const family = telegram.groups[FAMILY_GROUP];
  const withTelegram = (change) => ({
    ...FINANCE_SAFE_GATEWAY_CONFIG,
    channels: { telegram: { ...telegram, ...change } },
  });
  const withFamily = (change) => withTelegram({ groups: { [FAMILY_GROUP]: { ...family, ...change } } });
  for (const [label, config] of [
    ["pairing DMs", withTelegram({ dmPolicy: "pairing" })],
    ["open DMs", withTelegram({ dmPolicy: "open", allowFrom: ["*"] })],
    ["a second DM sender", withTelegram({ allowFrom: [owner, "654321"] })],
    ["another DM sender", withTelegram({ allowFrom: ["654321"] })],
    ["no DM allowlist", withTelegram({ allowFrom: undefined })],
    ["open groups", withTelegram({ groupPolicy: "open" })],
    ["a second account", withTelegram({ accounts: { other: {} } })],
    ["per-DM tool overrides", withTelegram({ direct: { "*": { tools: { allow: ["exec"] } } } })],
    ["a group without a tool allowlist", withFamily({ tools: undefined })],
    ["a group with an empty allowlist", withFamily({ tools: { allow: [] } })],
    ["a group deny list only", withFamily({ tools: { deny: ["exec"] } })],
    ["exec in a group", withFamily({ tools: { allow: ["web_search", "exec"] } })],
    ["file reads in a group", withFamily({ tools: { allow: ["read"] } })],
    ["session history in a group", withFamily({ tools: { allow: ["sessions_history"] } })],
    ["finance in a group", withFamily({ tools: { allow: ["pocketpiggies_read"] } })],
    ["local image reads in a group", withFamily({ tools: { allow: ["view_image"] } })],
    ["a group deny beside its allowlist", withFamily({ tools: { allow: ["web_search"], deny: ["speak"] } })],
    ["global session scope", { ...FINANCE_SAFE_GATEWAY_CONFIG, session: { ...FINANCE_SAFE_GATEWAY_CONFIG.session, scope: "global" } }],
    ["a group binding into the main session", { ...FINANCE_SAFE_GATEWAY_CONFIG, bindings: [{ session: { groupScope: "main" } }] }],
    ["a wildcard in a group", withFamily({ tools: { allow: ["*"] } })],
    ["a plugin owner in a group", withFamily({ tools: { allow: ["pocket-piggies"] } })],
    ["per-sender group overrides", withFamily({ toolsBySender: { "id:654321": { alsoAllow: ["exec"] } } })],
    ["group topics", withFamily({ topics: { "*": { tools: { allow: ["exec"] } } } })],
    ["a wildcard group without an allowlist", withTelegram({ groups: { [FAMILY_GROUP]: family, "*": { requireMention: true } } })],
    ["shared DM history", { ...FINANCE_SAFE_GATEWAY_CONFIG, session: { dmScope: "main", groupScope: "per-group" } }],
    ["groups in the main session", { ...FINANCE_SAFE_GATEWAY_CONFIG, session: { dmScope: "per-channel-peer", groupScope: "main" } }],
    ["no Telegram section", { ...FINANCE_SAFE_GATEWAY_CONFIG, channels: {} }],
  ]) {
    assert.equal(plugin.hasFinanceSafeGatewayPolicy(config, owner), false, label);
  }
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(FINANCE_SAFE_GATEWAY_CONFIG, "654321"), false);
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(withTelegram({ allowFrom: [`telegram:${owner}`] }), owner), true);
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(withTelegram({ groupPolicy: "disabled", groups: undefined }), owner), true);
});

test("finance requires the household app's family room on a safe allowlist whenever the app's channel is configured", () => {
  const uncovered = {
    enabled: true,
    owner: { id: "franco", name: "Franco" },
    assistant: { id: "corey", name: "Corey" },
    peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
  };
  const room = { ...uncovered, familyTools: [...plugin.SAFE_GROUP_TOOLS] };
  const withHousehold = (household) => ({
    ...FINANCE_SAFE_GATEWAY_CONFIG,
    channels: { ...FINANCE_SAFE_GATEWAY_CONFIG.channels, household },
  });
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(withHousehold(room), OWNER), true);
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(withHousehold({ ...room, familyTools: ["web_search"] }), OWNER), true);
  for (const [label, household] of [
    ["no family-room allowlist", uncovered],
    ["a switched-off channel with none, which a hot reload can switch on", { ...uncovered, enabled: false }],
    ["an empty family-room allowlist", { ...room, familyTools: [] }],
    ["exec in the family room", { ...room, familyTools: ["web_search", "exec"] }],
    ["file reads in the family room", { ...room, familyTools: ["read"] }],
    ["finance in the family room", { ...room, familyTools: ["pocketpiggies_read"] }],
    ["a wildcard in the family room", { ...room, familyTools: ["*"] }],
    ["a plugin owner in the family room", { ...room, familyTools: ["pocket-piggies"] }],
    ["a family-room allowlist that is not a list", { ...room, familyTools: "web_search" }],
    ["a household section that is not an object", null],
  ]) {
    assert.equal(plugin.hasFinanceSafeGatewayPolicy(withHousehold(household), OWNER), false, label);
  }
});
