// The household cart, from deploy/openclaw/plugins/household-app: one list both assistants
// add to, the Amazon link that fills the buyer's own cart, what crosses to the other
// gateway and what stays with the buyer, and the turns in which household_cart answers.
//
// Run with `node --test tests/js/household_app_cart.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { CART_TOOL, amazonProduct, checkoutLink, createCart } from "../../deploy/openclaw/plugins/household-app/cart.js";
import { createCartTool } from "../../deploy/openclaw/plugins/household-app/cart-tool.js";

const NOW = Date.UTC(2026, 9, 15, 21, 52);
const FRANCO = { id: "franco", name: "Franco" };
const GIA = { id: "gia", name: "Gia" };
const COREY = { id: "corey", name: "Corey" };
const DENISE = { id: "denise", name: "Denise" };
const TOWELS = "https://www.amazon.com/Bounty-Paper-Towels/dp/B07XYZ1234/ref=sr_1_3?keywords=bounty";
const SOAP = "https://www.amazon.com/gp/product/B08ABC5678";

// Every cart a test opens stays open until the run ends, when all are closed and their
// files removed together: Windows refuses to remove a database file that is still open.
const ROOT = mkdtempSync(path.join(os.tmpdir(), "household-cart-"));
const opened = [];
after(() => {
  for (const cart of opened) cart.close();
  rmSync(ROOT, { recursive: true, force: true });
});

function directory() {
  return mkdtempSync(path.join(ROOT, "gateway-"));
}

function openCart(settings) {
  const cart = createCart(settings);
  opened.push(cart);
  return cart;
}

let counter = 0;
const newId = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;

// Corey's gateway and Denise's, each with its own file, as on the box.
function gateways() {
  let clock = NOW;
  const changes = { corey: 0, denise: 0 };
  const open = (assistant, peerAssistant) => openCart({
    file: path.join(directory(), "cart.sqlite"),
    assistant,
    peerAssistant,
    people: [FRANCO, GIA],
    now: () => clock,
    newId,
    changed: () => {
      changes[assistant.id] += 1;
    },
  });
  const corey = open(COREY, DENISE);
  const denise = open(DENISE, COREY);
  return {
    corey,
    denise,
    changes,
    tick: (milliseconds = 1000) => {
      clock += milliseconds;
    },
    // What the other gateway reads from the share: the source's own outbox section, as its batch.
    relay: (from, to) => to.acceptPeer({ cart: from.outbox().cart }),
  };
}

// MARK: - Amazon links

test("a product link is reduced to its Amazon id, wherever the id sits in the path", () => {
  assert.deepEqual(amazonProduct(TOWELS), { asin: "B07XYZ1234", url: "https://www.amazon.com/dp/B07XYZ1234" });
  assert.deepEqual(amazonProduct(SOAP), { asin: "B08ABC5678", url: "https://www.amazon.com/dp/B08ABC5678" });
  assert.deepEqual(amazonProduct("https://amazon.com/dp/B000DEF901?th=1"), {
    asin: "B000DEF901",
    url: "https://www.amazon.com/dp/B000DEF901",
  });
  assert.deepEqual(amazonProduct("https://www.amazon.com/gp/aw/d/B000DEF901"), {
    asin: "B000DEF901",
    url: "https://www.amazon.com/dp/B000DEF901",
  });
});

for (const [why, link] of [
  ["another store", "https://www.target.com/p/towels/-/A-12345678"],
  ["a look-alike host", "https://www.amazon.com.evil.example/dp/B07XYZ1234"],
  ["another country's Amazon", "https://www.amazon.co.uk/dp/B07XYZ1234"],
  ["a short link that hides its product", "https://a.co/d/abc1234"],
  ["plain http", "http://www.amazon.com/dp/B07XYZ1234"],
  ["a search page", "https://www.amazon.com/s?k=paper+towels"],
  ["not a link", "paper towels"],
]) {
  test(`a link to ${why} is not an Amazon product`, () => {
    assert.equal(amazonProduct(link), null);
  });
}

