// The app's two conversations on one gateway, and the rules for each: the family room,
// which this gateway shares with the other one through the host relay, and the owner's
// own thread with the assistant, which it shares with nobody.
//
// Who may say what:
// - The owner speaks through this gateway, from a phone paired with it, and every message
//   carries that phone's signature. The other gateway checks a family message's, and this
//   one checks both: a token with write scope, or an assistant talked into it, holds no
//   phone's key, so it can neither put words in the owner's mouth for the other gateway
//   nor start the owner's own turn in the direct thread, where the owner's private tools
//   answer.
// - The other gateway may only bring what its own person and its own assistant did in
//   the family room. Its person's messages must carry that person's phone signature;
//   its assistant's are attributed to that assistant whatever they say.
// - An assistant reacts only with one of the five tapbacks, only to a person's message, and
//   only in the conversation its turn is in (react-tool.js), and the other gateway's
//   assistant is held to the same.
//
// Who answers: the owner's direct messages always reach the assistant. A person's
// family message reaches it only when it names the assistant or replies to one of its
// messages; a voice note names it by
// its words, heard once on this gateway (voice-notes.js). The other assistant hands it a
// request by @mentioning it, or puts a question to it by name (mentions.js), and that
// starts one family-room turn whose sender is that assistant, never a person, so nothing
// that answers only a person is reachable from it. What such a turn writes is marked `handedOver`, and a marked message,
// one ten minutes old or older, or one already kept starts nothing, so the two can never
// answer each other in a loop.
//
// Who is on it: a person's message that asks both assistants gets one answer, from the asker's
// own assistant, which claims it as its turn starts (a step of the household note, notes.js,
// that the other side and both phones see). The other assistant stands down. Both gateways
// apply the same rule to the same signed message, so deciding takes no message between them
// and no wait. Only when no sign of the claimer reaches the other side within CLAIM_BOUND_MS,
// its typing, its claim or its reply, does the other take the question over.
//
// Who is told: the owner's phones are pushed every message the owner did not write, each
// by its own choice for that conversation in Settings (push.js). A scheduled reminder's is
// marked time sensitive, so it gets through a Focus. When a person reacts to one of this
// assistant's messages, or takes a reaction back, the assistant is told on its next turn in
// that conversation, as a line of context that starts nothing (tapbacks.js).
//
// What an assistant's answer changed rides on it as its `did` list (did.js), relayed with a
// family-room reply like the rest of it.
//
// Who the other assistant is: each assistant's name, voice and model travel as one
// "profile" entry in the family room, the way faces do, so a phone can show the other
// assistant's page and play its voice.
//
// The family room's look: either person may change the color round its face and its
// appearance, and each change, a new room photo included, is one "look" entry written as
// that person, which crosses like their messages and shows in the room as a line with its
// time (family-look.js).
//
// Maps: a person may share where they are as a message, once or live, and move a live
// one while it lasts (map-share.js), and answer a reminder by place that would watch
// them (place-consent.js). Each is signed by that person's phone and crosses to the
// other gateway like a message or a reaction.
//
// Calls: the owner's voice call with the assistant runs as ordinary messages in their own
// thread, and once it ends, the phone that made it folds them into one call entry that
// keeps what was said as text (call-log.js). A call never leaves the owner's own thread.
// The phone marks each message said on a call outside what it signs, and the mark only
// asks that turn for a spoken answer (CALL_TURN_INSTRUCTION), so it grants nothing.
//
// Nothing here logs what anybody said.

import { randomUUID } from "node:crypto";
import path from "node:path";

import { CALL_KEEP_DAYS, cleanCallEnd, foldCall } from "./call-log.js";
import { cleanDid } from "./did.js";
import { cleanLookChange, foldLook } from "./family-look.js";
import { cleanLiveUpdate, cleanSharedLocation, liveText } from "./map-share.js";
import { isMediaId, photoSize } from "./media.js";
import { isAskedByName, isMentioned, withAppMentions } from "./mentions.js";
import { asksFor, cleanPlaceAnswer, placeAnswerText } from "./place-consent.js";
import { RoomError } from "./room-error.js";
import { callEndSignedText, isPhoneKey, isSignedBy, isTextSignedBy } from "./signature.js";
import { TAPBACKS, reactionNote } from "./tapbacks.js";

export { RoomError };

