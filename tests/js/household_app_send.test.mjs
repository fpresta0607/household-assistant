// One-tap "send it", from deploy/openclaw/plugins/household-app: a draft, an email, a booking
// request or the cart's order, waits as a card with where it goes and every word of it, or
// every item and the total; only the owner's allow-once on that card sends it, once; a
// changed draft needs a new tap; and a command's own Gmail send is refused. The send target
// is a stand-in that records what it was given, so nothing reaches anyone.
//
// Run with `node --test tests/js/household_app_send.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { approvalNativeRuntime, createApprovals } from "../../deploy/openclaw/plugins/household-app/approvals.js";
import { createCart } from "../../deploy/openclaw/plugins/household-app/cart.js";
import { SEND_TOOL, createSendTool, createSends, draftOf, refuseDirectSend } from "../../deploy/openclaw/plugins/household-app/send-tool.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";
import { runningChannel } from "./fixtures/household-app-channel.mjs";

const FRANCO = { id: "franco", name: "Franco" };
const GIA = { id: "gia", name: "Gia" };
const OWNERS_THREAD = "agent:main:household:direct:franco";
const OWNERS_FAMILY = "agent:main:household:group:family:sender:franco";
const ROOT = mkdtempSync(path.join(os.tmpdir(), "household-send-"));
const opened = [];
after(() => {
  for (const each of opened) each.close();
  rmSync(ROOT, { recursive: true, force: true });
});

function cartWith(...names) {
  const cart = createCart({
    file: path.join(mkdtempSync(path.join(ROOT, "cart-")), "cart.sqlite"),
    assistant: { id: "corey", name: "Corey" },
    peerAssistant: { id: "denise", name: "Denise" },
    people: [FRANCO, GIA],
  });
  opened.push(cart);
  for (const name of names) cart.add({ name, quantity: name === "Milk" ? 2 : 1, forPerson: "franco" });
  return cart;
}

// A stand-in send target: every draft it was handed, and nothing sent anywhere.
function standIn() {
  const sent = [];
  return { sent, deliver: async (draft) => (sent.push(draft), { sent: true, kind: draft.kind }) };
}

const EMAIL = { kind: "email", to: "dentist@example.com", subject: "Moving Thursday's cleaning", body: `Hello,\n\n${"Could we move Thursday's cleaning to Friday morning? ".repeat(12)}\n\nThanks` };

test("an email draft is where it goes and every word of it, the same each time", () => {
  // Act
  const draft = draftOf(EMAIL, { cart: cartWith() });

  // Assert
  assert.equal(draft.text, `To: dentist@example.com\nSubject: Moving Thursday's cleaning\n\n${EMAIL.body}`);
  assert.equal(draft.hash, draftOf({ ...EMAIL }, { cart: cartWith() }).hash);
  assert.notEqual(draft.hash, draftOf({ ...EMAIL, body: `${EMAIL.body}!` }, { cart: cartWith() }).hash, "a changed word is a changed draft");
});

for (const [why, params, code] of [
  ["no address", { ...EMAIL, to: "the dentist" }, "invalid_draft"],
  ["two addresses", { ...EMAIL, to: "a@example.com, b@example.com" }, "invalid_draft"],
  ["no words", { ...EMAIL, body: "  " }, "invalid_draft"],
  ["a kind it does not send", { ...EMAIL, kind: "text" }, "invalid_draft"],
]) {
  test(`a draft with ${why} is refused`, () => {
    assert.throws(() => draftOf(params, { cart: cartWith() }), (error) => error.code === code);
  });
}

test("an order is every cart item with its price, and the total the owner sees before the tap", () => {
  // Arrange
  const cart = cartWith("Milk", "Paper towels");
  const [milk, towels] = cart.card().items;

  // Act
  const draft = draftOf({ kind: "order", prices: [{ item: milk.id, price: 3.49 }, { item: towels.id, price: 21.99 }] }, { cart });

  // Assert
  assert.equal(draft.total, "$28.97");
  assert.deepEqual(draft.items, [{ name: "Milk", quantity: 2, price: "$3.49" }, { name: "Paper towels", quantity: 1, price: "$21.99" }]);
  assert.equal(draft.text, "2 × Milk, $3.49 each\n1 × Paper towels, $21.99 each\nTotal: $28.97");
  assert.throws(() => draftOf({ kind: "order", prices: [{ item: milk.id, price: 3.49 }] }, { cart }), (error) => error.code === "unpriced");
  assert.throws(() => draftOf({ kind: "order", prices: [] }, { cart: cartWith() }), (error) => error.code === "empty_cart");
});