test("checkout carries every item with an Amazon id and its quantity, numbered from one", () => {
  assert.equal(
    checkoutLink([
      { asin: "B07XYZ1234", quantity: 1 },
      { quantity: 1 },
      { asin: "B000DEF901", quantity: 2 },
    ]),
    "https://www.amazon.com/gp/aws/cart/add.html?ASIN.1=B07XYZ1234&Quantity.1=1&ASIN.2=B000DEF901&Quantity.2=2",
  );
  assert.equal(checkoutLink([{ quantity: 1 }]), null, "nothing to check out");
  assert.equal(checkoutLink([]), null);
});

// MARK: - One cart on both gateways

test("an item either assistant adds is in one cart on both gateways, with who added it for whom", () => {
  const { corey, denise, tick, relay } = gateways();
  corey.add({ name: "Coffee filters #4", url: SOAP, quantity: 2, forPerson: "franco" });
  tick();
  denise.add({ name: "Paper towels, 12 rolls", url: TOWELS, forPerson: "gia" });
  relay(corey, denise);
  relay(denise, corey);

  for (const cart of [corey, denise]) {
    assert.deepEqual(
      cart.card().items.map(({ name, quantity, by, for: forName, url }) => ({ name, quantity, by, for: forName, url })),
      [
        { name: "Coffee filters #4", quantity: 2, by: "Corey", for: "Franco", url: "https://www.amazon.com/dp/B08ABC5678" },
        { name: "Paper towels, 12 rolls", quantity: 1, by: "Denise", for: "Gia", url: "https://www.amazon.com/dp/B07XYZ1234" },
      ],
    );
  }
  assert.deepEqual(corey.card(), denise.card(), "the same card from either gateway");
});

test("the cart card has the agreed shape and the checkout link", () => {
  const { corey } = gateways();
  const towels = corey.add({ name: "Paper towels, 12 rolls", url: TOWELS, forPerson: "gia" });
  corey.add({ name: "Birthday candles", forPerson: "franco" });
  assert.match(towels.id, /^ci-[0-9a-f]{8}$/);
  assert.deepEqual(corey.card(), {
    type: "cart",
    id: "household",
    title: "Household cart",
    items: [
      { id: towels.id, name: "Paper towels, 12 rolls", quantity: 1, by: "Corey", for: "Gia", url: "https://www.amazon.com/dp/B07XYZ1234" },
      { id: corey.card().items[1].id, name: "Birthday candles", quantity: 1, by: "Corey", for: "Franco" },
    ],
    checkout: "https://www.amazon.com/gp/aws/cart/add.html?ASIN.1=B07XYZ1234&Quantity.1=1",
    skill: "lists",
  });
});

test("an empty cart has no checkout link", () => {
  const { corey } = gateways();
  assert.deepEqual(corey.card(), { type: "cart", id: "household", title: "Household cart", items: [], skill: "lists" });
});

test("removing or changing an item on one gateway changes it on the other", () => {
  const { corey, denise, tick, relay } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  const soap = corey.add({ name: "Dish soap", url: SOAP, forPerson: "franco" });
  relay(corey, denise);
  tick();
  denise.remove(towels.id);
  denise.setQuantity(soap.id, 3);
  relay(denise, corey);
  assert.deepEqual(corey.card().items.map(({ name, quantity }) => ({ name, quantity })), [{ name: "Dish soap", quantity: 3 }]);
  assert.deepEqual(corey.card(), denise.card());
});

test("the same batch arriving twice changes nothing the second time", () => {
  const { corey, denise, changes, relay } = gateways();
  corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  assert.deepEqual(relay(corey, denise), { accepted: 1, refused: 0 });
  const before = changes.denise;
  assert.deepEqual(relay(corey, denise), { accepted: 0, refused: 0 });
  assert.equal(changes.denise, before, "nothing new, nothing announced");
  assert.equal(denise.card().items.length, 1);
});

test("a gateway publishes only its own steps, and a peer's never echo back", () => {
  const { corey, denise, relay } = gateways();
  corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  relay(corey, denise);
  assert.deepEqual(denise.outbox().cart, []);
  assert.equal(corey.outbox().cart.length, 1);
});

test("the cart survives a restart", () => {
  const file = path.join(directory(), "cart.sqlite");
  const settings = { file, assistant: COREY, peerAssistant: DENISE, people: [FRANCO, GIA], now: () => NOW, newId };
  const first = createCart(settings);
  first.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  first.close();
  const again = createCart(settings);
  assert.equal(again.card().items[0].name, "Paper towels");
  assert.equal(again.outbox().cart.length, 1, "its own steps are still published");
  again.close();
});

