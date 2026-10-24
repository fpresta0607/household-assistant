// The household-pictures OpenClaw plugin: a picture or a video someone asks for, made
// through OpenRouter, sent to their chat, and held to a daily ceiling for each person.
//
// OpenRouter, the chats and OpenClaw's media loader are stand-ins: every paid request and
// every message that would reach a chat is counted here.
//
// Run with `node --test tests/js/household_pictures.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import plugin, {
  chosenModel,
  createPictures,
  dollarsPerSecond,
  parseConfig,
  personOf,
} from "../../deploy/openclaw/plugins/household-pictures/index.js";
import { createLedger, dayOf } from "../../deploy/openclaw/plugins/household-pictures/ledger.js";

const START = new Date(2026, 9, 17, 12, 0).getTime();
const DAY = 24 * 3_600_000;
const KEY = `fixture-${randomBytes(8).toString("hex")}`;
const CONFIG = { pictureDayDollars: 0.1, videoDayDollars: 1 };
const RUNTIME_CONFIG = {
  plugins: { entries: { "household-pictures": { enabled: true } } },
  commands: { ownerAllowFrom: ["household:sam"] },
  channels: {
    household: { enabled: true, owner: { id: "sam" }, peer: { person: { id: "alex" } } },
  },
  session: { dmScope: "per-channel-peer", groupScope: "per-group" },
  agents: { defaults: { mediaModels: {
    image: { primary: "openrouter/openai/gpt-image-2.5-flare" },
    video: { primary: "openrouter/google/veo-3.1-fast" },
  } } },
};
// Turns in the household app, as OpenClaw 2026.9.4's run-channel-turn builds them.
const APP_PRIVATE = {
  agentId: "main", agentAccountId: "default", messageChannel: "household", requesterSenderId: "sam",
  sessionKey: "agent:main:household:direct:sam",
  deliveryContext: { channel: "household", accountId: "default", to: "household:sam" },
};
const APP_FAMILY = {
  ...APP_PRIVATE, requesterSenderId: "alex", sessionKey: "agent:main:household:group:family",
  deliveryContext: { channel: "household", accountId: "default", to: "household:family" },
};
// The first bytes of a PNG, which is all the plugin looks at.
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from("picture body")]);
const MP4 = Buffer.from("....ftypisom video body");
const VEO = {
  id: "google/veo-3.1-fast",
  supported_resolutions: ["720p", "1080p", "4K"],
  supported_aspect_ratios: ["16:9", "9:16"],
  supported_durations: [4, 6, 8],
  supported_frame_images: ["first_frame", "last_frame"],
  pricing_skus: {
    duration_seconds_with_audio: "0.12",
    duration_seconds_with_audio_720p: "0.10",
    duration_seconds_without_audio_720p: "0.08",
    duration_seconds_with_audio_4k: "0.30",
  },
};

// OpenRouter as the plugin sees it. `pictures` answers each picture request in turn with
// a cost (a number, null for none reported) or an HTTP status to fail with; `jobs` is the
// statuses a video job reports, one per ask.
function fakeOpenRouter({ pictures = [0.04], videoModels = [VEO], jobs = ["pending", "completed"], videoCost = 0.6 } = {}) {
  const asked = [];
  const pictureAnswers = [...pictures];
  const jobAnswers = [...jobs];
  const json = (body, status = 200) => ({
    ok: status === 200 || status === 202,
    status,
    headers: new Map([["content-type", "application/json"]]),
    json: async () => body,
    text: async () => JSON.stringify(body),
  });
  async function fetchFn(url, init = {}) {
    asked.push({ url, init, body: init.body ? JSON.parse(init.body) : undefined });
    if (url === "https://openrouter.ai/api/v1/images") {
      const answer = pictureAnswers.shift();
      if (typeof answer === "number" && answer >= 100) return json({ error: { message: "Provider returned error" } }, answer);
      return json({ data: [{ b64_json: PNG.toString("base64"), media_type: "image/png" }], usage: answer === null ? undefined : { cost: answer } });
    }
    if (url === "https://openrouter.ai/api/v1/videos/models") return json({ data: videoModels });
    if (url === "https://openrouter.ai/api/v1/videos") return json({ id: "job-123", polling_url: "https://elsewhere.example/job-123", status: "pending" }, 202);
    if (url === "https://openrouter.ai/api/v1/videos/job-123") {
      const status = jobAnswers.shift() ?? "pending";
      return json({ id: "job-123", status, ...(status === "completed" ? { usage: { cost: videoCost } } : {}), ...(status === "failed" ? { error: "content refused" } : {}) });
    }
    if (url === "https://openrouter.ai/api/v1/videos/job-123/content?index=0") {
      return {
        ok: true,
        status: 200,
        headers: new Map([["content-type", "video/mp4"], ["content-length", String(MP4.length)]]),
        arrayBuffer: async () => MP4,
      };
    }
    throw new Error(`unexpected request to ${url}`);
  }
  return { asked, fetchFn };
}

