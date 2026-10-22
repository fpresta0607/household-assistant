// Which app turn a tool is being offered to, from the runtime's metadata alone, for the
// tools that answer only in the owner's own thread and the family room.
//
// - The owner's own thread in the app. household-app starts that turn only for a message
//   one of the owner's paired phones signed, and names the owner as its sender, which
//   OpenClaw hands tools as the trusted `requesterSenderId`: the proof PocketPiggies takes
//   for the same thread.
// - The family room, for a turn one of the household's two people started there. Their
//   messages are signed too (room.js), and a turn the other assistant's @mention starts
//   names that assistant, so it gets nothing.
// - The owner's own family-room turn (isOwnersTurn), which runs in a session of its own:
//   OpenClaw's per-sender form of the room's, `agent:main:household:group:family:sender:
//   <owner>`. No other sender's turn reads that session's transcript, so what the owner's
//   tools return there never reaches the other person's turn or the other assistant's, and
//   nobody else's message can be steered into a run of it.
//
// Everything else is no turn: Telegram, other sessions, automations and sub-agents, which
// name no sender, and a gateway client's chat.send, which names its own client id.

export const FAMILY = "family";
const FAMILY_SESSION = `agent:main:household:group:${FAMILY}`;

/**
 * The ids OpenClaw 2026.9.4 lets a gateway client connect as (GATEWAY_CLIENT_IDS). chat.send
 * names its sender by that id, so a household person called one of these could be spoken
 * for by any client with write scope, and gets no tool.
 */
const GATEWAY_CLIENT_IDS = new Set([
  "webchat-ui", "openclaw-control-ui", "openclaw-browser-copilot", "openclaw-tui", "webchat", "cli",
  "gateway-client", "openclaw-macos", "openclaw-linux", "openclaw-ios", "openclaw-watchos",
  "openclaw-android", "node-host", "openclaw-worker", "test", "fingerprint", "openclaw-probe",
]);

export function householdId(value) {
  return typeof value === "string"
    ? /^(?:household:)?([a-z][a-z0-9-]{0,31})$/.exec(value)?.[1]
    : undefined;
}

export const isNameable = (person) => householdId(person) === person && person !== FAMILY && !GATEWAY_CLIENT_IDS.has(person);

// The group OpenClaw reads from the owner's own family-room session, and the session.
export const ownersFamilyGroup = (owner) => `${FAMILY}:sender:${owner}`;
export const ownersFamilySession = (owner) => `${FAMILY_SESSION}:sender:${owner}`;

// { kind: "direct" } for the owner's own thread, { kind: "family", sender } for the family
// room, with `isOwnersOwn` in the owner's own family-room session, or null for a turn the
// owner's consent can never cover.
export function turnOf(context, { owner, people }) {
  if (!isNameable(owner) || !people.every(isNameable)) return null;
  if (context?.agentId !== "main" || context.agentAccountId !== "default" || context.oneShotCliRun === true) return null;
  const delivery = context.deliveryContext;
  if (context.messageChannel !== "household" || delivery?.channel !== "household") return null;
  if (delivery.accountId !== "default" || delivery.threadId != null) return null;
  const sender = householdId(context.requesterSenderId);
  const to = householdId(delivery.to);
  // A queued turn can omit the native chat; when both are present they must agree.
  const chat = context.nativeChannelId === undefined ? to : householdId(context.nativeChannelId);
  if (sender === undefined || to === undefined || chat !== to) return null;
  if (to === owner && sender === owner && context.sessionKey === `agent:main:household:direct:${owner}`) {
    return { kind: "direct", sender };
  }
  if (to === FAMILY && people.includes(sender) && context.sessionKey === FAMILY_SESSION) {
    return { kind: FAMILY, sender };
  }
  if (to === FAMILY && sender === owner && context.sessionKey === ownersFamilySession(owner)) {
    return { kind: FAMILY, sender, isOwnersOwn: true };
  }
  return null;
}

// Whether `turn` is one the owner started with their own assistant: their own thread, or
// their own family-room session. There an assistant works for its owner exactly as in their
// thread; in the room's shared session it has The Fam's tools alone, for anyone, so the
// owner's private data answers in the room only when the owner asked.
export function isOwnersTurn(turn) {
  return turn?.kind === "direct" || turn?.isOwnersOwn === true;
}
