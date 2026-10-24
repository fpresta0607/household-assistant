// Pictures and short videos the family asks either assistant for, for both household
// gateways.
//
// OpenClaw 2026.9.4 has image_generate and video_generate, and both reach OpenRouter, but
// neither can be held to a budget: its OpenRouter provider drops the `usage.cost` each
// answer carries, its request names nobody, and the model picks the model and how many
// pictures. So the model is handed `picture` and `video` in their place, and this plugin
// does the rest by rule:
//
// - A picture is made from the model's description, with the photos a person sent to
//   change or build on, by the image model chosen in Settings
//   (agents.defaults.mediaModels.image, which household-app writes), one a call. This
//   plugin sends it to the chat: the Steward app keeps it in the room at full size like
//   any photo. The tool's result is a line of text and no picture, so the model is handed
//   nothing heavy and nothing is sent twice.
// - A video is started the same way, by the video model chosen in Settings. The tool
//   answers at once, and the video is sent to the chat once OpenRouter has made it. Only
//   this process waits for it, so one still being made when the gateway restarts is lost.
// - What each one cost is OpenRouter's own figure, kept in the ledger and logged with who
//   asked and never with what. Each person has a ceiling a day for pictures and one for
//   videos on this gateway. Past it the tool refuses and says so, and a video whose listed
//   price would pass it is refused before it starts.
// - Only a person's turn in the household app gets either tool: the family room, for its
//   two people, and its owner's own thread, the turns family_history answers in. A
//   scheduled run, a sub-agent or a gateway client gets neither.
// - OpenClaw's own image_generate and video_generate are refused if a config ever hands
//   them back to the model.

import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { createLedger } from "./ledger.js";
import { OpenRouterError, createVideoModels, fetchVideo, makePicture, startVideo, videoStatus } from "./openrouter.js";

