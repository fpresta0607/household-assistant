// household_note: the household note (notes.js) for the assistant, in the owner's own thread
// and the family room (turn.js), and nowhere else. A line is down for whoever asked. Every
// app turn already starts with the note, the other assistant's handed-over turns included,
// so this is only for writing it and for reading a topic the start of a turn left out.

import { NOTE_TOOL, NoteError } from "./notes.js";
import { turnOf } from "./turn.js";

const ACTIONS = {
  view: ["topic"],
  add: ["topic", "text"],
  correct: ["line", "topic", "text"],
  remove: ["line"],
};

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

const failure = (code, message) => result({ code, message }, true);

export function createNoteTool({ context, owner, people, notes, peerAssistantName }) {
  const turn = turnOf(context, { owner, people });
  if (turn === null) return null;
  return {
    name: NOTE_TOOL,
    label: "Household note",
    description:
      `The household note: what the family keeps track of together, such as kitten weights, dates and lists, which ${notes.readers} ` +
      `all read in every chat of the app. Add a line whenever someone asks you to save, track, note or keep something for the family, ` +
      `or to tell ${peerAssistantName} something, so it is never only a message: ${peerAssistantName} sees it at the start of each turn. ` +
      "Keep one topic for one thing, such as \"Kitten weights\", and add a line for each new fact under it, with its day or time when it has one. " +
      "In your own person's chats a turn starts with only the lines you kept for them there, and counts the rest: `view` them when they matter. " +
      "`correct` changes a line by its id when someone says it is wrong, `remove` takes out one that no longer matters, and `view` shows a topic, " +
      "or every topic. Both people read everything here, so never write anyone's private things, such as money, mail or health, unless they ask you to share them.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: Object.keys(ACTIONS) },
        topic: { type: "string", minLength: 1, maxLength: 60, description: "What the line is about, in a few words, the same each time." },
        text: { type: "string", minLength: 1, maxLength: 500, description: "One fact, as it should read." },
        line: { type: "string", description: "A line's id, such as hn-1a2b3c4d, from the note." },
      },
    },
    async execute(_id, args) {
      const allowed = typeof args?.action === "string" && Object.hasOwn(ACTIONS, args.action) ? ACTIONS[args.action] : null;
      if (!allowed || Object.keys(args).some((key) => key !== "action" && !allowed.includes(key))) {
        return failure("invalid_arguments", `Use one action of ${Object.keys(ACTIONS).join(", ")}, with only its own fields.`);
      }
      try {
        if (args.action === "view") return result(notes.view(args.topic));
        if (args.action === "add") return result(notes.add({ topic: args.topic, text: args.text, forWho: turn.sender }));
        if (args.action === "correct") {
          if (args.topic === undefined && args.text === undefined) return failure("invalid_arguments", "Give the line's new text, its new topic or both.");
          return result(notes.correct(args.line, { topic: args.topic, text: args.text, forWho: turn.sender }));
        }
        return result(notes.remove(args.line));
      } catch (error) {
        if (error instanceof NoteError) return failure(error.code, error.message);
        throw error;
      }
    },
  };
}
