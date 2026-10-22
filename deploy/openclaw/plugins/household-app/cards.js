// The assistants' cards: a chart, a table, a checklist and the rest, each one JSON object
// in a fenced block marked `steward-card` inside an ordinary reply. The app draws them;
// see deploy/openclaw/skills/steward-cards/SKILL.md for the format the assistants write.
//
// A tick on a checklist in the app is kept for the assistant's next turn in that
// conversation, so its list stays in step with what the family ticked. The item is read
// from the assistant's own message rather than taken from the phone.
//
// Ordered on the household cart's card is whoever checked out saying they did. The items
// are again read from the assistant's own message, and only those still in the cart are
// ordered. The gateway answers at once, with no turn: the conversation gets the cart as it
// now stands, and the owner's own thread gets the order.

import { CLOSING, OPENING, cardsIn } from "./card-blocks.js";
import { CART_ID, CartError } from "./cart.js";
import { CONVERSATIONS, RoomError } from "./room.js";

const MAX_CARD_ID = 80;
const APP_SESSION = "agent:main:household:";

// OpenClaw's dashboard tool draws a widget on the operator's dashboard, which neither the
// app nor anyone in the family sees. On 17 October Denise answered "put them in a chart"
// with one, so in an app turn the call is refused with what to send instead.
export const DASHBOARD_TOOL = "dashboard";

export function refuseDashboardInApp(context) {
  if (typeof context?.sessionKey !== "string" || !context.sessionKey.startsWith(APP_SESSION)) return undefined;
  return {
    block: true,
    blockReason: "The Steward app cannot show dashboard widgets, so nobody would see this. " +
      "Put a chart in your reply as a steward-card chart block, and a table as a table card (the steward-cards skill).",
  };
}

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

function isChecklist(card) {
  return card.type === "checklist" && typeof card.id === "string" && card.id.trim() !== "" && card.id.length <= MAX_CARD_ID &&
    (card.title === undefined || typeof card.title === "string") && Array.isArray(card.items) && card.items.length > 0 &&
    card.items.every((item) => typeof item?.text === "string" && typeof item.done === "boolean");
}

// The item ids the household cart's card showed, from the last such card in the text.
function cartItemsIn(text) {
  let found = null;
  for (const card of cardsIn(text)) {
    if (card.type === "cart" && card.id === CART_ID && Array.isArray(card.items)) {
      found = card.items.map((item) => item?.id).filter((id) => typeof id === "string");
    }
  }
  return found;
}

const asBlock = (card) => `${OPENING}\n${JSON.stringify(card)}\n${CLOSING}`;

function checklistIn(text, id) {
  return cardsIn(text).find((card) => isChecklist(card) && card.id === id) ?? null;
}

// `enqueue` is OpenClaw's next-turn injection, which keeps the note on the session until
// that conversation's next turn starts and then adds it to the turn's context.
export function createCardTick({ store, ownerName, assistantIds, sessionKeys, enqueue }) {
  return async function tick(params) {
    const { conversation, messageId, cardId, item, done } = params ?? {};
    if (!CONVERSATIONS.has(conversation)) refuse("unknown conversation");
    if (typeof done !== "boolean") refuse("done must be true or false");
    if (typeof cardId !== "string" || !cardId || cardId.length > MAX_CARD_ID) refuse("bad checklist id");
    if (!Number.isSafeInteger(item) || item < 0) refuse("bad checklist item");
    const message = typeof messageId === "string" ? store.message(messageId) : null;
    if (!message || message.conversation !== conversation) refuse("no such message");
    if (!assistantIds.includes(message.author)) refuse("only an assistant's checklist can be ticked");
    const list = checklistIn(message.text, cardId);
    if (!list) refuse("no such checklist");
    if (item >= list.items.length) refuse("no such checklist item");
    const named = list.title ? `the checklist "${list.title}" (id ${cardId})` : `the checklist ${cardId}`;
    const text = `${ownerName} ${done ? "ticked" : "unticked"} "${list.items[item].text}" on ${named} in the app.`;
    const result = await enqueue({ sessionKey: sessionKeys[conversation], text });
    return { kept: result?.enqueued === true };
  };
}

// `reply` keeps a message as this gateway's assistant's and shows it on the phones.
export function createCartOrdered({ store, cart, assistantIds, reply }) {
  return async function ordered(params) {
    const { conversation, messageId } = params ?? {};
    if (!CONVERSATIONS.has(conversation)) refuse("unknown conversation");
    const message = typeof messageId === "string" ? store.message(messageId) : null;
    if (!message || message.conversation !== conversation) refuse("no such message");
    if (!assistantIds.includes(message.author)) refuse("only an assistant's cart can be marked ordered");
    const ids = cartItemsIn(message.text);
    if (!ids) refuse("no cart on that message");
    let tapped;
    try {
      tapped = cart.tapOrdered(ids);
    } catch (error) {
      if (error instanceof CartError) refuse(error.message);
      throw error;
    }
    const said = tapped.count === 1 ? "Marked 1 item ordered." : `Marked ${tapped.count} items ordered.`;
    const cartBlock = asBlock(cart.card());
    const orderBlock = asBlock(tapped.order);
    if (conversation === "direct") {
      await reply({ conversation, text: `${said}\n\n${orderBlock}\n\n${cartBlock}` });
    } else {
      await reply({ conversation, text: `${said}\n\n${cartBlock}` });
      await reply({ conversation: "direct", text: `${said}\n\n${orderBlock}` });
    }
    return { ordered: tapped.count };
  };
}