function standIns({ config = RUNTIME_CONFIG, photos = {} } = {}) {
  const sent = [];
  const logged = [];
  const loaded = [];
  const runtimeConfig = structuredClone(config);
  const keep = (params) => {
    const file = params.mediaUrl ?? params.payload?.mediaUrl;
    sent.push({ ...params, bytes: file ? readFileSync(file) : null });
  };
  const api = {
    sent,
    logged,
    loaded,
    runtimeConfig,
    logger: { info: (line) => logged.push(line), warn: (line) => logged.push(line), error: (line) => logged.push(line) },
    runtime: {
      config: { current: () => runtimeConfig },
      state: { resolveStateDir: () => "/state" },
      media: {
        async loadWebMedia(source, options) {
          loaded.push({ source, options });
          if (!(source in photos)) throw new Error(`Local media path is not under an allowed directory: ${source}`);
          return { buffer: photos[source].buffer, contentType: photos[source].mime };
        },
      },
      channel: {
        outbound: {
          async loadAdapter(channel) {
            if (channel === "household") {
              return {
                async sendText(params) { sent.push({ ...params, bytes: null }); return { messageId: `app-${sent.length}` }; },
                async sendMedia(params) { keep(params); return { messageId: `app-${sent.length}` }; },
              };
            }
            return undefined;
          },
        },
      },
    },
  };
  return api;
}

async function pictures(api, openRouter, { config = CONFIG, clock = { now: START }, env = { OPENROUTER_API_KEY: KEY } } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-pictures-"));
  const ledgerFile = path.join(directory, "ledger.json");
  const sleeps = [];
  const made = createPictures(api, config, {
    env,
    fetchFn: openRouter.fetchFn,
    now: () => clock.now,
    ledgerFile,
    sleep: async (ms) => {
      sleeps.push(ms);
      clock.now += ms;
    },
  });
  return { ...made, clock, ledgerFile, sleeps, ledger: createLedger(ledgerFile, { now: () => clock.now }) };
}

