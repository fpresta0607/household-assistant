// The meal plan that builds the cart, from deploy/openclaw/plugins/household-app/meals.js and
// meals-tool.js: the week's dinners from what is in the kitchen and what is on sale, and an
// accepted plan put in the household cart with no item twice. Nothing is ordered: that stays
// the one-tap send. Every dinner and price here is made up.
//
// Run with `node --test tests/js/household_app_meals.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { createMeals, itemKey } from "../../deploy/openclaw/plugins/household-app/meals.js";
import { runningChannel } from "./fixtures/household-app-channel.mjs";

const ROOT = mkdtempSync(path.join(os.tmpdir(), "household-meals-"));
const opened = [];
after(() => {
  for (const each of opened) each.close();
  rmSync(ROOT, { recursive: true, force: true });
});

function mealsAt(moment = Date.UTC(2026, 9, 22, 17, 0)) {
  let clock = moment;
  let counter = 0;
  const meals = createMeals({
    file: path.join(mkdtempSync(path.join(ROOT, "gateway-")), "meals.sqlite"),
    now: () => clock,
    newId: () => String(++counter).padStart(8, "0"),
  });
  opened.push(meals);
  return { meals, at: (next) => {
    clock = next;
  } };
}

const WEEK = [
  { day: "Mon", name: "Chicken tacos", ingredients: [{ name: "chicken thighs", quantity: 2, sale: "$1.99/lb" }, { name: "onions" }, { name: "tortillas" }, { name: "Tomatoes" }] },
  { day: "Tue", name: "Fried rice", ingredients: [{ name: "rice" }, { name: "eggs" }, { name: "onion", quantity: 2 }, { name: "rice vinegar" }] },
  { day: "Wed", name: "Pasta al pomodoro", ingredients: [{ name: "spaghetti" }, { name: "tomato", quantity: 3 }, { name: "2 lb ground beef" }] },
];

for (const [left, right, isSame] of [
  ["Tomatoes", "tomato", true],
  ["onions", "Onion", true],
  ["berries", "berry", true],
  ["2 lb ground beef", "Ground beef", true],
  ["asparagus", "asparagu", false],
  ["rice", "rice vinegar", false],
  ["chicken", "chicken thighs", false],
]) {
  test(`"${left}" and "${right}" are ${isSame ? "one item" : "two items"}`, () => {
    assert.equal(itemKey(left) === itemKey(right), isSame);
  });
}

test("a plan buys each ingredient once, its quantities added, and nothing the kitchen or the cart has", () => {
  // Arrange
  const { meals } = mealsAt();

  // Act
  const plan = meals.propose({ dinners: WEEK, kitchen: ["Rice", "eggs"], cart: ["Spaghetti"] });

  // Assert
  assert.match(plan.plan, /^mp-[0-9a-f]{8}$/);
  assert.deepEqual(plan.have, ["rice", "eggs"]);
  assert.deepEqual(plan.inCart, ["spaghetti"]);
  assert.deepEqual(plan.buy, [
    { name: "chicken thighs", quantity: 2 },
    { name: "onions", quantity: 3 },
    { name: "tortillas", quantity: 1 },
    { name: "Tomatoes", quantity: 4 },
    { name: "rice vinegar", quantity: 1 },
    { name: "2 lb ground beef", quantity: 1 },
  ]);
  assert.deepEqual(plan.card.rows[0], ["Mon", "Chicken tacos", "chicken thighs ($1.99/lb)"]);
  assert.deepEqual(plan.card.rows[1], ["Tue", "Fried rice", "-"]);
});

test("a plan is accepted once, against the cart as it stands then", () => {
  const { meals } = mealsAt();
  const { plan } = meals.propose({ dinners: WEEK, kitchen: [], cart: [] });
  const first = meals.accept(plan, { kitchen: [], cart: ["Onion"], room: 40 });
  assert.deepEqual(first.inCart, ["onions"], "added to the cart since it was proposed");
  assert.throws(() => meals.accept(plan, { kitchen: [], cart: [], room: 40 }), { code: "already_accepted" });
});

test("a plan the cart has no room for is refused whole and can be accepted later", () => {
  const { meals } = mealsAt();
  const { plan } = meals.propose({ dinners: WEEK, kitchen: [], cart: [] });
  assert.throws(() => meals.accept(plan, { kitchen: [], cart: [], room: 3 }), { code: "cart_full" });
  assert.equal(meals.accept(plan, { kitchen: [], cart: [], room: 40 }).buy.length, 9);
});