test("a draft in the owner's own turn waits for a yes that covers it alone; anywhere else it is refused", () => {
  // Arrange
  const sends = createSends({ cart: cartWith(), canEmail: true, ...standIn() });
  const ownerSessions = [OWNERS_THREAD, OWNERS_FAMILY];

  // Act
  const asked = sends.ask({ toolName: SEND_TOOL, toolCallId: "call-1", params: EMAIL }, { sessionKey: OWNERS_THREAD }, { ownerSessions });
  const inTheRoom = sends.ask({ toolName: SEND_TOOL, toolCallId: "call-2", params: EMAIL }, { sessionKey: "agent:main:household:group:family" }, { ownerSessions });
  const bad = sends.ask({ toolName: SEND_TOOL, toolCallId: "call-3", params: { ...EMAIL, to: "nobody" } }, { sessionKey: OWNERS_THREAD }, { ownerSessions });

  // Assert
  assert.equal(asked.requireApproval.title, "Send: Moving Thursday's cleaning");
  assert.deepEqual(asked.requireApproval.allowedDecisions, ["allow-once", "deny"]);
  assert.equal(asked.requireApproval.timeoutMs, 600_000);
  assert.deepEqual(asked.requireApproval.scope, { kind: "message-send", target: "email", recipientCount: 1, recipients: ["dentist@example.com"], audience: "external" });
  assert.equal(asked.requireApproval.description.length, 512, "OpenClaw keeps a few lines; the card keeps the whole draft");
  assert.equal(sends.draftFor("call-1").text.length > 512, true);
  assert.equal(inTheRoom.block, true);
  assert.equal(bad.block, true);
  assert.match(bad.blockReason, /email address/);
});

test("an order asks as a payment with its total", () => {
  // Arrange
  const cart = cartWith("Milk");
  const sends = createSends({ cart, canEmail: false, ...standIn() });
  const prices = [{ item: cart.card().items[0].id, price: 3.49 }];

  // Act
  const asked = sends.ask({ toolCallId: "call-1", params: { kind: "order", prices } }, { sessionKey: OWNERS_THREAD }, { ownerSessions: [OWNERS_THREAD] });
  const email = sends.ask({ toolCallId: "call-2", params: EMAIL }, { sessionKey: OWNERS_THREAD }, { ownerSessions: [OWNERS_THREAD] });

  // Assert
  assert.equal(asked.requireApproval.title, "Order 1 item, $6.98");
  assert.deepEqual(asked.requireApproval.scope, { kind: "payment", amount: "6.98", currency: "USD", target: "Amazon" });
  assert.equal(asked.requireApproval.severity, "critical");
  assert.equal(email.block, true, "a gateway with no Gmail to send from asks for no email");
});

test("only an allow-once sends, exactly the draft the card showed, once; a denial or a changed draft sends nothing", async () => {
  // Arrange
  const target = standIn();
  const sends = createSends({ cart: cartWith(), canEmail: true, ...target });
  const ask = (toolCallId, params) => sends.ask({ toolCallId, params }, { sessionKey: OWNERS_THREAD }, { ownerSessions: [OWNERS_THREAD] }).requireApproval;
  const refusal = async (toolCallId, params) => {
    try {
      await sends.send(toolCallId, params);
      return null;
    } catch (error) {
      return error.code;
    }
  };

  // Act
  const unanswered = await refusal(ask("call-1", EMAIL) && "call-1", EMAIL);
  ask("call-2", EMAIL).onResolution("deny");
  const denied = await refusal("call-2", EMAIL);
  ask("call-3", EMAIL).onResolution("allow-once");
  const changed = await refusal("call-3", { ...EMAIL, to: "someone@example.com" });
  ask("call-4", EMAIL).onResolution("allow-once");
  const answer = await sends.send("call-4", EMAIL);
  const again = await refusal("call-4", EMAIL);

  // Assert
  assert.deepEqual([unanswered, denied, changed, again], ["not_approved", "not_approved", "changed", "not_approved"]);
  assert.deepEqual(answer, { sent: true, kind: "email" });
  assert.equal(target.sent.length, 1);
  assert.equal(target.sent[0].body, EMAIL.body);
  assert.equal(target.sent[0].to, "dentist@example.com");
});

for (const command of [
  "gog gmail send --to a@example.com --subject Hi --body Hello",
  "gog --account franco@example.com gmail drafts send r-123",
  "cd /tmp && /usr/local/bin/gog mail send --to a@example.com",
  "gog-bin -a franco@example.com email send --to a@example.com",
  "GOG_HOME=/tmp/g gog gmail send --to a@example.com",
  "sh -c 'gog gmail send --to a@example.com --body hi'",
]) {
  test(`a command's own Gmail send is refused: ${command.slice(0, 40)}`, () => {
    const refused = refuseDirectSend({ toolName: "exec", params: { command } });
    assert.equal(refused?.block, true);
    assert.match(refused.blockReason, /household_send/);
  });
}

test("reading mail and making a draft are left alone", () => {
  for (const command of ["gog gmail search 'from:school' --json", "gog gmail drafts create --to a@example.com --subject Hi --body Hello", "echo gog gmail send"]) {
    assert.equal(refuseDirectSend({ toolName: "exec", params: { command } }), undefined, command);
  }
});

