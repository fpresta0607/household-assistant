// The family room's tools, from deploy/openclaw/plugins/household-app: anyone else's
// family-room turn gets The Fam's own tool allowlist, no tools at all when there is none,
// and the owner's own turns, their thread and a family-room turn they started, keep every
// tool.
//
// Run with `node --test tests/js/household_app_family_tools.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { familyToolPolicy } from "../../deploy/openclaw/plugins/household-app/family-tools.js";
import { stubChannelSdk } from "./fixtures/openclaw-channel-sdk.mjs";

const PLUGIN = new URL("../../deploy/openclaw/plugins/household-app/", import.meta.url);
const THE_FAMS_TOOLS = ["web_search", "web_fetch", "speak", "family_history", "picture", "video"];
const ROOM = {
  owner: { id: "franco", name: "Franco" },
  assistant: { id: "corey", name: "Corey" },
  peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
};
const NO_TOOLS = { deny: ["*"] };

function configWith(household) {
  return { channels: { household: { ...ROOM, ...household } } };
}

// What OpenClaw 2026.9.4 hands a channel's group adapter for a turn in the family room.
function familyTurn(cfg, change = {}) {
  return { cfg, groupId: "family", accountId: "default", senderId: "gia", senderName: "Gia", ...change };
}

// The two assistants' direct line is a group of its own, and a handoff's turn there, sent by
// the other assistant, gets The Fam's tools like any turn in the room's shared session.
test("a handoff's turn in the assistants' direct line gets the tools The Fam allows, even sent as the owner", () => {
  const cfg = configWith({ familyTools: THE_FAMS_TOOLS });
  for (const change of [{ senderId: "denise", senderName: "Denise" }, { senderId: "franco", senderName: "Franco", senderPolicyMode: "always" }]) {
    assert.deepEqual(familyToolPolicy(familyTurn(cfg, { groupId: "pair", ...change })), { allow: THE_FAMS_TOOLS }, JSON.stringify(change));
  }
  assert.deepEqual(familyToolPolicy(familyTurn(configWith({}), { groupId: "pair", senderId: "denise" })), NO_TOOLS);
});

test("anyone else's family-room turn gets the tools The Fam allows", () => {
  const cfg = configWith({ familyTools: THE_FAMS_TOOLS });
  for (const change of [
    {},
    { senderId: "denise", senderName: "Denise" },
    { senderId: "household:gia" },
    { senderPolicyMode: "never" },
    // A run with sender rules off, such as a scheduled one, is nobody's own turn.
    { senderId: "franco", senderName: "Franco", senderPolicyMode: "never" },
    { senderId: undefined, senderName: undefined },
    { senderId: "openclaw-ios" },
    { senderId: "Franco" },
    { senderId: "franco-2" },
  ]) {
    assert.deepEqual(familyToolPolicy(familyTurn(cfg, change)), { allow: THE_FAMS_TOOLS }, JSON.stringify(change));
  }
});

// The owner's own session of the room, `agent:main:household:group:family:sender:franco`,
// whose groups OpenClaw asks about in order: `family:sender:franco`, then `family`.
const OWNERS_OWN = { groupId: "family:sender:franco", senderId: "franco", senderName: "Franco", senderPolicyMode: "always" };

test("the owner's own session of the room keeps every tool their thread has, list or none", () => {
  for (const cfg of [configWith({ familyTools: THE_FAMS_TOOLS }), configWith({})]) {
    for (const change of [OWNERS_OWN, { ...OWNERS_OWN, senderId: "household:franco" }, { ...OWNERS_OWN, senderPolicyMode: "when-sender-id" }]) {
      // A policy that restricts nothing, so OpenClaw stops at it and never reaches `family`.
      assert.deepEqual(familyToolPolicy(familyTurn(cfg, change)), { deny: [] }, JSON.stringify(change));
    }
  }
});