// MARK: - What the other gateway may say

for (const [why, step] of [
  ["it claims to be this gateway's own assistant", { author: "denise" }],
  ["it names someone else entirely", { author: "mallory" }],
  ["its item is for a stranger", { item: { for: "mallory" } }],
  ["its item has no name", { item: { name: "" } }],
  ["its quantity is not a whole number", { item: { quantity: 1.5 } }],
  ["its quantity is too large", { item: { quantity: 1000 } }],
  ["its link is not an Amazon product", { item: { url: "https://evil.example/dp/B07XYZ1234" } }],
  ["its kind is unknown", { kind: "erase" }],
  ["its id is malformed", { id: "../../etc" }],
  ["its time is not a time", { at: "yesterday" }],
  ["its link is not the plain product link", { item: { url: "https://www.amazon.com/Towels/dp/B07XYZ1234/ref=sr_1" } }],
  ["its name hides invisible characters", { item: { name: "Paper\u202etowels" } }],
  ["it removes something that is not an item", { kind: "remove", item: "everything" }],
  ["it sets a quantity of zero", { kind: "quantity", item: "ci-0badc0de", quantity: 0 }],
  ["it claims a shipping step, which never crosses", { kind: "status", items: ["ci-0badc0de"], status: "shipped" }],
  ["it orders nothing", { kind: "status", items: [], status: "ordered" }],
]) {
  test(`a step from the other gateway is refused when ${why}`, () => {
    const base = {
      id: "co-00000000-0000-4000-8000-000000000999",
      at: NOW,
      author: "corey",
      kind: "add",
      item: { id: "ci-0badc0de", name: "Paper towels", quantity: 1, for: "franco", url: "https://www.amazon.com/dp/B07XYZ1234" },
    };
    const raw = { ...base, ...step, item: { ...base.item, ...step.item } };
    const denise = openCart({
      file: path.join(directory(), "cart.sqlite"),
      assistant: DENISE,
      peerAssistant: COREY,
      people: [FRANCO, GIA],
      now: () => NOW,
      newId,
    });
    assert.deepEqual(denise.acceptPeer({ cart: [raw] }), { accepted: 0, refused: 1 });
    assert.deepEqual(denise.card().items, []);
  });
}

test("a batch with more steps than any gateway could have taken is refused whole", () => {
  const { denise } = gateways();
  assert.deepEqual(denise.acceptPeer({ cart: Array.from({ length: 50_001 }, () => ({})) }), { accepted: 0, refused: 50_001 });
});

test("a gateway that lost its file gets all of the other's steps back with the next delivery", () => {
  const { corey, relay } = gateways();
  for (let round = 0; round < 7; round += 1) {
    for (let index = 0; index < 40; index += 1) corey.add({ name: `Item ${round}-${index}`, forPerson: "franco" });
    if (round < 6) corey.tapOrdered(corey.card().items.map((item) => item.id));
  }
  assert.ok(corey.outbox().cart.length > 250, "more steps than the old bound");
  const fresh = openCart({
    file: path.join(directory(), "cart.sqlite"),
    assistant: DENISE,
    peerAssistant: COREY,
    people: [FRANCO, GIA],
    now: () => NOW,
    newId,
  });
  relay(corey, fresh);
  assert.deepEqual(fresh.card(), corey.card());
});

test("a batch without a cart section is nothing to do", () => {
  const { denise } = gateways();
  assert.deepEqual(denise.acceptPeer({ entries: [] }), { accepted: 0, refused: 0 });
  assert.deepEqual(denise.acceptPeer(undefined), { accepted: 0, refused: 0 });
});

// MARK: - What this gateway refuses itself