test("the card in the owner's thread carries the whole draft, where it goes and what it is", async () => {
  // Arrange
  const sends = createSends({ cart: cartWith(), canEmail: true, ...standIn() });
  const asked = sends.ask({ toolCallId: "call-7", params: EMAIL }, { sessionKey: OWNERS_THREAD }, { ownerSessions: [OWNERS_THREAD] }).requireApproval;
  const store = openRoomStore(path.join(await mkdtemp(path.join(ROOT, "room-")), "room.sqlite"));
  opened.push(store);
  const announced = [];
  const approvals = createApprovals({
    store,
    assistant: { id: "corey" },
    sessionKeys: { direct: OWNERS_THREAD },
    announce: async (entry) => announced.push(entry),
    ownerKeys: async () => [],
    isSignedBy: () => false,
    resolve: async () => {},
    draftFor: (toolCallId) => sends.draftFor(toolCallId),
  });
  const request = {
    id: "plugin:0b1c2d3e-0000-4000-8000-000000000007",
    request: { title: asked.title, description: asked.description, toolName: SEND_TOOL, toolCallId: "call-7", sessionKey: OWNERS_THREAD, turnSourceChannel: "household" },
  };
  const view = { approvalKind: "plugin", title: asked.title, description: asked.description, actions: [{ decision: "allow-once" }, { decision: "deny" }] };

  // Act
  const card = approvalNativeRuntime.presentation.buildPendingPayload({ request, approvalKind: "plugin", view });
  await approvalNativeRuntime.transport.deliverPending({ context: { approvals }, request, approvalKind: "plugin", view, pendingPayload: card });

  // Assert
  const [entry] = announced;
  assert.equal(entry.conversation, "direct");
  assert.equal(entry.approval.detail, sends.draftFor("call-7").text, "every word, not OpenClaw's few lines");
  assert.deepEqual(entry.approval.send, { kind: "email", to: "dentist@example.com", subject: "Moving Thursday's cleaning" });
  assert.deepEqual(entry.approval.decisions, ["allow-once", "deny"]);
});

test("the tool is offered only in the owner's own turns, and says when there is no Gmail to send from", () => {
  // Arrange
  const sends = createSends({ cart: cartWith(), canEmail: false, ...standIn() });
  const context = (sessionKey, sender, to) => ({
    agentId: "main",
    agentAccountId: "default",
    messageChannel: "household",
    deliveryContext: { channel: "household", accountId: "default", to },
    requesterSenderId: sender,
    sessionKey,
  });
  const offer = (each) => createSendTool({ context: each, owner: "franco", people: ["franco", "gia"], sends, canEmail: false });

  // Act and Assert
  const own = offer(context(OWNERS_THREAD, "franco", "household:franco"));
  assert.equal(own.name, SEND_TOOL);
  assert.deepEqual(own.parameters.properties.kind.enum, ["order"]);
  assert.match(own.description, /no Gmail to send from/);
  assert.equal(offer(context("agent:main:household:group:family", "gia", "household:family")), null, "the room's shared session");
  assert.equal(offer({ ...context(OWNERS_THREAD, "franco", "household:franco"), messageChannel: "telegram" }), null, "Telegram");
});

// Through the plugin's own entry: the tool, the yes it asks for, and the refusal of a
// command's send, as OpenClaw runs the plugin's hooks.
test("through the plugin, an order in the owner's thread waits for its tap, then hands over the checkout; a command's send is refused", async () => {
  // Arrange
  const channel = await runningChannel({
    channels: {
      household: {
        owner: { id: "franco", name: "Franco" },
        assistant: { id: "corey", name: "Corey" },
        peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
      },
    },
  });
  const OWNERS = {
    agentId: "main",
    agentAccountId: "default",
    messageChannel: "household",
    deliveryContext: { channel: "household", accountId: "default", to: "household:franco" },
    requesterSenderId: "franco",
    sessionKey: OWNERS_THREAD,
  };
  try {
    const cartTool = channel.tools.find(({ options }) => options.names.includes("household_cart")).factory(OWNERS);
    await cartTool.execute("call-0", { action: "add", name: "Milk", quantity: 2 });
    const [milk] = JSON.parse((await cartTool.execute("call-0b", { action: "view" })).content[0].text).cart.items;
    const tool = channel.tools.find(({ options }) => options.names.includes(SEND_TOOL)).factory(OWNERS);
    const params = { kind: "order", prices: [{ item: milk.id, price: 3.49 }] };

    // Act
    const before = JSON.parse((await tool.execute("call-1", params)).content[0].text);
    const asked = await channel.beforeToolCall({ toolName: SEND_TOOL, toolCallId: "call-1", params }, { sessionKey: OWNERS_THREAD });
    const early = JSON.parse((await tool.execute("call-1", params)).content[0].text);
    asked.requireApproval.onResolution("allow-once");
    const after = JSON.parse((await tool.execute("call-1", params)).content[0].text);
    const command = await channel.beforeToolCall({ toolName: "exec", params: { command: "gog gmail send --to a@example.com --subject x --body y" } }, { sessionKey: OWNERS_THREAD });

    // Assert
    assert.equal(before.code, "not_approved");
    assert.equal(asked.requireApproval.title, "Order 1 item, $6.98");
    assert.equal(early.code, "not_approved");
    assert.equal(after.sent, "checkout");
    assert.equal(after.total, "$6.98");
    assert.equal(command.block, true);
  } finally {
    await channel.stop();
  }
});
