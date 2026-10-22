// A call with the owner's own assistant, kept as one entry once it ends.
//
// The app's voice Call sends each spoken turn as an ordinary message in the owner's own
// thread, and the assistant answers with ordinary messages, so a call runs through the same
// signed sends, turns and pushes as typing does. When the call ends, the phone asks the
// gateway to fold the call's messages into one `call` entry that keeps what was said as
// text only, and the messages themselves go, so the thread shows one call rather than
// every line of it.
//
// The phone signs which messages were the call's (signature.js), so only one of the owner's
// phones folds anything, and of those only the owner's and this assistant's messages in the
// owner's own thread, said while the call lasted, fold. Any other id is skipped, since a
// send may have failed. A call is kept for thirty days after it ended.
//
// While the call lasts, each turn it starts carries CALL_TURN_INSTRUCTION for that turn
// alone, through OpenClaw's per-chat system prompt (`supplemental.groupSystemPrompt`, which
// 2026.9.4 adds to the turn's system prompt in a direct chat as in a group). The same model
// and tools answer as in chat. The instruction asks for an answer made to be heard, and for
// one short line said before anything slow, so the person never waits in silence: the phone
// says each sentence as soon as it is whole, and a tool starting says what came before it.

import { RoomError } from "./room-error.js";

export const CALL_TURN_INSTRUCTION = [
  "The owner said this message aloud on a voice call with you, and your reply is spoken to them in your own voice as it arrives.",
  "When the owner ends the conversation with a standalone thank you, thanks, goodbye or bye, give one brief warm goodbye, then stop. The phone ends the call after you finish speaking. Do not ask another question or use tools. A thank-you followed by a new request is not a goodbye.",
  "Keep the answer short and made to be heard: plain spoken sentences, with no lists, tables, cards, links, code or emoji.",
  "Lead with the useful answer in a short first sentence, usually twelve words or fewer, so the phone can start speaking promptly. Most turns need only one or two sentences. Give more detail when they ask for it or accuracy requires it.",
  "Sound like a warm, relaxed conversation: use contractions, everyday words and natural variation. Match their pace and mood. Skip canned enthusiasm, repeating their question and narrating your reasoning. Do not add a follow-up question unless it helps them move forward.",
  "Before you use any tool, or start anything that takes more than a moment, first say one brief natural line on its own, such as \"One sec, checking the thermostat.\", and then do it.",
  "For a simple answer, start with the answer instead of a holding line. Never claim you checked or completed something before its result is back. If they interrupt or correct you, follow their latest words without restarting your old answer.",
].join(" ");

export const CALL_TRANSCRIPT_MAX_CHARS = 50_000;
export const CALL_KEEP_DAYS = 30;
const CALL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ID = /^[A-Za-z0-9][A-Za-z0-9-]{7,79}$/;
const MAX_TURNS = 400;
const LONGEST_CALL_MS = 6 * 3_600_000;
// How far a call's end may be ahead of the gateway's clock, as for a message.
const NEWEST_MS = 5 * 60_000;
// A turn's time is the phone's clock when it was sent, which may run a little before the
// call's start as the phone counts it, and the assistant's last answer lands after the
// phone hangs up.
const EARLIEST_TURN_MS = 60_000;
const LATEST_TURN_MS = 120_000;

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

// The fields a phone may send when a call ends, checked and nothing else kept.
export function cleanCallEnd(params, now) {
  const { callId, startedAt, endedAt, turns } = params ?? {};
  if (typeof callId !== "string" || !CALL_ID.test(callId)) refuse("bad call id");
  if (!Number.isSafeInteger(startedAt) || !Number.isSafeInteger(endedAt)) refuse("bad call time");
  if (endedAt < startedAt || endedAt - startedAt > LONGEST_CALL_MS || endedAt > now + NEWEST_MS) refuse("call time out of range");
  if (!Array.isArray(turns) || turns.length > MAX_TURNS) refuse(`a call's turns are a list of at most ${MAX_TURNS} message ids`);
  if (!turns.every((id) => typeof id === "string" && ID.test(id))) refuse("bad call turns");
  return { callId, startedAt, endedAt, turns };
}

// How the phone's call came up, from the `setup` it sends beside the call's end (CallSetup in
// the app), as one line for this gateway's log, read with `docker logs <gateway> | grep
// "call setup"`: each moment from the tap in milliseconds, and whether CallKit took the
// call. Numbers and the route only, never anything said. A setup that does not read is said
// to be unreadable rather than refusing the call's end, which matters more.
const BUILD = /^[0-9A-Za-z.() +-]{1,32}$/;
const ROUTE = /^(callkit|unplaced|app (simulator|reset|refused -?[0-9]{1,9}))$/;
const SETUP_MOMENTS = [
  ["linkMs", "link"],
  ["soundMs", "sound"],
  ["connectedMs", "connected"],
  ["firstReplyMs", "first reply"],
];

function isMoment(value) {
  return value === undefined || (Number.isSafeInteger(value) && value >= 0 && value <= LONGEST_CALL_MS);
}

export function callSetupLine({ startedAt, endedAt, setup }, entry) {
  const call = `lasted ${((endedAt - startedAt) / 1000).toFixed(1)} s, ${entry.turnIds.length} turns`;
  if (setup === undefined) return `household-app: call setup not sent; ${call}`;
  const { build, route } = setup ?? {};
  const isReadable = typeof build === "string" && BUILD.test(build) && typeof route === "string" && ROUTE.test(route) &&
    SETUP_MOMENTS.every(([field]) => isMoment(setup[field]));
  if (!isReadable) return `household-app: call setup unreadable; ${call}`;
  const moments = SETUP_MOMENTS.map(([field, name]) => `${name} ${setup[field] === undefined ? "never" : `${setup[field]} ms`}`);
  return `household-app: call setup, build ${build}, ${route}: ${moments.join(", ")}; ${call}`;
}

// The call's entry, from the messages its turns name as the store holds them, null for one
// it does not have. Each line is a message's words, trimmed, and none of its attachments;
// one with no words adds no line. Lines are added in the order the messages were kept while
// their words together stay within the cap, and the first that would pass it ends the
// transcript, which then says it was cut. Every turn that fits the call folds either way.
export function foldCall({ callId, startedAt, endedAt }, messages, { owner, assistant }) {
  const turns = messages
    .filter((message) =>
      message?.conversation === "direct" &&
      (message.author === owner || message.author === assistant) &&
      !message.approval &&
      message.at >= startedAt - EARLIEST_TURN_MS &&
      message.at <= endedAt + LATEST_TURN_MS)
    .sort((one, other) => one.rev - other.rev);
  const transcript = [];
  let characters = 0;
  let isCut = false;
  for (const turn of turns) {
    const text = turn.text.trim();
    if (!text) continue;
    if (characters + text.length > CALL_TRANSCRIPT_MAX_CHARS) {
      isCut = true;
      break;
    }
    characters += text.length;
    transcript.push({ author: turn.author, text, at: turn.at });
  }
  return {
    id: `call:${callId}`,
    author: owner,
    at: startedAt,
    endedAt,
    with: assistant,
    turnIds: turns.map((turn) => turn.id),
    transcript,
    isCut,
    origin: "local",
  };
}

