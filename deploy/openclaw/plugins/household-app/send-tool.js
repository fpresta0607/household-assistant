// household_send: a draft the owner sends with one tap. Corey could draft an email but never
// send one, so every message ended with the owner doing the last mile. Now the assistant
// gives the whole draft, an email, a booking request or the household cart's order, and it
// waits as a card in the owner's own thread with where it goes and every word of it, or for
// an order every item, its price and the total. Approve sends it; nothing else does.
//
// The yes is OpenClaw's own plugin approval (approvals.js shows it, and only the owner's
// phone can answer it), asked for in `before_tool_call`, which freezes the call's
// parameters: the approval covers that one draft, and a changed draft is a new call with a
// card of its own. The tool sends only a draft whose own approval said allow-once, and only
// when the draft it is about to send is the one the card showed, by its hash, once.
//
// It is offered only in the owner's own turns (turn.js isOwnersTurn), and an email goes from
// the owner's own Gmail, the account the order mail reader uses. An order cannot be placed
// by anyone but the buyer at Amazon, so its tap hands over the cart's checkout link, with the
// items and the total the owner approved. A model's own `gog gmail send`, or a draft's send,
// is refused everywhere: mail goes out from here, after the tap, or not at all.

import { createHash } from "node:crypto";

import { commandWords, programPath, simpleCommands } from "./approval-asks.js";
import { isOwnersTurn, turnOf } from "./turn.js";

export const SEND_TOOL = "household_send";
const KINDS = ["email", "booking", "order"];
const EMAIL = /^[^\s@<>(),;:"\\[\]]+@[^\s@<>(),;:"\\[\]]+\.[^\s@<>(),;:"\\[\]]+$/;
const MAX_ADDRESS = 254;
const MAX_SUBJECT = 200;
const MAX_BODY = 8000;
const MAX_PRICE_CENTS = 1_000_000;
// What OpenClaw lets a plugin put in an approval's title and description, and its longest wait.
const MAX_TITLE = 80;
const MAX_DESCRIPTION = 512;
const TIMEOUT_MS = 10 * 60_000;
// A draft is forgotten a minute after its approval could last.
const FORGET_MS = TIMEOUT_MS + 60_000;
const MAX_WAITING = 50;

export class SendError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const oneLine = (value) => (typeof value === "string" ? value.replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/g, " ").trim() : "");
const dollars = (cents) => `$${(cents / 100).toFixed(2)}`;

// The draft a call's parameters make, exactly as the card shows it and the send sends it,
// with its hash. `cart` is the household cart, for an order.
export function draftOf(params, { cart }) {
  const kind = params?.kind;
  if (!KINDS.includes(kind)) throw new SendError("invalid_draft", `A draft is one of ${KINDS.join(", ")}.`);
  let draft;
  if (kind === "order") {
    const items = cart.card().items;
    if (items.length === 0) throw new SendError("empty_cart", "The cart is empty, so there is no order to send.");
    const prices = new Map((Array.isArray(params.prices) ? params.prices : []).map((each) => [each?.item, each?.price]));
    const priced = items.map((item) => {
      const cents = Math.round(Number(prices.get(item.id)) * 100);
      if (!Number.isSafeInteger(cents) || cents <= 0 || cents > MAX_PRICE_CENTS) {
        throw new SendError("unpriced", `Give every cart item its price, in dollars, first ${item.id} (${item.name}).`);
      }
      return { name: item.name, quantity: item.quantity, cents };
    });
    const total = priced.reduce((sum, item) => sum + item.quantity * item.cents, 0);
    draft = {
      kind,
      items: priced.map(({ name, quantity, cents }) => ({ name, quantity, price: dollars(cents) })),
      total: dollars(total),
      ...(cart.card().checkout ? { checkout: cart.card().checkout } : {}),
      text: [...priced.map(({ name, quantity, cents }) => `${quantity} × ${name}, ${dollars(cents)} each`), `Total: ${dollars(total)}`].join("\n"),
    };
  } else {
    const to = oneLine(params.to);
    const subject = oneLine(params.subject);
    const body = typeof params.body === "string" ? params.body.replace(/\r\n?/g, "\n").trim() : "";
    if (!EMAIL.test(to) || to.length > MAX_ADDRESS) throw new SendError("invalid_draft", "Give the one email address it goes to.");
    if (!subject || subject.length > MAX_SUBJECT) throw new SendError("invalid_draft", `Give a subject of at most ${MAX_SUBJECT} characters.`);
    if (!body || body.length > MAX_BODY) throw new SendError("invalid_draft", `Give the whole message, at most ${MAX_BODY} characters.`);
    draft = { kind, to, subject, body, text: `To: ${to}\nSubject: ${subject}\n\n${body}` };
  }
  return { ...draft, hash: createHash("sha256").update(JSON.stringify(draft)).digest("hex") };
}

// The card's title, its few words OpenClaw keeps, and the scope it shows.
function approvalOf(draft) {
  if (draft.kind === "order") {
    return {
      title: `Order ${draft.items.length === 1 ? "1 item" : `${draft.items.length} items`}, ${draft.total}`,
      scope: { kind: "payment", amount: draft.total.slice(1), currency: "USD", target: "Amazon" },
    };
  }
  return {
    title: `${draft.kind === "booking" ? "Book" : "Send"}: ${draft.subject}`,
    scope: { kind: "message-send", target: "email", recipientCount: 1, recipients: [draft.to], audience: "external" },
  };
}

// The words a command runs gog's Gmail send with, or a draft's send.
function isGmailSend(words) {
  const [group, first, second] = commandWords(words, ["--account", "-a", "--client", "--home", "--access-token", "--quota-project"]);
  if (group !== "gmail" && group !== "mail" && group !== "email") return false;
  return first === "send" || ((first === "drafts" || first === "draft") && second === "send");
}

