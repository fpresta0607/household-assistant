// The household-speech OpenClaw plugin: one spoken reply is one clean set of voice notes.
//
// The speech provider and Telegram are stand-ins. The provider is what the plugin calls
// through `api.runtime.tts`, and Telegram is the outbound adapter it loads, so every
// paid call and every message that would reach a chat is counted here.

import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import telegramContexts from "./fixtures/openclaw-telegram-contexts.json" with { type: "json" };

import plugin, {
  PART_CHARACTERS,
  createSpeech,
  parseConfig,
  splitIntoParts,
} from "../../deploy/openclaw/plugins/household-speech/index.js";

const CHAT = "telegram:7000000001";
const SESSION = "agent:main:telegram:direct:7000000001";
const TARGET = { channel: "telegram", to: CHAT, accountId: "default" };
const START = Date.UTC(2026, 9, 10, 15, 0);
const DAY = 24 * 3_600_000;
const CONFIG = { replyCharacters: 8000, dayCharacters: 25000 };
const RUNTIME_CONFIG = {
  plugins: { entries: {
    "household-speech": { enabled: true },
    "household-family-room": { enabled: true, config: { groupChatId: "-7000000002" } },
  } },
  channels: {
    telegram: { groups: { "-7000000002": { allowFrom: ["7000000001"] } } },
    household: { enabled: true, owner: { id: "sam" }, peer: { person: { id: "alex" } } },
  },
  session: { dmScope: "per-channel-peer", groupScope: "per-group" },
};
// A turn in the household app, as OpenClaw 2026.9.4's run-channel-turn builds it: the
// app names no native chat, and its sender is the person's app id.
const APP_PRIVATE = {
  agentId: "main", agentAccountId: "default", messageChannel: "household", requesterSenderId: "sam",
  sessionKey: "agent:main:household:direct:sam",
  deliveryContext: { channel: "household", accountId: "default", to: "household:sam" },
};
const APP_FAMILY = {
  ...APP_PRIVATE, requesterSenderId: "alex", sessionKey: "agent:main:household:group:family",
  deliveryContext: { channel: "household", accountId: "default", to: "household:family" },
};

// About 100 characters a sentence, so a count of sentences is a known length.
const sentence = (index) =>
  `Sentence number ${String(index).padStart(3, "0")} says a plain thing about the day and then it comes to a full stop.`;
const prose = (sentences) => Array.from({ length: sentences }, (_, index) => sentence(index)).join(" ");

// `fails` maps a part's first words to how many times the provider refuses it, and
// `error` is what it says when it does, or what it throws.
function standIns({ fails = {}, error = "openrouter: OpenRouter TTS API error (500)", unsendable = [] } = {}) {
  const spoken = [];
  const sent = [];
  const remaining = { ...fails };
  const runtimeConfig = structuredClone(RUNTIME_CONFIG);
  const api = {
    spoken,
    sent,
    logger: { info() {}, warn() {}, error() {} },
    runtime: {
      config: { current: () => runtimeConfig },
      state: { resolveStateDir: () => "/unused" },
      tts: {
        async textToSpeech(params) {
          spoken.push(params);
          const key = Object.keys(remaining).find((start) => params.text.startsWith(start));
          if (key && remaining[key] > 0) {
            remaining[key] -= 1;
            if (error instanceof Error) throw error;
            return { success: false, error };
          }
          return { success: true, audioPath: `/media/tool-speech-synthesis/voice-${spoken.length}.mp3`, audioAsVoice: true };
        },
      },
      channel: {
        outbound: {
          async loadAdapter(channel) {
            // The household app's adapter, like any chat channel built on the SDK's
            // attached results, has sendText and sendMedia and no sendPayload.
            if (channel === "household") {
              return {
                async sendText() { assert.fail("a voice note is media"); },
                async sendMedia(params) {
                  sent.push({ ...params, payload: { text: params.text, mediaUrl: params.mediaUrl, audioAsVoice: params.audioAsVoice } });
                  return { channel, messageId: `app-${sent.length}` };
                },
              };
            }
            if (channel !== "telegram") return undefined;
            return {
              async sendPayload(params) {
                if (unsendable.includes(params.payload.text)) throw new Error("Telegram sendVoice failed (502)");
                sent.push(params);
                return { messageId: String(900 + sent.length) };
              },
            };
          },
        },
      },
    },
  };
  return api;
}

async function speech(api, { config = CONFIG, clock = { now: START }, directory } = {}) {
  const kept = directory ?? (await mkdtemp(path.join(tmpdir(), "household-speech-")));
  const made = createSpeech(api, config, { now: () => clock.now, directory: kept });
  // These tests are about delivery; who may speak is tested through the tool and /tts.
  return { clock, directory: kept, ...made, speak: (request) => made.speak({ isAuthorized: () => true, ...request }) };
}

const captions = (api) => api.sent.map((send) => send.payload.text);

test("a long text is cut at sentence ends into parts under the limit", () => {
  const text = prose(50);

  const parts = splitIntoParts(text);

  assert.equal(parts.length, 3);
  assert.equal(parts.join(" "), text);
  for (const part of parts) {
    assert.ok(part.length <= PART_CHARACTERS, `${part.length} is over the limit`);
    assert.match(part, /^Sentence number \d{3} /);
    assert.match(part, /full stop\.$/);
  }
  const lengths = parts.map((part) => part.length);
  assert.ok(Math.max(...lengths) - Math.min(...lengths) < 300, `parts are uneven: ${lengths}`);
});

