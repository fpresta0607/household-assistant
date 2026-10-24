import test from "node:test";
import assert from "node:assert/strict";
import { createFamilyPosts, familyConversationRef, appFamilyConversationRef, householdRoutingGuidance } from "../../deploy/openclaw/plugins/household-app/family-posts.js";
const group = "-5100000001";
const config = { channels: { household: { owner: { id: "franco" } } }, plugins: { entries: { "household-family-room": { enabled: false, config: { groupChatId: group } } } } };
const route = (toolName, params, context = {}) => createFamilyPosts({ config: () => config }).beforeToolCall({ toolName, params }, context);

test("legacy family sends use only the household channel, even with Telegram disabled", async () => {
  for (const target of [group, `telegram:${group}`, `tg:group:${group}`]) {
    const result = await route("message", { action: "send", channel: "telegram", target, message: "@Denise, family update", replyTo: "legacy-id" });
    assert.equal(result.params.channel, "household");
    assert.equal(result.params.target, "family");
    assert.equal(result.params.message, "@Denise, family update");
    assert.equal(result.params.replyTo, undefined);
  }
});
test("legacy conversations resolve to the registered app family identity", async () => {
  const result = await route("conversations_send", { conversationRef: familyConversationRef(group), message: "Family update" });
  assert.equal(result.params.conversationRef, appFamilyConversationRef());
  assert.equal(result.params.message, "Family update");
});
test("Fam aliases resolve to the family room without changing private targets", async () => {
  for (const target of ["The Fam", "fam", "household:family"]) {
    assert.equal((await route("message", { action: "send", target, message: "Hello" })).params.target, "family");
  }
  assert.equal(await route("message", { action: "send", channel: "household", target: "franco", message: "Private" }), undefined);
});
test("unknown Telegram targets and mixed broadcasts fail without rerouting private text", async () => {
  for (const params of [
    { action: "send", channel: "telegram", target: "123" },
    { action: "send", target: "telegram:123" },
    { action: "broadcast", channel: "telegram", targets: [group, "123"] },
    { action: "react", channel: "telegram", target: group },
  ]) assert.equal((await route("message", params)).block, true);
});
test("legacy implicit-channel sends and a family-only broadcast are migrated", async () => {
  assert.equal((await route("message", { action: "send", target: group, message: "Hello" })).params.channel, "household");
  assert.equal((await route("message", { action: "send", target: group, message: "Hello" }, { sessionKey: "agent:main:telegram:direct:123" })).params.channel, "household");
  assert.equal((await route("message", { action: "send", channel: "telegram", target: "The Fam", message: "Hello" })).params.target, "family");
  assert.deepEqual((await route("message", { action: "broadcast", channel: "telegram", targets: [group], message: "Hello" })).params.targets, ["family"]);
});
test("migration preserves owner checks and rejects an alternate account", async () => {
  assert.equal((await route("message", { action: "send", target: group }, { requester: { senderIsOwner: false } })).block, true);
  assert.equal((await route("conversations_send", { conversationRef: familyConversationRef(group) }, { requester: { senderIsOwner: false } })).block, true);
  assert.equal((await route("message", { action: "send", channel: "telegram", target: group, accountId: "other" })).block, true);
});
test("every agent turn learns the app family destination and privacy boundary", () => {
  const guidance = householdRoutingGuidance(config);
  assert.match(guidance, /Telegram is retired/);
  assert.match(guidance, /channel=household, target=family/);
  assert.match(guidance, /target=franco/);
  assert.match(guidance, /To coordinate with the other assistant, use household_note with action=hand/);
  assert.match(guidance, /without a family-room message/);
  assert.match(guidance, /Keep family logs and facts in household_note, not a private tracker/);
  assert.match(guidance, /Never copy private information/);
});