test("a plan two weeks old is no longer kept", () => {
  const { meals, at } = mealsAt();
  const { plan } = meals.propose({ dinners: WEEK, kitchen: [], cart: [] });
  at(Date.UTC(2026, 10, 6, 18, 0));
  assert.throws(() => meals.accept(plan, { kitchen: [], cart: [], room: 40 }), { code: "unknown_plan" });
});

for (const [why, dinners] of [
  ["no dinners", []],
  ["eight dinners", Array.from({ length: 8 }, () => WEEK[0])],
  ["a dinner with no ingredients", [{ name: "Soup", ingredients: [] }]],
  ["an ingredient with no words", [{ name: "Soup", ingredients: [{ name: "  " }] }]],
  ["a quantity of zero", [{ name: "Soup", ingredients: [{ name: "leeks", quantity: 0 }] }]],
]) {
  test(`a plan with ${why} is refused`, () => {
    const { meals } = mealsAt();
    assert.throws(() => meals.propose({ dinners, kitchen: [], cart: [] }), { code: "invalid_plan" });
  });
}

// Through Corey's plugin: what Franco keeps in the kitchen and the cart, a plan Gia accepts in
// the family room, and the cart that crosses.

const COREY = {
  agents: { entries: { main: { identity: { name: "Corey" } } } },
  channels: {
    household: {
      owner: { id: "franco", name: "Franco" },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};
const turnIn = (sessionKey, to, sender) => ({
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  deliveryContext: { channel: "household", accountId: "default", to },
  requesterSenderId: sender,
  sessionKey,
});
const FRANCOS_THREAD = turnIn("agent:main:household:direct:franco", "household:franco", "franco");
const SHARED_ROOM = turnIn("agent:main:household:group:family", "household:family", "gia");
const toolOf = (channel, name, context) => channel.tools.find(({ options }) => options.names.includes(name)).factory(context);
const run = async (tool, args) => JSON.parse((await tool.execute("call-1", args)).content[0].text);

test("through the plugin, an accepted plan fills the cart with each item once, and orders nothing", async () => {
  // Arrange: Franco's kitchen has rice and eggs, and the cart already has spaghetti.
  const channel = await runningChannel(COREY);
  const outbox = path.join(channel.stateDir, "household-app", "share", "outbox.json");
  try {
    await run(toolOf(channel, "household_note", FRANCOS_THREAD), { action: "add", topic: "In the kitchen", rows: [{ text: "half a bag", item: "rice" }, { text: "a dozen", item: "eggs" }] });
    await run(toolOf(channel, "household_cart", FRANCOS_THREAD), { action: "add", name: "Spaghetti" });
    const meals = toolOf(channel, "household_meals", SHARED_ROOM);

    // Act: Gia asks Corey for the week's dinners in the family room, and says yes.
    const proposed = await run(meals, { action: "propose", dinners: WEEK });
    const accepted = await run(meals, { action: "accept", plan: proposed.plan });
    const again = await run(meals, { action: "accept", plan: proposed.plan });
    // The outbox is rewritten whole for each add, so it is read only now and then, never in a
    // tight loop that could meet a rewrite: on Windows a replace that meets a read is lost.
    let crossing = [];
    for (let readsLeft = 40; readsLeft > 0 && crossing.length < 7; readsLeft -= 1) {
      await new Promise((resolve) => setTimeout(resolve, 250));
      crossing = (JSON.parse(await readFile(outbox, "utf8").catch(() => "{}")).cart ?? []).filter((step) => step.kind === "add");
    }

    // Assert
    assert.deepEqual(proposed.have, ["rice", "eggs"]);
    assert.equal(accepted.logged, "6 items in the cart");
    const names = accepted.cart.items.map((item) => item.name);
    assert.deepEqual(names, ["Spaghetti", "chicken thighs", "onions", "tortillas", "Tomatoes", "rice vinegar", "2 lb ground beef"]);
    assert.equal(new Set(names.map(itemKey)).size, names.length, "no item twice");
    assert.equal(accepted.cart.items.find((item) => item.name === "Tomatoes").quantity, 4);
    assert.equal(accepted.cart.items.find((item) => item.name === "onions").for, "Gia", "down for whoever asked");
    assert.equal(again.code, "already_accepted");
    assert.equal(crossing.length, 7, "each item crosses once, as the cart's own step");
    assert.equal(channel.dispatches.length, 0, "no turn and no message: nothing was sent to anyone");
    assert.equal(toolOf(channel, "household_meals", turnIn("agent:main:cron:1", "household:franco", "franco")), null, "no tool outside the app's turns");
  } finally {
    await channel.stop();
  }
});