export const PLUGIN_ID = "household-pictures";
export const PICTURE_TOOL = "picture";
export const VIDEO_TOOL = "video";
const BUILT_IN = { image_generate: PICTURE_TOOL, video_generate: VIDEO_TOOL };
const OPENROUTER = "openrouter/";
const ASPECT_RATIOS = ["1:1", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16"];
const VIDEO_ASPECT_RATIOS = ["16:9", "9:16", "1:1"];
const MAX_PROMPT = 4000;
const MAX_PHOTOS = 4;
const MAX_PHOTO_BYTES = 10 * 1024 * 1024;
// The app's ceiling for one file.
const MAX_VIDEO_BYTES = 50 * 1024 * 1024;
const VIDEO_SECONDS = 6;
const VIDEO_POLL_MS = 5_000;
// A job not done by then is given up on, which bounds the poll at 180 asks.
const VIDEO_WAIT_MS = 15 * 60_000;
const ENDED = new Set(["failed", "cancelled", "expired"]);
const EXTENSIONS = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov" };

const NOT_AUTHORIZED = "Not made: this turn is not one a person in the household started in their own chat.";
const AFTER_PICTURE = "The picture is in the chat. Say one short line about it, without describing it or saying it again. Name the cost only if asked.";
const AFTER_VIDEO = "Tell them in one short line that the video will arrive in this chat in a minute or two. Name the cost only if asked.";

function householdId(value) {
  return typeof value === "string" ? /^(?:household:)?([a-z][a-z0-9-]{0,31})$/.exec(value)?.[1] : undefined;
}

// A person's turn in the household app: the family room, for its two people, and its
// owner's own thread. The app names no native chat, so its trusted delivery target stands
// in for one.
export function isAuthorizedTurn(config, context) {
  if (
    !context || context.agentId !== "main" || context.agentAccountId !== "default" ||
    context.oneShotCliRun === true || config?.plugins?.enabled === false ||
    config?.plugins?.entries?.[PLUGIN_ID]?.enabled !== true ||
    config?.session?.groupScope !== "per-group" ||
    !["per-channel-peer", "per-account-channel-peer"].includes(config?.session?.dmScope) ||
    context.messageChannel !== "household"
  ) return false;
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

// Who asked, as the ledger counts them: a person of the household by their app id.
export function personOf(context) {
  return householdId(context.requesterSenderId);
}

// The OpenRouter id of the model Settings chose for a kind of media, or null.
export function chosenModel(config, kind) {
  const slot = config?.agents?.defaults?.mediaModels?.[kind];
  const ref = typeof slot === "string" ? slot : slot?.primary;
  return typeof ref === "string" && ref.startsWith(OPENROUTER) && ref.length > OPENROUTER.length ? ref.slice(OPENROUTER.length) : null;
}

// The listed length nearest the one asked for, the shorter of two as near.
function lengthOf(listed, asked) {
  const lengths = (Array.isArray(listed?.supported_durations) ? listed.supported_durations : []).filter(Number.isSafeInteger);
  if (lengths.length === 0) return null;
  return lengths.reduce((best, length) => (Math.abs(length - asked) < Math.abs(best - asked) ? length : best));
}

function resolutionOf(listed) {
  const sizes = Array.isArray(listed?.supported_resolutions) ? listed.supported_resolutions : [];
  return sizes.includes("720p") ? "720p" : sizes[0] ?? null;
}

function aspectOf(listed, asked) {
  const ratios = Array.isArray(listed?.supported_aspect_ratios) ? listed.supported_aspect_ratios : [];
  if (asked && ratios.includes(asked)) return asked;
  return ratios.includes("16:9") ? "16:9" : ratios[0] ?? null;
}

// Dollars a second of video at a size, from OpenRouter's listed prices, the dearest of the
// ones that match, or null when it lists none. A price named for no size is the default,
// and the price of continuing a video is left out, since this tool only starts them.
export function dollarsPerSecond(listed, resolution) {
  const prices = Object.entries(listed?.pricing_skus ?? {})
    .filter(([name]) => /second/.test(name) && !/continuation/.test(name))
    .map(([name, value]) => [name, Number(value) / (name.startsWith("cents_") ? 100 : 1)])
    .filter(([, value]) => Number.isFinite(value) && value >= 0);
  const sized = resolution ? prices.filter(([name]) => name.toLowerCase().endsWith(`_${resolution.toLowerCase()}`)) : [];
  const pool = sized.length > 0 ? sized : prices.filter(([name]) => !/_\d+(?:p|k)$/i.test(name));
  return pool.length > 0 ? Math.max(...pool.map(([, value]) => value)) : null;
}

const money = (dollars) => `$${dollars.toFixed(dollars < 0.1 ? 3 : 2)}`;
const tenthsOfACent = (dollars) => Math.round(dollars * 1000) / 1000;

function result(payload, line) {
  return { content: [{ type: "text", text: `${JSON.stringify(payload)}${line ? `\n${line}` : ""}` }] };
}

const failure = (message) => ({ content: [{ type: "text", text: message }], isError: true });

// OpenClaw validates this plugin's config against the manifest's schema before it loads
// the plugin, so the entry hands back that schema rather than keeping a copy.
const CONFIG_SCHEMA = JSON.parse(
  readFileSync(new URL("./openclaw.plugin.json", import.meta.url), "utf8"),
).configSchema;

export function parseConfig(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "expected a config object" };
  const unknown = Object.keys(raw).filter((key) => !(key in CONFIG_SCHEMA.properties));
  if (unknown.length > 0) return { error: `unknown config keys: ${unknown.join(", ")}` };
  for (const key of CONFIG_SCHEMA.required) {
    if (typeof raw[key] !== "number" || !(raw[key] > 0) || raw[key] > CONFIG_SCHEMA.properties[key].maximum) {
      return { error: `${key} must be a number of dollars above 0 and at most ${CONFIG_SCHEMA.properties[key].maximum}` };
    }
  }
  return { value: { pictureDayDollars: raw.pictureDayDollars, videoDayDollars: raw.videoDayDollars } };
}

const configSchema = {
  safeParse(value) {
    const parsed = parseConfig(value);
    if (parsed.error) return { success: false, error: { issues: [{ path: [], message: parsed.error }] } };
    return { success: true, data: value };
  },
  jsonSchema: CONFIG_SCHEMA,
};

export function createPictures(api, config, options = {}) {
  const { pictureDayDollars, videoDayDollars } = config;
  const env = options.env ?? process.env;
  const fetchFn = options.fetchFn ?? fetch;
  const now = options.now ?? Date.now;
  const sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const stateDir = api.runtime.state.resolveStateDir(env);
  const ledger = createLedger(options.ledgerFile ?? path.join(stateDir, PLUGIN_ID, "ledger.json"), { now });
  const videoModels = createVideoModels({ fetchFn, now });
  const log = api.logger;
  const current = (context) => (typeof context?.getRuntimeConfig === "function" ? context.getRuntimeConfig() : api.runtime.config.current());

  // One person's asks one at a time, so two cannot both read the day's spend before
  // either adds to it. A video still being made counts at its listed price until done.
  const queues = new Map();
  const making = new Map();
  function inTurn(person, work) {
    const next = (queues.get(person) ?? Promise.resolve()).then(work);
    const settled = next.catch(() => undefined);
    queues.set(person, settled);
    settled.then(() => {
      if (queues.get(person) === settled) queues.delete(person);
    });
    return next;
  }

  // Photos to work from, as data URLs: the app's own photos and the files OpenClaw keeps
  // of what came in, or a public https link.
  async function photosOf(sources) {
    const localRoots = [path.join(stateDir, "media"), path.join(stateDir, "household-app", "media")];
    const photos = [];
    for (const source of sources) {
      const loaded = await api.runtime.media.loadWebMedia(source, { maxBytes: MAX_PHOTO_BYTES, localRoots });
      const mime = String(loaded?.contentType ?? "").split(";")[0].trim();
      if (!mime.startsWith("image/")) throw new Error(`${source} is not a photo`);
      photos.push(`data:${mime};base64,${loaded.buffer.toString("base64")}`);
    }
    return photos;
  }

  // Sends a file, or a line of text, to the chat a turn came from: a channel that takes a
  // whole payload gets one, and the app has sendText and sendMedia.
  async function send(target, { bytes, mime, text }) {
    const adapter = await api.runtime.channel.outbound.loadAdapter(target.channel);
    const base = { cfg: api.runtime.config.current(), to: target.to, accountId: target.accountId, threadId: target.threadId };
    if (!bytes) {
      if (adapter?.sendPayload) return adapter.sendPayload({ ...base, payload: { text } });
      if (adapter?.sendText) return adapter.sendText({ ...base, text });
      throw new Error(`there is no way to send to ${target.channel}`);
    }
    const directory = await mkdtemp(path.join(tmpdir(), `${PLUGIN_ID}-`));
    try {
      const file = path.join(directory, `${randomUUID()}.${EXTENSIONS[mime] ?? "bin"}`);
      await writeFile(file, bytes, { mode: 0o600 });
      const media = { ...base, mediaLocalRoots: [directory] };
      if (adapter?.sendPayload) return await adapter.sendPayload({ ...media, payload: { mediaUrl: file } });
      if (adapter?.sendMedia) return await adapter.sendMedia({ ...media, mediaUrl: file });
      throw new Error(`there is no way to send media to ${target.channel}`);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }

  async function record(person, kind, model, cost) {
    await ledger.record({ person, kind, model, cost });
    log.info(`${PLUGIN_ID}: a ${kind} for ${person} with ${model} cost ${cost === null ? "an amount OpenRouter did not report" : money(cost)}`);
  }

  // Why a person may not have another today, or null when they may.
  async function refusal(person, kind, ceiling, estimate = 0) {
    const spent = await ledger.today(person, kind);
    const pending = making.get(person) ?? 0;
    const noun = kind === "picture" ? "pictures" : "videos";
    let why = null;
    if (spent.isUncounted) {
      why = `Not made: OpenRouter did not say what an earlier one of today's ${noun} cost, so no more ${noun} for ${person} today.`;
    } else if (spent.dollars + pending >= ceiling || spent.dollars + pending + estimate > ceiling) {
      const would = estimate > 0 ? ` and this one would cost about ${money(estimate)}` : "";
      why = `Not made: ${noun} for ${person} today have cost ${money(spent.dollars + pending)}${would}, ` +
        `and the limit is ${money(ceiling)} a day. More can be made tomorrow.`;
    }
    if (why) log.info(`${PLUGIN_ID}: a ${kind} for ${person} was refused at the day's limit of ${money(ceiling)}`);
    return why;
  }

  function pictureTool(context) {
    return {
      name: PICTURE_TOOL,
      label: "Picture",
      description:
        "Make a picture and send it to this chat, only when someone asks for a picture, an image, a drawing or a change to a photo. " +
        "Describe it in `prompt` in your own words: the subject, the setting, the style, the light, and any words it should show. " +
        "To change or build on photos someone sent, pass their paths or https links as `images`. One picture a call. " +
        "It sends the picture itself, so never describe it at length or say it again. Never use it for a chart of numbers: " +
        "in the app that is a chart card.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["prompt"],
        properties: {
          prompt: { type: "string", maxLength: MAX_PROMPT, description: "What the picture shows, in detail." },
          aspectRatio: { type: "string", enum: ASPECT_RATIOS, description: "Its shape; 1:1 unless the subject wants another." },
          images: {
            type: "array",
            maxItems: MAX_PHOTOS,
            items: { type: "string", maxLength: 2000 },
            description: "Paths or https links of photos someone sent, to change or build on.",
          },
        },
      },
      async execute(_id, params, signal) {
        const cfg = current(context);
        if (!isAuthorizedTurn(cfg, context)) return failure(NOT_AUTHORIZED);
        const prompt = typeof params?.prompt === "string" ? params.prompt.trim() : "";
        const sources = params?.images ?? [];
        if (!prompt || prompt.length > MAX_PROMPT) return failure(`Give a description of up to ${MAX_PROMPT} characters as \`prompt\`.`);
        if (params?.aspectRatio !== undefined && !ASPECT_RATIOS.includes(params.aspectRatio)) {
          return failure(`\`aspectRatio\` is one of ${ASPECT_RATIOS.join(", ")}.`);
        }
        if (!Array.isArray(sources) || sources.length > MAX_PHOTOS || !sources.every((source) => typeof source === "string" && source)) {
          return failure(`\`images\` is a list of up to ${MAX_PHOTOS} paths or links.`);
        }
        const model = chosenModel(cfg, "image");
        if (!model) return failure("Not made: no picture model is chosen in Settings.");
        const apiKey = env.OPENROUTER_API_KEY;
        if (!apiKey) return failure("Not made: OPENROUTER_API_KEY is not in the gateway's environment.");
        const person = personOf(context);
        return inTurn(person, async () => {
          const refused = await refusal(person, "picture", pictureDayDollars);
          if (refused) return result({ made: false, reason: "daily_limit" }, refused);
          let photos;
          try {
            photos = await photosOf(sources);
          } catch (error) {
            return failure(`Not made: a photo to work from could not be read: ${error?.message ?? error}`);
          }
          let made;
          try {
            made = await makePicture({ apiKey, model, prompt, aspectRatio: params.aspectRatio, references: photos, fetchFn, signal });
          } catch (error) {
            if (error instanceof OpenRouterError || error?.name === "TimeoutError" || error?.name === "AbortError") {
              return failure(`Not made: ${error.message}`);
            }
            throw error;
          }
          await record(person, "picture", model, made.cost);
          try {
            await send(context.deliveryContext, made);
          } catch (error) {
            log.warn(`${PLUGIN_ID}: a picture was made and not sent: ${error?.message ?? error}`);
            return failure("The picture was made but could not be sent to this chat.");
          }
          const spent = await ledger.today(person, "picture");
          return result(
            {
              sent: true,
              model,
              cost: made.cost === null ? null : tenthsOfACent(made.cost),
              spentToday: tenthsOfACent(spent.dollars),
              dailyLimit: pictureDayDollars,
            },
            AFTER_PICTURE,
          );
        });
      },
    };
  }

  // A started video, asked about until it is done and then sent, in the background. Its
  // cost is kept when OpenRouter reports it; a job given up on keeps none it could count.
  async function follow({ id, person, model, target, apiKey, estimate }) {
    making.set(person, (making.get(person) ?? 0) + estimate);
    const started = now();
    try {
      for (;;) {
        await sleep(VIDEO_POLL_MS);
        const isLate = now() - started > VIDEO_WAIT_MS;
        let job;
        try {
          job = await videoStatus({ apiKey, id, fetchFn });
        } catch (error) {
          if (!isLate) {
            log.warn(`${PLUGIN_ID}: OpenRouter could not say how a video is going: ${error?.message ?? error}`);
            continue;
          }
          job = { status: "", cost: null, error: String(error?.message ?? error) };
        }
        if (job.status === "completed") {
          await record(person, "video", model, job.cost);
          const video = await fetchVideo({ apiKey, id, maxBytes: MAX_VIDEO_BYTES, fetchFn });
          await send(target, video);
          return;
        }
        if (ENDED.has(job.status) || isLate) {
          await record(person, "video", model, job.cost);
          const why = job.error ?? (isLate ? "it was not done in 15 minutes" : `OpenRouter says it ${job.status}`);
          await send(target, { text: `The video could not be made: ${why}.` });
          return;
        }
      }
    } catch (error) {
      log.error(`${PLUGIN_ID}: a video was not delivered: ${error?.message ?? error}`);
      await send(target, { text: "The video could not be sent to this chat." }).catch(() => undefined);
    } finally {
      const left = (making.get(person) ?? 0) - estimate;
      if (left > 1e-9) making.set(person, left);
      else making.delete(person);
    }
  }

  function videoTool(context) {
    return {
      name: VIDEO_TOOL,
      label: "Video",
      description:
        "Make a short video and send it to this chat, only when someone asks for a video. Describe it in `prompt`: what happens, " +
        "the setting, the style and the camera. To start from a photo someone sent, pass its path or https link as `image`. " +
        "It answers at once and the video arrives in the chat a minute or two later, so never call it again for the same ask.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["prompt"],
        properties: {
          prompt: { type: "string", maxLength: MAX_PROMPT, description: "What happens in the video, in detail." },
          seconds: { type: "integer", minimum: 1, maximum: 20, description: "How long, if they said; about 6 otherwise." },
          aspectRatio: { type: "string", enum: VIDEO_ASPECT_RATIOS },
          image: { type: "string", maxLength: 2000, description: "A path or https link of a photo to start from." },
        },
      },
      async execute(_id, params) {
        const cfg = current(context);
        if (!isAuthorizedTurn(cfg, context)) return failure(NOT_AUTHORIZED);
        const prompt = typeof params?.prompt === "string" ? params.prompt.trim() : "";
        if (!prompt || prompt.length > MAX_PROMPT) return failure(`Give a description of up to ${MAX_PROMPT} characters as \`prompt\`.`);
        if (params?.seconds !== undefined && !(Number.isSafeInteger(params.seconds) && params.seconds >= 1 && params.seconds <= 20)) {
          return failure("`seconds` is a whole number from 1 to 20.");
        }
        if (params?.image !== undefined && (typeof params.image !== "string" || !params.image)) return failure("`image` is one path or link.");
        const model = chosenModel(cfg, "video");
        if (!model) return failure("Not made: no video model is chosen in Settings.");
        const apiKey = env.OPENROUTER_API_KEY;
        if (!apiKey) return failure("Not made: OPENROUTER_API_KEY is not in the gateway's environment.");
        let listed;
        try {
          listed = (await videoModels.read()).find((entry) => entry?.id === model);
        } catch (error) {
          return failure(`Not made: ${error?.message ?? error}`);
        }
        if (!listed) return failure(`Not made: OpenRouter does not offer the video model chosen in Settings (${model}) now.`);
        const frames = Array.isArray(listed.supported_frame_images) ? listed.supported_frame_images : [];
        if (params.image && !frames.includes("first_frame")) return failure(`Not made: ${model} cannot start from a photo.`);
        const seconds = lengthOf(listed, params.seconds ?? VIDEO_SECONDS);
        const resolution = resolutionOf(listed);
        const perSecond = dollarsPerSecond(listed, resolution);
        const estimate = seconds !== null && perSecond !== null ? seconds * perSecond : 0;
        const person = personOf(context);
        return inTurn(person, async () => {
          const refused = await refusal(person, "video", videoDayDollars, estimate);
          if (refused) return result({ made: false, reason: "daily_limit" }, refused);
          let firstFrame;
          try {
            [firstFrame] = params.image ? await photosOf([params.image]) : [];
          } catch (error) {
            return failure(`Not made: the photo to start from could not be read: ${error?.message ?? error}`);
          }
          let job;
          try {
            job = await startVideo({ apiKey, model, prompt, seconds, resolution, aspectRatio: aspectOf(listed, params.aspectRatio), firstFrame, fetchFn });
          } catch (error) {
            if (error instanceof OpenRouterError || error?.name === "TimeoutError") return failure(`Not made: ${error.message}`);
            throw error;
          }
          log.info(`${PLUGIN_ID}: a ${seconds ?? "default length"} second video for ${person} with ${model} started, listed at about ${money(estimate)}`);
          void follow({ id: job.id, person, model, target: context.deliveryContext, apiKey, estimate });
          return result({ started: true, model, seconds, estimate: tenthsOfACent(estimate) }, AFTER_VIDEO);
        });
      },
    };
  }

  function onBeforeToolCall(event) {
    const instead = BUILT_IN[event?.toolName];
    if (!instead) return undefined;
    return { block: true, blockReason: `Use the ${instead} tool: it sends the result to this chat and keeps within today's limit.` };
  }

  // No video tool while no video model is chosen, or while OpenRouter's list, once read,
  // does not offer the chosen one. The list is read here the first time, for later turns.
  function offersVideo(cfg) {
    const model = chosenModel(cfg, "video");
    if (!model) return false;
    const latest = videoModels.latest();
    if (latest === null) {
      videoModels.read().catch((error) => log.warn(`${PLUGIN_ID}: OpenRouter's video models could not be read: ${error?.message ?? error}`));
      return true;
    }
    return latest.some((entry) => entry?.id === model);
  }

  return {
    pictureTool: (context) => (isAuthorizedTurn(current(context), context) ? pictureTool(context) : null),
    videoTool: (context) => (isAuthorizedTurn(current(context), context) && offersVideo(current(context)) ? videoTool(context) : null),
    onBeforeToolCall,
  };
}

export default {
  id: PLUGIN_ID,
  name: "Household pictures",
  description: "Makes a picture or a short video someone asks for through OpenRouter, under a daily ceiling for each person.",
  configSchema,
  register(api) {
    const parsed = parseConfig(api.pluginConfig);
    if (parsed.error) {
      api.logger.error(`${PLUGIN_ID}: not started, ${parsed.error}`);
      return;
    }
    const pictures = createPictures(api, parsed.value);
    api.registerTool(pictures.pictureTool, { names: [PICTURE_TOOL] });
    api.registerTool(pictures.videoTool, { names: [VIDEO_TOOL] });
    api.on("before_tool_call", pictures.onBeforeToolCall);
  },
};
