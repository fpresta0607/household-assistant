// household_react: a tapback from the assistant on a person's message, the way the people
// react in the app, in the owner's own thread and the family room (turn.js), and nowhere
// else. A family-room turn also gets only The Fam's tool allowlist, so the tool reaches the
// room only once it is on that list.
//
// It reacts only in the conversation its turn is in, only to the owner's or the other
// person's message there, and only with one of the five tapbacks (room.js). In the family
// room the reaction crosses to the other gateway like the owner's own.
//
// The turn already names the messages it can react to: OpenClaw gives the message being
// answered as `message_id` in the turn's conversation info, and each line of the family
// room's history starts with its message's `#id`.

import { RoomError } from "./room-error.js";
import { TAPBACKS } from "./tapbacks.js";
import { turnOf } from "./turn.js";

export const REACT_TOOL = "household_react";
const FIELDS = ["messageId", "emoji"];

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

const failure = (code, message) => result({ code, message }, true);

export function createReactTool({ context, owner, people, room }) {
  const turn = turnOf(context, { owner, people });
  if (turn === null) return null;
  return {
    name: REACT_TOOL,
    label: "React",
    description:
      `React to a person's message with a tapback, the way people do in the app: ${TAPBACKS.join(" ")}. ` +
      "Use it sparingly, only where a person naturally would, such as a heart on good news or a laugh at a joke, " +
      "and never instead of answering: a message that asks for something gets your answer in words. At most one " +
      "tapback on a message, and never on your own or the other assistant's. `messageId` is the id the turn gives " +
      "the message: `message_id` in the conversation info for the one you are answering, or the `#id` that starts " +
      "a line of the chat history. A tapback only shows on the message; it tells nobody anything.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: FIELDS,
      properties: {
        messageId: { type: "string", maxLength: 80, description: "The id of a person's message in this conversation." },
        emoji: { type: "string", enum: TAPBACKS },
      },
    },
    async execute(_id, args) {
      if (!args || typeof args !== "object" || Object.keys(args).some((key) => !FIELDS.includes(key))) {
        return failure("invalid_arguments", "Give only `messageId` and `emoji`.");
      }
      if (!TAPBACKS.includes(args.emoji)) {
        return failure("not_a_tapback", `React with one of ${TAPBACKS.join(" ")}.`);
      }
      try {
        room.reactAsAssistant({ conversation: turn.kind, messageId: args.messageId, emoji: args.emoji });
      } catch (error) {
        if (error instanceof RoomError) return failure("not_reactable", error.message);
        throw error;
      }
      return result({ reacted: args.emoji, messageId: args.messageId });
    },
  };
}