test("an item needs a name, a sensible quantity and a person of the household", () => {
  const { corey } = gateways();
  assert.throws(() => corey.add({ name: "   ", forPerson: "franco" }), { code: "invalid_item" });
  assert.throws(() => corey.add({ name: "x".repeat(121), forPerson: "franco" }), { code: "invalid_item" });
  assert.throws(() => corey.add({ name: "Towels", quantity: 0, forPerson: "franco" }), { code: "invalid_item" });
  assert.throws(() => corey.add({ name: "Towels", quantity: 100, forPerson: "franco" }), { code: "invalid_item" });
  assert.throws(() => corey.add({ name: "Towels", forPerson: "mallory" }), { code: "invalid_item" });
  assert.throws(() => corey.add({ name: "Towels", url: "https://a.co/d/abc1234", forPerson: "franco" }), { code: "not_amazon" });
});

test("a name keeps its words and loses control and invisible characters and runs of spaces", () => {
  const { corey } = gateways();
  const item = corey.add({ name: "  Paper\u0000 towels\u200b\n\n 12   rolls\u202e ", forPerson: "franco" });
  assert.equal(item.name, "Paper towels 12 rolls");
});

test("the cart holds at most forty open items", () => {
  const { corey } = gateways();
  for (let index = 0; index < 40; index += 1) corey.add({ name: `Item ${index}`, forPerson: "franco" });
  assert.throws(() => corey.add({ name: "One more", forPerson: "franco" }), { code: "cart_full" });
});

test("an unknown item cannot be removed or changed", () => {
  const { corey } = gateways();
  assert.throws(() => corey.remove("ci-00000000"), { code: "unknown_item" });
  assert.throws(() => corey.setQuantity("ci-00000000", 2), { code: "unknown_item" });
});

// MARK: - Orders: the status crosses, the order stays with the buyer

const ORDER = "113-1234567-8904417";

test("an order takes its items out of the cart on both gateways, and only the buyer keeps its details", () => {
  const { corey, denise, tick, relay } = gateways();
  const towels = denise.add({ name: "Paper towels", url: TOWELS, forPerson: "gia" });
  const filters = corey.add({ name: "Coffee filters", url: SOAP, forPerson: "franco" });
  const candles = corey.add({ name: "Candles", forPerson: "franco" });
  relay(denise, corey);
  relay(corey, denise);
  tick();

  const card = corey.markOrder({
    order: ORDER,
    items: [towels.id, filters.id],
    status: "ordered",
    at: "2026-10-14T19:42:00-04:00",
    arriving: "2026-10-16",
  });
  assert.deepEqual(card, {
    type: "order",
    title: "Household order",
    items: 2,
    status: "ordered",
    arriving: "2026-10-16",
    order: "113-***-4417",
    steps: [
      { label: "Ordered", at: "2026-10-14T19:42:00-04:00" },
      { label: "Shipped" },
      { label: "Out for delivery" },
      { label: "Delivered" },
    ],
    skill: "lists",
  });
  relay(corey, denise);
  for (const cart of [corey, denise]) {
    assert.deepEqual(cart.card().items.map((item) => item.id), [candles.id], "ordered items leave the cart");
  }

  const crossed = JSON.stringify(corey.outbox());
  assert.doesNotMatch(crossed, /113-|4417|2026-10-16|19:42/, "no order number, date or time crosses");
  assert.throws(() => denise.markOrder({ order: ORDER, status: "shipped" }), { code: "unknown_order" }, "the other gateway has no such order");
});

test("later emails move the order along, and only ordered and delivered cross", () => {
  const { corey, denise, tick, relay } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  corey.markOrder({ order: ORDER, items: [towels.id], status: "ordered", at: "2026-10-14T19:42:00-04:00" });
  tick();
  const crossedAfterOrdered = corey.outbox().cart.length;

  const shipped = corey.markOrder({ order: ORDER, status: "shipped", at: "2026-10-15T06:10:00-04:00", arriving: "2026-10-16" });
  assert.equal(shipped.status, "shipped");
  assert.deepEqual(shipped.steps.slice(0, 2), [
    { label: "Ordered", at: "2026-10-14T19:42:00-04:00" },
    { label: "Shipped", at: "2026-10-15T06:10:00-04:00" },
  ]);
  corey.markOrder({ order: ORDER, status: "out_for_delivery", at: "2026-10-16T07:30:00-04:00" });
  assert.equal(corey.outbox().cart.length, crossedAfterOrdered, "shipping steps stay on this gateway");

  const delivered = corey.markOrder({ order: ORDER, status: "delivered", at: "2026-10-16T14:05:00-04:00" });
  assert.equal(delivered.status, "delivered");
  assert.equal(delivered.steps.every((step) => step.at), true);
  assert.equal(corey.outbox().cart.length, crossedAfterOrdered + 1, "delivered crosses");
  const last = corey.outbox().cart.at(-1);
  assert.deepEqual([last.kind, last.items, last.status], ["status", [towels.id], "delivered"]);
  assert.deepEqual(relay(corey, denise), { accepted: 3, refused: 0 }, "the other gateway takes all three");

  corey.markOrder({ order: ORDER, status: "delivered", at: "2026-10-16T14:05:00-04:00" });
  assert.equal(corey.outbox().cart.length, crossedAfterOrdered + 1, "a second delivered email crosses nothing more");
});

