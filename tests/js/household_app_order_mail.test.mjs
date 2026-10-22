// The household cart's order mail, from deploy/openclaw/plugins/household-app: the plugin
// reading the owner's own Amazon emails on a timer, with no model, and what it tells whom,
// and the gog commands it reads Gmail with.
//
// Every email here is synthetic. None was copied from anyone's mailbox.
//
// Run with `node --test tests/js/household_app_order_mail.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { createCart } from "../../deploy/openclaw/plugins/household-app/cart.js";
import { gmailSource } from "../../deploy/openclaw/plugins/household-app/gmail-source.js";
import { createOrderMail } from "../../deploy/openclaw/plugins/household-app/order-mail.js";

const NOW = Date.UTC(2026, 9, 15, 21, 52);
const OWNER = "gia.example@gmail.com";
const ORDER = "113-1234567-8904417";
const TOWELS = "B07XYZ1234";
const AUTH = "mx.google.com; dkim=pass header.i=@amazon.com header.s=rjv7xxwhd; spf=pass; dmarc=pass header.from=amazon.com";

const ROOT = mkdtempSync(path.join(os.tmpdir(), "household-order-mail-"));
const opened = [];
after(() => {
  for (const cart of opened) cart.close();
  rmSync(ROOT, { recursive: true, force: true });
});

function email(subject, body, date = "Wed, 15 Oct 2026 06:10:22 -0400") {
  return [
    `Authentication-Results: ${AUTH}`,
    `Date: ${date}`,
    'From: "Amazon.com" <shipment-tracking@amazon.com>',
    `To: ${OWNER}`,
    `Subject: ${subject}`,
    "MIME-Version: 1.0",
    "Content-Type: text/html; charset=UTF-8",
    "",
    body,
  ].join("\r\n");
}

const ORDERED = email("Ordered: Paper towels", `<p>Arriving Thursday, October 16</p><p>Order # ${ORDER}</p><a href="https://www.amazon.com/dp/${TOWELS}">x</a>`, "Tue, 14 Oct 2026 19:42:00 -0400");
const SHIPPED = email("Shipped: Paper towels", `<p>Order # ${ORDER}</p>`, "Wed, 15 Oct 2026 06:10:22 -0400");
const DELIVERED = email("Delivered: Paper towels", `<p>Order # ${ORDER}</p>`, "Thu, 16 Oct 2026 14:05:00 -0400");
const OTHER_ORDER = email("Ordered: A book", `<p>Order # 114-7654321-1234567</p><a href="https://www.amazon.com/dp/B0OTHERBOOK">x</a>`);
const PROMOTION = email("Deals picked for you", "<p>Save now</p>");