test("no length of text leaves a scrap as its last part", () => {
  // A text just under a whole number of full parts used to fill each part and leave
  // one sentence over: 39 sentences of 100 characters came out as 1,918, 1,918 and 100.
  for (const words of ["", ", more or less", ", as far as anyone in this house can tell"]) {
    for (let sentences = 1; sentences <= 140; sentences += 1) {
      const text = prose(sentences).replaceAll(" stop.", ` stop${words}.`);

      const lengths = splitIntoParts(text).map((part) => part.length);

      assert.equal(lengths.reduce((sum, length) => sum + length + 1, -1), text.length);
      assert.ok(Math.max(...lengths) <= PART_CHARACTERS, `${text.length} characters: ${lengths}`);
      assert.ok(
        Math.min(...lengths) * 2 >= Math.max(...lengths),
        `${text.length} characters were cut unevenly: ${lengths}`,
      );
    }
  }
});

for (const [name, text, limit, expected] of [
  ["a short text is one part", "Milk is on the list.", 100, ["Milk is on the list."]],
  ["nothing is no parts", "  \n ", 100, []],
  ["a question and an exclamation end sentences", "Is it late? It is! Go to bed.", 12, ["Is it late?", "It is!", "Go to bed."]],
  ["a paragraph break ends a part's sentence", "First line\n\nSecond line", 12, ["First line", "Second line"]],
  ["a sentence over the limit is cut between words", "one two three four five six", 9, ["one two", "three", "four five", "six"]],
  ["a word over the limit is cut where it must be", "abcdefghij", 4, ["abcd", "efgh", "ij"]],
]) {
  test(`splitting: ${name}`, () => {
    assert.deepEqual(splitIntoParts(text, limit), expected);
  });
}

test("a long reply arrives as numbered voice notes in order, each sent once", async () => {
  const api = standIns();
  const { speak } = await speech(api);
  const text = prose(50);

  const result = await speak({ text, target: TARGET, replyKey: "run-1", agentId: "main" });

  assert.deepEqual(captions(api), ["1 of 3", "2 of 3", "3 of 3"]);
  assert.equal(api.spoken.map((call) => call.text).join(" "), text);
  assert.equal(api.spoken.length, 3);
  for (const [index, send] of api.sent.entries()) {
    assert.equal(send.to, CHAT);
    assert.equal(send.accountId, "default");
    assert.deepEqual(send.cfg, api.runtime.config.current());
    assert.equal(send.payload.audioAsVoice, true);
    assert.equal(send.payload.mediaUrl, `/media/tool-speech-synthesis/voice-${index + 1}.mp3`);
    assert.deepEqual(send.mediaLocalRoots, ["/media/tool-speech-synthesis"]);
  }
  assert.equal(api.spoken[0].channel, "telegram");
  assert.equal(api.spoken[0].agentId, "main");
  assert.equal(result.isComplete, true);
  assert.equal(result.text, "Spoken as 3 voice notes, numbered 1 of 3 to 3 of 3.");
});

test("a short reply is one voice note with no number on it", async () => {
  const api = standIns();
  const { speak } = await speech(api);

  const result = await speak({ text: "Milk is on the list.", target: TARGET, replyKey: "run-1" });

  assert.equal(api.sent.length, 1);
  assert.equal(api.sent[0].payload.text, undefined);
  assert.equal(result.text, "Spoken as one voice note.");
});

test("a part that fails once is tried once more and every part is still sent once", async () => {
  const api = standIns({ fails: { [sentence(17).slice(0, 19)]: 1 } });
  const { speak } = await speech(api);

  const result = await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });

  assert.equal(api.spoken.length, 4);
  assert.equal(api.spoken[1].text, api.spoken[2].text);
  assert.deepEqual(captions(api), ["1 of 3", "2 of 3", "3 of 3"]);
  assert.equal(result.isComplete, true);
});

test("a part that fails twice is said in one line, and no delivered part is sent again", async () => {
  const api = standIns({ fails: { [sentence(17).slice(0, 19)]: 5 } });
  const { speak } = await speech(api);

  const result = await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });

  assert.equal(api.spoken.length, 4, "part 2 is tried twice and no more");
  assert.deepEqual(captions(api), ["1 of 3", "3 of 3"]);
  assert.equal(result.isComplete, false);
  assert.equal(result.text, "Sent 2 of 3 voice notes.\nPart 2 of 3 could not be spoken.");
});

test("a reply that was tried is not tried again, whatever is asked for in the same turn", async () => {
  const api = standIns({ fails: { [sentence(17).slice(0, 19)]: 5 } });
  const { speak } = await speech(api);
  await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });

  const again = await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });
  const reworded = await speak({ text: "Part two again, shorter this time.", target: TARGET, replyKey: "run-1" });

  assert.equal(api.spoken.length, 4);
  assert.deepEqual(captions(api), ["1 of 3", "3 of 3"]);
  // Part 2 never arrived, so the line must not say the reply was spoken.
  assert.equal(
    again.text,
    "This reply was already tried once and not all of it was spoken. Nothing more was sent.",
  );
  assert.equal(reworded.text, again.text);
});

test("a reply that was spoken whole says so when it is asked for again", async () => {
  const api = standIns();
  const { speak } = await speech(api);
  await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });

  const again = await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });

  assert.equal(api.spoken.length, 3);
  assert.equal(again.isComplete, false);
  assert.equal(again.text, "This reply was already spoken once. Nothing more was sent.");
});

