// One spoken reply is one clean set of voice notes, for both household gateways.
//
// OpenClaw 2026.9.4 leaves all of that to the model. Its `tts` tool refuses a text over
// 4,096 characters and has no rule for a long one, so the model rewrites the reply in
// pieces of its own choosing and nothing says which voice note is which. It holds every
// result until the model's written reply and sends them together, and Telegram's code
// then sends that reply's text twice: once as the first voice note's caption, and once
// more alone, because the step that takes already-sent audio out of the final reply
// keeps its text. Nothing bounds what a turn or a day may spend.
//
// So the model is handed `speak` in place of `tts`, and this plugin does the rest by
// rule:
//
// - The whole text comes in one call and is cut at sentence ends into even parts.
// - Each part is made by the gateway's configured speech provider and sent to the chat
//   by this plugin, in order, captioned "1 of 3". The tool's result is a line of text
//   and no audio, so OpenClaw has nothing to attach the written reply to and nothing to
//   send twice.
// - A part the provider fails is tried once more and no more. A voice note that was
//   sent is never sent again, and one Telegram refused is not sent again either, since
//   a send that failed may still have arrived.
// - A reply is spoken once: a second call in the same turn sends nothing.
// - A turn whose words may ask to hear the reply is reminded, in that turn, to call
//   `speak`, since the model has been seen to plan a spoken answer and write it.
// - One spoken reply may be `replyCharacters` long, and every character sent to the
//   provider in a day, retries included, counts against `dayCharacters`.
//
// `/tts` typed in a chat is this plugin's too, so `/tts latest` and `/tts audio` follow
// the same rules, and the built-in's `/tts on`, which would speak every reply with none
// of them, is no longer reachable from a chat. It is claimed in `before_dispatch` and
// not registered as a command: Telegram keeps its own handler for a built-in command
// and marks the turn so that a plugin command of the same name is skipped, which would
// leave the built-in `/tts` answering there. `before_dispatch` runs ahead of both.
// The built-in `tts` tool is refused if a config ever hands it back to the model.
//
// The day's count lives in one small JSON file in this plugin's own directory under the
// gateway's state, for the reason household-family-room gives for its files.

import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export const PLUGIN_ID = "household-speech";
export const TOOL_NAME = "speak";

// A part's size. OpenClaw refuses over 4,096 in one call and gives a call 30 seconds
// unless told otherwise, and on 2026-10-10 the provider took 34 seconds over 3,237
// characters. 2,000 is about two and a quarter minutes of speech, made in about 20.
export const PART_CHARACTERS = 2000;
const SYNTHESIS_TIMEOUT_MS = 120_000;
const TRIES_PER_PART = 2;
// A refusal for want of money or quota is not tried again: the same call would be
// refused again, and each try is one more request against a key other things share.
// A rate limit is among them, since a second call straight after one is refused too.
const SPEND_ERROR = /\b(?:402|429)\b|quota|credit|billing|limit|insufficient|payment|balance/i;
const MAX_REMEMBERED = 500;

const AFTER_SPEAKING = "Answer with one short line that says this. Do not write the spoken text out again.";
const NO_TEXT = "Not spoken: there was no text.";
const NO_CHAT = "Not spoken: there is no chat here to send a voice note to.";
const NO_ADAPTER = "Not spoken: the voice delivery adapter is unavailable.";
const NOT_AUTHORIZED = "Not spoken: this turn is not authorized for voice replies.";
const APP_SPEAK_ONLY = "To hear a message in Steward, long-press it and choose Speak. For a conversation aloud, start a call.";
const ALREADY_SPOKEN = "This reply was already spoken once. Nothing more was sent.";
const ALREADY_TRIED =
  "This reply was already tried once and not all of it was spoken. Nothing more was sent.";
