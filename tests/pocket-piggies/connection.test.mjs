import assert from "node:assert/strict";
import test from "node:test";
import * as plugin from "../../deploy/openclaw/plugins/pocket-piggies/index.mjs";
import { FINANCE_SAFE_GATEWAY_CONFIG, OWNER } from "./fixtures/gateway.mjs";

const CONFIG = { ownerHouseholdPersonId: OWNER, accountLabel: "corey" };
// `/pocketpiggies` in the owner's own thread, as OpenClaw hands a household-app turn's command
// to a plugin: the signed author as the sender, the owner's thread as the chat and session.
const OWN_THREAD_COMMAND = {
  channel: "household",
  senderId: OWNER,
  from: `household:${OWNER}`,
  to: `household:${OWNER}`,
  isAuthorizedSender: true,
  sessionKey: `agent:main:household:direct:${OWNER}`,
};

test("connection commands require the authorized owner in their own thread", () => {
  assert.equal(plugin.authorizedAppCommand(OWN_THREAD_COMMAND, CONFIG), true);
  for (const change of [
    { senderId: "gia" },
    { senderId: undefined },
    { from: "household:gia" },
    { to: "household:family" },
    { to: "household:gia" },
    { from: undefined },
    { to: undefined },
    { isAuthorizedSender: false },
    { isAuthorizedSender: undefined },
    { channel: "webchat" },
    { channel: "telegram" },
    { sessionKey: "agent:main:main" },
    { sessionKey: "agent:main:household:group:family" },
    { sessionKey: `agent:main:household:group:family:sender:${OWNER}` },
    { sessionKey: `agent:main:subagent:${OWNER}` },
    { sessionKey: "agent:main:household:direct:gia" },
    { sessionKey: undefined },
    { messageThreadId: 1 },
  ]) {
    assert.equal(
      plugin.authorizedAppCommand({ ...OWN_THREAD_COMMAND, ...change }, CONFIG),
      false,
      JSON.stringify(change),
    );
  }
  for (const owner of ["gia", "family", "cli", "openclaw-ios", "Franco", undefined]) {
    assert.equal(plugin.authorizedAppCommand(OWN_THREAD_COMMAND, { ...CONFIG, ownerHouseholdPersonId: owner }), false, String(owner));
  }
});

test("finance requires the owner's channel, every other chat channel off and isolated sessions", () => {
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(FINANCE_SAFE_GATEWAY_CONFIG, OWNER), true);
  const channels = FINANCE_SAFE_GATEWAY_CONFIG.channels;
  const withChannels = (change) => ({ ...FINANCE_SAFE_GATEWAY_CONFIG, channels: { ...channels, ...change } });
  for (const [label, config] of [
    ["Telegram switched back on", withChannels({ telegram: { ...channels.telegram, enabled: true } })],
    ["Telegram with no switch, which OpenClaw starts", withChannels({ telegram: { botToken: "x" } })],
    ["another chat channel", withChannels({ whatsapp: { dmPolicy: "allowlist" } })],
    ["a channel that is not an object", withChannels({ signal: true })],
    ["another person's app channel", withChannels({ household: { ...channels.household, owner: { id: "gia" } } })],
    ["global session scope", { ...FINANCE_SAFE_GATEWAY_CONFIG, session: { ...FINANCE_SAFE_GATEWAY_CONFIG.session, scope: "global" } }],
    ["a group binding into the main session", { ...FINANCE_SAFE_GATEWAY_CONFIG, bindings: [{ session: { groupScope: "main" } }] }],
    ["shared DM history", { ...FINANCE_SAFE_GATEWAY_CONFIG, session: { dmScope: "main", groupScope: "per-group" } }],
    ["groups in the main session", { ...FINANCE_SAFE_GATEWAY_CONFIG, session: { dmScope: "per-channel-peer", groupScope: "main" } }],
  ]) {
    assert.equal(plugin.hasFinanceSafeGatewayPolicy(config, OWNER), false, label);
  }
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(FINANCE_SAFE_GATEWAY_CONFIG, "gia"), false);
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(FINANCE_SAFE_GATEWAY_CONFIG, "7000000001"), false);
  // The retired channel gone altogether, and settings that configure every channel, are fine.
  const { telegram, ...appOnly } = channels;
  assert.equal(plugin.hasFinanceSafeGatewayPolicy({ ...FINANCE_SAFE_GATEWAY_CONFIG, channels: appOnly }, OWNER), true);
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(withChannels({ modelByChannel: { household: "x" } }), OWNER), true);
  // No app channel at all: no turn can be the owner's, and nothing else can reach a full-tool turn.
  assert.equal(plugin.hasFinanceSafeGatewayPolicy({ ...FINANCE_SAFE_GATEWAY_CONFIG, channels: {} }, OWNER), true);
});

test("finance requires the household app's family room on a safe allowlist whenever the app's channel is configured", () => {
  const { familyTools, ...uncovered } = FINANCE_SAFE_GATEWAY_CONFIG.channels.household;
  const room = { ...uncovered, familyTools: [...plugin.SAFE_GROUP_TOOLS] };
  const withHousehold = (household) => ({
    ...FINANCE_SAFE_GATEWAY_CONFIG,
    channels: { ...FINANCE_SAFE_GATEWAY_CONFIG.channels, household },
  });
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(withHousehold(room), OWNER), true);
  assert.equal(plugin.hasFinanceSafeGatewayPolicy(withHousehold({ ...room, familyTools: ["web_search"] }), OWNER), true);
  assert.ok(!plugin.SAFE_GROUP_TOOLS.includes("speak"), "nothing provides speak any more");
  for (const [label, household] of [
    ["no family-room allowlist", uncovered],
    ["a switched-off channel with none, which a hot reload can switch on", { ...uncovered, enabled: false }],
    ["an empty family-room allowlist", { ...room, familyTools: [] }],
    ["exec in the family room", { ...room, familyTools: ["web_search", "exec"] }],
    ["file reads in the family room", { ...room, familyTools: ["read"] }],
    ["session history in the family room", { ...room, familyTools: ["sessions_history"] }],
    ["finance in the family room", { ...room, familyTools: ["pocketpiggies_read"] }],
    ["local image reads in the family room", { ...room, familyTools: ["view_image"] }],
    ["a wildcard in the family room", { ...room, familyTools: ["*"] }],
    ["a plugin owner in the family room", { ...room, familyTools: ["pocket-piggies"] }],
    ["a family-room allowlist that is not a list", { ...room, familyTools: "web_search" }],
    ["a household section that is not an object", null],
  ]) {
    assert.equal(plugin.hasFinanceSafeGatewayPolicy(withHousehold(household), OWNER), false, label);
  }
});