test("a voice note Telegram refuses is not made again and not sent again", async () => {
  const api = standIns({ unsendable: ["2 of 3"] });
  const { speak } = await speech(api);

  const result = await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });

  assert.equal(api.spoken.length, 3);
  assert.deepEqual(captions(api), ["1 of 3", "3 of 3"]);
  assert.equal(result.text, "Sent 2 of 3 voice notes.\nPart 2 of 3 was made but could not be sent.");
});

for (const error of [
  "openrouter: OpenRouter TTS API error (402): insufficient credits",
  "openrouter: OpenRouter TTS API error (429): rate limit exceeded",
  "openrouter: Payment Required",
  "openrouter: insufficient funds",
  "openrouter: the balance on this key is too low",
  "openrouter: monthly quota exceeded",
]) {
  test(`a refusal for want of credit or quota is not tried again and stops the reply: ${error}`, async () => {
    const api = standIns({ fails: { [sentence(17).slice(0, 19)]: 5 }, error });
    const { speak } = await speech(api);

    const result = await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });

    assert.equal(api.spoken.length, 2, "no second try and no third part");
    assert.deepEqual(captions(api), ["1 of 3"]);
    assert.equal(
      result.text,
      "Sent 1 of 3 voice notes.\nStopped at part 2 of 3: the speech key is out of credit or over its limit.",
    );
  });
}

for (const error of [
  "openrouter: OpenRouter TTS API error (500)",
  "TTS conversion failed",
  "timed out after 120000ms",
  new Error("socket hang up"),
]) {
  test(`any other failure of the provider is tried once more and no more: ${error}`, async () => {
    const api = standIns({ fails: { [sentence(17).slice(0, 19)]: 5 }, error });
    const { speak } = await speech(api);

    const result = await speak({ text: prose(50), target: TARGET, replyKey: "run-1" });

    assert.equal(api.spoken.length, 4);
    assert.deepEqual(captions(api), ["1 of 3", "3 of 3"]);
    assert.equal(result.text, "Sent 2 of 3 voice notes.\nPart 2 of 3 could not be spoken.");
  });
}

test("two replies asked for at once are spoken one after the other, so both count against the day", async () => {
  const api = standIns();
  const text = prose(20);
  const dayCharacters = text.length + 100;
  const { speak } = await speech(api, { config: { replyCharacters: 8000, dayCharacters } });

  const outcomes = await Promise.all([
    speak({ text, target: TARGET, replyKey: "run-1" }),
    speak({ text, target: TARGET, replyKey: "run-2" }),
  ]);

  // Side by side, both would read a day with nothing spent and both would be spoken.
  assert.deepEqual(outcomes.map((outcome) => outcome.isComplete), [true, false]);
  assert.equal(api.spoken.length, 1);
  assert.equal(
    outcomes[1].text,
    `Not spoken: this reply is ${text.length.toLocaleString("en-US")} characters and today has 100 left of ${dayCharacters.toLocaleString("en-US")}.`,
  );
});

test("a reply over the ceiling is not spoken and says so, and a shorter one then is", async () => {
  const api = standIns();
  const { speak } = await speech(api, { config: { replyCharacters: 1000, dayCharacters: 25000 } });
  const long = prose(12);

  const refused = await speak({ text: long, target: TARGET, replyKey: "run-1" });

  assert.equal(api.spoken.length, 0);
  assert.equal(api.sent.length, 0);
  assert.equal(
    refused.text,
    `Not spoken: this reply is ${long.length.toLocaleString("en-US")} characters and one spoken reply may be 1,000.`,
  );

  const shorter = await speak({ text: prose(5), target: TARGET, replyKey: "run-1" });

  assert.equal(shorter.text, "Spoken as one voice note.");
  assert.equal(api.sent.length, 1);
});

test("the day's ceiling counts every call, stops the next reply, and lifts the next day", async () => {
  const api = standIns();
  const config = { replyCharacters: 8000, dayCharacters: 6000 };
  const first = await speech(api, { config });
  const text = prose(50);
  await first.speak({ text, target: TARGET, replyKey: "run-1" });

  // A gateway that restarted reads what the day has already spent.
  const restarted = await speech(api, { config, clock: first.clock, directory: first.directory });
  const refused = await restarted.speak({ text, target: TARGET, replyKey: "run-2" });

  const spent = api.spoken.reduce((sum, call) => sum + call.text.length, 0);
  assert.equal(api.spoken.length, 3);
  assert.equal(
    refused.text,
    `Not spoken: this reply is ${text.length.toLocaleString("en-US")} characters and today has ${(6000 - spent).toLocaleString("en-US")} left of 6,000.`,
  );

  restarted.clock.now += DAY + 3_600_000;
  const nextDay = await restarted.speak({ text, target: TARGET, replyKey: "run-3" });

  assert.equal(nextDay.isComplete, true);
  assert.equal(api.spoken.length, 6);
});

test("a retry that would pass the day's ceiling is not made", async () => {
  const text = prose(50);
  const third = splitIntoParts(text)[2];
  const api = standIns({ fails: { [third.slice(0, 19)]: 1 } });
  const { speak } = await speech(api, { config: { replyCharacters: 8000, dayCharacters: text.length + 100 } });

  const result = await speak({ text, target: TARGET, replyKey: "run-1" });

  assert.equal(api.spoken.length, 3, "the third part's second try would pass the ceiling");
  assert.deepEqual(captions(api), ["1 of 3", "2 of 3"]);
  assert.equal(
    result.text,
    `Sent 2 of 3 voice notes.\nStopped at part 3 of 3: today's speech limit of ${(text.length + 100).toLocaleString("en-US")} characters is reached.`,
  );
});