test("an item added to an order after it was delivered is delivered too", () => {
  const { corey } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  const soap = corey.add({ name: "Dish soap", url: SOAP, forPerson: "franco" });
  corey.markOrder({ order: ORDER, items: [towels.id], status: "delivered" });
  corey.markOrder({ order: ORDER, items: [soap.id], status: "delivered" });
  const last = corey.outbox().cart.at(-1);
  assert.deepEqual([last.items, last.status], [[soap.id], "delivered"]);
  assert.equal(corey.markOrder({ order: ORDER, status: "delivered" }).items, 2);
});

test("an order names each item once, however often it is listed", () => {
  const { corey } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  const card = corey.markOrder({ order: ORDER, items: [towels.id, towels.id], status: "ordered" });
  assert.equal(card.items, 1);
  assert.deepEqual(corey.outbox().cart.at(-1).items, [towels.id]);
});

test("an order larger than the cart can be delivered and the other gateway takes it", () => {
  const { corey, denise, relay } = gateways();
  for (let round = 0; round < 2; round += 1) {
    const batch = [];
    for (let index = 0; index < 30; index += 1) batch.push(corey.add({ name: `Item ${round}-${index}`, forPerson: "franco" }).id);
    corey.markOrder({ order: ORDER, items: batch, status: "ordered" });
  }
  corey.markOrder({ order: ORDER, status: "delivered" });
  assert.equal(corey.outbox().cart.at(-1).items.length, 60);
  assert.equal(relay(corey, denise).refused, 0);
});

test("a step is never timed before one already kept, even when the clock steps back", () => {
  let clock = NOW;
  const corey = openCart({
    file: path.join(directory(), "cart.sqlite"),
    assistant: COREY,
    peerAssistant: DENISE,
    people: [FRANCO, GIA],
    now: () => clock,
    newId,
  });
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  clock -= 60_000;
  corey.setQuantity(towels.id, 4);
  assert.equal(corey.card().items[0].quantity, 4);
  const [add, quantity] = corey.outbox().cart;
  assert.ok(quantity.at > add.at);
});

// MARK: - The Ordered tap

test("tapping Ordered takes the card's open items out of the cart on both gateways, as an order with no number", () => {
  const { corey, denise, relay } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  const soap = corey.add({ name: "Dish soap", url: SOAP, forPerson: "franco" });
  const later = corey.add({ name: "Candles", forPerson: "franco" });
  const { count, order } = corey.tapOrdered([towels.id, soap.id, soap.id, "ci-00000000"]);
  assert.equal(count, 2);
  assert.deepEqual(order, {
    type: "order",
    title: "Household order",
    items: 2,
    status: "ordered",
    steps: [{ label: "Ordered", at: new Date(NOW).toISOString() }, { label: "Shipped" }, { label: "Out for delivery" }, { label: "Delivered" }],
    skill: "lists",
  });
  relay(corey, denise);
  assert.deepEqual(denise.card().items.map((item) => item.id), [later.id]);
});

test("tapping Ordered when everything on the card is gone changes nothing", () => {
  const { corey } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  corey.tapOrdered([towels.id]);
  const steps = corey.outbox().cart.length;
  assert.throws(() => corey.tapOrdered([towels.id]), { code: "nothing_open" });
  assert.throws(() => corey.tapOrdered("everything"), { code: "nothing_open" });
  assert.equal(corey.outbox().cart.length, steps);
});

