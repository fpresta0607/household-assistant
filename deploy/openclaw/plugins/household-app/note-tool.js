// household_note: the household note (notes.js) for the assistant, in the owner's own thread
// and the family room (turn.js), and nowhere else. A line is down for whoever asked. Every
// app turn already starts with the note, the other assistant's handed-over turns included,
// so this is only for writing it and for reading what the start of a turn left out.

import { MAX_ITEM, MAX_ROWS, MAX_TEXT, MAX_TOPIC, NOTE_TOOL, NoteError, REPEATS } from "./notes.js";
import { turnOf } from "./turn.js";

const ROW_FIELDS = ["text", "item", "day", "due", "owner"];
const ACTIONS = {
  view: ["topic"],
  due: [],
  add: ["topic", ...ROW_FIELDS, "rows"],
  promise: ["topic", "text", "due", "owner"],
  hand: ["topic", "text", "due"],
  remind: ["topic", "text", "due", "time", "every"],
  correct: ["line", "topic", ...ROW_FIELDS],
  done: ["line"],
  remove: ["line"],
};
// Where a promise, and a handoff, go when they name no topic of their own.
const PROMISES = "Promises";
const HANDOFFS = "Handoffs";
const REMINDERS = "Reminders";

const DATE = { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$" };
const ROW = {
  text: { type: "string", minLength: 1, maxLength: MAX_TEXT, description: "One fact or one row's value, as it should read, such as \"212 g\"." },
  item: { type: "string", minLength: 1, maxLength: MAX_ITEM, description: "Who or what a row is about, such as a kitten's name." },
  day: { ...DATE, description: "The day it happened or was measured, YYYY-MM-DD, when that is not today." },
  due: { ...DATE, description: "The day it is due, YYYY-MM-DD, for a dose, a visit, a deadline or a promise." },
  owner: { type: "string", minLength: 1, maxLength: 40, description: "Who will do it, by name: you, the other assistant, or one of the people. It makes the line a promise." },
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
      `The household note: the family's one shared record, which ${notes.readers} all read in every chat of the app, ` +
      `and which you and ${peerAssistantName} both write. It is where anything the family tracks or must agree on goes, and nowhere else: ` +
      "never keep family data in a file or tracker of your own, and when you find one, move what it holds here. " +
      "A log is one topic, such as \"Kitten weights\", with one row per item: `add` with `rows` takes a whole weigh-in at once, " +
      "each row's `item` (the kitten) and `text` (\"212 g\"), with `day` when it was not today. " +
      "Something due, such as a deworming dose, first shots, a vet visit or a deadline, is a line with `due`; `done` marks it done, and `due` lists what is overdue and due within a week. " +
      `Facts both of you must know, such as dates, church times or a code the family shares on purpose, are lines too. Anything you are asked to tell ${peerAssistantName} goes here, so it is never only a message. ` +
      `\`hand\` is your direct line to ${peerAssistantName}: it hands them a question or a piece of work without a word in the family room, their side marks it seen at once and answers it in a turn of their own, ` +
      `and every turn of yours shows whether it was seen and what they answered. Both people can watch that line in the app, so hand over only what the family shares, never anyone's private things. ` +
      "`remind` sets a reminder the family asked for, such as \"remind us every Saturday at 4:40\": its words, the day it next goes off as `due`, its `time` and how often it repeats (`every`). " +
      `Your own gateway posts those words in the family room when it comes due, every time, and ${peerAssistantName} sees it in every turn. A reminder for one person alone stays one of your automations. ` +
      "Whatever someone asks for in passing that is not done in this turn is a `promise`, with who will do it (`owner`, you unless they said otherwise) and `due` when it has a date; " +
      "every turn starts with the promises still open, so a restart drops nothing, and `done` closes one as soon as it is done. " +
      "In your own person's chats a turn starts with only the lines you kept for them there, and counts the rest: `view` them when they matter. " +
      "`correct` changes a line by its id when someone says it is wrong, `remove` takes out one that no longer matters, and `view` shows a topic, " +
      "or every topic. Both people read everything here, so never write anyone's private things, such as money, mail or health, unless they ask you to share them.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: Object.keys(ACTIONS) },
        topic: { type: "string", minLength: 1, maxLength: MAX_TOPIC, description: "What the line is about, in a few words, the same each time." },
        ...ROW,
        rows: {
          type: "array",
          minItems: 1,
          maxItems: MAX_ROWS,
          description: "Several rows under one topic at once, such as each kitten's weight from one weigh-in.",
          items: { type: "object", additionalProperties: false, required: ["text"], properties: ROW },
        },
        line: { type: "string", description: "A line's id, such as hn-1a2b3c4d, from the note." },
        time: { type: "string", pattern: "^([01]\\d|2[0-3]):[0-5]\\d$", description: "When a reminder goes off, HH:MM on a 24-hour clock, in the family's time." },
        every: { type: "string", enum: REPEATS, description: "How often a reminder repeats; leave it out for once." },
      },
    },
    async execute(_id, args) {
      const allowed = typeof args?.action === "string" && Object.hasOwn(ACTIONS, args.action) ? ACTIONS[args.action] : null;
      if (!allowed || Object.keys(args).some((key) => key !== "action" && !allowed.includes(key))) {
        return failure("invalid_arguments", `Use one action of ${Object.keys(ACTIONS).join(", ")}, with only its own fields.`);
      }
      // An owner by name, as the model writes it, is kept by id.
      const ownerOf = (value) => (value === undefined ? undefined : notes.whoIs(value) ?? value);
      const row = { text: args.text, item: args.item, day: args.day, due: args.due, owner: ownerOf(args.owner) };
      try {
        if (args.action === "view") return result(notes.view(args.topic));
        if (args.action === "due") return result(notes.due());
        if (args.action === "add") {
          if (args.rows !== undefined && ROW_FIELDS.some((field) => args[field] !== undefined)) {
            return failure("invalid_arguments", "Give either one line's fields or rows, not both.");
          }
          const rows = args.rows?.map((each) => ({ ...each, owner: ownerOf(each.owner) }));
          return result(notes.add({ topic: args.topic, ...(rows === undefined ? row : { rows }), forWho: turn.sender }));
        }
        if (args.action === "promise") {
          return result(notes.add({ topic: args.topic ?? PROMISES, ...row, owner: row.owner ?? notes.self, forWho: turn.sender }));
        }
        if (args.action === "remind") {
          const remind = { at: args.time, ...(args.every === undefined ? {} : { every: args.every }) };
          return result(notes.add({ topic: args.topic ?? REMINDERS, text: args.text, due: args.due, owner: notes.self, remind, forWho: turn.sender }));
        }
        if (args.action === "hand") {
          return result(notes.add({ topic: args.topic ?? HANDOFFS, ...row, owner: notes.peer, forWho: turn.sender }));
        }
        if (args.action === "correct") {
          if (args.topic === undefined && ROW_FIELDS.every((field) => args[field] === undefined)) {
            return failure("invalid_arguments", "Give what the line should now say: its text, item, day, due date or topic.");
          }
          return result(notes.correct(args.line, { topic: args.topic, ...row, forWho: turn.sender }));
        }
        if (args.action === "done") return result(notes.done(args.line, { forWho: turn.sender }));
        return result(notes.remove(args.line));
      } catch (error) {
        if (error instanceof NoteError) return failure(error.code, error.message);
        throw error;
      }
    },
  };
}