export const CONVERSATIONS = new Set(["family", "direct"]);
const MEDIA_KINDS = new Set(["voice", "photo", "video", "file"]);
const ID = /^[A-Za-z0-9][A-Za-z0-9-]{7,79}$/;
const MIME = /^[A-Za-z0-9.+-]+\/[A-Za-z0-9.+-]+$/;
const DEVICE_TOKEN = /^[0-9a-fA-F]{32,200}$/;
const MAX_MEDIA = 10;
const MAX_PERSON_MESSAGE_UNITS = 64_000;
// A message's attachments together, as their files on disk measure them, so the host
// relay can carry any family message to the other gateway in one delivery. The relay
// sends at most this much in one (MAX_BATCH_MEDIA_BYTES in scripts/household-app-relay.py),
// and a message over it would hold up every message after it.
const MAX_MESSAGE_MEDIA_BYTES = 120 * 1024 * 1024;
const MAX_WAVEFORM = 128;
const DAY_MS = 86_400_000;
// A reaction the assistant has not been told of within a day is no longer worth telling.
const REACTION_NOTE_MS = DAY_MS;
const OLDEST_MS = 7 * DAY_MS;
const NEWEST_MS = 5 * 60_000;
// The other assistant's @mention starts a turn only while it is this fresh.
const HANDOVER_WITHIN_MS = 10 * 60_000;
// How long the assistant that stood down waits for a sign of the other's answer, and how far
// back a sign counts, since the other side's typing can arrive a delivery before its claim.
const CLAIM_BOUND_MS = 20_000;
const CLAIM_SIGN_MS = 5000;
// How many of the family room's newest messages are searched for the other's answer.
const ROOM_SIGN_MESSAGES = 50;
const TYPING_MS = 30_000;
const MAX_AVATAR_BYTES = 1024 * 1024;
const AVATAR_MIMES = new Set(["image/jpeg", "image/png"]);
// The family room's own photo, kept as a face of its own that either side may set.
const FAMILY_FACE = "family";
const OUTBOX_LIMIT = 500;
const MEDIA_LABELS = { voice: "Voice note", photo: "Photo", video: "Video", file: "File" };
// What a notification says of a map with no words.
const mapLabel = (entry) => (entry.location ? (entry.location.until === null ? "Location" : "Live location") : "");
// A paired phone's device id, as OpenClaw names it on the phone's connection.
const PHONE = /^[A-Za-z0-9._:-]{1,128}$/;
const VOICE_ID = /^[a-z][a-z0-9_-]{0,39}$/;
const MAX_MODEL_NAME = 80;
// How an assistant behaves in the family room, the same on both gateways.
const FAMILY_ROOM = "Answers when named";

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

function cleanMedia(item, exists) {
  if (!item || typeof item !== "object") refuse("bad attachment");
  const { id, kind, mime, bytes, durationMs, width, height, waveform, name } = item;
  if (!isMediaId(id) || !MEDIA_KINDS.has(kind)) refuse("bad attachment");
  if (typeof mime !== "string" || mime.length > 100 || !MIME.test(mime)) refuse("bad attachment type");
  if (!Number.isSafeInteger(bytes) || bytes <= 0) refuse("bad attachment size");
  if (!exists(id)) refuse("attachment not received");
  const clean = { id, kind, mime, bytes };
  if (durationMs !== undefined) {
    if (!Number.isSafeInteger(durationMs) || durationMs < 0) refuse("bad attachment duration");
    clean.durationMs = durationMs;
  }
  for (const [key, value] of [["width", width], ["height", height]]) {
    if (value === undefined) continue;
    if (!Number.isSafeInteger(value) || value <= 0) refuse("bad attachment dimensions");
    clean[key] = value;
  }
  if (waveform !== undefined) {
    if (!Array.isArray(waveform) || waveform.length > MAX_WAVEFORM ||
      !waveform.every((level) => typeof level === "number" && level >= 0 && level <= 1)) {
      refuse("bad attachment waveform");
    }
    clean.waveform = waveform;
  }
  if (name !== undefined) {
    if (typeof name !== "string" || name.length > 200 || name !== path.basename(name)) refuse("bad attachment name");
    clean.name = name;
  }
  return clean;
}