test("an order that only ever showed up as shipped still counts its items as ordered", () => {
  const { corey } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  const card = corey.markOrder({ order: ORDER, items: [towels.id], status: "shipped", at: "2026-10-15T06:10:00-04:00" });
  assert.deepEqual(card.steps.slice(0, 2), [{ label: "Ordered" }, { label: "Shipped", at: "2026-10-15T06:10:00-04:00" }]);
  assert.deepEqual(corey.card().items, []);
});

test("an order is refused when its number, items, status, time or date are wrong", () => {
  const { corey } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "franco" });
  const good = { order: ORDER, items: [towels.id], status: "ordered", at: "2026-10-14T19:42:00-04:00" };
  assert.throws(() => corey.markOrder({ ...good, order: "1131234567" }), { code: "invalid_order" });
  assert.throws(() => corey.markOrder({ ...good, items: [] }), { code: "invalid_order" });
  assert.throws(() => corey.markOrder({ ...good, items: ["ci-00000000"] }), { code: "unknown_item" });
  assert.throws(() => corey.markOrder({ ...good, status: "lost" }), { code: "invalid_order" });
  assert.throws(() => corey.markOrder({ ...good, at: "last Tuesday" }), { code: "invalid_order" });
  assert.throws(() => corey.markOrder({ ...good, arriving: "Thursday" }), { code: "invalid_order" });
  assert.throws(() => corey.markOrder({ ...good, arriving: "2026-02-30" }), { code: "invalid_order" });
  assert.throws(() => corey.markOrder({ order: ORDER, status: "shipped" }), { code: "unknown_order" }, "a new order names its items");
});

// MARK: - Orders from the buyer's own Amazon mail

const MAILED = { order: ORDER, status: "ordered", at: "2026-10-14T19:42:00-04:00", arriving: "2026-10-16" };

test("an order email takes the open items it links to out of the cart, on both gateways", () => {
  const { corey, denise, relay } = gateways();
  corey.add({ name: "Paper towels", url: TOWELS, forPerson: "gia" });
  corey.add({ name: "Candles", forPerson: "gia" });
  corey.add({ name: "Dish soap", url: SOAP, forPerson: "gia" });
  const { card, isAdvance } = corey.mailOrder({ ...MAILED, asins: ["B07XYZ1234", "B0NOTINCART"] });
  assert.equal(isAdvance, true);
  assert.deepEqual([card.items, card.status, card.order, card.arriving], [1, "ordered", "113-***-4417", "2026-10-16"]);
  relay(corey, denise);
  for (const cart of [corey, denise]) {
    assert.deepEqual(cart.card().items.map((item) => item.name), ["Candles", "Dish soap"]);
  }
});

test("an order email that links to nothing in the cart is not the household's and changes nothing", () => {
  const { corey } = gateways();
  corey.add({ name: "Paper towels", url: TOWELS, forPerson: "gia" });
  const steps = corey.outbox().cart.length;
  assert.equal(corey.mailOrder({ ...MAILED, asins: ["B0NOTINCART"] }), null);
  assert.equal(corey.mailOrder({ ...MAILED, asins: [] }), null);
  assert.equal(corey.outbox().cart.length, steps);
  assert.equal(corey.mailOrder({ ...MAILED, status: "shipped", asins: [] }), null, "nor does a later email of it");
});

test("later emails of the order move it along, and only a step beyond where it stands is an advance", () => {
  const { corey } = gateways();
  corey.add({ name: "Paper towels", url: TOWELS, forPerson: "gia" });
  corey.mailOrder({ ...MAILED, asins: ["B07XYZ1234"] });
  const shipped = corey.mailOrder({ order: ORDER, status: "shipped", at: "2026-10-15T06:10:00-04:00", asins: [] });
  assert.deepEqual([shipped.isAdvance, shipped.card.status], [true, "shipped"]);
  assert.equal(corey.mailOrder({ order: ORDER, status: "shipped", at: "2026-10-15T09:00:00-04:00", asins: [] }).isAdvance, false);
  assert.equal(corey.mailOrder({ order: ORDER, status: "ordered", at: "2026-10-14T19:42:00-04:00", asins: [] }).isAdvance, false, "a late Ordered email is no news");
  assert.equal(corey.mailOrder({ order: ORDER, status: "shipped", at: "2026-10-15T09:00:00-04:00", asins: [] }).card.steps[1].at, "2026-10-15T06:10:00-04:00");
});

