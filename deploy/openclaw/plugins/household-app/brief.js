// The assistant's one line for the day, above the pins on Chats in the phones from before
// the Today card: household_brief, the tool it writes it with, and today's brief for
// household-app.brief. Each Today card writes one beside it too (today.js).
//
// The tool is offered in the main agent's own turns only: the owner's own thread in the
// app, a family-room turn the owner started (turn.js isOwnersTurn), the owner's private
// chat on Telegram, and a scheduled run. Never in anyone else's family-room turn or a
// Telegram group: the line comes from the owner's own calendar and shows on the owner's
// phones alone.
//
// Only today's is kept, in the plugin's own store, and a new one replaces it. Today is
// the gateway's, so after midnight there is none until the next is written.

import { dayOf } from "./settings-store.js";
import { isOwnersTurn, turnOf } from "./turn.js";

export const BRIEF_TOOL = "household_brief";
export const MAX_BRIEF_CHARACTERS = 140;
const KEY = "brief";
// An isolated scheduled run of the main agent: its job's session, or one run of it.
const SCHEDULED_RUN = /^agent:main:cron:[^:]+(?::run:[^:]+)?$/;
const TELEGRAM_USER = /^(?:telegram:)?([1-9]\d*)$/;
// A line break, a tab or any other control character: the phone draws one plain line.
const NOT_ONE_LINE = /[\p{Cc}\p{Zl}\p{Zp}]/u;

// `changed` is told each new brief, for the phones that follow.
export function createBrief({ store, now = Date.now, changed = () => {} }) {
  return {
    today() {
      const kept = store.value(KEY);
      const brief = kept === null ? null : JSON.parse(kept);
      return brief?.day === dayOf(now()) ? brief : null;
    },

    write(text) {
      const at = now();
      const brief = { text, day: dayOf(at), at };
      store.setValue(KEY, JSON.stringify(brief));
      changed(brief);
      return brief;
    },
  };
}

// The words as the phone shows them, trimmed, or null when they are not one short line.
function cleanText(text) {
  if (typeof text !== "string") return null;
  const trimmed = text.trim();
  const characters = [...trimmed].length;
  return characters > 0 && characters <= MAX_BRIEF_CHARACTERS && !NOT_ONE_LINE.test(trimmed) ? trimmed : null;
}

const telegramId = (value) => (typeof value === "string" ? TELEGRAM_USER.exec(value)?.[1] : undefined);

// The owner's private chat with this assistant on Telegram: the sender is the chat, the
// session is that chat's own, and the gateway names that sender as its owner.
function isOwnersTelegramChat(context, owners) {
  const delivery = context.deliveryContext;
  if (context.agentAccountId !== "default" || context.messageChannel !== "telegram") return false;
  if (delivery?.channel !== "telegram" || delivery.accountId !== "default" || delivery.threadId != null) return false;
  const sender = telegramId(context.requesterSenderId);
  const to = telegramId(delivery.to);
  // A queued turn can omit the native chat; when both are present they must agree.
  const chat = context.nativeChannelId === undefined ? to : telegramId(context.nativeChannelId);
  return (
    sender !== undefined && sender === to && chat === to &&
    context.sessionKey === `agent:main:telegram:direct:${sender}` &&
    Array.isArray(owners) && owners.includes(`telegram:${sender}`)
  );
}

// A scheduled run names no sender; one that does is somebody's turn.
function isScheduledRun(context) {
  return (
    SCHEDULED_RUN.test(context.sessionKey ?? "") && context.requesterSenderId == null &&
    (context.agentAccountId === undefined || context.agentAccountId === "default")
  );
}

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

// Whether this is one of the owner's own turns: their thread in the app, a family-room
// turn they started, their private chat on Telegram, or a scheduled run. `owners` is the
// gateway's `commands.ownerAllowFrom`.
export function isOwnTurn({ context, owner, owners }) {
  if (context?.agentId !== "main" || context.oneShotCliRun === true) return false;
  return isOwnersTurn(turnOf(context, { owner, people: [owner] })) ||
    isOwnersTelegramChat(context, owners) || isScheduledRun(context);
}

// The tool for this turn, or null.
export function createBriefTool({ context, owner, owners, write }) {
  if (!isOwnTurn({ context, owner, owners })) return null;
  return {
    name: BRIEF_TOOL,
    label: "Today's brief",
    description:
      "Writes today's brief: the one line the owner sees above their conversations in the Steward AI app, such " +
      `as "Dentist at 3:30. Soccer pickup at 5:45." One or two short sentences, at most ${MAX_BRIEF_CHARACTERS} ` +
      "characters, plain text on one line with no Markdown, the most important thing first. Write it from today's " +
      "calendar, reminders and what you know of the day. A new brief replaces today's, and it is gone at midnight. " +
      "It is shown in the app and messages nobody.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["text"],
      properties: {
        text: { type: "string", minLength: 1, maxLength: MAX_BRIEF_CHARACTERS, description: "Today's brief, one plain line." },
      },
    },
    async execute(_id, args) {
      const text = Object.keys(args ?? {}).every((key) => key === "text") ? cleanText(args?.text) : null;
      if (text === null) {
        return result({
          code: "invalid_arguments",
          message: `Give only \`text\`: one or two short sentences of plain text on one line, at most ${MAX_BRIEF_CHARACTERS} characters.`,
        }, true);
      }
      return result({ brief: write(text) });
    },
  };
}