for (const [name, request, line] of [
  ["no text", { text: "   ", target: TARGET }, "Not spoken: there was no text."],
  ["no chat", { text: "Hello.", target: {} }, "Not spoken: there is no chat here to send a voice note to."],
  ["a channel with no sender", { text: "Hello.", target: { channel: "webchat", to: "someone" } }, "Not spoken: the voice delivery adapter is unavailable."],
]) {
  test(`nothing is spoken with ${name}`, async () => {
    const api = standIns();
    const { speak } = await speech(api);

    const result = await speak({ ...request, replyKey: "run-1" });

    assert.equal(result.text, line);
    assert.equal(api.spoken.length, 0);
    assert.equal(api.sent.length, 0);
  });
}

const toolContext = telegramContexts.cases.find((entry) => entry.name === "fresh-private").context;

test("speak accepts pinned fresh and queued private and family routes", async () => {
  for (const recorded of telegramContexts.cases) {
    const api = standIns();
    const made = await speech(api);

    const result = await made.tool(recorded.context).execute(recorded.name, { text: "Requested reply." });

    assert.match(result.content[0].text, /^Spoken as one voice note/, recorded.name);
    assert.equal(api.spoken.length, 1);
    assert.equal(api.sent[0].to, recorded.context.deliveryContext.to);
  }
});

test("speak denies child shared-main foreign mismatched and unlisted authority before synthesis", async () => {
  const denied = [
    { sessionKey: "agent:main:subagent:child" },
    { sessionKey: "agent:main:main" },
    { agentId: "other" }, { agentAccountId: "other" }, { messageChannel: "webchat" },
    { requesterSenderId: "7000000009" }, { requesterSenderId: undefined },
    { nativeChannelId: "-7000000002" }, { nativeChannelId: null },
    { deliveryContext: { ...TARGET, to: "telegram:7000000009" } },
    { deliveryContext: { ...TARGET, accountId: "other" } },
    { deliveryContext: { ...TARGET, threadId: "9" } },
    { sessionKey: "agent:main:telegram:group:-7000000009", nativeChannelId: "-7000000009",
      deliveryContext: { ...TARGET, to: "telegram:-7000000009" } },
    { oneShotCliRun: true },
  ];
  for (const change of denied) {
    const api = standIns();
    const made = await speech(api);

    const result = await made.tool({ ...toolContext, ...change }).execute("denied", { text: "Private reply." });

    assert.equal(result.isError, true, JSON.stringify(change));
    assert.match(result.content[0].text, /not authorized/i);
    assert.equal(api.spoken.length, 0);
    assert.equal(api.sent.length, 0);
  }
});

test("speak distinguishes missing destination from missing adapter without synthesis", async () => {
  for (const [context, expected] of [
    [{ ...toolContext, deliveryContext: undefined }, /there is no chat/],
    [toolContext, /voice delivery adapter is unavailable/],
  ]) {
    const api = standIns();
    api.runtime.channel.outbound.loadAdapter = async () => undefined;
    const made = await speech(api);

    const result = await made.tool(context).execute("missing", { text: "Requested reply." });

    assert.match(result.content[0].text, expected);
    assert.equal(api.spoken.length, 0);
    assert.equal(api.sent.length, 0);
  }
});

test("speak rechecks current family membership after discovery and before sending", async () => {
  for (const revokeDuringSynthesis of [false, true]) {
    const api = standIns();
    const made = await speech(api);
    const tool = made.tool(toolContext);
    const revoke = () => { api.runtime.config.current().channels.telegram.groups["-7000000002"].allowFrom = []; };
    if (revokeDuringSynthesis) {
      const synthesize = api.runtime.tts.textToSpeech;
      api.runtime.tts.textToSpeech = async (params) => { const result = await synthesize(params); revoke(); return result; };
    } else revoke();

    const result = await tool.execute("revoked", { text: "Requested reply." });

    assert.match(result.content[0].text, /not authorized/i);
    assert.equal(api.spoken.length, revokeDuringSynthesis ? 1 : 0);
    assert.equal(api.sent.length, 0);
  }
});

test("nothing is spoken by a caller that brings no authorization decision", async () => {
  const api = standIns();
  const made = createSpeech(api, CONFIG, { now: () => START, directory: await mkdtemp(path.join(tmpdir(), "household-speech-")) });

  await assert.rejects(made.speak({ text: "Hello.", target: TARGET, replyKey: "run-1" }), TypeError);

  assert.equal(api.spoken.length, 0);
  assert.equal(api.sent.length, 0);
});

test("the speak tool sends the voice notes itself and hands the model only a line of text", async () => {
  const api = standIns();
  const { tool, onBeforeToolCall } = await speech(api);
  await onBeforeToolCall({ toolName: "speak", toolCallId: "call-1", runId: "run-1" });

  const result = await tool(toolContext).execute("call-1", { text: prose(50) });

  assert.deepEqual(captions(api), ["1 of 3", "2 of 3", "3 of 3"]);
  // No audio rides on the result, so OpenClaw has nothing to attach the reply's text to
  // and nothing to send a second time: the model's one written reply is the only text.
  assert.deepEqual(Object.keys(result), ["content"]);
  assert.equal(result.content.length, 1);
  assert.equal(result.content[0].type, "text");
  assert.match(result.content[0].text, /^Spoken as 3 voice notes, numbered 1 of 3 to 3 of 3\.\n/);
  assert.ok(api.sent.every((send) => send.payload.mediaUrl && send.payload.audioAsVoice === true));
});