function setup({ mail, alreadyRead = true }) {
  let counter = 0;
  const directory = mkdtempSync(path.join(ROOT, "gateway-"));
  const seenFile = path.join(directory, "order-mail-seen.json");
  if (alreadyRead) writeFileSync(seenFile, "[]");
  const cart = createCart({
    file: path.join(directory, "cart.sqlite"),
    assistant: { id: "denise", name: "Denise" },
    peerAssistant: { id: "corey", name: "Corey" },
    people: [{ id: "gia", name: "Gia" }, { id: "franco", name: "Franco" }],
    now: () => NOW,
    newId: () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`,
  });
  opened.push(cart);
  cart.add({ name: "Paper towels", url: `https://www.amazon.com/dp/${TOWELS}`, forPerson: "gia" });
  const reads = [];
  const source = {
    list: async () => {
      if (mail.listFails) throw Object.assign(new Error("the mailbox did not answer"), { code: "ETIMEDOUT" });
      return Object.keys(mail.messages);
    },
    raw: async (id) => {
      reads.push(id);
      if (mail.failing?.has(id)) throw Object.assign(new Error("that message did not come"), { code: "ETIMEDOUT" });
      return mail.messages[id];
    },
  };
  const posts = [];
  const warnings = [];
  const make = ({ postFails = false } = {}) => createOrderMail({
    source,
    owner: OWNER,
    cart,
    post: async (message) => {
      if (postFails) throw new Error("the room is closed");
      posts.push(message);
    },
    seenFile,
    log: { warn: (text) => warnings.push(text), info() {} },
  });
  return { cart, reads, posts, warnings, make };
}

const cardsIn = (text) => [...text.matchAll(/```steward-card\n(.*)\n```/g)].map((found) => JSON.parse(found[1]));

test("an order email takes its items out of the cart and puts the order in the owner's own thread", async () => {
  const { cart, posts, make } = setup({ mail: { messages: { m1: ORDERED, m2: PROMOTION, m3: OTHER_ORDER } } });
  assert.deepEqual(await make().poll(), { read: 3, recorded: 1 });
  assert.deepEqual(cart.card().items, []);
  assert.equal(posts.length, 1);
  assert.equal(posts[0].conversation, "direct");
  assert.match(posts[0].text, /^Amazon confirmed your household order\./);
  const [card] = cardsIn(posts[0].text);
  assert.deepEqual([card.type, card.status, card.order, card.arriving], ["order", "ordered", "113-***-4417", "2026-10-16"]);
});

test("the first read records the week it finds and posts none of it", async () => {
  const mail = { messages: { m1: ORDERED, m2: SHIPPED } };
  const { cart, posts, make } = setup({ mail, alreadyRead: false });
  assert.deepEqual(await make().poll(), { read: 2, recorded: 2 });
  assert.deepEqual(posts, []);
  assert.deepEqual(cart.card().items, [], "the cart still learns the items were ordered");
  mail.messages.m3 = DELIVERED;
  await make().poll();
  assert.deepEqual(posts.map((post) => post.conversation), ["direct", "family"]);
});

test("emails are taken oldest first, so the newest step is the one that stands", async () => {
  const { posts, make } = setup({ mail: { messages: { m3: DELIVERED, m2: SHIPPED, m1: ORDERED } } });
  await make().poll();
  assert.deepEqual(posts.map((post) => post.text.split("\n")[0]), [
    "Amazon confirmed your household order.",
    "Your household order shipped.",
    "Your household order was delivered.",
    "The household order was delivered.",
  ]);
});

test("each email is read once, even across a restart", async () => {
  const { reads, posts, make } = setup({ mail: { messages: { m1: ORDERED, m2: PROMOTION } } });
  await make().poll();
  await make().poll();
  assert.deepEqual(reads, ["m1", "m2"]);
  assert.equal(posts.length, 1);
});

test("shipping says so in the owner's thread, and delivery also tells the family room in one line", async () => {
  const mail = { messages: { m1: ORDERED } };
  const { posts, make } = setup({ mail });
  const reader = make();
  await reader.poll();
  mail.messages.m2 = SHIPPED;
  await reader.poll();
  mail.messages.m3 = DELIVERED;
  await reader.poll();
  assert.deepEqual(posts.map((post) => post.conversation), ["direct", "direct", "direct", "family"]);
  assert.match(posts[1].text, /^Your household order shipped\./);
  assert.match(posts[2].text, /^Your household order was delivered\./);
  assert.deepEqual(posts[3], { conversation: "family", text: "The household order was delivered." });
});

test("an email of a step the order already passed says nothing", async () => {
  const mail = { messages: { m1: ORDERED, m2: SHIPPED } };
  const { posts, make } = setup({ mail });
  await make().poll();
  mail.messages.m3 = SHIPPED;
  mail.messages.m4 = ORDERED;
  await make().poll();
  assert.equal(posts.length, 2);
});

test("a mailbox that does not answer posts nothing and is asked again next time", async () => {
  const mail = { messages: { m1: ORDERED }, listFails: true };
  const { posts, warnings, make } = setup({ mail });
  const reader = make();
  assert.deepEqual(await reader.poll(), { read: 0, recorded: 0 });
  assert.equal(posts.length, 0);
  assert.match(warnings[0], /could not list the mailbox \(ETIMEDOUT\)/);
  mail.listFails = false;
  assert.deepEqual(await reader.poll(), { read: 1, recorded: 1 });
});

test("a message that did not come is tried three times, then left", async () => {
  const mail = { messages: { m1: ORDERED, m2: PROMOTION }, failing: new Set(["m1"]) };
  const { reads, make } = setup({ mail });
  const reader = make();
  assert.deepEqual(await reader.poll(), { read: 1, recorded: 0 });
  assert.deepEqual(await reader.poll(), { read: 0, recorded: 0 });
  assert.deepEqual(await reader.poll(), { read: 1, recorded: 0 }, "the third failure gives it up");
  await reader.poll();
  assert.deepEqual(reads, ["m1", "m2", "m1", "m1"]);
});

test("a post that fails is logged, and the email still counts as read", async () => {
  const { reads, warnings, make } = setup({ mail: { messages: { m1: ORDERED } } });
  await make({ postFails: true }).poll();
  await make().poll();
  assert.deepEqual(reads, ["m1"]);
  assert.match(warnings[0], /could not be posted/);
});

test("nothing an email said is logged", async () => {
  const mail = { messages: { m1: ORDERED }, failing: new Set(["m1"]) };
  const { warnings, make } = setup({ mail });
  await make().poll();
  assert.equal(warnings.some((line) => /Paper towels|113-|B07XYZ1234|gia/.test(line)), false);
});

// MARK: - gog

function runner(outputs) {
  const calls = [];
  return {
    calls,
    run: async (file, args, signal) => {
      calls.push({ command: [file, ...args], signal });
      return { stdout: outputs.shift() };
    },
  };
}

test("Gmail is read through gog, read-only, as the owner, Amazon's order mail of the last week", async () => {
  const { calls, run } = runner([
    JSON.stringify([{ id: "18f1" }, { id: "18f2" }]),
    JSON.stringify({ id: "18f1", raw: Buffer.from(ORDERED).toString("base64url") }),
  ]);
  const source = gmailSource({ account: OWNER, run });
  const signal = new AbortController().signal;
  assert.deepEqual(await source.list(signal), ["18f1", "18f2"]);
  assert.equal((await source.raw("18f1", signal)).toString("utf8"), ORDERED);
  assert.deepEqual(calls[0].command, [
    "gog", "--readonly", "--no-input", "--account", OWNER, "gmail", "messages", "search",
    'from:amazon.com newer_than:7d (subject:ordered OR subject:shipped OR subject:"out for delivery" OR subject:delivered OR subject:"your amazon.com order")',
    "--max", "50", "--json", "--results-only",
  ]);
  assert.deepEqual(calls[1].command, ["gog", "--readonly", "--no-input", "--account", OWNER, "gmail", "get", "18f1", "--format", "raw", "--json", "--results-only"]);
  assert.equal(calls[0].signal, signal, "the channel's stop reaches the command");
});

test("gog's list is taken whether it comes as a list or under messages", async () => {
  const { run } = runner([JSON.stringify({ messages: [{ id: "18f1" }] })]);
  assert.deepEqual(await gmailSource({ account: OWNER, run }).list(), ["18f1"]);
});

test("a message id that is not one is refused before it reaches a command", async () => {
  const { calls, run } = runner([JSON.stringify([{ id: "--format=metadata" }, { id: "18f1" }])]);
  const source = gmailSource({ account: OWNER, run });
  assert.deepEqual(await source.list(), ["18f1"]);
  await assert.rejects(source.raw("--help"));
  assert.equal(calls.length, 1);
});
