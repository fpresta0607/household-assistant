// A meal plan that builds the cart: the assistant proposes the week's dinners from what is in
// the kitchen and what is on sale, and an accepted plan becomes items in the household cart
// (cart.js), each once. Placing the order stays the one-tap send (send-tool.js).
//
// What is in the kitchen is the household note's (notes.js): any topic about the kitchen, the
// pantry, the fridge or the freezer, one line for each thing. What is on sale is what the
// assistant found for the family's store this week, said beside each ingredient. The plan
// itself is the assistant's; what is here is the arithmetic a model gets wrong: which
// ingredients the kitchen already has, the same ingredient across dinners bought once with
// its quantities added, and nothing put in the cart that is already there, by name.
//
// A proposed plan is kept on this gateway, in its own SQLite file beside the room, until it
// is accepted, once, or until it is two weeks old. Only what it puts in the cart crosses, as
// the cart's own steps.

import { randomBytes } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

export const MAX_DINNERS = 7;
export const MAX_INGREDIENTS = 15;
export const MAX_NAME = 120;
export const MAX_SALE = 60;
export const KITCHEN = /\b(kitchen|pantry|fridge|freezer)\b/i;
const MAX_QUANTITY = 99;
const PLAN_DAYS = 14;
const DAY_MS = 86_400_000;
const PLAN_ID = /^mp-[0-9a-f]{8}$/;
// Counts and measures in front of a name, which say how much and not what.
const MEASURES = new Set(["lb", "lbs", "oz", "g", "kg", "pound", "pounds", "ounce", "ounces", "can", "cans", "bag", "bags", "box", "boxes", "bunch", "pack", "package", "jar", "bottle", "dozen", "of"]);

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS plans (id TEXT PRIMARY KEY, at INTEGER NOT NULL, body TEXT NOT NULL, accepted_at INTEGER);
`;

export class MealError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const oneLine = (value) => (typeof value === "string" ? value.replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/g, " ").trim() : "");

// One word as a shopping list means it: lowercase, and one of a plural, so "Tomatoes" and
// "tomato" are the same thing and "berries" is "berry". Words that end in s by themselves
// ("asparagus", "hummus", "swiss") stay as they are.
function singular(word) {
  if (word.length <= 3 || /(ss|us|is)$/.test(word)) return word;
  if (word.endsWith("ies")) return `${word.slice(0, -3)}y`;
  if (/(oes|ches|shes|xes|zes)$/.test(word)) return word.slice(0, -2);
  return word.endsWith("s") ? word.slice(0, -1) : word;
}

// What a name means for "is it the same thing": its words, each singular, with any count or
// measure in front left out, so "2 lb ground beef" and "Ground beef" are one item.
export function itemKey(name) {
  const words = oneLine(name).toLowerCase().match(/[\p{L}]+/gu) ?? [];
  return words.filter((word) => !MEASURES.has(word)).map(singular).join(" ");
}

export function createMeals({ file, now = Date.now, newId = () => randomBytes(4).toString("hex") }) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
  db.exec(SCHEMA);
  const statements = {
    keep: db.prepare("INSERT INTO plans (id, at, body) VALUES (?, ?, ?)"),
    one: db.prepare("SELECT * FROM plans WHERE id = ?"),
    accept: db.prepare("UPDATE plans SET accepted_at = ? WHERE id = ? AND accepted_at IS NULL"),
    old: db.prepare("DELETE FROM plans WHERE at < ?"),
  };

  function cleanDinners(dinners) {
    if (!Array.isArray(dinners) || dinners.length === 0 || dinners.length > MAX_DINNERS) {
      throw new MealError("invalid_plan", `A plan is one to ${MAX_DINNERS} dinners.`);
    }
    return dinners.map((dinner) => {
      const name = oneLine(dinner?.name);
      const day = oneLine(dinner?.day);
      const ingredients = dinner?.ingredients;
      if (!name || name.length > MAX_NAME || day.length > 20) throw new MealError("invalid_plan", `Each dinner has a name of at most ${MAX_NAME} characters.`);
      if (!Array.isArray(ingredients) || ingredients.length === 0 || ingredients.length > MAX_INGREDIENTS) {
        throw new MealError("invalid_plan", `Each dinner lists one to ${MAX_INGREDIENTS} ingredients.`);
      }
      return {
        name,
        ...(day ? { day } : {}),
        ingredients: ingredients.map((ingredient) => {
          const words = oneLine(ingredient?.name);
          const quantity = ingredient?.quantity ?? 1;
          const sale = oneLine(ingredient?.sale);
          if (!words || words.length > MAX_NAME || !itemKey(words)) throw new MealError("invalid_plan", `Each ingredient has a name of at most ${MAX_NAME} characters.`);
          if (!Number.isInteger(quantity) || quantity < 1 || quantity > MAX_QUANTITY) throw new MealError("invalid_plan", `A quantity is from 1 to ${MAX_QUANTITY}.`);
          if (sale.length > MAX_SALE) throw new MealError("invalid_plan", `What a sale is, in at most ${MAX_SALE} characters.`);
          return { name: words, quantity, ...(sale ? { sale } : {}) };
        }),
      };
    });
  }

  // What to buy for `dinners`: each ingredient once, by what it means, its quantities added,
  // the first name it was given kept, and set apart what the kitchen has and what the cart has.
  function shopping(dinners, { kitchen, cart }) {
    // The same thing by name, never a part of one: "rice" in the kitchen is no "rice vinegar".
    const kitchenKeys = new Set(kitchen.map(itemKey));
    const cartKeys = new Set(cart.map(itemKey));
    const byKey = new Map();
    for (const ingredient of dinners.flatMap((dinner) => dinner.ingredients)) {
      const key = itemKey(ingredient.name);
      const found = byKey.get(key);
      if (found) found.quantity = Math.min(MAX_QUANTITY, found.quantity + ingredient.quantity);
      else byKey.set(key, { key, name: ingredient.name, quantity: ingredient.quantity });
    }
    const have = [];
    const inCart = [];
    const buy = [];
    for (const item of byKey.values()) {
      if (kitchenKeys.has(item.key)) have.push(item.name);
      else if (cartKeys.has(item.key)) inCart.push(item.name);
      else buy.push({ name: item.name, quantity: item.quantity });
    }
    return { buy, have, inCart };
  }

  function card(dinners) {
    const onSale = (dinner) => dinner.ingredients.filter((ingredient) => ingredient.sale).map((ingredient) => `${ingredient.name} (${ingredient.sale})`).join(", ");
    return {
      type: "table",
      title: "Dinners this week",
      columns: ["Day", "Dinner", "On sale"],
      rows: dinners.map((dinner, index) => [dinner.day ?? `Night ${index + 1}`, dinner.name, onSale(dinner) || "-"]),
      skill: "lists",
    };
  }

  function plan(id) {
    const row = typeof id === "string" && PLAN_ID.test(id) ? statements.one.get(id) : undefined;
    if (!row || now() - Number(row.at) > PLAN_DAYS * DAY_MS) throw new MealError("unknown_plan", "That plan is not kept any more. Propose the week's dinners again.");
    return row;
  }

  return {
    // The week's dinners as the assistant proposes them, kept for its accept, with what they
    // need from the store, what the kitchen and the cart already have, and the card to send.
    propose({ dinners, kitchen, cart }) {
      const cleaned = cleanDinners(dinners);
      statements.old.run(now() - PLAN_DAYS * DAY_MS);
      const id = `mp-${newId()}`;
      statements.keep.run(id, now(), JSON.stringify({ dinners: cleaned }));
      return { plan: id, ...shopping(cleaned, { kitchen, cart }), card: card(cleaned) };
    },

    // An accepted plan's items to put in the cart now, against the kitchen and the cart as they
    // stand, once: a plan accepted already puts nothing in again. `room` is how many more items
    // the cart takes; a plan that needs more is refused whole and stays unaccepted.
    accept(id, { kitchen, cart, room }) {
      const row = plan(id);
      if (row.accepted_at !== null) throw new MealError("already_accepted", "That plan's items are in the cart already.");
      const needed = shopping(JSON.parse(row.body).dinners, { kitchen, cart });
      if (needed.buy.length > room) {
        throw new MealError("cart_full", `The plan needs ${needed.buy.length} more items and the cart has room for ${room}. Check out or remove some first.`);
      }
      statements.accept.run(now(), row.id);
      return needed;
    },

    close() {
      db.close();
    },
  };
}