const USAGE = "Use /tts latest to hear the last reply, /tts audio and some words to hear them, or /tts status.";
const STOPPED_ON_ERROR = "Speech stopped on an error. Nothing more was sent.";
// `/tts` at the start of a message, with a bot's name on it or not, and the words after
// it. OpenClaw takes a colon between a command and its words, so this does too.
const TTS_COMMAND = /^\/tts(?:@[^\s:]+)?(?::|\s|$)\s*(.*)$/is;
// The session a channel runs a typed command in, which is not the chat's own.
const COMMAND_SESSION = /^agent:[^:]+:[^:]+:slash:/i;
// Words that may ask to hear the reply. On 2026-10-15 in the app, with `speak` in hand and
// AGENTS.md saying it is the only way to speak, Corey planned a spoken answer to "a voice
// note" and wrote it instead, so a turn with such words is told so in the turn itself.
// The line leaves the judgement to the model, so a mention of a voice note is no order.
const ASKS_TO_HEAR = /\bvoice\b|\baloud\b|\bout loud\b|\bspeak\b|\bread (?:it|this|that|them) to me\b|\blet me hear\b/i;
const HEAR_IT = `If they are asking to hear your reply, call ${TOOL_NAME} once with the whole reply. Written text is never heard.`;
// The metadata blocks OpenClaw may put around a person's words, as household-memory reads them.
const METADATA_BLOCK = /^[^\n]*\(untrusted metadata\):[ \t]*\n```json\n[\s\S]*?\n```[ \t]*\n?/gm;

function isAppContext(context) {
  return context?.messageChannel === "household" || context?.channelId === "household" ||
    context?.deliveryContext?.channel === "household" || /^agent:[^:]+:household:/.test(context?.sessionKey ?? "");
}

function telegramId(value) {
  return typeof value === "string" ? /^(?:(?:telegram|tg):)?(-?[1-9]\d*)$/i.exec(value)?.[1] : undefined;
}

function householdId(value) {
  return typeof value === "string" ? /^(?:household:)?([a-z][a-z0-9-]{0,31})$/.exec(value)?.[1] : undefined;
}

// The household app's family room, for its two people, and its owner's own thread: the
// chats family_history answers in there. The app names no native chat, so its trusted
// delivery target stands in for one.
function isAuthorizedInApp(config, context) {
  const household = config?.channels?.household;
  const owner = household?.owner?.id;
  const people = [owner, household?.peer?.person?.id].filter((id) => householdId(id) === id);
  const sender = householdId(context.requesterSenderId);
  const delivery = context.deliveryContext;
  if (!household || household.enabled === false || !sender || !people.includes(sender)) return false;
  if (delivery?.channel !== "household" || delivery.accountId !== "default" || delivery.threadId != null) return false;
  const chat = householdId(delivery.to);
  if (!chat || (context.nativeChannelId !== undefined && householdId(context.nativeChannelId) !== chat)) return false;
  // A family-room turn the owner started runs in the owner's own session of the room.
  if (chat === "family") {
    return context.sessionKey === "agent:main:household:group:family" ||
      (sender === owner && context.sessionKey === `agent:main:household:group:family:sender:${owner}`);
  }
  return chat === owner && sender === owner && context.sessionKey === `agent:main:household:direct:${owner}`;
}

