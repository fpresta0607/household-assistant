// The household cart: one shopping list both assistants add to, and the Amazon link that
// puts it in the buyer's own Amazon cart, where the buyer checks out. Nothing here talks to
// Amazon. The link opens Amazon's Add to Cart form, which asks the person to confirm.
//
// Each gateway keeps every step either assistant took, adding, removing, changing a
// quantity or an order's status, in its own SQLite file beside the room. It publishes all
// of its own steps in its outbox, the other gateway reads them from its share with
// every change, and both replay the same steps in the same order, so the two carts agree
// without either reaching into the other's state, and a gateway that lost its file gets the
// other's steps back with the next delivery. A step is a couple of hundred bytes, so years
// of a household's shopping stay well inside the outbox's bound.
//
// An order is the buyer's alone. Its number, dates and shipping steps stay on the gateway
// that recorded it, from its owner's mailbox or from the Ordered tap in the app. All that
// crosses is that items were ordered, which takes them out of the cart, and that they were
// delivered.

import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

export const CART_TOOL = "household_cart";
export const CART_ID = "household";
const TITLE = "Household cart";
const ORDER_TITLE = "Household order";
const SKILL = "lists";
export const MAX_OPEN_ITEMS = 40;
const MAX_ORDER_ITEMS = 200;
const MAX_NAME = 120;
const MAX_QUANTITY = 99;
// More steps than one delivery from the other gateway could honestly hold.
const MAX_PEER_STEPS = 50_000;
const STATUSES = ["ordered", "shipped", "out_for_delivery", "delivered"];
const LABELS = { ordered: "Ordered", shipped: "Shipped", out_for_delivery: "Out for delivery", delivered: "Delivered" };
const CROSSING = new Set(["ordered", "delivered"]);
const ITEM_ID = /^ci-[0-9a-f]{8}$/;
const STEP_ID = /^co-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const AMAZON_HOSTS = new Set(["www.amazon.com", "amazon.com"]);
const PRODUCT_PATH = /\/(?:dp\/product|dp|gp\/product|gp\/aw\/d)\/([A-Z0-9]{10})(?:\/|$)/;
const ORDER_NUMBER = /^(\d{3})-\d{7}-\d{3}(\d{4})$/;
const MOMENT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2})$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS steps (
    id TEXT PRIMARY KEY,
    seq INTEGER NOT NULL UNIQUE,
    at INTEGER NOT NULL,
    origin TEXT NOT NULL,
    body TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS orders (
    number TEXT PRIMARY KEY,
    body TEXT NOT NULL
  );
`;

export class CartError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// An Amazon US product page reduced to its id and a plain link to it, or null for anything
// else: another store or country, a search, or a short link that hides which product it is.
export function amazonProduct(link) {
  let url;
  try {
    url = new URL(link);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || !AMAZON_HOSTS.has(url.hostname)) return null;
  const asin = PRODUCT_PATH.exec(url.pathname)?.[1];
  return asin ? { asin, url: `https://www.amazon.com/dp/${asin}` } : null;
}

// Amazon's Add to Cart form for every item that has an Amazon id, or null when none has.
export function checkoutLink(items) {
  const query = items
    .filter((item) => item.asin)
    .map((item, index) => `ASIN.${index + 1}=${item.asin}&Quantity.${index + 1}=${item.quantity}`);
  return query.length ? `https://www.amazon.com/gp/aws/cart/add.html?${query.join("&")}` : null;
}

// Words only: no control characters, and none of the invisible ones that reorder or hide
// text, since a name the other assistant wrote is read by this one.
function cleanName(value) {
  if (typeof value !== "string") return "";
  return value.replace(/\s+/g, " ").replace(/[\p{Cc}\p{Cf}]/gu, "").replace(/ +/g, " ").trim();
}

const isQuantity = (value) => Number.isInteger(value) && value >= 1 && value <= MAX_QUANTITY;
const isMoment = (value) => typeof value === "string" && MOMENT.test(value) && Number.isFinite(Date.parse(value));
const isDay = (value) => typeof value === "string" && DAY.test(value) &&
  Number.isFinite(Date.parse(`${value}T00:00:00Z`)) && new Date(`${value}T00:00:00Z`).toISOString().startsWith(value);
const isItemIds = (value, limit) => Array.isArray(value) && value.length >= 1 && value.length <= limit &&
  value.every((id) => typeof id === "string" && ITEM_ID.test(id));