test("a second speak call in the same turn sends nothing, and the next turn speaks again", async () => {
  const api = standIns();
  const { tool, onBeforeToolCall } = await speech(api);
  const speakTool = tool(toolContext);
  await onBeforeToolCall({ toolName: "speak", toolCallId: "call-1", runId: "run-1" });
  await onBeforeToolCall({ toolName: "speak", toolCallId: "call-2", runId: "run-1" });
  await onBeforeToolCall({ toolName: "speak", toolCallId: "call-3", runId: "run-2" });
  await speakTool.execute("call-1", { text: "Milk is on the list." });

  const second = await speakTool.execute("call-2", { text: "Milk is on the list, again." });
  const nextTurn = await speakTool.execute("call-3", { text: "Milk is on the list." });

  assert.match(second.content[0].text, /^This reply was already spoken once\. Nothing more was sent\./);
  assert.match(nextTurn.content[0].text, /^Spoken as one voice note\./);
  assert.equal(api.sent.length, 2);
});

test("a speak call the gateway names no turn for is a reply of its own, never an earlier one", async () => {
  const api = standIns();
  const { tool, onBeforeToolCall } = await speech(api);
  const speakTool = tool(toolContext);
  // Some providers number their calls from nothing in every turn.
  await speakTool.execute("call_0", { text: "Milk is on the list." });
  await onBeforeToolCall({ toolName: "speak", toolCallId: "call_1", runId: "run-1" });
  await speakTool.execute("call_1", { text: "Eggs are on the list." });

  const sameId = await speakTool.execute("call_0", { text: "Bread is on the list." });
  const staleTurn = await speakTool.execute("call_1", { text: "Tea is on the list." });

  assert.match(sameId.content[0].text, /^Spoken as one voice note\./);
  assert.match(staleTurn.content[0].text, /^Spoken as one voice note\./);
  assert.equal(api.sent.length, 4);
});

test("the built-in tts tool is refused and names the tool to use", async () => {
  const { onBeforeToolCall } = await speech(standIns());

  const decision = await onBeforeToolCall({ toolName: "tts", toolCallId: "call-1", runId: "run-1" });

  assert.equal(decision.block, true);
  assert.match(decision.blockReason, /speak/);
  assert.equal(await onBeforeToolCall({ toolName: "exec", toolCallId: "call-2", runId: "run-1" }), undefined);
});

// A `/tts` turn as `before_dispatch` is handed it. Telegram names the chat by its routing
// target there and runs a command in a session of its own. When a reply is sent it names
// the same chat by its bare id, in the chat's own session.
const SLASH_SESSION = "agent:main:telegram:slash:7000000001";
const typed = (content, context = {}) => [
  { content, channel: "telegram", sessionKey: SLASH_SESSION },
  { channelId: "telegram", accountId: "default", conversationId: CHAT, sessionKey: SLASH_SESSION, ...context },
];
const sentReply = (content, extra = {}) => ({
  type: "message",
  action: "sent",
  sessionKey: SESSION,
  context: {
    success: true,
    channelId: "telegram",
    to: "7000000001",
    conversationId: "7000000001",
    content,
    ...extra,
  },
});

test("/tts latest speaks the last reply by the same rules, and only once", async () => {
  const api = standIns();
  const { onBeforeDispatch, onSent } = await speech(api);
  await onSent(sentReply("An older reply."));
  await onSent(sentReply(prose(50)));
  await onSent(sentReply("A reply that never reached the chat.", { success: false }));

  const first = await onBeforeDispatch(...typed("/tts latest"));
  const second = await onBeforeDispatch(...typed("/tts latest"));

  assert.deepEqual(captions(api), ["1 of 3", "2 of 3", "3 of 3"]);
  assert.ok(api.sent.every((send) => send.to === CHAT && send.accountId === "default"));
  assert.equal(api.spoken[0].agentId, "main");
  // The voice notes are the answer. A line of text is sent only when something is wrong.
  assert.deepEqual(first, { handled: true });
  assert.deepEqual(second, {
    handled: true,
    text: "This reply was already spoken once. Nothing more was sent.",
  });
  assert.equal(api.spoken.length, 3);
});

test("/tts latest says what went wrong in its own reply, and that reply is not the next latest", async () => {
  const api = standIns();
  const { onBeforeDispatch, onSent } = await speech(api, { config: { replyCharacters: 1000, dayCharacters: 25000 } });
  const long = prose(12);
  await onSent(sentReply(long));

  const refused = await onBeforeDispatch(...typed("/tts@CoreyBot latest"));
  await onSent(sentReply(refused.text));
  const again = await onBeforeDispatch(...typed("/tts latest"));

  assert.deepEqual(refused, {
    handled: true,
    text: "Not spoken: this reply is 1,043 characters and one spoken reply may be 1,000.",
  });
  assert.deepEqual(again, refused);
  assert.equal(api.spoken.length, 0);
});

test("/tts latest does not speak a send that no session made, such as this plugin's own voice note", async () => {
  const api = standIns();
  const { onBeforeDispatch, onSent } = await speech(api);
  await onSent(sentReply("Milk is on the list."));
  await onSent({ ...sentReply("2 of 3"), sessionKey: undefined });

  await onBeforeDispatch(...typed("/tts latest"));

  assert.deepEqual(api.spoken.map((call) => call.text), ["Milk is on the list."]);
});

