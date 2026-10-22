// The assistants' cards, from deploy/openclaw/plugins/household-app: a checklist tick in
// the app, kept for the assistant's next turn, and the Ordered tap on the household cart.
//
// Run with `node --test tests/js/household_app_cards.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { createCardTick, createCartOrdered, refuseDashboardInApp } from "../../deploy/openclaw/plugins/household-app/cards.js";
import { createCart } from "../../deploy/openclaw/plugins/household-app/cart.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";

const AT = Date.UTC(2026, 9, 14, 23, 0);

const block = (card) => "```steward-card\n" + JSON.stringify(card) + "\n```";

const SESSION_KEYS = { family: "agent:main:household:group:family", direct: "agent:main:household:direct:franco" };

const BEFORE_THE_TRIP = block({
  type: "checklist",
  id: "before-trip",
  title: "Before the trip",
  items: [
    { text: "Sign the permission slip", done: true },
    { text: "Pack lunch", done: false },
    { text: "Fill the water bottle", done: false },
  ],
});

async function setup({ enqueued = true } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-cards-"));
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const say = (id, author, conversation, text) =>
    store.addMessage({ id, conversation, author, at: AT, text, media: [], replyTo: null, origin: "local" });
  say("a-checklist-1", "corey", "family", `Here is what is left.\n\n${BEFORE_THE_TRIP}`);
  say("a-denise-1", "denise", "family", BEFORE_THE_TRIP);
  say("m-person-1", "franco", "family", BEFORE_THE_TRIP);
  say("a-direct-1", "corey", "direct", block({ type: "checklist", id: "groceries", items: [{ text: "Milk", done: false }] }));
  const notes = [];
  const tick = createCardTick({
    store,
    ownerName: "Franco",
    assistantIds: ["corey", "denise"],
    sessionKeys: SESSION_KEYS,
    enqueue: async (injection) => {
      notes.push(injection);
      return { enqueued, id: `note-${notes.length}`, sessionKey: injection.sessionKey };
    },
  });
  return { tick, notes };
}

test("a tick is kept for the assistant's next turn in that conversation", async () => {
  const { tick, notes } = await setup();
  const result = await tick({ conversation: "family", messageId: "a-checklist-1", cardId: "before-trip", item: 1, done: true });
  assert.deepEqual(result, { kept: true });
  assert.deepEqual(notes, [
    {
      sessionKey: SESSION_KEYS.family,
      text: 'Franco ticked "Pack lunch" on the checklist "Before the trip" (id before-trip) in the app.',
    },
  ]);
});

test("taking a tick back is kept too, and a list with no title is named by its id", async () => {
  const { tick, notes } = await setup();
  await tick({ conversation: "family", messageId: "a-checklist-1", cardId: "before-trip", item: 0, done: false });
  await tick({ conversation: "direct", messageId: "a-direct-1", cardId: "groceries", item: 0, done: true });
  assert.deepEqual(notes, [
    {
      sessionKey: SESSION_KEYS.family,
      text: 'Franco unticked "Sign the permission slip" on the checklist "Before the trip" (id before-trip) in the app.',
    },
    { sessionKey: SESSION_KEYS.direct, text: 'Franco ticked "Milk" on the checklist groceries in the app.' },
  ]);
});

test("the other assistant's list in the family room can be ticked", async () => {
  const { tick, notes } = await setup();
  await tick({ conversation: "family", messageId: "a-denise-1", cardId: "before-trip", item: 2, done: true });
  assert.equal(notes.length, 1);
  assert.match(notes[0].text, /"Fill the water bottle"/);
});

test("a tick OpenClaw did not keep says so", async () => {
  const { tick } = await setup({ enqueued: false });
  const result = await tick({ conversation: "family", messageId: "a-checklist-1", cardId: "before-trip", item: 1, done: true });
  assert.deepEqual(result, { kept: false });
});

const GOOD_TICK = { conversation: "family", messageId: "a-checklist-1", cardId: "before-trip", item: 1, done: true };

const REFUSED_TICKS = [
  ["an unknown conversation", { conversation: "elsewhere" }],
  ["an unknown message", { messageId: "a-missing-1" }],
  ["a message id that is not a string", { messageId: 7 }],
  ["a person's message", { messageId: "m-person-1" }],
  ["a message from the other conversation", { conversation: "direct" }],
  ["a checklist the message does not hold", { cardId: "after-trip" }],
  ["a checklist id that is not a string", { cardId: 3 }],
  ["a checklist id that is too long", { cardId: "x".repeat(81) }],
  ["an item past the end of the list", { item: 3 }],
  ["an item before the start of the list", { item: -1 }],
  ["an item that is not a whole number", { item: 1.5 }],
  ["done that is not true or false", { done: "yes" }],
];

for (const [what, change] of REFUSED_TICKS) {
  test(`${what} is refused and nothing is kept`, async () => {
    const { tick, notes } = await setup();
    await assert.rejects(() => tick({ ...GOOD_TICK, ...change }), { code: "INVALID_REQUEST" });
    assert.deepEqual(notes, []);
  });
}