test("the room's shared session holds the owner to The Fam's list too, and the owner's session holds everyone else", () => {
  const cfg = configWith({ familyTools: THE_FAMS_TOOLS });
  for (const change of [
    { senderId: "franco" },
    { ...OWNERS_OWN, groupId: "family" },
    { ...OWNERS_OWN, senderId: "gia" },
    { ...OWNERS_OWN, senderId: "denise" },
    // A gateway client's chat.send naming the owner's session names its own client id.
    { ...OWNERS_OWN, senderId: "openclaw-ios" },
    { ...OWNERS_OWN, senderId: undefined },
    { ...OWNERS_OWN, senderPolicyMode: "never" },
    { ...OWNERS_OWN, groupId: "family:sender:gia", senderId: "gia" },
    { ...OWNERS_OWN, groupId: "family:sender:franco:topic:1" },
  ]) {
    assert.deepEqual(familyToolPolicy(familyTurn(cfg, change)), { allow: THE_FAMS_TOOLS }, JSON.stringify(change));
  }
  for (const owner of ["cli", "webchat", "family", "openclaw-ios"]) {
    const reserved = { channels: { household: { ...ROOM, owner: { id: owner }, familyTools: THE_FAMS_TOOLS } } };
    const turn = familyTurn(reserved, { groupId: `family:sender:${owner}`, senderId: owner, senderPolicyMode: "always" });
    assert.deepEqual(familyToolPolicy(turn), { allow: THE_FAMS_TOOLS }, `an owner named ${owner} could be spoken for by a client`);
  }
});

test("with no allowlist a family-room turn gets no tools at all, never every tool", () => {
  // OpenClaw reads no policy, and an empty allow list, as every tool, so neither may come back.
  for (const [label, cfg] of [
    ["no list", configWith({})],
    ["an empty list", configWith({ familyTools: [] })],
    ["a list that is not one", configWith({ familyTools: "web_search" })],
    ["a null list", configWith({ familyTools: null })],
    ["a wildcard", configWith({ familyTools: ["*"] })],
    ["a glob", configWith({ familyTools: ["web_*"] })],
    ["a tool group", configWith({ familyTools: ["group:fs"] })],
    ["a plugin's tools by its id", configWith({ familyTools: ["pocket-piggies"] })],
    ["a name that is not a string", configWith({ familyTools: ["web_search", ["exec"]] })],
    ["no household section", { channels: {} }],
    ["no config", undefined],
  ]) {
    assert.deepEqual(familyToolPolicy(familyTurn(cfg)), NO_TOOLS, label);
  }
});

test("the manifest takes the list as plain tool names, at least one", () => {
  const manifest = JSON.parse(readFileSync(new URL("openclaw.plugin.json", PLUGIN), "utf8"));
  const familyTools = manifest.channelConfigs.household.schema.properties.familyTools;
  assert.equal(familyTools.type, "array");
  assert.equal(familyTools.minItems, 1);
  const name = new RegExp(familyTools.items.pattern);
  assert.ok(THE_FAMS_TOOLS.every((tool) => name.test(tool)));
  for (const refused of ["*", "web_*", "group:fs", "pocket-piggies", "", "Exec"]) {
    assert.equal(name.test(refused), false, refused);
  }
});

test("the channel restricts only the family room, through OpenClaw's group adapter", async () => {
  stubChannelSdk(fileURLToPath(new URL("index.js", PLUGIN)));
  const { householdChannel } = await import(new URL("index.js", PLUGIN));
  const cfg = configWith({ familyTools: THE_FAMS_TOOLS });

  assert.deepEqual(householdChannel.groups.resolveToolPolicy(familyTurn(cfg)), { allow: THE_FAMS_TOOLS });
  assert.deepEqual(householdChannel.groups.resolveToolPolicy(familyTurn(configWith({}))), NO_TOOLS);
  // OpenClaw asks the group adapter only for a session whose key names a group. The
  // owner's own thread is a direct session, and nothing else in the channel sets a tool
  // policy, so that thread keeps every tool.
  const policies = Object.keys(householdChannel).filter((key) => typeof householdChannel[key]?.resolveToolPolicy === "function");
  assert.deepEqual(policies, ["groups"]);
  assert.equal(householdChannel.messaging.inferTargetChatType({ to: "household:franco" }), "direct");
  const direct = householdChannel.messaging.resolveOutboundSessionRoute({ cfg, agentId: "main", accountId: "default", target: "franco" });
  assert.deepEqual([direct.peer, direct.chatType], [{ kind: "direct", id: "franco" }, "direct"]);
  assert.equal(householdChannel.messaging.inferTargetChatType({ to: "household:family" }), "group");
});