test("an adopted item the order has no room for stays in its tapped order", () => {
  const { corey } = gateways();
  const asin = (round, index) => `B0R${round}I${String(index).padStart(5, "0")}`;
  for (let round = 0; round < 6; round += 1) {
    for (let index = 0; index < 40; index += 1) {
      corey.add({ name: `Item ${round}-${index}`, url: `https://www.amazon.com/dp/${asin(round, index)}`, forPerson: "gia" });
    }
    corey.tapOrdered(corey.card().items.map((item) => item.id));
  }
  const all = Array.from({ length: 6 }, (_, round) => Array.from({ length: 40 }, (_, index) => asin(round, index))).flat();
  assert.equal(corey.mailOrder({ ...MAILED, asins: all }).card.items, 200, "as many as an order holds");
  assert.equal(corey.mailOrder({ ...MAILED, order: "113-7654321-1111111", asins: all }).card.items, 40, "the rest wait for another order");
});

test("items someone tapped Ordered join the order their email names, and its delivery crosses for them", () => {
  const { corey, denise, relay } = gateways();
  const towels = corey.add({ name: "Paper towels", url: TOWELS, forPerson: "gia" });
  const soap = corey.add({ name: "Dish soap", url: SOAP, forPerson: "gia" });
  corey.tapOrdered([towels.id, soap.id]);
  const steps = corey.outbox().cart.length;

  const { card } = corey.mailOrder({ ...MAILED, asins: ["B07XYZ1234"] });
  assert.equal(card.items, 1);
  assert.equal(corey.outbox().cart.length, steps, "already ordered, so nothing more crosses");

  corey.mailOrder({ order: ORDER, status: "delivered", at: "2026-10-16T14:05:00-04:00", asins: [] });
  const last = corey.outbox().cart.at(-1);
  assert.deepEqual([last.items, last.status], [[towels.id], "delivered"]);
  relay(corey, denise);
  assert.deepEqual(denise.card().items, []);
});

// MARK: - The tool, and the turns it answers in

const DIRECT = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  deliveryContext: { channel: "household", accountId: "default", to: "household:franco" },
  requesterSenderId: "franco",
  sessionKey: "agent:main:household:direct:franco",
};
const FAMILY = {
  ...DIRECT,
  deliveryContext: { ...DIRECT.deliveryContext, to: "household:family" },
  requesterSenderId: "gia",
  sessionKey: "agent:main:household:group:family",
};

function tool(context) {
  const { corey } = gateways();
  return { cart: corey, found: createCartTool({ context, owner: "franco", people: [FRANCO, GIA], cart: corey }) };
}

async function run(found, args) {
  const result = await found.execute("call-1", args);
  return { ...JSON.parse(result.content[0].text), isError: result.isError === true };
}

test("the tool is offered in the owner's own thread and in the family room", () => {
  for (const context of [DIRECT, FAMILY]) {
    const { found } = tool(context);
    assert.equal(found.name, CART_TOOL);
    assert.equal(found.parameters.additionalProperties, false);
  }
});

for (const [why, context] of [
  ["Telegram", { ...DIRECT, messageChannel: "telegram", deliveryContext: { ...DIRECT.deliveryContext, channel: "telegram" } }],
  ["an automation with no sender", { ...DIRECT, requesterSenderId: undefined }],
  ["a gateway client speaking as itself", { ...DIRECT, requesterSenderId: "openclaw-ios", deliveryContext: { ...DIRECT.deliveryContext, to: "household:openclaw-ios" } }],
  ["the other person in the owner's thread", { ...DIRECT, requesterSenderId: "gia" }],
  ["a stranger in the family room", { ...FAMILY, requesterSenderId: "mallory" }],
  ["a turn the other assistant's @mention started", { ...FAMILY, requesterSenderId: "denise" }],
  ["another agent", { ...DIRECT, agentId: "helper" }],
]) {
  test(`the tool is not offered to ${why}`, () => {
    assert.equal(tool(context).found, null);
  });
}