// Every send waiting for, or holding, its tap, by the tool call that made it. `deliver(draft,
// signal)` sends one, and answers what to tell the assistant. `canEmail` says whether this
// gateway has a Gmail to send from.
export function createSends({ deliver, cart, canEmail, now = Date.now }) {
  const waiting = new Map();

  function forgetOld() {
    for (const [id, entry] of waiting) if (now() - entry.at > FORGET_MS) waiting.delete(id);
    while (waiting.size > MAX_WAITING) waiting.delete(waiting.keys().next().value);
  }

  return {
    // `before_tool_call` for household_send: a card for the draft, in the owner's own turns
    // alone, and a refusal anywhere else or for a draft that is not one.
    ask(event, context, { ownerSessions }) {
      const toolCallId = event?.toolCallId ?? context?.toolCallId;
      if (!ownerSessions.includes(context?.sessionKey) || typeof toolCallId !== "string") {
        return { block: true, blockReason: "A draft is sent only from the owner's own chat in the Steward app." };
      }
      if (!canEmail && event.params?.kind !== "order") {
        return { block: true, blockReason: "This gateway has no Gmail to send from, so only an order can be sent." };
      }
      let draft;
      try {
        draft = draftOf(event.params, { cart });
      } catch (error) {
        if (error instanceof SendError) return { block: true, blockReason: error.message };
        throw error;
      }
      forgetOld();
      const entry = { draft, at: now(), isApproved: false };
      waiting.set(toolCallId, entry);
      const { title, scope } = approvalOf(draft);
      return {
        requireApproval: {
          title: title.slice(0, MAX_TITLE),
          description: draft.text.slice(0, MAX_DESCRIPTION),
          scope,
          severity: draft.kind === "order" ? "critical" : "warning",
          allowedDecisions: ["allow-once", "deny"],
          timeoutMs: TIMEOUT_MS,
          onResolution: (decision) => {
            entry.isApproved = decision === "allow-once";
          },
        },
      };
    },

    // The whole draft a card shows, by the tool call OpenClaw's approval names.
    draftFor(toolCallId) {
      return waiting.get(toolCallId)?.draft ?? null;
    },

    // The approved draft sent, once.
    async send(toolCallId, params, signal) {
      const entry = waiting.get(toolCallId);
      if (!entry?.isApproved) throw new SendError("not_approved", "Nothing is sent without the owner's tap on its card.");
      const draft = draftOf(params, { cart });
      if (draft.hash !== entry.draft.hash) throw new SendError("changed", "The draft changed after its card, so it needs a new tap.");
      waiting.delete(toolCallId);
      return deliver(draft, signal);
    },
  };
}

// `before_tool_call` for a command, in every session: gog's Gmail send, or a draft's, is
// refused, so mail goes out only after a tap.
export function refuseDirectSend(event) {
  const command = event?.params?.command;
  return typeof command === "string" && sendsMail(command)
    ? { block: true, blockReason: `Mail goes out only through ${SEND_TOOL}, after the owner's tap on its card.` }
    : undefined;
}

// Whether a shell command runs gog's Gmail send: as a command's program, after any variables
// it sets, or inside a shell's -c.
function sendsMail(command) {
  for (const words of simpleCommands(command)) {
    const index = words.findIndex((word) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(word));
    if (index === -1) continue;
    const program = programPath(words[index]).split("/").at(-1);
    if ((program === "gog" || program === "gog-bin") && isGmailSend(words.slice(index + 1))) return true;
    const script = words[index + 1] === "-c" ? words[index + 2] : undefined;
    if (["sh", "bash", "dash", "zsh"].includes(program) && typeof script === "string" && sendsMail(script)) return true;
  }
  return false;
}

function result(payload, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], ...(isError ? { isError } : {}) };
}

export function createSendTool({ context, owner, people, sends, canEmail }) {
  const turn = turnOf(context, { owner, people });
  if (!isOwnersTurn(turn)) return null;
  return {
    name: SEND_TOOL,
    label: "Send it",
    description:
      "Sends a draft once your person taps Approve on its card in their own chat, and never otherwise: an `email`, a `booking` request by email, " +
      "or the household cart's `order`. Give the whole draft in one call, exactly as it should go: the address it goes to, the subject and every word of the message, " +
      "or for an order each cart item's price in dollars, which make the total the card shows. The card shows all of it; " +
      "a changed draft is a new call and a new tap. Never send mail any other way. " +
      (canEmail ? "Email goes from your person's own Gmail. " : "This gateway has no Gmail to send from, so only an order can be sent. ") +
      "An order's tap hands your person Amazon's checkout with the cart filled in, where they pay.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["kind"],
      properties: {
        kind: { type: "string", enum: canEmail ? KINDS : ["order"] },
        to: { type: "string", maxLength: MAX_ADDRESS, description: "The email address it goes to, for an email or a booking." },
        subject: { type: "string", maxLength: MAX_SUBJECT },
        body: { type: "string", maxLength: MAX_BODY, description: "Every word of the message, as it should go." },
        prices: {
          type: "array",
          maxItems: 60,
          description: "For an order: each cart item's id and its price in dollars, from the product's page.",
          items: { type: "object", additionalProperties: false, required: ["item", "price"], properties: { item: { type: "string" }, price: { type: "number" } } },
        },
      },
    },
    async execute(toolCallId, args, signal) {
      try {
        return result(await sends.send(toolCallId, args, signal));
      } catch (error) {
        if (error instanceof SendError) return result({ code: error.code, message: error.message }, true);
        throw error;
      }
    },
  };
}