const textOf = (outcome) => outcome.content.map((block) => block.text).join("\n");
const payloadOf = (outcome) => JSON.parse(textOf(outcome).split("\n")[0]);
// Waits for what a video does in the background, which reads and writes files, up to two
// seconds.
async function until(isDone) {
  for (let tries = 0; tries < 400 && !isDone(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.ok(isDone(), "the background work did not finish");
}

test("the config is two ceilings in dollars, and nothing else", () => {
  assert.deepEqual(parseConfig(CONFIG), { value: CONFIG });
  assert.match(parseConfig({ ...CONFIG, extra: 1 }).error, /unknown config keys: extra/);
  assert.match(parseConfig({ pictureDayDollars: 0, videoDayDollars: 1 }).error, /pictureDayDollars/);
  assert.match(parseConfig({ pictureDayDollars: 1, videoDayDollars: "3" }).error, /videoDayDollars/);
  assert.match(parseConfig({ pictureDayDollars: 101, videoDayDollars: 1 }).error, /at most 100/);
  assert.match(parseConfig(null).error, /expected a config object/);
});

test("the models are the ones Settings chose on OpenRouter, and nothing else counts as chosen", () => {
  assert.equal(chosenModel(RUNTIME_CONFIG, "image"), "openai/gpt-image-2.5-flare");
  assert.equal(chosenModel(RUNTIME_CONFIG, "video"), "google/veo-3.1-fast");
  assert.equal(chosenModel({ agents: { defaults: { mediaModels: { image: "openrouter/a/b" } } } }, "image"), "a/b");
  assert.equal(chosenModel({ agents: { defaults: { mediaModels: { image: { primary: "openai/gpt-image-2" } } } } }, "image"), null);
  assert.equal(chosenModel({}, "video"), null);
});

test("who asked: a person of the household by their app id", () => {
  assert.equal(personOf(APP_PRIVATE), "sam");
  assert.equal(personOf(APP_FAMILY), "alex");
  assert.equal(personOf({ ...APP_FAMILY, requesterSenderId: "household:alex" }), "alex");
});

test("only a person's turn in a chat the household set up is handed either tool", async () => {
  const made = await pictures(standIns(), fakeOpenRouter());
  const ownersOwnSession = { ...APP_FAMILY, requesterSenderId: "sam", sessionKey: "agent:main:household:group:family:sender:sam" };
  for (const context of [APP_PRIVATE, APP_FAMILY, ownersOwnSession]) {
    assert.equal(made.pictureTool(context)?.name, "picture", context.sessionKey);
    assert.equal(made.videoTool(context)?.name, "video", context.sessionKey);
  }
  const refused = [
    { ...APP_PRIVATE, requesterSenderId: undefined },
    { ...APP_PRIVATE, requesterSenderId: "alex" },
    { ...APP_PRIVATE, sessionKey: "agent:main:main" },
    { ...APP_FAMILY, requesterSenderId: "corey" },
    { ...APP_FAMILY, sessionKey: "agent:main:household:group:family:sender:sam" },
    { ...APP_FAMILY, requesterSenderId: "pat" },
    { ...APP_PRIVATE, sessionKey: "agent:main:cron:daily" },
    { ...APP_PRIVATE, messageChannel: "telegram" },
    { ...APP_PRIVATE, deliveryContext: { channel: "telegram", accountId: "default", to: "telegram:7000000001" } },
    { ...APP_FAMILY, deliveryContext: { ...APP_FAMILY.deliveryContext, threadId: "1" } },
    { ...APP_PRIVATE, oneShotCliRun: true },
    { ...APP_PRIVATE, agentId: "worker" },
    { agentId: "main", agentAccountId: "default", sessionKey: "agent:main:main" },
  ];
  for (const context of refused) {
    assert.equal(made.pictureTool(context), null, JSON.stringify(context));
    assert.equal(made.videoTool(context), null, JSON.stringify(context));
  }
});

test("a picture in the app is made with the chosen model, sent to the thread at full size and counted at OpenRouter's cost", async () => {
  const api = standIns();
  const openRouter = fakeOpenRouter({ pictures: [0.042] });
  const made = await pictures(api, openRouter);
  const outcome = await made.pictureTool(APP_PRIVATE).execute("call-1", { prompt: "A red fox asleep in the snow", aspectRatio: "3:2" });

  assert.equal(outcome.isError, undefined);
  assert.deepEqual(payloadOf(outcome), { sent: true, model: "openai/gpt-image-2.5-flare", cost: 0.042, spentToday: 0.042, dailyLimit: 0.1 });
  assert.match(textOf(outcome), /Say one short line/);
  const [request] = openRouter.asked;
  assert.equal(request.url, "https://openrouter.ai/api/v1/images");
  assert.equal(request.init.headers.Authorization, `Bearer ${KEY}`);
  assert.deepEqual(request.body, { model: "openai/gpt-image-2.5-flare", prompt: "A red fox asleep in the snow", n: 1, aspect_ratio: "3:2" });
  assert.equal(api.sent.length, 1);
  assert.equal(api.sent[0].to, "household:sam");
  assert.match(api.sent[0].mediaUrl, /\.png$/);
  assert.deepEqual(api.sent[0].bytes, PNG);
  assert.deepEqual(api.sent[0].mediaLocalRoots, [path.dirname(api.sent[0].mediaUrl)]);
  assert.equal(existsSync(api.sent[0].mediaUrl), false, "the file is gone once sent");
  const [entry] = JSON.parse(await readFile(made.ledgerFile, "utf8"));
  assert.deepEqual({ ...entry, at: undefined }, { day: dayOf(START), at: undefined, person: "sam", kind: "picture", model: "openai/gpt-image-2.5-flare", cost: 0.042 });
  assert.ok(api.logged.some((line) => line === "household-pictures: a picture for sam with openai/gpt-image-2.5-flare cost $0.042"));
  assert.ok(api.logged.every((line) => !line.includes("fox")), "what was asked for is never logged");
});

test("a picture in the family room is sent to the room", async () => {
  const api = standIns();
  const made = await pictures(api, fakeOpenRouter());
  await made.pictureTool(APP_FAMILY).execute("call-1", { prompt: "A lighthouse at dusk" });

  assert.equal(api.sent.length, 1);
  assert.equal(api.sent[0].to, "household:family");
  assert.match(api.sent[0].mediaUrl, /\.png$/);
  assert.deepEqual(api.sent[0].bytes, PNG);
});

test("past the day's ceiling a person is refused in plain words, and OpenRouter is not asked", async () => {
  const api = standIns();
  const openRouter = fakeOpenRouter({ pictures: [0.06, 0.05, 0.02, 0.03] });
  const made = await pictures(api, openRouter);
  const tool = made.pictureTool(APP_PRIVATE);
  await tool.execute("call-1", { prompt: "One" });
  await tool.execute("call-2", { prompt: "Two" });
  const refused = await tool.execute("call-3", { prompt: "Three" });

  assert.deepEqual(payloadOf(refused), { made: false, reason: "daily_limit" });
  assert.match(textOf(refused), /pictures for sam today have cost \$0\.11, and the limit is \$0\.10 a day\. More can be made tomorrow\./);
  assert.equal(openRouter.asked.length, 2);
  assert.equal(api.sent.length, 2);
  assert.ok(api.logged.includes("household-pictures: a picture for sam was refused at the day's limit of $0.10"));

  // Someone else's day is their own, and the next day starts again.
  await made.pictureTool(APP_FAMILY).execute("call-4", { prompt: "Four" });
  assert.equal(openRouter.asked.length, 3);
  made.clock.now += DAY;
  const tomorrow = await made.pictureTool(APP_PRIVATE).execute("call-5", { prompt: "Five" });
  assert.equal(payloadOf(tomorrow).sent, true);
  assert.equal(openRouter.asked.length, 4);
});

test("a picture whose cost OpenRouter did not report closes that person's day", async () => {
  const api = standIns();
  const openRouter = fakeOpenRouter({ pictures: [null, 0.01] });
  const made = await pictures(api, openRouter);
  const tool = made.pictureTool(APP_PRIVATE);
  const first = await tool.execute("call-1", { prompt: "One" });
  const second = await tool.execute("call-2", { prompt: "Two" });

  assert.equal(payloadOf(first).cost, null);
  assert.match(textOf(second), /OpenRouter did not say what an earlier one of today's pictures cost/);
  assert.equal(openRouter.asked.length, 1);
  assert.ok(api.logged.includes("household-pictures: a picture for sam with openai/gpt-image-2.5-flare cost an amount OpenRouter did not report"));
});

test("a picture OpenRouter could not make costs nothing, is not counted and sends nothing", async () => {
  const api = standIns();
  const made = await pictures(api, fakeOpenRouter({ pictures: [502] }));
  const outcome = await made.pictureTool(APP_PRIVATE).execute("call-1", { prompt: "A storm" });

  assert.equal(outcome.isError, true);
  assert.match(textOf(outcome), /^Not made: OpenRouter answered 502 for the picture: Provider returned error$/);
  assert.equal(api.sent.length, 0);
  assert.equal(existsSync(made.ledgerFile), false);
});

test("photos to work from are read under the gateway's media folders and sent along as references", async () => {
  const photo = "/state/media/inbound/photo-1.jpg";
  const api = standIns({ photos: { [photo]: { buffer: Buffer.from("jpeg bytes"), mime: "image/jpeg" } } });
  const openRouter = fakeOpenRouter();
  const made = await pictures(api, openRouter);
  await made.pictureTool(APP_PRIVATE).execute("call-1", { prompt: "Make it a watercolor", images: [photo] });

  assert.deepEqual(api.loaded[0].options.localRoots, [path.join("/state", "media"), path.join("/state", "household-app", "media")]);
  assert.deepEqual(openRouter.asked[0].body.input_references, [
    { type: "image_url", image_url: { url: `data:image/jpeg;base64,${Buffer.from("jpeg bytes").toString("base64")}` } },
  ]);
});

test("a photo that cannot be read, or is not a photo, stops the picture before anything is paid for", async () => {
  const notPhoto = "/state/media/inbound/notes.pdf";
  const api = standIns({ photos: { [notPhoto]: { buffer: Buffer.from("%PDF"), mime: "application/pdf" } } });
  const openRouter = fakeOpenRouter();
  const made = await pictures(api, openRouter);
  const tool = made.pictureTool(APP_PRIVATE);
  const outside = await tool.execute("call-1", { prompt: "Brighter", images: ["/etc/passwd"] });
  const document = await tool.execute("call-2", { prompt: "Brighter", images: [notPhoto] });

  assert.match(textOf(outside), /a photo to work from could not be read: Local media path is not under an allowed directory/);
  assert.match(textOf(document), /is not a photo/);
  assert.equal(openRouter.asked.length, 0);
});

test("no chosen model, no key, or a bad argument is said plainly and costs nothing", async () => {
  const unchosen = structuredClone(RUNTIME_CONFIG);
  delete unchosen.agents;
  const openRouter = fakeOpenRouter();
  const noModel = await pictures(standIns({ config: unchosen }), openRouter);
  assert.match(textOf(await noModel.pictureTool(APP_PRIVATE).execute("c", { prompt: "A cat" })), /no picture model is chosen in Settings/);
  assert.equal(noModel.videoTool(APP_PRIVATE), null, "no video tool without a video model");

  const noKey = await pictures(standIns(), openRouter, { env: {} });
  assert.match(textOf(await noKey.pictureTool(APP_PRIVATE).execute("c", { prompt: "A cat" })), /OPENROUTER_API_KEY/);

  const made = await pictures(standIns(), openRouter);
  const tool = made.pictureTool(APP_PRIVATE);
  assert.match(textOf(await tool.execute("c", { prompt: "  " })), /Give a description/);
  assert.match(textOf(await tool.execute("c", { prompt: "A cat", aspectRatio: "5:1" })), /aspectRatio/);
  assert.match(textOf(await tool.execute("c", { prompt: "A cat", images: ["a", "b", "c", "d", "e"] })), /up to 4/);
  assert.equal(openRouter.asked.length, 0);
});

test("OpenClaw's own image_generate and video_generate are refused in favour of these tools", async () => {
  const made = await pictures(standIns(), fakeOpenRouter());
  assert.deepEqual(made.onBeforeToolCall({ toolName: "image_generate" }), {
    block: true,
    blockReason: "Use the picture tool: it sends the result to this chat and keeps within today's limit.",
  });
  assert.equal(made.onBeforeToolCall({ toolName: "video_generate" }).block, true);
  assert.equal(made.onBeforeToolCall({ toolName: "picture" }), undefined);
  assert.equal(made.onBeforeToolCall({ toolName: "web_search" }), undefined);
});

test("a video starts at a length and size the model lists, answers at once, and arrives in the chat when done", async () => {
  const api = standIns();
  const openRouter = fakeOpenRouter({ jobs: ["pending", "in_progress", "completed"], videoCost: 0.6 });
  const made = await pictures(api, openRouter);
  const outcome = await made.videoTool(APP_PRIVATE).execute("call-1", { prompt: "Waves on a beach at sunrise", seconds: 5 });

  assert.deepEqual(payloadOf(outcome), { started: true, model: "google/veo-3.1-fast", seconds: 4, estimate: 0.4 });
  assert.match(textOf(outcome), /arrive in this chat in a minute or two/);
  const start = openRouter.asked.find((request) => request.url === "https://openrouter.ai/api/v1/videos");
  assert.deepEqual(start.body, { model: "google/veo-3.1-fast", prompt: "Waves on a beach at sunrise", duration: 4, resolution: "720p", aspect_ratio: "16:9" });

  await until(() => api.sent.length === 1);
  assert.equal(api.sent[0].to, "household:sam");
  assert.match(api.sent[0].mediaUrl, /\.mp4$/);
  assert.deepEqual(api.sent[0].bytes, MP4);
  // Asked about at OpenRouter's own address only, never at the polling URL the answer named.
  assert.ok(openRouter.asked.every((request) => request.url.startsWith("https://openrouter.ai/api/v1/")));
  assert.deepEqual(made.sleeps, [5000, 5000, 5000]);
  assert.deepEqual((await made.ledger.today("sam", "video")).dollars, 0.6);
});

test("a video whose listed price would pass the ceiling is refused before it starts, and one being made counts", async () => {
  const api = standIns();
  const openRouter = fakeOpenRouter({ jobs: Array(500).fill("pending") });
  const made = await pictures(api, openRouter, { config: { pictureDayDollars: 1, videoDayDollars: 1 } });
  const tool = made.videoTool(APP_PRIVATE);
  const long = await tool.execute("call-1", { prompt: "A long one", seconds: 20 });
  assert.equal(payloadOf(long).started, true, "8 seconds at $0.10 is under $1");
  const second = await tool.execute("call-2", { prompt: "Another", seconds: 6 });
  assert.match(textOf(second), /videos for sam today have cost \$0\.80 and this one would cost about \$0\.60, and the limit is \$1\.00 a day/);
  assert.equal(openRouter.asked.filter((request) => request.url === "https://openrouter.ai/api/v1/videos").length, 1);
});

test("a video OpenRouter could not make says so in the chat, and one never done is given up on with its day closed", async () => {
  const api = standIns();
  const failed = await pictures(api, fakeOpenRouter({ jobs: ["pending", "failed"] }));
  await failed.videoTool(APP_FAMILY).execute("call-1", { prompt: "Fireworks" });
  await until(() => api.sent.length === 1);
  assert.deepEqual(api.sent.map((send) => [send.to, send.text]), [["household:family", "The video could not be made: content refused."]]);

  const slowApi = standIns();
  const slow = await pictures(slowApi, fakeOpenRouter({ jobs: Array(500).fill("in_progress") }));
  await slow.videoTool(APP_PRIVATE).execute("call-1", { prompt: "Clouds" });
  await until(() => slowApi.sent.length === 1);
  assert.equal(slow.sleeps.length, 181, "asked every 5 seconds for 15 minutes, then given up on");
  assert.equal(slowApi.sent.at(-1).text, "The video could not be made: it was not done in 15 minutes.");
  assert.equal((await slow.ledger.today("sam", "video")).isUncounted, true);
});

test("no video tool once OpenRouter's list is read and does not offer the chosen model", async () => {
  const openRouter = fakeOpenRouter({ videoModels: [{ id: "x-ai/grok-imagine-video-1.5" }] });
  const made = await pictures(standIns(), openRouter);
  assert.equal(made.videoTool(APP_PRIVATE)?.name, "video", "offered until the list has been read");
  await until(() => made.videoTool(APP_PRIVATE) === null);
});

test("a second of video is priced from OpenRouter's list at the size asked for, in dollars or cents", () => {
  assert.equal(dollarsPerSecond(VEO, "720p"), 0.1);
  assert.equal(dollarsPerSecond(VEO, "4K"), 0.3);
  assert.equal(dollarsPerSecond(VEO, "1080p"), 0.12, "a price named for no size is the default");
  assert.equal(dollarsPerSecond({ pricing_skus: { cents_per_image_input: "1", cents_per_video_output_second_720p: "3" } }, "720p"), 0.03);
  assert.equal(dollarsPerSecond({ pricing_skus: {} }, "720p"), null);
  assert.equal(dollarsPerSecond({}, null), null);
  const continued = { pricing_skus: { cents_per_second_output_720p: "17", cents_per_second_video_continuation_720p: "41" } };
  assert.equal(dollarsPerSecond(continued, "720p"), 0.17, "the tool never continues a video, so that price is not counted");
});

test("the ledger keeps two months and a day's spend by person and kind", async () => {
  const clock = { now: START };
  const directory = await mkdtemp(path.join(tmpdir(), "household-pictures-ledger-"));
  const ledger = createLedger(path.join(directory, "ledger.json"), { now: () => clock.now });
  await ledger.record({ person: "sam", kind: "picture", model: "m", cost: 0.04 });
  await ledger.record({ person: "sam", kind: "video", model: "m", cost: 0.5 });
  await ledger.record({ person: "alex", kind: "picture", model: "m", cost: 0.02 });
  assert.deepEqual(await ledger.today("sam", "picture"), { dollars: 0.04, isUncounted: false });
  clock.now += 70 * DAY;
  await ledger.record({ person: "sam", kind: "picture", model: "m", cost: 0.01 });
  const kept = JSON.parse(await readFile(path.join(directory, "ledger.json"), "utf8"));
  assert.deepEqual(kept.map((entry) => entry.cost), [0.01]);
});

test("a ledger file that is not a list of costs is an error, never an empty day", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "household-pictures-ledger-"));
  const file = path.join(directory, "ledger.json");
  const { writeFile } = await import("node:fs/promises");
  await writeFile(file, JSON.stringify([{ day: "2026-10-17", person: "sam", kind: "picture", model: "m", cost: "0.04" }]));
  await assert.rejects(createLedger(file).today("sam", "picture"), /does not hold a list of costs/);
});

test("the plugin registers both tools and the hook, and refuses to start on a bad config", () => {
  const registered = { tools: [], hooks: [] };
  const api = { ...standIns(), pluginConfig: CONFIG };
  api.registerTool = (factory, options) => registered.tools.push(options.names);
  api.on = (name) => registered.hooks.push(name);
  plugin.register(api);
  assert.deepEqual(registered, { tools: [["picture"], ["video"]], hooks: ["before_tool_call"] });

  const errors = [];
  plugin.register({ ...standIns(), pluginConfig: { pictureDayDollars: 1 }, logger: { error: (line) => errors.push(line) } });
  assert.match(errors[0], /not started, videoDayDollars must be a number of dollars/);
});