test("/tts latest does not speak a command's own answer, which Telegram sends in the command's session", async () => {
  const api = standIns();
  const { onBeforeDispatch, onSent } = await speech(api);
  await onSent(sentReply("Milk is on the list."));
  await onSent({ ...sentReply("Session: 41 messages, 12 tools."), sessionKey: SLASH_SESSION });

  await onBeforeDispatch(...typed("/tts latest"));

  assert.deepEqual(api.spoken.map((call) => call.text), ["Milk is on the list."]);
});

test("/tts latest speaks a later reply that says the same words as one it already spoke", async () => {
  const api = standIns();
  const { onBeforeDispatch, onSent } = await speech(api);
  await onSent(sentReply("Done."));
  await onBeforeDispatch(...typed("/tts latest"));
  await onSent(sentReply("Done."));

  const later = await onBeforeDispatch(...typed("/tts latest"));
  const again = await onBeforeDispatch(...typed("/tts latest"));

  assert.deepEqual(later, { handled: true });
  assert.equal(again.text, "This reply was already spoken once. Nothing more was sent.");
  assert.equal(api.spoken.length, 2);
});

test("/tts latest speaks the reply of the chat it was typed in, not another chat's", async () => {
  const api = standIns();
  const { onBeforeDispatch, onSent } = await speech(api);
  await onSent(sentReply("Milk is on the list.", { to: "7000000002", conversationId: "7000000002" }));

  const here = await onBeforeDispatch(...typed("/tts latest"));
  const there = await onBeforeDispatch(...typed("/tts latest", { conversationId: "telegram:7000000002:topic:4" }));

  assert.deepEqual(here, { handled: true, text: "There is no reply to speak yet." });
  assert.deepEqual(there, { handled: true });
  assert.deepEqual(api.sent.map((send) => send.to), ["telegram:7000000002:topic:4"]);
});

for (const [name, body, expected] of [
  ["latest with nothing said yet", "/tts latest", "There is no reply to speak yet."],
  ["audio with no words", "/tts audio", "Not spoken: there was no text."],
  ["switching speech on for every reply", "/tts on", "Use /tts latest to hear the last reply, /tts audio and some words to hear them, or /tts status."],
  ["no action", "/tts", "Use /tts latest to hear the last reply, /tts audio and some words to hear them, or /tts status."],
  ["capital letters", "/TTS Latest", "There is no reply to speak yet."],
  ["a colon before the action", "/tts: on", "Use /tts latest to hear the last reply, /tts audio and some words to hear them, or /tts status."],
  ["a colon and no space", "/tts:latest", "There is no reply to speak yet."],
  ["a bot's name and a colon", "/tts@CoreyBot: latest", "There is no reply to speak yet."],
  ["a colon after a space", "/tts : on", "Use /tts latest to hear the last reply, /tts audio and some words to hear them, or /tts status."],
]) {
  test(`/tts: ${name}`, async () => {
    const api = standIns();
    const { onBeforeDispatch } = await speech(api);

    assert.deepEqual(await onBeforeDispatch(...typed(body)), { handled: true, text: expected });
    assert.equal(api.spoken.length, 0);
  });
}

test("/tts audio speaks the words it is given, and /tts status says what the day has spent", async () => {
  const api = standIns();
  const { onBeforeDispatch } = await speech(api);

  const spoken = await onBeforeDispatch(...typed("/tts audio Milk is on the list."));
  const status = await onBeforeDispatch(...typed("/tts status"));

  assert.deepEqual(spoken, { handled: true });
  assert.equal(api.spoken[0].text, "Milk is on the list.");
  assert.equal(api.sent[0].to, CHAT);
  assert.deepEqual(status, {
    handled: true,
    text: "Spoken today: 20 of 25,000 characters. One spoken reply may be 8,000.",
  });
});

for (const body of ["Speak it to me.", "/ttsx latest", "/tts-on", "/status", "what does /tts latest do?", "", undefined]) {
  test(`a turn that is not /tts is left to the assistant: ${JSON.stringify(body)}`, async () => {
    const api = standIns();
    const { onBeforeDispatch, onSent } = await speech(api);
    await onSent(sentReply("Milk is on the list."));

    assert.equal(await onBeforeDispatch(...typed(body)), undefined);
    assert.equal(api.spoken.length, 0);
  });
}

const TODAY = [new Date(START).getFullYear(), new Date(START).getMonth() + 1, new Date(START).getDate()].join("-");

for (const [name, content] of [
  ["text that is not JSON", "not json"],
  ["an empty object", "{}"],
  ["a list", "[]"],
  ["a bare number", "123"],
  ["nothing but null", "null"],
  ["a day with no count", JSON.stringify({ day: TODAY })],
  ["a count that is text", JSON.stringify({ day: TODAY, characters: "7" })],
  ["a count below nothing", JSON.stringify({ day: TODAY, characters: -5000 })],
  ["a count that is not whole", JSON.stringify({ day: TODAY, characters: 1.5 })],
  ["a count with no day", JSON.stringify({ characters: 7 })],
]) {
  test(`a day's count the plugin cannot vouch for stops speech and never reads as nothing spent: ${name}`, async () => {
    const api = standIns();
    const made = await speech(api);
    await writeFile(path.join(made.directory, "spent.json"), content);
    await made.onSent(sentReply("Milk is on the list."));

    await assert.rejects(made.speak({ text: "Hello.", target: TARGET, replyKey: "run-1" }));
    // The turn is still claimed, so the built-in `/tts` never speaks it with no ceiling.
    for (const body of ["/tts latest", "/tts audio Hello.", "/tts status"]) {
      assert.deepEqual(await made.onBeforeDispatch(...typed(body)), {
        handled: true,
        text: "Speech stopped on an error. Nothing more was sent.",
      });
    }
    assert.equal(api.spoken.length, 0);
  });
}