// No ASCII, except the digit or sign a keycap is built on: 1️⃣ is "1", U+FE0F and U+20E3.
function isEmoji(value) {
  return typeof value === "string" && value.length >= 1 && value.length <= 16 &&
    !/[\x00-\x7F]/.test(value.replace(/[0-9#*]️?⃣/g, ""));
}

// A name a person gives their assistant in Settings, in any alphabet.
function plainName(value) {
  return typeof value === "string" && /^\p{L}[\p{L} .'-]{0,39}$/u.test(value);
}

function modelName(value) {
  return typeof value === "string" && value.length >= 1 && value.length <= MAX_MODEL_NAME && /^[^\r\n]+$/.test(value);
}

// `runInChannel` runs a task in the channel's own context. A turn a phone's request
// starts must run there: OpenClaw closes a request's work when its handler returns and
// refuses a turn begun inside it ("Gateway is draining").
//
// `phoneKeys` answers with the keys of the phones OpenClaw has paired to this gateway
// for the app, so a phone paired by setup code speaks for the owner without anyone
// pinning its key. The other gateway learns them from this one's outbox, the way it
// learns everything else this one says.
//
// `notificationChoices` answers with one paired phone's choices by conversation, and
// `assistantNames` with the names this assistant answers to as the gateway holds them
// now, which may differ from the family room's.
//
// `enqueue` is OpenClaw's next-turn injection, which keeps a line on a session until that
// conversation's next turn starts and then adds it to the turn's context.
//
// `ownersFamilySession` is the owner's own session of the family room (turn.js), where the
// owner's own family-room turns run, so their replies stream from there to the owner's phones.
//
// `pairLastAt` answers with when the two assistants' direct line last moved, or null, which
// every page carries so the family room can show, quietly, that they are coordinating.
//
// `isPeerAddressed` says whether a family message also asks the other assistant, and
// `claims` keeps who took a question both were asked (notes.js claim, took and claimOf), and
// the questions this assistant stood down from until their bound is checked (standDown,
// standingDown and settled).
// `schedule` runs a task later, for the bound on a claim.
export function createRoom({
  identity,
  sessionKeys = {},
  ownersFamilySession,
  pairLastAt = () => null,
  isPeerAddressed = async () => false,
  claims = {
    claim: () => false,
    took: () => false,
    claimOf: () => ({ claimedBy: null, tookBy: null }),
    standDown: () => {},
    standingDown: () => [],
    settled: () => {},
  },
  schedule = (task, milliseconds) => setTimeout(task, milliseconds).unref(),
  phoneKeys = async () => [],
  notificationChoices = () => ({}),
  assistantNames = () => [],
  runInChannel = (task) => task(),
  enqueue = async () => ({ enqueued: false }),
  store,
  media,
  now = Date.now,
  emit,
  writeOutbox,
  push,
  dispatch,
  isAddressed,
  log,
}) {
  const { owner, assistant, peer } = identity;
  let ownerPhones = [];
  let peerPhones = [];
  const ownerKeys = () => [...new Set([...owner.keys, ...ownerPhones])];
  const peerKeys = () => [...new Set([...peer.person.keys, ...peerPhones])];

  async function refreshPhoneKeys() {
    const keys = await phoneKeys();
    ownerPhones = Array.isArray(keys) ? keys.filter(isPhoneKey) : [];
    return ownerKeys();
  }
  // Who this phone belongs to, and where its assistant's replies stream from, on every
  // page, so the phone never has to guess either from a list.
  const orientation = () => {
    const familyAvatar = store.avatars()[FAMILY_FACE];
    const looks = store.looks();
    const pairAt = pairLastAt();
    return {
      self: { person: owner.id, assistant: assistant.id },
      sessionKeys,
      ...(ownersFamilySession ? { ownersFamilySession } : {}),
      participants: participants(),
      peerAssistant: peerPage(),
      ...(familyAvatar ? { familyAvatar } : {}),
      ...(looks.length > 0 ? { familyLook: foldLook(looks) } : {}),
      ...(pairAt ? { pair: { lastAt: pairAt } } : {}),
    };
  };
  const peerAssistant = { ...peer.assistant };
  let typing = {};
  // Who on the other side the phones were last told is typing. The other gateway says one
  // stopped by leaving them out of its list, so this is how the phones hear that they did.
  let peerTypers = new Set();
  // When the other assistant last showed it was answering in the family room, for a claim.
  let peerAssistantActiveAt = 0;
  // Whether this assistant's page was shared since the channel started. The first share
  // after a start is written afresh even when nothing changed, since the other gateway
  // refuses a page while it runs an older plugin during a rollout, and an unchanged page
  // would otherwise never reach it again.
  let hasSharedProfile = false;

  const names = () => ({
    [owner.id]: owner.name,
    [peer.person.id]: peer.person.name,
    [assistant.id]: assistant.name,
    [peerAssistant.id]: peerAssistant.name,
  });

  function participants() {
    const faces = store.avatars();
    const face = (id) => (faces[id] ? { avatar: faces[id] } : {});
    const assistantRow = (who) => ({
      id: who.id,
      name: who.name,
      kind: "assistant",
      isOwner: false,
      ...(who.emoji ? { emoji: who.emoji } : {}),
      ...face(who.id),
    });
    return [
      { id: owner.id, name: owner.name, kind: "person", isOwner: true, ...face(owner.id) },
      { id: peer.person.id, name: peer.person.name, kind: "person", isOwner: false, ...face(peer.person.id) },
      assistantRow(assistant),
      assistantRow(peerAssistant),
    ];
  }

  // The other assistant's page, as far as the other gateway has said: only its name
  // until its first profile entry arrives.
  function peerPage() {
    const page = store.profiles()[peerAssistant.id];
    return {
      name: peerAssistant.name,
      voiceName: page?.voiceName ?? null,
      voice: page?.voice ?? null,
      modelName: page?.modelName ?? null,
      familyRoom: FAMILY_ROOM,
    };
  }

  // A face: a JPEG or PNG photo this gateway already has, of at most a megabyte.
  async function cleanAvatar(item) {
    const size = await media.size(item?.id);
    const photo = cleanMedia(item, () => size > 0);
    if (photo.kind !== "photo" || !AVATAR_MIMES.has(photo.mime)) refuse("a face must be a JPEG or PNG photo");
    if (size > MAX_AVATAR_BYTES) refuse("a face must be at most a megabyte");
    return { ...photo, bytes: size };
  }

  function liveTyping() {
    return Object.fromEntries(Object.entries(typing).filter(([, state]) => state.until > now()));
  }

  // Who types in the family room on this side, the owner and the assistant each on their
  // own, for the other gateway's phones. Each write is a delivery to the other gateway, and
  // OpenClaw keeps a turn's typing up every few seconds, so a typing is written again only
  // once less than half its time is left, and a stop only for someone still typing.
  function setFamilyTyping(author, active) {
    const { [author]: current, ...others } = liveTyping();
    if (active ? current && current.until - now() > TYPING_MS / 2 : !current) return;
    typing = active ? { ...others, [author]: { conversation: "family", until: now() + TYPING_MS } } : others;
    publishOutbox();
  }

  function publishOutbox() {
    writeOutbox({
      entries: store.outbox(OUTBOX_LIMIT),
      typing: liveTyping(),
      identity: {
        person: { id: owner.id, keys: ownerKeys() },
        assistant: { id: assistant.id, name: assistant.name, ...(assistant.emoji ? { emoji: assistant.emoji } : {}) },
      },
    });
  }

  function changed(entry) {
    emit("changed", { rev: entry.rev });
    if (entry.conversation === "family" && entry.origin === "local") publishOutbox();
  }

  // One of the household's two people, rather than an assistant.
  const isPersonId = (id) => id === owner.id || id === peer.person.id;

  // What `author` has reacted to a message with, before a reaction changes it, or null.
  const reactionBy = (author, messageId) =>
    store.reactions(messageId).find((reaction) => reaction.author === author)?.emoji ?? null;

  // A person's reaction to one of this assistant's messages, just kept, waits for the
  // assistant's next turn in that conversation. One that changes nothing, such as a phone's
  // retry or the relay bringing it twice, tells nothing new.
  function tellAssistant(entry, before) {
    const message = store.message(entry.messageId);
    const sessionKey = sessionKeys[message?.conversation];
    if (!isPersonId(entry.author) || message?.author !== assistant.id || !sessionKey || before === entry.emoji) return;
    const text = reactionNote({ name: names()[entry.author], emoji: entry.emoji, previous: before, message });
    void Promise.resolve(enqueue({ sessionKey, text, ttlMs: REACTION_NOTE_MS })).catch((error) => {
      log.warn(`household-app: a reaction was not kept for the assistant's next turn: ${error?.message ?? error}`);
    });
  }

  // The message fields a phone may set, checked and nothing else kept. A map carries its
  // place in `location` and nothing attached.
  async function cleanMessage(params, isPerson = true) {
    const { conversation, id, at, replyTo, text, media: attachments, location } = params ?? {};
    if (!CONVERSATIONS.has(conversation)) refuse("unknown conversation");
    if (typeof id !== "string" || !ID.test(id)) refuse("bad message id");
    if (!Number.isSafeInteger(at) || at < now() - OLDEST_MS || at > now() + NEWEST_MS) refuse("message time out of range");
    if (replyTo !== null && replyTo !== undefined && (typeof replyTo !== "string" || !ID.test(replyTo))) refuse("bad reply id");
    if (typeof text !== "string") refuse("text must be a string");
    if (isPerson && text.length > MAX_PERSON_MESSAGE_UNITS) {
      refuse("Message is too long. Split it into smaller messages (64,000 UTF-16 units maximum each).");
    }
    const list = attachments ?? [];
    if (!Array.isArray(list) || list.length > MAX_MEDIA) refuse("too many attachments");
    const isMap = location !== undefined && location !== null;
    if (isMap && list.length > 0) refuse("a shared map carries no attachments");
    const sizes = new Map();
    for (const item of list) {
      const size = await media.size(item?.id);
      if (size > 0) sizes.set(item.id, size);
    }
    const cleaned = list.map((item) => cleanMedia(item, (mediaId) => sizes.has(mediaId)));
    if ([...sizes.values()].reduce((total, size) => total + size, 0) > MAX_MESSAGE_MEDIA_BYTES) {
      refuse("attachments too large to send together");
    }
    if (!text.trim() && cleaned.length === 0 && !isMap) refuse("empty message");
    return {
      conversation,
      id,
      at,
      replyTo: replyTo ?? null,
      text,
      media: cleaned,
      ...(isMap ? { location: cleanSharedLocation(location, at) } : {}),
    };
  }

  async function notifyOwner(entry, { isTimeSensitive = false } = {}) {
    const devices = store.devices();
    if (devices.length === 0) return;
    const first = entry.media?.[0];
    const results = await push.notify(
      devices.map((device) => ({ ...device, notifications: device.phone ? notificationChoices(device.phone) : {} })),
      {
        conversation: entry.conversation,
        messageId: entry.id,
        sender: entry.author,
        title: names()[entry.author] ?? entry.author,
        body: entry.text.trim() || (first ? MEDIA_LABELS[first.kind] : "") || mapLabel(entry),
        mentions: [owner.name, assistant.name],
        ...(isTimeSensitive ? { isTimeSensitive } : {}),
      },
    );
    for (const result of results) {
      if (result.gone) store.removeDevice(result.token);
      else if (!result.ok) log.warn(`household-app: a notification was not delivered: ${result.reason}`);
    }
  }

  function start(turn) {
    void Promise.resolve(dispatch(turn)).catch((error) => {
      log.warn(`household-app: a turn in the ${turn.conversation} conversation failed to start: ${error?.message ?? error}`);
    });
  }

  // Whether this assistant should answer a person's message, and if so, its turn. A message
  // the phone marks as said on a voice call (`call: true` beside the signed fields, never in
  // them) makes its turn a call turn, which only shapes that turn's instructions (index.js).
  // A call never leaves the owner's own thread, so the mark means nothing in the family room.
  async function consider(entry, { isCall = false } = {}) {
    let addressed = entry.conversation === "direct";
    let claim;
    if (!addressed) {
      const repliedTo = entry.replyTo ? store.message(entry.replyTo) : null;
      addressed = await isAddressed(entry, { isReplyToAssistant: repliedTo?.author === assistant.id });
      if (addressed && await isPeerAddressed(entry)) {
        if (entry.author !== owner.id) {
          standDown(entry);
          return;
        }
        claims.claim(entry.id, { forWho: entry.author });
        claim = "claimed";
      }
    }
    if (!addressed) return;
    start({
      conversation: entry.conversation,
      message: entry,
      author: { id: entry.author, name: names()[entry.author] },
      isCall: isCall && entry.conversation === "direct",
      ...(claim ? { claim } : {}),
    });
  }

  // The other person asked both assistants, so the other assistant has it. This one takes it
  // over once the bound passes with no sign of that one's answer: its typing in the room, its
  // claim, or a message of its own.
  // The bound is kept in the household note's file, so a restart inside it still checks it
  // once (resumeStandDowns).
  function standDown(entry) {
    const bound = { since: now() - CLAIM_SIGN_MS, deadline: now() + CLAIM_BOUND_MS };
    claims.standDown(entry.id, bound);
    takeOverAfter(entry, bound);
  }

  // A sign of the other assistant's answer since `since`: its typing or a message of its own
  // while this channel ran, its message kept before a restart, or its claim.
  function takeOverAfter(entry, { since, deadline }) {
    schedule(() => {
      claims.settled(entry.id);
      const hasAnswered = store.history("family", { limit: ROOM_SIGN_MESSAGES }).messages
        .some((message) => message.author === peerAssistant.id && message.at >= since);
      if (peerAssistantActiveAt >= since || hasAnswered || claims.claimOf(entry.id).claimedBy === peerAssistant.id) return;
      if (!claims.took(entry.id)) return;
      start({ conversation: "family", message: entry, author: { id: entry.author, name: names()[entry.author] }, claim: "tookOver" });
    }, Math.max(0, deadline - now()));
  }

  // The questions this assistant stood down from before the channel last stopped, each checked
  // once when its bound passes, or at once when it already has. One whose question is past the
  // handover bound, or no longer here, is let go.
  function resumeStandDowns() {
    for (const { message, since, deadline } of claims.standingDown()) {
      const entry = store.message(message);
      if (!entry || now() - entry.at >= HANDOVER_WITHIN_MS) {
        claims.settled(message);
        continue;
      }
      takeOverAfter(entry, { since, deadline });
    }
  }

  // The other assistant's family message, just kept: a fresh @mention of this assistant, or
  // a question put to it by name, that no handed-over turn wrote starts one family-room
  // turn, sent by that assistant. The turn's own messages are marked, so it can answer once
  // and never start one back.
  function considerHandover(entry) {
    if (entry.handedOver === true || now() - entry.at >= HANDOVER_WITHIN_MS) return;
    const answersTo = new Set([assistant.name, ...assistantNames()]);
    if (![...answersTo].some((name) => isMentioned(entry.text, name) || isAskedByName(entry.text, name))) return;
    start({
      conversation: "family",
      message: entry,
      author: { id: entry.author, name: names()[entry.author], isAssistant: true },
      handedOver: true,
    });
  }

  // The owner's message, kept. Whether the assistant answers is `consider`'s to decide.
  async function accept(params) {
    const message = await cleanMessage(params);
    if (!isSignedBy(message, params.signature, await refreshPhoneKeys())) {
      refuse("messages must carry the signature of one of the owner's phones");
    }
    const { added, entry } = store.addMessage({ ...message, author: owner.id, origin: "local", signature: params.signature });
    if (added) changed(entry);
    return { added, entry };
  }

  async function acceptPeerMessage(raw) {
    if (raw.author !== peer.person.id && raw.author !== peerAssistant.id) refuse("not the other gateway's to say");
    const isPerson = raw.author === peer.person.id;
    const message = await cleanMessage(raw, isPerson);
    if (message.conversation !== "family") refuse("only the family room is shared");
    if (isPerson && !isSignedBy(message, raw.signature, peerKeys())) refuse("signature does not match the person's phone");
    if (raw.did !== undefined && !Array.isArray(raw.did)) refuse("bad did list");
    const runId = !isPerson && typeof raw.runId === "string" && ID.test(raw.runId) ? raw.runId : undefined;
    const { added, entry } = store.addMessage({
      ...message,
      author: raw.author,
      origin: "peer",
      ...(isPerson ? { signature: raw.signature } : {}),
      ...(runId ? { runId } : {}),
      ...(!isPerson && raw.handedOver === true ? { handedOver: true } : {}),
      did: isPerson ? [] : cleanDid(raw.did ?? []),
    });
    if (!added) return;
    changed(entry);
    await notifyOwner(entry);
    if (isPerson) await consider(entry);
    else {
      peerAssistantActiveAt = now();
      considerHandover(entry);
    }
  }

  async function acceptPeerAvatar(raw) {
    if (![peer.person.id, peerAssistant.id, FAMILY_FACE].includes(raw.author)) refuse("not the other gateway's to say");
    if (raw.conversation !== "family" || !Number.isSafeInteger(raw.at)) refuse("bad face");
    if (!Array.isArray(raw.media) || raw.media.length !== 1) refuse("bad face");
    const entry = store.setAvatar({ author: raw.author, at: raw.at, origin: "peer", media: [await cleanAvatar(raw.media[0])] });
    if (entry) changed(entry);
  }

  // A change to the family room's look the other person made on their phone, or the line
  // their new room photo wrote.
  function acceptPeerLook(raw) {
    if (raw.author !== peer.person.id) refuse("only the other person changes the look from there");
    if (raw.conversation !== "family" || !Number.isSafeInteger(raw.at)) refuse("bad look");
    const change = cleanLookChange(raw, refuse, { mayBePhoto: true });
    const entry = store.addLook({ author: raw.author, at: raw.at, origin: "peer", ...change });
    if (entry) changed(entry);
  }

  // An update to the other person's live map, signed by their phone. It counts if it was
  // signed before the share's end, however late the relay brings it.
  async function acceptPeerLive(raw) {
    if (raw.author !== peer.person.id) refuse("only the other person moves their map");
    const map = store.message(raw.messageId);
    if (map?.author !== raw.author || map.conversation !== "family") refuse("no live map by that id");
    const update = cleanLiveUpdate(raw, { map, current: store.live(map.id), now: null });
    if (!isTextSignedBy(liveText(update), raw.signature, peerKeys())) refuse("signature does not match the person's phone");
    const entry = store.setLive({ ...update, author: raw.author, origin: "peer", signature: raw.signature });
    if (!entry) refuse("the gateway already has a newer update");
    changed(entry);
  }

  // The other person's answer to an assistant's reminder by place that would watch them.
  function acceptPeerPlace(raw) {
    if (raw.author !== peer.person.id) refuse("only the other person answers for themselves");
    const answer = cleanPlaceAnswer(raw, null);
    if (!asksAt(answer.messageId, peer.person)) refuse("no reminder by place there asks for the other person");
    if (!isTextSignedBy(placeAnswerText(answer), raw.signature, peerKeys())) refuse("signature does not match the person's phone");
    const entry = store.setPlaceAnswer({ ...answer, author: raw.author, origin: "peer", signature: raw.signature });
    if (!entry) refuse("the gateway already has a newer answer");
    changed(entry);
  }

  // Whether the family-room message `messageId` is an assistant's place-reminder card that
  // would watch `person`.
  function asksAt(messageId, person) {
    const card = store.message(messageId);
    return card?.conversation === "family" && (card.author === assistant.id || card.author === peerAssistant.id) &&
      asksFor(card.text, person);
  }

  function acceptPeerProfile(raw) {
    if (raw.author !== peerAssistant.id) refuse("only the other assistant's page is the other gateway's to say");
    if (raw.conversation !== "family" || !Number.isSafeInteger(raw.at)) refuse("bad page");
    if (!plainName(raw.name) || !VOICE_ID.test(raw.voice ?? "") || !plainName(raw.voiceName) || !modelName(raw.modelName)) {
      refuse("bad page");
    }
    const { author, at, name, voice, voiceName } = raw;
    const entry = store.setProfile({ author, at, origin: "peer", name, voice, voiceName, modelName: raw.modelName });
    if (!entry) return;
    peerAssistant.name = name;
    changed(entry);
  }

  function acceptPeerMarker(raw) {
    if (raw.author !== peer.person.id && raw.author !== peerAssistant.id) refuse("not the other gateway's to say");
    if (!Number.isSafeInteger(raw.at)) refuse("bad time");
    if (typeof raw.messageId !== "string" || !ID.test(raw.messageId)) refuse("bad message id");
    if (raw.kind === "reaction") {
      if (raw.emoji !== null && !isEmoji(raw.emoji)) refuse("bad reaction");
      const target = store.message(raw.messageId);
      if (target?.conversation !== "family") return;
      if (raw.author === peerAssistant.id && ((raw.emoji !== null && !TAPBACKS.includes(raw.emoji)) || !isPersonId(target.author))) {
        refuse("an assistant reacts only to a person's message, with a tapback");
      }
      const before = reactionBy(raw.author, raw.messageId);
      const entry = store.setReaction({ messageId: raw.messageId, author: raw.author, emoji: raw.emoji, at: raw.at, origin: "peer" });
      if (entry) {
        changed(entry);
        tellAssistant(entry, before);
      }
      return;
    }
    if (raw.conversation !== "family") refuse("only the family room is shared");
    const entry = store.markRead({ conversation: "family", author: raw.author, messageId: raw.messageId, at: raw.at, origin: "peer" });
    if (entry) changed(entry);
  }

  return {
    participants,
    accept,
    consider,
    resumeStandDowns,
    refreshPhoneKeys,
    peerKeys,
    publishOutbox,

    // A phone's message: answered once kept. Whether the assistant answers, and its
    // turn, come after, in the channel's context.
    async receive(params) {
      const { added, entry } = await accept(params);
      if (added) {
        const isCall = params.call === true;
        void Promise.resolve(runInChannel(() => consider(entry, { isCall }))).catch((error) => {
          log.warn(`household-app: a ${entry.conversation} turn could not be considered: ${error?.message ?? error}`);
        });
      }
      return { entry };
    },

    async send(params) {
      const result = await accept(params);
      if (result.added) await consider(result.entry, { isCall: params.call === true });
      return { entry: result.entry };
    },

    // The owner's call with this assistant, ended, signed by one of the owner's phones: the
    // messages it names that were the call's, folded into one call entry. Ended again, it
    // answers with the call already kept.
    async endCall(params) {
      const call = cleanCallEnd(params, now());
      if (!isTextSignedBy(callEndSignedText(call), params.signature, await refreshPhoneKeys())) {
        refuse("a call must carry the signature of one of the owner's phones");
      }
      const messages = [...new Set(call.turns)].map((id) => store.message(id));
      const { added, entry } = store.addCall(foldCall(call, messages, { owner: owner.id, assistant: assistant.id }));
      if (added) changed(entry);
      return { entry };
    },

    // Calls that ended over CALL_KEEP_DAYS ago, gone from history and catching up.
    dropOldCalls() {
      store.dropCallsEndedBefore(now() - CALL_KEEP_DAYS * DAY_MS);
    },

    // What the assistant said: its words, and any files its reply carried, already
    // read through the gateway's own media policy by the caller. `handedOver` marks a
    // reply from a turn the other assistant's @mention started, `did` is what its run
    // changed, and `isTimeSensitive` marks a scheduled reminder's push.
    async reply({ conversation, runId, text, files = [], handedOver = false, did = [], isTimeSensitive = false }) {
      const attachments = [];
      for (const file of files) {
        const kept = await media.putBytes(file.bytes);
        const mime = typeof file.mime === "string" && MIME.test(file.mime) ? file.mime : "application/octet-stream";
        const kind = MEDIA_KINDS.has(file.kind) ? file.kind
          : mime.startsWith("image/") ? "photo"
          : mime.startsWith("video/") ? "video"
          : mime.startsWith("audio/") ? "voice"
          : "file";
        const name = typeof file.name === "string" ? path.basename(file.name.replaceAll("\\", "/")).slice(0, 200) : "";
        const size = kind === "photo" ? photoSize(file.bytes) : null;
        attachments.push({
          id: kept.id,
          kind,
          mime,
          bytes: kept.bytes,
          ...(Number.isSafeInteger(file.durationMs) ? { durationMs: file.durationMs } : {}),
          ...(size ?? {}),
          ...(kind === "file" && name ? { name } : {}),
        });
      }
      const words = withAppMentions(String(text ?? ""), [...new Set([assistant.name, peerAssistant.name, ...assistantNames()])]);
      if (!words.trim() && attachments.length === 0) return null;
      const { entry } = store.addMessage({
        id: `a-${randomUUID()}`,
        conversation,
        author: assistant.id,
        at: now(),
        text: words,
        media: attachments,
        replyTo: null,
        runId,
        handedOver,
        did,
        origin: "local",
      });
      changed(entry);
      await notifyOwner(entry, { isTimeSensitive });
      return entry;
    },

    // An entry this gateway kept on its own, such as an approval card or how it ended:
    // phones follow it, and a message the owner did not write reaches their phones.
    async announce(entry) {
      changed(entry);
      if (entry.kind === "message") await notifyOwner(entry);
    },

    // A voice note's words, just heard (voice-notes.js): the owner's phones show them under
    // the note. They are this gateway's own, so nothing crosses to the other gateway.
    heard(entry) {
      emit("changed", { rev: entry.rev });
    },

    async acceptPeer({ entries = [], typing: peerTyping = {}, identity: peerIdentity } = {}) {
      let accepted = 0;
      let refused = 0;
      const peerName = peerIdentity?.assistant?.name;
      const peerEmoji = peerIdentity?.assistant?.emoji;
      if (plainName(peerName)) peerAssistant.name = peerName;
      if (isEmoji(peerEmoji)) peerAssistant.emoji = peerEmoji;
      const relayedKeys = peerIdentity?.person?.keys;
      if (peerIdentity?.person?.id === peer.person.id && Array.isArray(relayedKeys) && relayedKeys.every(isPhoneKey)) {
        peerPhones = relayedKeys;
      }
      for (const raw of Array.isArray(entries) ? entries : []) {
        try {
          if (raw?.kind === "message") await acceptPeerMessage(raw);
          else if (raw?.kind === "reaction" || raw?.kind === "read") acceptPeerMarker(raw);
          else if (raw?.kind === "avatar") await acceptPeerAvatar(raw);
          else if (raw?.kind === "profile") acceptPeerProfile(raw);
          else if (raw?.kind === "look") acceptPeerLook(raw);
          else if (raw?.kind === "live") await acceptPeerLive(raw);
          else if (raw?.kind === "place") acceptPeerPlace(raw);
          else refuse("unknown entry kind");
          accepted += 1;
        } catch (error) {
          refused += 1;
          log.warn(`household-app: refused a ${raw?.kind ?? "malformed"} entry from the other gateway: ${error.message}`);
        }
      }
      const told = new Map();
      for (const [author, state] of Object.entries(peerTyping ?? {})) {
        if (author !== peer.person.id && author !== peerAssistant.id) continue;
        if (state?.conversation !== "family") continue;
        const active = Number(state.until) > now();
        if (active && author === peerAssistant.id) peerAssistantActiveAt = now();
        if (active || peerTypers.has(author)) told.set(author, active);
      }
      for (const author of peerTypers) if (!told.has(author)) told.set(author, false);
      for (const [author, active] of told) emit("typing", { conversation: "family", author, active });
      peerTypers = new Set([...told].filter(([, active]) => active).map(([author]) => author));
      return { accepted, refused };
    },

    // The owner's phone setting the owner's face, their assistant's or the family room's
    // own photo, from a photo it uploaded. Everyone in the family room sees it, on both
    // gateways, and the newer family photo of the two sides stays. A new room photo also
    // shows in the room as the owner's line.
    async setAvatar({ participant, media: item }) {
      if (![owner.id, assistant.id, FAMILY_FACE].includes(participant)) {
        refuse("a phone sets only its person's face, their assistant's and the family room's");
      }
      const at = now();
      const entry = store.setAvatar({ author: participant, at, origin: "local", media: [await cleanAvatar(item)] });
      if (entry) changed(entry);
      if (entry && participant === FAMILY_FACE) {
        const line = store.addLook({ author: owner.id, at, origin: "local", change: "photo" });
        if (line) changed(line);
      }
      return { participants: participants() };
    },

    // The owner's phone changing the family room's color or appearance, which both phones
    // then show, with the owner's line in the room for the change.
    setLook(params) {
      const change = cleanLookChange(params, refuse);
      const entry = store.addLook({ author: owner.id, at: now(), origin: "local", ...change });
      if (entry) changed(entry);
      return { familyLook: foldLook(store.looks()) };
    },

    // This assistant's page as its gateway holds it now, relayed to the other gateway the
    // first time after the channel starts, and after that when it differs from the last
    // one kept.
    publishProfile({ name, voice, voiceName, modelName: model }) {
      const kept = store.profiles()[assistant.id];
      const isUnchanged = kept && kept.name === name && kept.voice === voice && kept.voiceName === voiceName && kept.modelName === model;
      if (hasSharedProfile && isUnchanged) return;
      hasSharedProfile = true;
      const entry = store.setProfile({ author: assistant.id, at: now(), origin: "local", name, voice, voiceName, modelName: model });
      if (entry) changed(entry);
    },

    async react({ messageId, emoji }) {
      if (emoji !== null && !isEmoji(emoji)) refuse("bad reaction");
      if (!store.message(messageId)) refuse("no such message");
      const before = reactionBy(owner.id, messageId);
      const entry = store.setReaction({ messageId, author: owner.id, emoji, at: now(), origin: "local" });
      if (entry) {
        changed(entry);
        tellAssistant(entry, before);
      }
      return entry;
    },

    // This assistant's tapback on a person's message in the conversation its turn is in,
    // from household_react. In the family room it crosses to the other gateway like the
    // owner's reaction does.
    reactAsAssistant({ conversation, messageId, emoji }) {
      if (!TAPBACKS.includes(emoji)) refuse("an assistant reacts only with a tapback");
      const target = typeof messageId === "string" ? store.message(messageId) : null;
      if (!target || target.conversation !== conversation) refuse("no such message in this conversation");
      if (!isPersonId(target.author)) refuse("an assistant reacts only to a person's message");
      const entry = store.setReaction({ messageId, author: assistant.id, emoji, at: now(), origin: "local" });
      if (entry) changed(entry);
      return entry;
    },

    // An update to a live map the owner shared: where they are now, or a null position to
    // stop it early. Refused once the share has ended or stopped, and when it is no newer
    // than the last one kept.
    async live(params) {
      const map = typeof params?.messageId === "string" ? store.message(params.messageId) : null;
      if (map && map.author !== owner.id) refuse("no live map by that id");
      const update = cleanLiveUpdate(params, { map, current: map ? store.live(map.id) : null, now: now() });
      if (!isTextSignedBy(liveText(update), params.signature, await refreshPhoneKeys())) {
        refuse("an update must carry the signature of one of the owner's phones");
      }
      const entry = store.setLive({ ...update, author: owner.id, origin: "local", signature: params.signature });
      if (!entry) refuse("the gateway already has a newer update");
      changed(entry);
      return { entry };
    },

    // The owner saying yes or no to a reminder by place in the family room that would watch
    // them, from their own phone. Their phone watches the place only after a yes.
    async answerPlace(params) {
      const answer = cleanPlaceAnswer(params, now());
      if (!asksAt(answer.messageId, owner)) refuse("no reminder by place there asks for you");
      if (!isTextSignedBy(placeAnswerText(answer), params.signature, await refreshPhoneKeys())) {
        refuse("an answer must carry the signature of one of the owner's phones");
      }
      const entry = store.setPlaceAnswer({ ...answer, author: owner.id, origin: "local", signature: params.signature });
      if (!entry) refuse("the gateway already has a newer answer");
      changed(entry);
      return { entry };
    },

    async read({ conversation, messageId }) {
      if (!CONVERSATIONS.has(conversation)) refuse("unknown conversation");
      const entry = store.markRead({ conversation, author: owner.id, messageId, at: now(), origin: "local" });
      if (entry) changed(entry);
      return entry;
    },

    // The assistant has taken up a message to answer it: its read marker, which the
    // owner's phones show as Read under their message, and in the family room the other
    // gateway's phones as Read by it.
    assistantRead({ conversation, messageId }) {
      const entry = store.markRead({ conversation, author: assistant.id, messageId, at: now(), origin: "local" });
      if (entry) changed(entry);
      return entry;
    },

    // `phone` is the paired phone's own device id, from its connection, never from what it sent.
    registerDevice({ token, environment, key, phone }) {
      if (typeof token !== "string" || !DEVICE_TOKEN.test(token)) refuse("bad device token");
      if (environment !== "production" && environment !== "sandbox") refuse("bad device environment");
      if (typeof key !== "string" || Buffer.from(key, "base64").length !== 32) refuse("bad device key");
      if (phone !== undefined && (typeof phone !== "string" || !PHONE.test(phone))) refuse("bad device id");
      store.putDevice({ token, environment, key, phone, at: now() });
    },

    setTyping({ conversation, active }) {
      emit("typing", { conversation, author: assistant.id, active });
      if (conversation !== "family") return;
      setFamilyTyping(assistant.id, active);
    },

    // The owner's phone saying the owner is typing. Only the family room has anyone else
    // to tell, on the other gateway, and the owner's own phones are not told.
    personTyping({ conversation, active }) {
      if (!CONVERSATIONS.has(conversation)) refuse("unknown conversation");
      if (typeof active !== "boolean") refuse("active must be true or false");
      if (conversation !== "family") return;
      setFamilyTyping(owner.id, active);
    },

    sync({ since = 0, limit = 500 } = {}) {
      return { ...store.changesSince(since, Math.min(limit, 500)), ...orientation() };
    },

    history({ conversation, before, limit = 100 }) {
      if (!CONVERSATIONS.has(conversation)) refuse("unknown conversation");
      const page = store.history(conversation, { before, limit: Math.min(limit, 200) });
      const ended = page.messages.filter((message) => message.approval).map((message) => [message.id, store.approvalState(message.id)]);
      const moved = page.messages.filter((message) => message.location?.until != null).map((message) => [message.id, store.live(message.id)]);
      const answered = page.messages.map((message) => [message.id, store.placeAnswers(message.id)]);
      const heard = page.messages.map((message) => [message.id, store.transcript(message.id)]);
      return {
        ...page,
        reactions: Object.fromEntries(page.messages.map((message) => [message.id, store.reactions(message.id)])),
        transcripts: Object.fromEntries(heard.filter(([, words]) => words !== null)),
        approvals: Object.fromEntries(ended.filter(([, state]) => state)),
        lives: Object.fromEntries(moved.filter(([, live]) => live).map(([id, live]) => [id, { at: live.at, position: live.position }])),
        places: Object.fromEntries(answered.filter(([, answers]) => answers.length > 0)),
        reads: store.readMarkers(conversation),
        ...orientation(),
      };
    },
  };
}