// MARK: - The Ordered tap on the household cart

async function cartSetup() {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-cart-tap-"));
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const cart = createCart({
    file: path.join(directory, "cart.sqlite"),
    assistant: { id: "corey", name: "Corey" },
    peerAssistant: { id: "denise", name: "Denise" },
    people: [{ id: "franco", name: "Franco" }, { id: "gia", name: "Gia" }],
    now: () => AT,
  });
  const towels = cart.add({ name: "Paper towels", url: "https://www.amazon.com/dp/B07XYZ1234", forPerson: "gia" });
  const soap = cart.add({ name: "Dish soap", url: "https://www.amazon.com/dp/B08ABC5678", forPerson: "franco" });
  const shown = block(cart.card());
  const say = (id, author, conversation, text) =>
    store.addMessage({ id, conversation, author, at: AT, text, media: [], replyTo: null, origin: "local" });
  say("a-cart-1", "denise", "family", `The cart now.\n\n${shown}`);
  say("a-cart-2", "corey", "direct", shown);
  say("m-person-2", "gia", "family", shown);
  say("a-plain-1", "corey", "family", "No card here.");
  const replies = [];
  const ordered = createCartOrdered({
    store,
    cart,
    assistantIds: ["corey", "denise"],
    reply: async (message) => {
      replies.push(message);
      return { id: `a-reply-${replies.length}` };
    },
  });
  const cardsIn = (text) => [...text.matchAll(/```steward-card\n(.*)\n```/g)].map((found) => JSON.parse(found[1]));
  return { ordered, cart, replies, cardsIn, towels, soap };
}

test("Ordered in the family room empties the cart there and puts the order in the owner's own thread", async () => {
  const { ordered, cart, replies, cardsIn } = await cartSetup();
  assert.deepEqual(await ordered({ conversation: "family", messageId: "a-cart-1" }), { ordered: 2 });
  assert.deepEqual(cart.card().items, []);
  assert.deepEqual(replies.map((reply) => reply.conversation), ["family", "direct"]);
  const [roomCard] = cardsIn(replies[0].text);
  assert.deepEqual([roomCard.type, roomCard.id, roomCard.items], ["cart", "household", []]);
  const [orderCard] = cardsIn(replies[1].text);
  assert.deepEqual([orderCard.type, orderCard.items, orderCard.status, orderCard.order], ["order", 2, "ordered", undefined]);
  assert.match(replies[0].text, /^Marked 2 items ordered\./);
});

test("Ordered in the owner's own thread answers there once, with the order and the cart", async () => {
  const { ordered, replies, cardsIn } = await cartSetup();
  assert.deepEqual(await ordered({ conversation: "direct", messageId: "a-cart-2" }), { ordered: 2 });
  assert.equal(replies.length, 1);
  assert.equal(replies[0].conversation, "direct");
  assert.deepEqual(cardsIn(replies[0].text).map((card) => card.type), ["order", "cart"]);
});

test("Ordered marks only what the card showed and is still in the cart", async () => {
  const { ordered, cart, towels } = await cartSetup();
  cart.remove(towels.id);
  const later = cart.add({ name: "Candles", forPerson: "franco" });
  assert.deepEqual(await ordered({ conversation: "family", messageId: "a-cart-1" }), { ordered: 1 });
  assert.deepEqual(cart.card().items.map((item) => item.id), [later.id]);
});

for (const [why, params] of [
  ["the conversation is unknown", { conversation: "elsewhere", messageId: "a-cart-1" }],
  ["the message is in another conversation", { conversation: "direct", messageId: "a-cart-1" }],
  ["the message does not exist", { conversation: "family", messageId: "a-missing-1" }],
  ["a person wrote the card", { conversation: "family", messageId: "m-person-2" }],
  ["the message has no cart", { conversation: "family", messageId: "a-plain-1" }],
]) {
  test(`Ordered is refused when ${why}`, async () => {
    const { ordered, cart, replies } = await cartSetup();
    await assert.rejects(ordered(params), { code: "INVALID_REQUEST" });
    assert.equal(cart.card().items.length, 2);
    assert.deepEqual(replies, []);
  });
}

test("Ordered twice on the same card is refused the second time, with nothing said", async () => {
  const { ordered, replies } = await cartSetup();
  await ordered({ conversation: "family", messageId: "a-cart-1" });
  await assert.rejects(ordered({ conversation: "family", messageId: "a-cart-1" }), { code: "INVALID_REQUEST" });
  assert.equal(replies.length, 2);
});

test("a dashboard widget is refused in an app turn, with what to send instead, and left alone elsewhere", () => {
  for (const sessionKey of ["agent:main:household:direct:franco", "agent:main:household:group:family"]) {
    const refused = refuseDashboardInApp({ sessionKey });
    assert.equal(refused.block, true);
    assert.match(refused.blockReason, /steward-card chart block/);
  }
  for (const context of [{ sessionKey: "agent:main:main" }, { sessionKey: "agent:main:telegram:direct:7000000001" }, {}, undefined]) {
    assert.equal(refuseDashboardInApp(context), undefined);
  }
});