test("nothing the plugin says holds a semicolon or an em dash", async () => {
  const lines = [];
  for (const options of [
    {},
    { fails: { [sentence(17).slice(0, 19)]: 50 } },
    { fails: { [sentence(17).slice(0, 19)]: 50 }, error: "quota exceeded" },
    { unsendable: ["2 of 3"] },
  ]) {
    const api = standIns(options);
    const made = await speech(api, { config: { replyCharacters: 6000, dayCharacters: 11000 } });
    const speakTool = made.tool(toolContext);
    for (const text of [prose(50), prose(50), prose(70), ""]) {
      lines.push((await speakTool.execute(`call-${lines.length}`, { text })).content[0].text);
    }
    for (const body of ["/tts", "/tts latest", "/tts status", "/tts audio"]) {
      lines.push((await made.onBeforeDispatch(...typed(body))).text ?? "");
    }
    lines.push((await made.onBeforeToolCall({ toolName: "tts" })).blockReason);
    lines.push(speakTool.description);
    lines.push(made.onBeforePromptBuild({ prompt: "voice note please" }, { trigger: "user" }).prependContext);
    // A second request in one turn, for a reply spoken whole or in part.
    await made.onBeforeToolCall({ toolName: "speak", toolCallId: "first", runId: "run-1" });
    await made.onBeforeToolCall({ toolName: "speak", toolCallId: "second", runId: "run-1" });
    await speakTool.execute("first", { text: sentence(17) });
    lines.push((await speakTool.execute("second", { text: sentence(17) })).content[0].text);
    lines.push((await made.tool({ agentId: "main" }).execute("nowhere", { text: "Hello." })).content[0].text);
    await writeFile(path.join(made.directory, "spent.json"), "not json");
    lines.push((await made.onBeforeDispatch(...typed("/tts status"))).text);
  }

  for (const start of [
    "Spoken as 3 voice notes",
    "Sent 2 of 3 voice notes.",
    "Stopped at part",
    "Not spoken: this reply is",
    "Not spoken: there was no text.",
    "Not spoken: there is no chat here",
    "This reply was already spoken once.",
    "This reply was already tried once",
    "Speech stopped on an error.",
    "There is no reply to speak yet.",
    "Spoken today:",
    "Use /tts latest",
  ]) {
    assert.ok(lines.some((line) => line.includes(start)), `no line says: ${start}`);
  }
  for (const line of lines) assert.doesNotMatch(line, /[;—]/);
});

for (const [name, raw, problem] of [
  ["no config", undefined, /expected a config object/],
  ["an unknown key", { ...CONFIG, voice: "will" }, /unknown config keys: voice/],
  ["a missing ceiling", { replyCharacters: 8000 }, /dayCharacters must be a whole number of characters, 1 or more/],
  ["a ceiling of nothing", { replyCharacters: 0, dayCharacters: 25000 }, /replyCharacters must be a whole number/],
  ["a ceiling that is not a number", { replyCharacters: "8000", dayCharacters: 25000 }, /replyCharacters must be a whole number/],
]) {
  test(`the config is refused with ${name}`, () => {
    assert.match(parseConfig(raw).error, problem);
  });
}

test("the config is read as the two ceilings", () => {
  assert.deepEqual(parseConfig(CONFIG), { value: CONFIG });
});

function registration(pluginConfig) {
  const registered = { tools: [], commands: [], hooks: [], typed: [], errors: [] };
  const api = standIns();
  plugin.register({
    ...api,
    pluginConfig,
    logger: { info() {}, warn() {}, error: (message) => registered.errors.push(message) },
    runtime: { ...api.runtime, state: { resolveStateDir: () => path.join(tmpdir(), "household-speech-unused") } },
    registerTool: (factory, options) => registered.tools.push({ factory, options }),
    registerCommand: (definition) => registered.commands.push(definition),
    registerHook: (event, handler, options) => registered.hooks.push({ event, handler, options }),
    on: (event, handler, options) => registered.typed.push({ event, handler, options }),
  });
  return registered;
}

const HEAR_IT = "If they are asking to hear your reply, call speak once with the whole reply. Written text is never heard.";
const TELEGRAM_ENVELOPE = 'Conversation info (untrusted metadata):\n```json\n{"chat": "voice and text"}\n```\n';

for (const [name, prompt] of [
  ["a voice note asked for in the app", "Say your answer as a voice note."],
  ["a short ask", "voice note please"],
  ["out loud", "Can you say that out loud?"],
  ["read it to me", "Read it to me"],
  ["a Telegram voice note asking to be spoken to", `${TELEGRAM_ENVELOPE}[Audio transcript (machine-generated, untrusted)]: "Speak it to me."`],
]) {
  test(`a turn that may ask to hear the reply is told to call speak: ${name}`, async () => {
    const made = await speech(standIns());

    const added = made.onBeforePromptBuild({ prompt }, { trigger: "user" });

    assert.deepEqual(added, { prependContext: HEAR_IT });
  });
}

