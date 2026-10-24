import test from "node:test";
import assert from "node:assert/strict";
import { FAMILY_POST_TOOLS, createFamilyPosts, householdRoutingGuidance } from "../../deploy/openclaw/plugins/household-app/family-posts.js";
const config = { channels: { household: { owner: { id: "franco" } } } };
const route = (toolName, params, context = {}) => createFamilyPosts().beforeToolCall({ toolName, params }, context);

test("only the message tool is watched", () => {
  assert.deepEqual(FAMILY_POST_TOOLS, ["message"]);
  assert.equal(route("conversations_send", { conversationRef: "conv_x", message: "Hello" }), undefined);
});
test("Fam aliases resolve to the family room without changing private targets", () => {
  for (const target of ["The Fam", "fam", "household:family"]) {
    const result = route("message", { action: "send", target, message: "Hello", replyTo: "old-id" });
    assert.equal(result.params.channel, "household");
    assert.equal(result.params.target, "family");
    assert.equal(result.params.message, "Hello");
    assert.equal(result.params.replyTo, undefined);
  }
  assert.equal(route("message", { action: "send", channel: "household", target: "franco", message: "Private" }), undefined);
  assert.equal(route("message", { action: "read", channel: "household", target: "family" }), undefined);
});
test("a family-only broadcast is sent to the family room once", () => {
  assert.deepEqual(route("message", { action: "broadcast", targets: ["fam", "household:family"], message: "Hello" }).params.targets, ["family"]);
  assert.equal(route("message", { action: "broadcast", targets: ["fam", "franco"], message: "Hello" }), undefined);
});
test("anything addressed to Telegram is refused, with where to post instead", () => {
  for (const params of [
    { action: "send", channel: "telegram", target: "123" },
    { action: "send", channel: "tg", target: "The Fam" },
    { action: "send", target: "telegram:123" },
    { action: "broadcast", targets: ["family", "tg:group:-5100000001"] },
    { action: "react", channel: "telegram", target: "-5100000001" },
  ]) {
    const result = route("message", params);
    assert.equal(result.block, true, JSON.stringify(params));
    assert.match(result.blockReason, /channel=household, target=family/);
  }
});
test("a family post on another account is refused", () => {
  assert.equal(route("message", { action: "send", target: "family", accountId: "other" }).block, true);
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
  assert.equal(householdRoutingGuidance({}), "");
});