function isAuthorizedTurn(api, context) {
  const config = typeof context?.getRuntimeConfig === "function"
    ? context.getRuntimeConfig() : api.runtime.config.current();
  const family = config?.plugins?.entries?.["household-family-room"];
  const group = family?.config?.groupChatId;
  if (
    !/^-[1-9]\d*$/.test(group) || !context ||
    context.agentId !== "main" || context.agentAccountId !== "default" ||
    context.oneShotCliRun === true || config?.plugins?.enabled === false ||
    config?.plugins?.entries?.[PLUGIN_ID]?.enabled !== true || family.enabled !== true ||
    config?.session?.groupScope !== "per-group" ||
    !["per-channel-peer", "per-account-channel-peer"].includes(config?.session?.dmScope)
  ) return false;
  if (context.messageChannel === "household") return isAuthorizedInApp(config, context);
  const telegram = config?.channels?.telegram;
  const members = telegram?.groups?.[group];
  const sender = telegramId(context.requesterSenderId);
  const delivery = context.deliveryContext;
  if (
    !sender || !/^[1-9]\d*$/.test(sender) || context.messageChannel !== "telegram" ||
    telegram?.enabled === false || telegram?.groupPolicy === "disabled" ||
    members?.enabled === false || members?.groupPolicy === "disabled" ||
    Object.keys(telegram?.accounts ?? {}).length > 0 ||
    !Array.isArray(members?.allowFrom) || !members.allowFrom.some((value) => telegramId(String(value).trim()) === sender) ||
    delivery?.channel !== "telegram" || delivery.accountId !== "default" || delivery.threadId != null
  ) return false;
  const destination = telegramId(delivery.to);
  const native = context.nativeChannelId === undefined ? destination : telegramId(context.nativeChannelId);
  if (!native || native !== destination) return false;
  if (native === group) return context.sessionKey === `agent:main:telegram:group:${group}`;
  const account = config.session.dmScope === "per-account-channel-peer" ? "default:" : "";
  return native === sender && context.sessionKey === `agent:main:telegram:${account}direct:${sender}`;
}

// One chat, as both hooks name it. OpenClaw 2026.9.4's Telegram code names the chat of
// an inbound turn by its routing target, "telegram:<id>" with ":topic:<n>" after it in
// a forum, and the chat of a sent reply by the bare id.
function chatOf(channel, conversation) {
  const prefix = `${channel}:`;
  const named = String(conversation);
  const id = named.startsWith(prefix) ? named.slice(prefix.length) : named;
  return prefix + id.replace(/:(?:direct-)?topic:\d+$/, "");
}

// OpenClaw validates this plugin's config against the manifest's schema before it
// loads the plugin, so the entry hands back that schema rather than keeping a copy.
const CONFIG_SCHEMA = JSON.parse(
  readFileSync(new URL("./openclaw.plugin.json", import.meta.url), "utf8"),
).configSchema;

export function parseConfig(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { error: "expected a config object" };
  }
  const unknown = Object.keys(raw).filter((key) => !(key in CONFIG_SCHEMA.properties));
  if (unknown.length > 0) {
    return { error: `unknown config keys: ${unknown.join(", ")}` };
  }
  for (const key of CONFIG_SCHEMA.required) {
    if (!Number.isInteger(raw[key]) || raw[key] < 1) {
      return { error: `${key} must be a whole number of characters, 1 or more` };
    }
  }
  return { value: { replyCharacters: raw.replyCharacters, dayCharacters: raw.dayCharacters } };
}

const configSchema = {
  safeParse(value) {
    const parsed = parseConfig(value);
    if (parsed.error) {
      return { success: false, error: { issues: [{ path: [], message: parsed.error }] } };
    }
    return { success: true, data: value };
  },
  jsonSchema: CONFIG_SCHEMA,
};

const count = (characters) => characters.toLocaleString("en-US");