for (const [name, prompt, context] of [
  ["a question with no ask to hear it", "What did I ask you to remember about the garage?", { trigger: "user" }],
  ["an empty message", "", { trigger: "user" }],
  ["words only in OpenClaw's metadata", `${TELEGRAM_ENVELOPE}What time is it?`, { trigger: "user" }],
  ["a turn no person started", "Read the morning note aloud.", { trigger: "cron" }],
]) {
  test(`a turn is left alone: ${name}`, async () => {
    const made = await speech(standIns());

    assert.equal(made.onBeforePromptBuild({ prompt }, context), undefined);
  });
}

test("the plugin registers the speak tool and its four hooks, and no command", () => {
  const registered = registration(CONFIG);

  assert.deepEqual(registered.errors, []);
  assert.deepEqual(registered.tools.map((tool) => tool.options), [{ names: ["speak"] }]);
  assert.equal(registered.tools[0].factory(toolContext).name, "speak");
  // Telegram keeps a built-in command's own handler and skips a plugin command of the
  // same name, so `/tts` is claimed in `before_dispatch` and no command is registered.
  assert.deepEqual(registered.commands, []);
  assert.deepEqual(registered.hooks.map((hook) => hook.event), ["message:sent"]);
  assert.deepEqual(registered.typed.map((hook) => hook.event), ["before_tool_call", "before_dispatch", "before_prompt_build"]);
  // A claiming hook with a time limit is given up on at the limit while it goes on
  // speaking, and the turn then falls through to the built-in `/tts`.
  assert.ok(registered.typed.every((hook) => hook.options?.timeoutMs === undefined));
});

test("the plugin does not start without its ceilings", () => {
  const registered = registration({ replyCharacters: 8000 });

  assert.equal(registered.errors.length, 1);
  assert.match(registered.errors[0], /household-speech: not started, dayCharacters must be/);
  assert.deepEqual([registered.tools, registered.commands, registered.hooks, registered.typed], [[], [], [], []]);
});

test("app chat requests explain the Speak action without generating or posting voice notes", async () => {
  const ownersOwnSession = { ...APP_FAMILY, requesterSenderId: "sam", sessionKey: "agent:main:household:group:family:sender:sam" };
  for (const context of [APP_PRIVATE, APP_FAMILY, { ...APP_FAMILY, requesterSenderId: "household:sam" }, ownersOwnSession]) {
    const api = standIns();
    const made = await speech(api);

    const result = await made.tool(context).execute("app", { text: prose(50) });

    assert.match(result.content[0].text, /long-press it and choose Speak/, JSON.stringify(context));
    assert.equal(api.spoken.length, 0);
    assert.equal(api.sent.length, 0);
  }
});

test("app speech commands and tools direct people to deliberate playback, while Telegram stays available", async () => {
  const api = standIns();
  const made = await speech(api);
  for (const context of [APP_PRIVATE, APP_FAMILY]) {
    const instruction = made.onBeforePromptBuild({ prompt: "Please speak it to me" }, { ...context, trigger: "user" });
    assert.match(instruction.prependContext, /Do not call speak or tts/);
    for (const toolName of ["tts", "speak"]) {
      assert.equal(made.onBeforeToolCall({ toolName }, context).block, true);
    }
    for (const content of ["/tts latest", "/tts audio Read this", "/tts on"]) {
      const result = await made.onBeforeDispatch({ content }, { ...context, channelId: "household" });
      assert.equal(result.handled, true);
      assert.match(result.text, /long-press it and choose Speak/);
    }
  }
  assert.equal(api.spoken.length, 0);
  assert.equal(api.sent.length, 0);
  assert.equal(made.onBeforeToolCall({ toolName: "speak" }, toolContext), undefined);
});

test("speak denies every other app route before synthesis", async () => {
  const denied = [
    { ...APP_FAMILY, requesterSenderId: "pat" },
    { ...APP_FAMILY, requesterSenderId: undefined },
    { ...APP_FAMILY, nativeChannelId: "sam" },
    { ...APP_FAMILY, sessionKey: "agent:main:household:group:other" },
    { ...APP_FAMILY, sessionKey: "agent:main:household:group:family:sender:sam" },
    { ...APP_FAMILY, sessionKey: "agent:main:household:group:family:sender:alex" },
    { ...APP_FAMILY, deliveryContext: { channel: "household", accountId: "default", to: "household:other" } },
    { ...APP_FAMILY, deliveryContext: { channel: "household", accountId: "default", to: "household:family", threadId: "1" } },
    { ...APP_PRIVATE, requesterSenderId: "alex" },
    { ...APP_PRIVATE, sessionKey: "agent:main:household:direct:alex",
      deliveryContext: { channel: "household", accountId: "default", to: "household:alex" } },
    { ...APP_PRIVATE, sessionKey: "agent:main:main" },
    { ...APP_PRIVATE, oneShotCliRun: true },
  ];
  for (const context of denied) {
    const api = standIns();
    const made = await speech(api);

    const result = await made.tool(context).execute("denied", { text: "Private reply." });

    assert.equal(result.isError, true, JSON.stringify(context));
    assert.equal(api.spoken.length, 0);
    assert.equal(api.sent.length, 0);
  }
  const api = standIns();
  delete api.runtime.config.current().channels.household;
  const made = await speech(api);
  assert.equal((await made.tool(APP_PRIVATE).execute("no-app", { text: "Private reply." })).isError, true);
  assert.equal(api.spoken.length, 0);
});

