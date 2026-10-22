// A reminder by place that would watch somebody else: "tell me when Gia leaves work". It
// runs on that person's own iPhone, which watches the place, and only once they said yes.
//
// The asking assistant writes a `place-reminder` card naming the person in the family
// room. The person's phone answers it, yes or no, signed with its device key like a
// message, and the answer is one entry per person and card, the newest kept, which the
// relay carries to the other gateway like a reaction. The place itself never comes back:
// the phone that watches it tells the room only when the person arrives or leaves, as a
// reply to the card, signed like any message.

import { cardsIn } from "./card-blocks.js";
import { RoomError } from "./room-error.js";

export const PLACE_VERSION = "household-app/place/v1";
const ANSWERS = new Set(["yes", "no"]);
// How far an answer's signing time may be from the gateway's clock, as for a message.
const SIGNED_WITHIN_MS = 5 * 60_000;
const ID = /^[A-Za-z0-9][A-Za-z0-9-]{7,79}$/;

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

// The exact text the phone signs.
export function placeAnswerText({ messageId, answer, at }) {
  return [PLACE_VERSION, messageId, answer, at].join("\n");
}

// The fields a phone may send, checked and nothing else kept. `now` is null for an answer
// the relay carried, which may arrive late.
export function cleanPlaceAnswer(params, now) {
  const { messageId, answer, at } = params ?? {};
  if (typeof messageId !== "string" || !ID.test(messageId)) refuse("bad card id");
  if (!ANSWERS.has(answer)) refuse("an answer is yes or no");
  if (!Number.isSafeInteger(at) || (now !== null && Math.abs(at - now) > SIGNED_WITHIN_MS)) refuse("answer time out of range");
  return { messageId, answer, at };
}

// Whether a message carries a place-reminder card that would watch `person`, named by
// their id or their name in any case.
export function asksFor(text, person) {
  const names = new Set([person.id, person.name].map((name) => name.toLowerCase()));
  return cardsIn(text).some((card) =>
    card.type === "place-reminder" && typeof card.for === "string" && names.has(card.for.trim().toLowerCase()));
}