// A sentence ends at a full stop, a question mark, an exclamation mark or an ellipsis,
// with any closing quote or bracket after it, and at a paragraph break.
const SENTENCE_END = /(?<=[.!?…]["'”’)\]]*)\s+|\s*\n\s*\n\s*/u;

// A sentence longer than a part is cut between words, and a word longer than a part
// where it must be.
function cutBetweenWords(sentence, limit) {
  const pieces = [];
  let piece = "";
  const words = sentence.split(" ").flatMap((word) => word.match(new RegExp(`.{1,${limit}}`, "gu")));
  for (const word of words) {
    if (piece && piece.length + 1 + word.length > limit) {
      pieces.push(piece);
      piece = word;
    } else {
      piece = piece ? `${piece} ${word}` : word;
    }
  }
  return [...pieces, piece];
}

// Sentences joined into `count` parts of a text `total` characters long. Each part ends
// at the sentence end nearest to its share of the whole text, so no part's rounding is
// carried into the next, and before it would pass `limit`, which can leave more parts
// than were asked for.
function fill(sentences, count, total, limit) {
  const parts = [];
  let part = "";
  let end = -1;
  for (const sentence of sentences) {
    const goal = ((parts.length + 1) * total) / count;
    const next = end + 1 + sentence.length;
    if (part && (part.length + 1 + sentence.length > limit || goal - end <= next - goal)) {
      parts.push(part);
      part = sentence;
    } else {
      part = part ? `${part} ${sentence}` : sentence;
    }
    end = next;
  }
  return part ? [...parts, part] : parts;
}

// The text as parts of `limit` characters or fewer, each ending where a sentence does.
// The parts are even rather than full ones and a scrap: three notes of a minute and a
// half, not two of two minutes and one of ten seconds.
export function splitIntoParts(text, limit = PART_CHARACTERS) {
  const sentences = String(text ?? "")
    .split(SENTENCE_END)
    .map((sentence) => sentence.replace(/\s+/g, " ").trim())
    .filter(Boolean)
    .flatMap((sentence) => (sentence.length <= limit ? [sentence] : cutBetweenWords(sentence, limit)));
  if (sentences.length === 0) return [];
  const total = sentences.reduce((sum, sentence) => sum + sentence.length + 1, -1);
  // The fewest parts the text could fit in, and one more for as long as that many
  // even parts leave something over, since sentences do not pack to the last
  // character. A part holds at least one sentence, so this ends.
  for (let count = Math.ceil(total / limit); ; count += 1) {
    const parts = fill(sentences, count, total, limit);
    if (parts.length <= count) return parts;
  }
}

// Keeps the newest entries of a map that would otherwise grow for as long as the
// gateway runs.
function remember(map, key, value) {
  map.delete(key);
  map.set(key, value);
  while (map.size > MAX_REMEMBERED) map.delete(map.keys().next().value);
}

// What this gateway has sent to the speech provider today, in characters, in one JSON
// file that lands with a rename so a reader never sees half of it. The day is the
// container's own, which the compose file sets to the household's.
function createDayCount(file, now) {
  const today = () => {
    const date = new Date(now());
    return [date.getFullYear(), date.getMonth() + 1, date.getDate()].join("-");
  };

  async function spentOn(day) {
    let kept;
    try {
      kept = JSON.parse(await readFile(file, "utf8"));
    } catch (error) {
      // A day with no speech yet has no file. Anything else is a count this plugin
      // cannot vouch for, and a ceiling that cannot be read must not read as zero.
      if (error?.code === "ENOENT") return 0;
      throw error;
    }
    // The same holds for a file that reads but is not a day and a whole count: a count
    // that is missing or is text would make every sum with it pass under the ceiling.
    if (typeof kept?.day !== "string" || !Number.isInteger(kept.characters) || kept.characters < 0) {
      throw new Error(`${file} does not hold a day and a count of characters`);
    }
    return kept.day === day ? kept.characters : 0;
  }

  const spent = () => spentOn(today());

  // The day is read once, so a call made as midnight passes is counted in one day.
  async function charge(characters) {
    const day = today();
    const next = { day, characters: (await spentOn(day)) + characters };
    await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
    const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(temporary, JSON.stringify(next), { mode: 0o600 });
    await rename(temporary, file);
  }

  return { spent, charge };
}

export function createSpeech(api, config, options = {}) {
  const { replyCharacters, dayCharacters } = config;
  const directory =
    options.directory ?? path.join(api.runtime.state.resolveStateDir(process.env), PLUGIN_ID);
  const day = createDayCount(path.join(directory, "spent.json"), options.now ?? Date.now);
  const log = api.logger;

  // Replies that were tried, by the turn or the command that asked, and whether all of
  // each was spoken, so none is tried twice. A reply that was refused before any call
  // is not here and may be asked again.
  const spokenReplies = new Map();
  // Which turn a `speak` call belongs to: the hook is told, the tool is not.
  const runOfCall = new Map();
  // The last written reply this assistant sent in each chat, for `/tts latest`, and the
  // last line this plugin said there, which is not a reply. They are kept by chat and
  // not by session, because Telegram runs a command in a session of its own. Neither
  // is written anywhere: after a restart there is no latest until the assistant next
  // replies.
  const lastReply = new Map();
  const ownLine = new Map();

  // One part as audio, or why there is none. Every try is counted before it is made,
  // so a call that fails after the provider has billed it is still under the ceiling.
  async function make(part, target, agentId, isAuthorized) {
    for (let attempt = 0; attempt < TRIES_PER_PART; attempt += 1) {
      if (!isAuthorized()) return { stopped: NOT_AUTHORIZED };
      if ((await day.spent()) + part.length > dayCharacters) {
        return { stopped: `today's speech limit of ${count(dayCharacters)} characters is reached.` };
      }
      await day.charge(part.length);
      if (!isAuthorized()) return { stopped: NOT_AUTHORIZED };
      let result;
      try {
        result = await api.runtime.tts.textToSpeech({
          text: part,
          cfg: api.runtime.config.current(),
          channel: target.channel,
          accountId: target.accountId,
          agentId,
          timeoutMs: SYNTHESIS_TIMEOUT_MS,
        });
      } catch (error) {
        result = { success: false, error: String(error) };
      }
      if (result?.success && result.audioPath) return { audioPath: result.audioPath };
      log.warn(`${PLUGIN_ID}: the speech provider did not make a part: ${result?.error}`);
      if (SPEND_ERROR.test(String(result?.error))) {
        return { stopped: "the speech key is out of credit or over its limit." };
      }
    }
    return {};
  }

  async function speakNow({ text, target, replyKey, agentId, isAuthorized }) {
    const incomplete = (line) => ({ isComplete: false, text: line });
    const said = String(text ?? "").trim();
    if (!said) return incomplete(NO_TEXT);
    if (!target?.channel || !target.to) return incomplete(NO_CHAT);
    if (!isAuthorized()) return incomplete(NOT_AUTHORIZED);
    // The native app's Speak action calls household-app.speak directly. Chat tools
    // never create voice-note replies; calls use their separate audio endpoint too.
    if (target.channel === "household") return incomplete(APP_SPEAK_ONLY);
    const adapter = await api.runtime.channel.outbound.loadAdapter(target.channel);
    if (!adapter?.sendPayload && !adapter?.sendMedia) return incomplete(NO_ADAPTER);
    if (spokenReplies.has(replyKey)) {
      return incomplete(spokenReplies.get(replyKey) ? ALREADY_SPOKEN : ALREADY_TRIED);
    }
    if (said.length > replyCharacters) {
      return incomplete(
        `Not spoken: this reply is ${count(said.length)} characters and one spoken reply may be ${count(replyCharacters)}.`,
      );
    }
    const left = dayCharacters - (await day.spent());
    if (said.length > left) {
      return incomplete(
        `Not spoken: this reply is ${count(said.length)} characters and today has ${count(Math.max(0, left))} left of ${count(dayCharacters)}.`,
      );
    }

    remember(spokenReplies, replyKey, false);
    const parts = splitIntoParts(said);
    const label = (index) => `${index + 1} of ${parts.length}`;
    const problems = [];
    let delivered = 0;
    for (const [index, part] of parts.entries()) {
      const made = await make(part, target, agentId, isAuthorized);
      if (made.stopped) {
        problems.push(`Stopped at part ${label(index)}: ${made.stopped}`);
        break;
      }
      if (!made.audioPath) {
        problems.push(`Part ${label(index)} could not be spoken.`);
        continue;
      }
      if (!isAuthorized()) {
        problems.push(NOT_AUTHORIZED);
        break;
      }
      const send = {
        cfg: api.runtime.config.current(),
        to: target.to,
        accountId: target.accountId,
        threadId: target.threadId,
        mediaLocalRoots: [path.dirname(made.audioPath)],
      };
      const caption = parts.length > 1 ? label(index) : undefined;
      try {
        // Telegram takes a whole payload. A channel built on the SDK's attached results,
        // such as the household app, has only sendText and sendMedia.
        if (adapter.sendPayload) {
          await adapter.sendPayload({
            ...send,
            payload: { ...(caption ? { text: caption } : {}), mediaUrl: made.audioPath, audioAsVoice: true },
          });
        } else {
          await adapter.sendMedia({ ...send, text: caption, mediaUrl: made.audioPath, audioAsVoice: true });
        }
        delivered += 1;
      } catch (error) {
        log.warn(`${PLUGIN_ID}: a voice note was made and not sent: ${error}`);
        problems.push(`Part ${label(index)} was made but could not be sent.`);
      }
    }

    if (delivered === parts.length) {
      remember(spokenReplies, replyKey, true);
      return {
        isComplete: true,
        text:
          parts.length === 1
            ? "Spoken as one voice note."
            : `Spoken as ${parts.length} voice notes, numbered ${label(0)} to ${label(parts.length - 1)}.`,
      };
    }
    const sent = delivered > 0 ? `Sent ${delivered} of ${parts.length} voice notes.` : "Nothing was spoken.";
    return incomplete([sent, ...problems].join("\n"));
  }

  // One reply at a time on this gateway, so two chats cannot both read the day's count
  // before either adds to it, and one reply's parts are never mixed with another's.
  let queue = Promise.resolve();
  function speak(request) {
    const next = queue.then(() => speakNow(request));
    queue = next.catch(() => undefined);
    return next;
  }

  function tool(toolContext) {
    return {
      name: TOOL_NAME,
      label: "Speak",
      description:
        "Speak a text aloud as voice notes in this chat, only when someone asks to hear it. Pass the whole text in one call, however long: it is cut into numbered voice notes and each is sent for you. Call it once for a reply.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["text"],
        properties: { text: { type: "string", description: "The whole text to speak." } },
      },
      async execute(toolCallId, params) {
        // The turn is read once and forgotten, because a provider may use a call's id
        // again in a later turn. A call no turn was named for is a reply of its own:
        // taking it for an earlier one would refuse to speak with nothing spoken.
        const run = runOfCall.get(toolCallId);
        runOfCall.delete(toolCallId);
        const outcome = await speak({
          text: params?.text,
          target: toolContext?.deliveryContext,
          replyKey: run ? `run:${run}` : `call:${randomUUID()}`,
          agentId: toolContext?.agentId,
          isAuthorized: () => isAuthorizedTurn(api, toolContext),
        });
        return {
          content: [{ type: "text", text: `${outcome.text}\n${AFTER_SPEAKING}` }],
          ...(outcome.text.includes(NOT_AUTHORIZED) ? { isError: true } : {}),
        };
      },
    };
  }

  function onBeforeToolCall(event, context) {
    if (isAppContext(context) && [TOOL_NAME, "tts"].includes(event?.toolName)) {
      return { block: true, blockReason: APP_SPEAK_ONLY };
    }
    if (event?.toolName === "tts") {
      return {
        block: true,
        blockReason: `Use the ${TOOL_NAME} tool to speak. It takes the whole text in one call, numbers each voice note and sends it.`,
      };
    }
    if (event?.toolName === TOOL_NAME && event.toolCallId && event.runId) {
      remember(runOfCall, event.toolCallId, event.runId);
    }
    return undefined;
  }

  function onSent(event) {
    const context = event?.context;
    if (event?.type !== "message" || event.action !== "sent" || !context?.success) return;
    const text = String(context.content ?? "").trim();
    const conversation = context.conversationId ?? context.to;
    // A send with no session is not a reply: it is this plugin's own voice note, or a
    // post the host relay made. Nor is one a command sent in its own session, which is
    // how Telegram sends the answer to `/status` and this plugin's own lines.
    if (!event.sessionKey || COMMAND_SESSION.test(event.sessionKey) || !text || !conversation) return;
    const chat = chatOf(context.channelId, conversation);
    // Each reply is its own, so a later one in the same words is spoken when asked for.
    if (ownLine.get(chat) !== text) remember(lastReply, chat, { id: randomUUID(), text });
  }

  // What `/tts` and its words do, as the outcome of speaking or as a line to say.
  async function onTts(action, words, chat, request) {
    if (action === "latest") {
      const latest = lastReply.get(chat);
      if (!latest) return "There is no reply to speak yet.";
      return speak({ ...request, text: latest.text, replyKey: `latest:${latest.id}` });
    }
    if (action === "audio") {
      return speak({ ...request, text: words.join(" "), replyKey: `audio:${randomUUID()}` });
    }
    if (action === "status") {
      return `Spoken today: ${count(await day.spent())} of ${count(dayCharacters)} characters. One spoken reply may be ${count(replyCharacters)}.`;
    }
    return USAGE;
  }

  // A turn that is `/tts` is answered here and goes no further. Every such turn is
  // claimed, an error included: one let through would be spoken by the built-in `/tts`
  // with no ceiling.
  async function onBeforeDispatch(event, context) {
    const typed = TTS_COMMAND.exec(String(event?.content ?? "").trim());
    if (!typed) return undefined;
    if (isAppContext(context)) return { handled: true, text: APP_SPEAK_ONLY };
    const chat = chatOf(context.channelId, context.conversationId);
    const [action, ...words] = typed[1].split(/\s+/);
    let outcome;
    try {
      outcome = await onTts(action.toLowerCase(), words, chat, {
        target: { channel: context.channelId, to: context.conversationId, accountId: context.accountId },
        agentId: /^agent:([^:]+):/i.exec(context.sessionKey ?? "")?.[1],
        // A typed /tts keeps the behaviour it had before the family boundary: it speaks only
        // into the chat it was typed in, under the ceilings. The boundary is the tool's.
        isAuthorized: () => true,
      });
    } catch (error) {
      log.error(`${PLUGIN_ID}: /tts stopped on an error: ${error}`);
      outcome = STOPPED_ON_ERROR;
    }
    // The voice notes are the answer. A line of text is sent only when something is wrong.
    if (outcome.isComplete) return { handled: true };
    const line = outcome.text ?? outcome;
    remember(ownLine, chat, line);
    return { handled: true, text: line };
  }

  // A person's turn whose words may ask to hear the reply gets one line before them.
  function onBeforePromptBuild(event, context) {
    if (context?.trigger !== undefined && context.trigger !== "user") return undefined;
    const words = String(event?.prompt ?? "").replace(METADATA_BLOCK, "");
    if (isAppContext(context)) {
      return { prependContext: "Reply in text in Steward chat. Do not call speak or tts or send generated voice notes. " +
        "If asked to read a chat message aloud, explain: " + APP_SPEAK_ONLY };
    }
    return ASKS_TO_HEAR.test(words) ? { prependContext: HEAR_IT } : undefined;
  }

  return { speak, tool, onBeforeToolCall, onSent, onBeforeDispatch, onBeforePromptBuild };
}

export default {
  id: PLUGIN_ID,
  name: "Household speech",
  description:
    "Speaks a reply as numbered voice notes, each made and sent once, under a ceiling for one reply and for one day.",
  configSchema,
  register(api) {
    const parsed = parseConfig(api.pluginConfig);
    if (parsed.error) {
      api.logger.error(`${PLUGIN_ID}: not started, ${parsed.error}`);
      return;
    }
    const speech = createSpeech(api, parsed.value);
    api.registerTool(speech.tool, { names: [TOOL_NAME] });
    api.registerHook("message:sent", speech.onSent, {
      name: `${PLUGIN_ID}-last-reply`,
      description: "Keeps the last written reply of each chat in memory for /tts latest",
    });
    api.on("before_tool_call", speech.onBeforeToolCall);
    // No time limit is set on this one: a hook past its limit is given up on while it
    // goes on speaking, and the turn then reaches the built-in `/tts` as well.
    api.on("before_dispatch", speech.onBeforeDispatch);
    api.on("before_prompt_build", speech.onBeforePromptBuild);
  },
};

