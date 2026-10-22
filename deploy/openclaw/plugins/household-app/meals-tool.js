// household_meals: the meal plan that builds the household cart (meals.js), in the owner's
// own thread and the family room (turn.js), and nowhere else, like the cart itself. The
// assistant proposes the week's dinners; once someone says yes, `accept` puts what they need
// in the cart, each item once and nothing the kitchen or the cart already has. Placing the
// order stays household_send's one tap.

import { CartError, MAX_OPEN_ITEMS } from "./cart.js";
import { KITCHEN, MAX_DINNERS, MAX_INGREDIENTS, MAX_NAME, MAX_SALE, MealError } from "./meals.js";
import { turnOf } from "./turn.js";

export const MEALS_TOOL = "household_meals";
const ACTIONS = { propose: ["dinners"], accept: ["plan"] };

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

const failure = (code, message) => result({ code, message }, true);

const INGREDIENT = {
  type: "object",
  additionalProperties: false,
  required: ["name"],
  properties: {
    name: { type: "string", minLength: 1, maxLength: MAX_NAME, description: "The ingredient as it goes on a shopping list, in the kitchen's own words when the kitchen has it." },
    quantity: { type: "integer", minimum: 1, maximum: 99 },
    sale: { type: "string", minLength: 1, maxLength: MAX_SALE, description: "Only when it is on sale this week: the deal, such as \"2 for $5\"." },
  },
};

export function createMealsTool({ context, owner, people, meals, notes, cart }) {
  const turn = turnOf(context, { owner, people: people.map((person) => person.id) });
  if (turn === null) return null;
  const kitchen = () => notes.thingsIn(KITCHEN);
  const inCart = () => cart.card().items.map((item) => item.name);
  return {
    name: MEALS_TOOL,
    label: "Meal plan",
    description:
      "The week's dinners, planned from what is in the kitchen and what is on sale, and turned into the household cart. " +
      "What is in the kitchen is the household note's kitchen topic, such as \"In the kitchen\", one line per thing: keep it there as people say what they have or used up. " +
      "What is on sale: look up this week's deals at the family's usual store before proposing, and favour them. " +
      `\`propose\` takes up to ${MAX_DINNERS} dinners, each with its day and its ingredients (up to ${MAX_INGREDIENTS}), an ingredient's \`sale\` when it is on sale. ` +
      "The answer says what the kitchen already has (`have`), what is already in the cart (`inCart`), what would be bought (`buy`, each item once with its quantities added), " +
      "and `card`, a table card of the dinners to send as a steward-card with a short word on what to buy. Ask whether to go ahead. " +
      "Only once someone says yes, `accept` with the plan's id puts the `buy` items in the cart, each once, and answers the cart card to send. " +
      "Placing the order is never yours: it stays household_send's one tap for the owner.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: Object.keys(ACTIONS) },
        dinners: {
          type: "array",
          minItems: 1,
          maxItems: MAX_DINNERS,
          items: {
            type: "object",
            additionalProperties: false,
            required: ["name", "ingredients"],
            properties: {
              day: { type: "string", maxLength: 20, description: "Which night, such as \"Mon\"." },
              name: { type: "string", minLength: 1, maxLength: MAX_NAME },
              ingredients: { type: "array", minItems: 1, maxItems: MAX_INGREDIENTS, items: INGREDIENT },
            },
          },
        },
        plan: { type: "string", description: "The plan's id, such as mp-1a2b3c4d, from `propose`." },
      },
    },
    async execute(_id, args) {
      const allowed = typeof args?.action === "string" && Object.hasOwn(ACTIONS, args.action) ? ACTIONS[args.action] : null;
      if (!allowed || Object.keys(args).some((key) => key !== "action" && !allowed.includes(key))) {
        return failure("invalid_arguments", `Use one action of ${Object.keys(ACTIONS).join(", ")}, with only its own fields.`);
      }
      try {
        if (args.action === "propose") return result(meals.propose({ dinners: args.dinners, kitchen: kitchen(), cart: inCart() }));
        const items = inCart();
        const { buy, have, inCart: already } = meals.accept(args.plan, { kitchen: kitchen(), cart: items, room: MAX_OPEN_ITEMS - items.length });
        for (const item of buy) cart.add({ name: item.name, quantity: item.quantity, forPerson: turn.sender });
        return result({
          logged: `${buy.length} ${buy.length === 1 ? "item" : "items"} in the cart`,
          ...(have.length > 0 ? { have } : {}),
          ...(already.length > 0 ? { inCart: already } : {}),
          cart: cart.card(),
        });
      } catch (error) {
        if (error instanceof MealError || error instanceof CartError) return failure(error.code, error.message);
        throw error;
      }
    },
  };
}
