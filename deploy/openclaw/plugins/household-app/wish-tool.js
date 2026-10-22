// household_wish: the assistant's side of gift and wishlist memory (wishes.js), in the owner's
// own turns only: their thread and their own session of the family room. It keeps a wish
// quietly, where it belongs, and a birthday, and shows only the wishes kept for the owner,
// which are never the owner's own.

import { WishError } from "./wishes.js";
import { isOwnersTurn, turnOf } from "./turn.js";

export const WISH_TOOL = "household_wish";
const ACTIONS = { wish: ["who", "what"], birthday: ["who", "date"], view: [] };

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

export function createWishTool({ context, owner, ownerName, peerName, people, wishes }) {
  if (!isOwnersTurn(turnOf(context, { owner, people }))) return null;
  return {
    name: WISH_TOOL,
    label: "Wishlist",
    description:
      "Gift and wishlist memory. Whenever someone says, even in passing, that they want or would love something, such as a book, a tool or an outing, " +
      "keep it with `wish`: who wants it and what, in their words. Do it quietly: never say you kept it or for whom, and never bring a kept wish up, " +
      `since a gift for ${ownerName} or ${peerName} must never reach that person. The household hands each wish to the right parent three weeks before ` +
      "that person's birthday or Christmas, by itself. `birthday` keeps someone's birthday, MM-DD or YYYY-MM-DD, for both sides. " +
      `\`view\` shows the wishes kept for ${ownerName}, when ${ownerName} asks for gift ideas.`,
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: Object.keys(ACTIONS) },
        who: { type: "string", minLength: 1, maxLength: 40, description: "Whose wish or birthday, by name." },
        what: { type: "string", minLength: 1, maxLength: 200, description: "What they want, in their words." },
        date: { type: "string", pattern: "^(\\d{4}-)?\\d{2}-\\d{2}$" },
      },
    },
    async execute(_id, args) {
      const allowed = typeof args?.action === "string" && Object.hasOwn(ACTIONS, args.action) ? ACTIONS[args.action] : null;
      if (!allowed || Object.keys(args).some((key) => key !== "action" && !allowed.includes(key))) {
        return result({ code: "invalid_arguments", message: `Use one action of ${Object.keys(ACTIONS).join(", ")}, with only its own fields.` }, true);
      }
      try {
        if (args.action === "wish") return result(wishes.wish({ who: args.who, words: args.what }));
        if (args.action === "birthday") return result(wishes.birthday({ who: args.who, date: args.date }));
        return result({ wishes: wishes.view() });
      } catch (error) {
        if (error instanceof WishError) return result({ code: error.code, message: error.message }, true);
        throw error;
      }
    },
  };
}