test("adding in the family room puts the item down for whoever asked", async () => {
  const { found } = tool(FAMILY);
  const answer = await run(found, { action: "add", name: "Paper towels", url: TOWELS });
  assert.equal(answer.isError, false);
  assert.deepEqual(answer.cart.items.map(({ by, for: forName }) => ({ by, for: forName })), [{ by: "Corey", for: "Gia" }]);
  assert.equal(answer.cart.checkout, "https://www.amazon.com/gp/aws/cart/add.html?ASIN.1=B07XYZ1234&Quantity.1=1");
});

test("view, quantity and remove answer with the whole cart card", async () => {
  const { found } = tool(DIRECT);
  const added = await run(found, { action: "add", name: "Paper towels", url: TOWELS });
  const id = added.cart.items[0].id;
  assert.equal((await run(found, { action: "quantity", item: id, quantity: 3 })).cart.items[0].quantity, 3);
  assert.equal((await run(found, { action: "view" })).cart.items.length, 1);
  assert.deepEqual((await run(found, { action: "remove", item: id })).cart.items, []);
});

test("orders are only for the owner's own turns: the other person's family-room turn records none", async () => {
  const { found } = tool(FAMILY);
  const answer = await run(found, { action: "order", order: ORDER, status: "ordered", items: ["ci-00000000"] });
  assert.equal(answer.isError, true);
  assert.equal(answer.code, "owner_thread_only");
});

test("the owner's own family-room turn, in their own session of the room, records an order as their thread does", async () => {
  const { found } = tool({ ...FAMILY, requesterSenderId: "franco", sessionKey: "agent:main:household:group:family:sender:franco" });
  const id = (await run(found, { action: "add", name: "Paper towels", url: TOWELS })).cart.items[0].id;
  const answer = await run(found, { action: "order", order: ORDER, status: "ordered", items: [id], at: "2026-10-14T19:42:00-04:00" });
  assert.equal(answer.isError, false);
});

test("the owner in the room's shared session records no order: only their own session of the room is theirs", async () => {
  const { found } = tool({ ...FAMILY, requesterSenderId: "franco" });
  const answer = await run(found, { action: "order", order: ORDER, status: "ordered", items: ["ci-00000000"] });
  assert.equal(answer.code, "owner_thread_only");
});

test("an order in the owner's thread answers with the order card and the cart", async () => {
  const { found } = tool(DIRECT);
  const id = (await run(found, { action: "add", name: "Paper towels", url: TOWELS })).cart.items[0].id;
  const answer = await run(found, { action: "order", order: ORDER, status: "ordered", items: [id], at: "2026-10-14T19:42:00-04:00" });
  assert.equal(answer.order.order, "113-***-4417");
  assert.deepEqual(answer.cart.items, []);
});

test("a mistake comes back as a coded error the assistant can explain", async () => {
  const { found } = tool(DIRECT);
  const notAmazon = await run(found, { action: "add", name: "Towels", url: "https://www.target.com/p/x" });
  assert.equal(notAmazon.isError, true);
  assert.equal(notAmazon.code, "not_amazon");
  const unknownAction = await run(found, { action: "checkout" });
  assert.equal(unknownAction.code, "invalid_arguments");
  const extra = await run(found, { action: "view", person: "gia" });
  assert.equal(extra.code, "invalid_arguments", "no argument names a person");
  for (const action of ["constructor", "toString", "__proto__"]) {
    assert.equal((await run(found, { action, name: "x" })).code, "invalid_arguments", action);
  }
});

// A grocery list said in one voice note lands in one call.
test("the tool adds a whole list at once, for whoever asked, and refuses a list beside one item", async () => {
  // Arrange
  const { cart, found } = tool(FAMILY);

  // Act
  const added = await run(found, { action: "add", list: [{ name: "Milk" }, { name: "Eggs" }, { name: "Bread", quantity: 2 }] });
  const both = await run(found, { action: "add", name: "Butter", list: [{ name: "Jam" }] });

  // Assert
  assert.equal(added.logged, "3 items in the cart");
  assert.deepEqual(cart.card().items.map((item) => [item.name, item.quantity]), [["Milk", 1], ["Eggs", 1], ["Bread", 2]]);
  assert.equal(both.code, "invalid_arguments");
  assert.equal(cart.card().items.length, 3);
});
