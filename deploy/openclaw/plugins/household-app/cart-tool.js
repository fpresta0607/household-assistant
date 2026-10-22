// household_cart: the household's shared cart for the assistant, in the owner's own thread
// and the family room (turn.js), and nowhere else. An item is down for whoever asked. An
// order's progress comes from the owner's own mailbox, so only the owner's own turns record
// it: their thread, and a family-room turn they started.

import { CART_TOOL, CartError } from "./cart.js";
import { isOwnersTurn, turnOf } from "./turn.js";

const ACTIONS = {
  view: [],
  add: ["name", "url", "quantity", "list"],
  remove: ["item"],
  quantity: ["item", "quantity"],
  order: ["order", "items", "status", "at", "arriving"],
};

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

const failure = (code, message) => result({ code, message }, true);
// A list said in one breath, such as the week's groceries.
const MAX_LIST = 30;

export function createCartTool({ context, owner, people, cart }) {
  const turn = turnOf(context, { owner, people: people.map((person) => person.id) });
  if (turn === null) return null;
  return {
    name: CART_TOOL,
    label: "Household cart",
    description:
      "The household's one shared shopping cart, which Corey and Denise both add to and Franco and Gia both see. " +
      "`view` shows it, `add` puts an item down for whoever asked, or with `list` a whole list at once, such as groceries said in a voice note, " +
      "and `quantity` and `remove` change one by its id. " +
      "Give `url` only as a full amazon.com product link with /dp/ in it, from the person, a share or a web search, " +
      "and never open Amazon yourself. Every answer has `cart`, a ready cart card: in the app, send it as a " +
      "steward-card after any change. Its checkout link fills the buyer's own Amazon cart, and the buyer pays there. " +
      "`order` is for the owner's own thread only: what an Amazon email said about an order, with its number, its " +
      "status, the email's time as `at`, the expected day as `arriving`, and, the first time, the cart items it took.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: Object.keys(ACTIONS) },
        name: { type: "string", minLength: 1, maxLength: 120, description: "What to buy, in a few words." },
        url: { type: "string", maxLength: 500, description: "A full amazon.com product link." },
        quantity: { type: "integer", minimum: 1, maximum: 99 },
        list: {
          type: "array",
          minItems: 1,
          maxItems: MAX_LIST,
          description: "Several items to add at once, each with its name and, when more than one, its quantity.",
          items: {
            type: "object",
            additionalProperties: false,
            required: ["name"],
            properties: { name: { type: "string", minLength: 1, maxLength: 120 }, quantity: { type: "integer", minimum: 1, maximum: 99 } },
          },
        },
        item: { type: "string", description: "A cart item's id, from the cart." },
        items: { type: "array", maxItems: 40, items: { type: "string" }, description: "The cart items' ids a new order took." },
        status: { type: "string", enum: ["ordered", "shipped", "out_for_delivery", "delivered"] },
        order: { type: "string", description: "The Amazon order number, such as 113-1234567-1234567." },
        at: { type: "string", description: "When the email said it happened, with its offset." },
        arriving: { type: "string", description: "The expected delivery day, such as 2026-10-16." },
      },
    },
    async execute(_id, args) {
      const allowed = typeof args?.action === "string" && Object.hasOwn(ACTIONS, args.action) ? ACTIONS[args.action] : null;
      if (!allowed || Object.keys(args).some((key) => key !== "action" && !allowed.includes(key))) {
        return failure("invalid_arguments", `Use one action of ${Object.keys(ACTIONS).join(", ")}, with only its own fields.`);
      }
      if (args.action === "order" && !isOwnersTurn(turn)) {
        return failure("owner_thread_only", "Orders are recorded in the owner's own thread, from the owner's own mail.");
      }
      try {
        if (args.action === "add" && args.list !== undefined) {
          if (args.name !== undefined || args.url !== undefined || args.quantity !== undefined || !Array.isArray(args.list) || args.list.length > MAX_LIST) {
            return failure("invalid_arguments", `Give either one item or a list of at most ${MAX_LIST}, not both.`);
          }
          const added = args.list.map((each) => cart.add({ name: each?.name, quantity: each?.quantity, forPerson: turn.sender }));
          return result({ logged: `${added.length} ${added.length === 1 ? "item" : "items"} in the cart`, cart: cart.card() });
        }
        if (args.action === "add") cart.add({ name: args.name, url: args.url, quantity: args.quantity, forPerson: turn.sender });
        else if (args.action === "remove") cart.remove(args.item);
        else if (args.action === "quantity") cart.setQuantity(args.item, args.quantity);
        else if (args.action === "order") {
          const order = cart.markOrder({ order: args.order, items: args.items, status: args.status, at: args.at, arriving: args.arriving });
          return result({ order, cart: cart.card() });
        }
        return result({ cart: cart.card() });
      } catch (error) {
        if (error instanceof CartError) return failure(error.code, error.message);
        throw error;
      }
    },
  };
}