export function createCart({ file, assistant, peerAssistant, people, now = Date.now, newId = randomUUID, changed = () => {} }) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
  db.exec(SCHEMA);
  const statements = {
    insert: db.prepare(
      "INSERT OR IGNORE INTO steps (id, seq, at, origin, body) VALUES (?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM steps), ?, ?, ?)",
    ),
    all: db.prepare("SELECT body FROM steps ORDER BY at, id"),
    latest: db.prepare("SELECT COALESCE(MAX(at), 0) AS at FROM steps"),
    local: db.prepare("SELECT body FROM steps WHERE origin = 'local' ORDER BY seq"),
    order: db.prepare("SELECT body FROM orders WHERE number = ?"),
    saveOrder: db.prepare("INSERT INTO orders (number, body) VALUES (?, ?) ON CONFLICT (number) DO UPDATE SET body = excluded.body"),
    tapOrders: db.prepare("SELECT number, body FROM orders WHERE number LIKE 'tap-%' ORDER BY number"),
    dropOrder: db.prepare("DELETE FROM orders WHERE number = ?"),
  };
  const names = new Map([...people, assistant, peerAssistant].map((who) => [who.id, who.name]));
  const personIds = new Set(people.map((who) => who.id));

  function keep(step, origin) {
    return statements.insert.run(step.id, step.at, origin, JSON.stringify(step)).changes > 0;
  }

  // A new step of this assistant's, timed after every step already kept, so a clock that
  // stepped back cannot sort it before the item it changes.
  function stepOf(fields) {
    return { id: `co-${newId()}`, at: Math.max(now(), Number(statements.latest.get().at) + 1), author: assistant.id, ...fields };
  }

  // Several writes that stand or fall together, announced once they stand.
  function together(write) {
    db.exec("BEGIN IMMEDIATE");
    try {
      const value = write();
      db.exec("COMMIT");
      changed();
      return value;
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  }

  // Every item either assistant ever added, as the steps so far leave it, in the order
  // the steps were taken.
  function replay() {
    const items = new Map();
    const removed = new Set();
    const rank = (status) => (status ? STATUSES.indexOf(status) : -1);
    for (const { body } of statements.all.all()) {
      const step = JSON.parse(body);
      if (step.kind === "add" && !items.has(step.item.id) && !removed.has(step.item.id)) {
        items.set(step.item.id, { ...step.item, by: step.author, status: null });
      } else if (step.kind === "remove") {
        items.delete(step.item);
        removed.add(step.item);
      } else if (step.kind === "quantity" && items.has(step.item)) {
        items.get(step.item).quantity = step.quantity;
      } else if (step.kind === "status") {
        for (const id of step.items) {
          const item = items.get(id);
          if (item && rank(step.status) > rank(item.status)) item.status = step.status;
        }
      }
    }
    return [...items.values()];
  }

  const openItems = () => replay().filter((item) => item.status === null);

  function openItem(id) {
    const item = typeof id === "string" ? openItems().find((candidate) => candidate.id === id) : undefined;
    if (!item) throw new CartError("unknown_item", "That item is not in the cart. View the cart for its items' ids.");
    return item;
  }

  function cardItem(item) {
    return {
      id: item.id,
      name: item.name,
      quantity: item.quantity,
      by: names.get(item.by) ?? item.by,
      for: names.get(item.for) ?? item.for,
      ...(item.url ? { url: item.url } : {}),
    };
  }

  // A step the other gateway's assistant took, in the shape this gateway would have
  // written it, or null when anything about it is wrong.
  function peerStep(raw) {
    if (!raw || typeof raw !== "object" || typeof raw.id !== "string" || !STEP_ID.test(raw.id)) return null;
    if (!Number.isSafeInteger(raw.at) || raw.author !== peerAssistant.id) return null;
    const base = { id: raw.id, at: raw.at, author: raw.author, kind: raw.kind };
    if (raw.kind === "add") {
      const item = raw.item ?? {};
      const name = cleanName(item.name);
      const product = item.url === undefined ? undefined : amazonProduct(item.url);
      if (typeof item.id !== "string" || !ITEM_ID.test(item.id) || !name || name !== item.name || name.length > MAX_NAME) return null;
      if (!isQuantity(item.quantity) || !personIds.has(item.for)) return null;
      if (product === null || (product && product.url !== item.url)) return null;
      return { ...base, item: { id: item.id, name, quantity: item.quantity, for: item.for, ...(product ? product : {}) } };
    }
    if (raw.kind === "remove") return typeof raw.item === "string" && ITEM_ID.test(raw.item) ? { ...base, item: raw.item } : null;
    if (raw.kind === "quantity") {
      return typeof raw.item === "string" && ITEM_ID.test(raw.item) && isQuantity(raw.quantity)
        ? { ...base, item: raw.item, quantity: raw.quantity }
        : null;
    }
    if (raw.kind === "status") {
      return isItemIds(raw.items, MAX_ORDER_ITEMS) && CROSSING.has(raw.status)
        ? { ...base, items: [...raw.items], status: raw.status }
        : null;
    }
    return null;
  }

  function readOrder(key) {
    const row = statements.order.get(key);
    return row ? JSON.parse(row.body) : null;
  }

  function orderCard(key) {
    const order = readOrder(key);
    if (!order) return null;
    const reached = STATUSES.filter((status) => order.steps[status] || status === "ordered");
    const number = ORDER_NUMBER.exec(key);
    return {
      type: "order",
      title: ORDER_TITLE,
      items: order.items.length,
      status: reached.at(-1),
      ...(order.arriving ? { arriving: order.arriving } : {}),
      ...(number ? { order: `${number[1]}-***-${number[2]}` } : {}),
      steps: STATUSES.map((status) => (order.steps[status]
        ? { label: LABELS[status], at: order.steps[status] }
        : { label: LABELS[status] })),
      skill: SKILL,
    };
  }

  // Records what an order now says, with the steps that cross, all at once. `taken` are
  // open cart items it takes for the first time, and `alsoWrite` any other change that
  // must stand or fall with it.
  function record(key, order, taken, status, at, alsoWrite = () => {}) {
    together(() => {
      alsoWrite();
      const isNewlyDelivered = status === "delivered" && !order.crossed.includes("delivered");
      if (taken.length) keep(stepOf({ kind: "status", items: taken, status: "ordered" }), "local");
      if (isNewlyDelivered) {
        keep(stepOf({ kind: "status", items: [...order.items, ...taken], status: "delivered" }), "local");
      } else if (taken.length && order.crossed.includes("delivered")) {
        keep(stepOf({ kind: "status", items: taken, status: "delivered" }), "local");
      }
      statements.saveOrder.run(key, JSON.stringify({
        ...order,
        items: [...order.items, ...taken],
        steps: { ...order.steps, [status]: order.steps[status] ?? at },
        crossed: isNewlyDelivered ? [...order.crossed, "delivered"] : order.crossed,
      }));
    });
    return orderCard(key);
  }

  // The open items among `ids`, each once, refusing any that is not open.
  function takenFrom(ids, order) {
    const taken = [...new Set(ids)].filter((id) => !order.items.includes(id)).map((id) => openItem(id).id);
    if (order.items.length + taken.length > MAX_ORDER_ITEMS) {
      throw new CartError("invalid_order", `An order holds at most ${MAX_ORDER_ITEMS} items.`);
    }
    return taken;
  }

  const moment = () => new Date(now()).toISOString();

  return {
    add({ name, url, quantity = 1, forPerson }) {
      const cleaned = cleanName(name);
      if (!cleaned || cleaned.length > MAX_NAME || !isQuantity(quantity) || !personIds.has(forPerson)) {
        throw new CartError("invalid_item", `An item needs a name of at most ${MAX_NAME} characters and a quantity from 1 to ${MAX_QUANTITY}.`);
      }
      const product = url === undefined ? undefined : amazonProduct(url);
      if (product === null) {
        throw new CartError("not_amazon", "Only a full amazon.com product link works, one with /dp/ and the product's id in it.");
      }
      if (openItems().length >= MAX_OPEN_ITEMS) {
        throw new CartError("cart_full", `The cart holds at most ${MAX_OPEN_ITEMS} items. Check out or remove some first.`);
      }
      const item = { id: `ci-${randomBytes(4).toString("hex")}`, name: cleaned, quantity, for: forPerson, ...(product ?? {}) };
      together(() => keep(stepOf({ kind: "add", item }), "local"));
      return cardItem({ ...item, by: assistant.id });
    },

    remove(id) {
      const item = openItem(id);
      together(() => keep(stepOf({ kind: "remove", item: item.id }), "local"));
    },

    setQuantity(id, quantity) {
      const item = openItem(id);
      if (!isQuantity(quantity)) throw new CartError("invalid_item", `A quantity is from 1 to ${MAX_QUANTITY}.`);
      together(() => keep(stepOf({ kind: "quantity", item: item.id, quantity }), "local"));
    },

    // What the buyer's mailbox says about an order. A new order names the cart items it
    // took. Its number, dates and steps stay here; ordered and delivered cross.
    markOrder({ order: number, items, status, at, arriving }) {
      if (typeof number !== "string" || !ORDER_NUMBER.test(number)) {
        throw new CartError("invalid_order", "An Amazon order number looks like 113-1234567-1234567.");
      }
      if (!STATUSES.includes(status)) throw new CartError("invalid_order", `The status is one of ${STATUSES.join(", ")}.`);
      if (at !== undefined && !isMoment(at)) throw new CartError("invalid_order", "`at` is a time with its offset, such as 2026-10-14T19:42:00-04:00.");
      if (arriving !== undefined && !isDay(arriving)) throw new CartError("invalid_order", "`arriving` is a day, such as 2026-10-16.");
      if (items !== undefined && (!Array.isArray(items) || items.length === 0 || items.length > MAX_ORDER_ITEMS)) {
        throw new CartError("invalid_order", "List the ids of the cart items this order took.");
      }
      const existing = readOrder(number);
      if (!existing && items === undefined) {
        throw new CartError("unknown_order", "This order is new, so name the cart items it took.");
      }
      const order = existing ?? { items: [], steps: {}, crossed: [] };
      const taken = takenFrom(items ?? [], order);
      return record(number, arriving ? { ...order, arriving } : order, taken, status, at ?? moment());
    },

    // What an email from Amazon to this gateway's owner said, as amazon-mail.js read it. A
    // known order moves along. A new one is the household's only when it links to items
    // in the cart, which it takes, or to items someone tapped Ordered, which it adopts from
    // that tap's order. Anything else is someone's other Amazon order, and null.
    // `isAdvance` is whether the order now stands further along than it did.
    mailOrder({ order: number, status, at, arriving, asins }) {
      if (typeof number !== "string" || !ORDER_NUMBER.test(number) || !STATUSES.includes(status) || !isMoment(at)) return null;
      const day = isDay(arriving) ? arriving : undefined;
      const rank = (order) => Math.max(-1, ...STATUSES.map((step, index) => (order.steps[step] ? index : -1)));
      const existing = readOrder(number);
      if (existing) {
        const card = record(number, day ? { ...existing, arriving: day } : existing, [], status, at);
        return { card, isAdvance: STATUSES.indexOf(status) > rank(existing) };
      }
      const wanted = new Set(Array.isArray(asins) ? asins : []);
      const items = replay();
      const asinOf = new Map(items.map((item) => [item.id, item.asin]));
      const taken = items
        .filter((item) => item.status === null && item.asin && wanted.has(item.asin))
        .map((item) => item.id)
        .slice(0, MAX_ORDER_ITEMS);
      let room = MAX_ORDER_ITEMS - taken.length;
      const adoptions = statements.tapOrders.all().map(({ number: key, body }) => {
        const tap = JSON.parse(body);
        const mine = tap.items.filter((id) => wanted.has(asinOf.get(id))).slice(0, Math.max(0, room));
        room -= mine.length;
        return { key, tap, mine };
      }).filter(({ mine }) => mine.length);
      const adopted = adoptions.flatMap(({ mine }) => mine);
      if (!taken.length && !adopted.length) return null;
      const earliest = adoptions.map(({ tap }) => tap.steps.ordered).filter(Boolean).sort()[0];
      const order = { items: adopted, steps: earliest ? { ordered: earliest } : {}, crossed: [], ...(day ? { arriving: day } : {}) };
      const card = record(number, order, taken, status, at, () => {
        for (const { key, tap, mine } of adoptions) {
          const left = tap.items.filter((id) => !mine.includes(id));
          if (left.length) statements.saveOrder.run(key, JSON.stringify({ ...tap, items: left }));
          else statements.dropOrder.run(key);
        }
      });
      return { card, isAdvance: true };
    },

    // Whoever checked out tapping Ordered on the cart card: the open items among those the
    // card showed are ordered now, as an order of their own with no number.
    tapOrdered(ids) {
      if (!Array.isArray(ids)) throw new CartError("nothing_open", "That cart card shows no items.");
      const open = new Set(openItems().map((item) => item.id));
      const taken = [...new Set(ids)].filter((id) => open.has(id)).slice(0, MAX_ORDER_ITEMS);
      if (!taken.length) throw new CartError("nothing_open", "Everything on that card was already ordered or removed.");
      return { count: taken.length, order: record(`tap-${newId()}`, { items: [], steps: {}, crossed: [] }, taken, "ordered", moment()) };
    },

    card() {
      const items = openItems();
      const checkout = checkoutLink(items);
      return {
        type: "cart",
        id: CART_ID,
        title: TITLE,
        items: items.map(cardItem),
        ...(checkout ? { checkout } : {}),
        skill: SKILL,
      };
    },

    outbox() {
      return { cart: statements.local.all().map(({ body }) => JSON.parse(body)) };
    },

    acceptPeer(batch) {
      const steps = batch?.cart;
      if (!Array.isArray(steps)) return { accepted: 0, refused: 0 };
      if (steps.length > MAX_PEER_STEPS) return { accepted: 0, refused: steps.length };
      let accepted = 0;
      let refused = 0;
      for (const raw of steps) {
        const step = peerStep(raw);
        if (step === null) refused += 1;
        else if (keep(step, "peer")) accepted += 1;
      }
      if (accepted) changed();
      return { accepted, refused };
    },

    close() {
      db.close();
    },
  };
}
