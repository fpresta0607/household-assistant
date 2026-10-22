// A phone reading and changing its own assistant's settings.
//
// Every change is signed by the phone's device key, the way a message or a location is,
// and checked against the keys of the phones paired to this gateway for the app. Only the
// gateway's own person pairs there, so Franco's phones change Corey and Gia's change
// Denise, and a token with write scope, or an assistant talked into it, changes nothing.
// A change carries its time: within five minutes of the gateway's clock and later than
// the newest accepted, which settings-store.js keeps, so no change can be played again.
//
// What OpenClaw itself reads is written to its config through the runtime's own config
// write, and the answer is read back from the config the gateway then holds, so the
// phone only ever shows what the gateway really has:
// - the name: the agent's identity, which OpenClaw puts in every prompt and makes the
//   name that addresses it in a group, and the family room's name for it;
// - the voice: the speech provider's voice;
// - the model: the primary of the chat chain, on OpenRouter, the fallbacks kept, and its
//   second and third, the chain's first two fallbacks, which OpenClaw answers with in that
//   order when the one before fails; a fallback that is cleared lets the next one move up;
// - the vision model: agents.defaults.imageModel, used by image-understanding.js;
// - the image and video generation models: the image and video primaries of
//   `agents.defaults.mediaModels`, on OpenRouter, which household-pictures makes pictures
//   and videos with;
// - a connector: see connectors.js.
// How the assistant talks and how long it answers are the plugin's own, turned into one
// standing instruction for every turn (`guidance`). Notification choices are the calling
// phone's own and change nothing for anyone else.

import { CONNECTORS, connectorView, connectorsFor, switchConnector } from "./connectors.js";
import { modelCard } from "./models.js";
import { visionModelOf } from "./image-understanding.js";
import { CONVERSATIONS, RoomError } from "./room.js";
import { isTextSignedBy } from "./signature.js";

export const SETTINGS_VERSION = "household-app/settings/v1";
const SIGNED_WITHIN_MS = 5 * 60_000;
const LINE = /^[^\r\n]*$/;
const MAX_FIELD = 100;
const MAX_VALUE = 200;
const NAME = /^\p{L}[\p{L} '-]{0,23}$/u;
const TONE = /^(0|[1-9][0-9]?|100)$/;
const LENGTHS = ["short", "balanced", "detailed"];
const CHOICES = ["all", "mentions", "off"];
const DEFAULT_TONE = 50;
const DEFAULT_LENGTH = "balanced";
const OPENROUTER = "openrouter/";
// The chain's second and third models, as `model.fallback.1` and `model.fallback.2`.
const FALLBACK = /^fallback\.([12])$/;

// ElevenLabs voices that OpenRouter's ElevenLabs speech model takes by name.
export const VOICES = [
  { id: "will", name: "Will", summary: "Young man, warm and easy" },
  { id: "jessica", name: "Jessica", summary: "Young woman, bright and kind" },
  { id: "liam", name: "Liam", summary: "Young man, clear and steady" },
  { id: "sarah", name: "Sarah", summary: "Woman, soft and reassuring" },
  { id: "brian", name: "Brian", summary: "Man, deep and calm" },
  { id: "matilda", name: "Matilda", summary: "Woman, warm and friendly" },
];

const TONES = [
  [20, "very calm, quiet and unhurried"],
  [40, "calm and gentle"],
  [60, "warm and even"],
  [80, "lively and upbeat"],
  [100, "very lively, playful and full of energy"],
];
const LENGTH_WORDS = {
  short: "keep answers short, a sentence or two unless asked for more",
  balanced: "keep answers to a few sentences unless more is needed",
  detailed: "give full, detailed answers",
};

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

// The exact text the phone signs, one line each.
export function settingsText({ at, field, value }) {
  return [SETTINGS_VERSION, String(at), field, value].join("\n");
}

function ensure(draft, keys) {
  let node = draft;
  for (const key of keys) {
    node[key] ??= {};
    node = node[key];
  }
  return node;
}

const chainOf = (cfg) => {
  const model = cfg?.agents?.defaults?.model;
  if (typeof model === "string") return [model];
  return model ? [model.primary, ...(model.fallbacks ?? [])].filter((ref) => typeof ref === "string") : [];
};
const bareId = (ref) => (ref.startsWith(OPENROUTER) ? ref.slice(OPENROUTER.length) : ref);
// The OpenRouter id of the image or video model, or null when none is named there.
const mediaModelOf = (cfg, kind) => {
  const slot = cfg?.agents?.defaults?.mediaModels?.[kind];
  const ref = typeof slot === "string" ? slot : slot?.primary;
  return typeof ref === "string" && ref.startsWith(OPENROUTER) && ref.length > OPENROUTER.length ? bareId(ref) : null;
};
const MEDIA_KINDS = { image: "imageModels", video: "videoModels" };
export const nameOf = (cfg) => cfg?.agents?.entries?.main?.identity?.name ?? cfg?.channels?.household?.assistant?.name ?? cfg?.channels?.household?.assistant?.id;
const voiceOf = (cfg) => cfg?.tts?.providers?.openrouter?.speakerVoice ?? null;

// This assistant as the other gateway's phones see it on its page, from the config as it
// is now and OpenRouter's model list.
export function assistantPage(cfg, list) {
  const voice = voiceOf(cfg);
  const [primary] = chainOf(cfg).map(bareId);
  return {
    name: nameOf(cfg),
    voice,
    voiceName: VOICES.find((known) => known.id === voice)?.name ?? null,
    modelName: primary ? modelCard(primary, list).name : null,
  };
}

// `config` answers with the gateway's current config, `mutateConfig` writes a change to
// it, `phoneKeys` answers with the owner's phones' keys, `catalog` is models.js's,
// `changed` is told which field changed the config, after it did, and `readBack` answers
// with a connector's sign-in kind and the owner's linked accounts on this gateway
// (connect.js).
export function createSettings({ config, mutateConfig, store, phoneKeys, catalog, changed, readBack, now = Date.now }) {
  const connectorsOf = (cfg) => connectorsFor(cfg?.channels?.household?.assistant?.id);
  const tone = () => Number(store.value("tone") ?? DEFAULT_TONE);
  const length = () => store.value("length") ?? DEFAULT_LENGTH;

  function notificationsOf(phone) {
    const chosen = phone ? store.notifications(phone) : {};
    return Object.fromEntries([...CONVERSATIONS].map((conversation) => [conversation, chosen[conversation] ?? "all"]));
  }

  // The connectors this gateway has, with their accounts, and, for a phone that asks with
  // `include: ["unavailable"]` (build 14 on), every other one the app knows as unavailable.
  // Build 13 does not ask, so it never shows a switch the gateway would refuse.
  async function connectorsView(cfg, isUnavailableIncluded) {
    const here = new Set(connectorsOf(cfg).map((connector) => connector.id));
    const listed = CONNECTORS.filter((connector) => isUnavailableIncluded || here.has(connector.id));
    return Promise.all(listed.map(async (connector) => connectorView(
      connector,
      cfg,
      here.has(connector.id) ? await readBack(connector) : { reason: "Not on this assistant" },
    )));
  }

  // The image or video model as the phone shows it, named from OpenRouter's list, or from
  // its own id while that list cannot be read, so the page never fails for want of it.
  async function mediaCard(cfg, kind) {
    const id = mediaModelOf(cfg, kind);
    if (!id) return null;
    const list = await catalog[MEDIA_KINDS[kind]]().catch(() => []);
    return modelCard(id, list);
  }

  // `request` is the phone's request, which may carry `include`.
  async function view(phone, request = {}) {
    const cfg = config();
    const [list, imageModel, videoModel] = await Promise.all([catalog.models(), mediaCard(cfg, "image"), mediaCard(cfg, "video")]);
    const [primary, ...fallbacks] = chainOf(cfg).map(bareId);
    const visionID = visionModelOf(cfg);
    const visionList = visionID ? await catalog.visionModels().catch(() => []) : [];
    return {
      assistant: { name: nameOf(cfg), voice: voiceOf(cfg), tone: tone(), length: length() },
      voices: VOICES,
      model: primary ? { ...modelCard(primary, list), fallbacks: fallbacks.map((id) => modelCard(id, list)) } : null,
      imageModel,
      visionModel: visionID ? modelCard(visionID, visionList) : null,
      videoModel,
      connectors: await connectorsView(cfg, Array.isArray(request?.include) && request.include.includes("unavailable")),
      notifications: notificationsOf(phone),
    };
  }

  // What a change does once it is accepted, after its value was checked: a config write,
  // or the plugin's own store.
  async function plan(field, value, phone) {
    const dot = field.indexOf(".");
    const [kind, target] = dot === -1 ? [field, null] : [field.slice(0, dot), field.slice(dot + 1)];
    if (kind === "name" && target === null) {
      if (!NAME.test(value) || value.trimEnd() !== value) refuse("a name is 1 to 24 letters, spaces, hyphens and apostrophes");
      return {
        write: (draft) => {
          ensure(draft, ["agents", "entries", "main", "identity"]).name = value;
          ensure(draft, ["channels", "household", "assistant"]).name = value;
        },
      };
    }
    if (kind === "voice" && target === null) {
      if (!VOICES.some((voice) => voice.id === value)) refuse("not one of the voices");
      return { write: (draft) => { ensure(draft, ["tts", "providers", "openrouter"]).speakerVoice = value; } };
    }
    if (kind === "tone" && target === null) {
      if (!TONE.test(value)) refuse("tone is a whole number from 0 to 100");
      return { keep: () => store.setValue("tone", value) };
    }
    if (kind === "length" && target === null) {
      if (!LENGTHS.includes(value)) refuse("length is short, balanced or detailed");
      return { keep: () => store.setValue("length", value) };
    }
    if (kind === "model" && target === null) {
      if (!(await catalog.models()).some((model) => model.id === value)) refuse("not a model on OpenRouter that takes tool calls");
      const ref = `${OPENROUTER}${value}`;
      return {
        write: (draft) => {
          const defaults = ensure(draft, ["agents", "defaults"]);
          const current = defaults.model;
          // A fallback that becomes the primary leaves the fallbacks, so no model is tried twice.
          defaults.model = current && typeof current === "object"
            ? { ...current, primary: ref, ...(Array.isArray(current.fallbacks) ? { fallbacks: current.fallbacks.filter((one) => one !== ref) } : {}) }
            : { primary: ref };
        },
      };
    }
    const fallback = kind === "model" ? FALLBACK.exec(target ?? "") : null;
    if (fallback) {
      const position = Number(fallback[1]) - 1;
      const chain = chainOf(config());
      if (chain.length === 0) refuse("the assistant has no model to fall back from");
      const ref = value === "" ? null : `${OPENROUTER}${value}`;
      if (ref !== null) {
        if (!(await catalog.models()).some((model) => model.id === value)) refuse("not a model on OpenRouter that takes tool calls");
        if (chain.some((one, index) => one === ref && index !== position + 1)) refuse("that model is already in the chain");
      }
      return {
        write: (draft) => {
          const defaults = ensure(draft, ["agents", "defaults"]);
          const current = defaults.model;
          const slot = current && typeof current === "object" ? current : { primary: current };
          const fallbacks = Array.isArray(slot.fallbacks) ? [...slot.fallbacks] : [];
          if (ref === null) fallbacks.splice(position, 1);
          else if (position < fallbacks.length) fallbacks[position] = ref;
          else fallbacks.push(ref);
          defaults.model = { ...slot, fallbacks };
        },
      };
    }
    if (kind === "model" && target === "vision") {
      if (!(await catalog.visionModels()).some((model) => model.id === value)) {
        refuse("not a model on OpenRouter that reads images and returns text");
      }
      return {
        write: (draft) => {
          // One explicit model, also used by OpenClaw's image tool. Do not retain a
          // hidden fallback that contradicts the model the phone shows as selected.
          ensure(draft, ["agents", "defaults"]).imageModel = { primary: `${OPENROUTER}${value}`, fallbacks: [] };
        },
      };
    }
    if (kind === "model" && Object.hasOwn(MEDIA_KINDS, target)) {
      if (!(await catalog[MEDIA_KINDS[target]]()).some((model) => model.id === value)) {
        refuse(`not ${target === "image" ? "an image" : "a video"} model on OpenRouter`);
      }
      return {
        write: (draft) => {
          const media = ensure(draft, ["agents", "defaults", "mediaModels"]);
          const current = media[target];
          media[target] = current && typeof current === "object" ? { ...current, primary: `${OPENROUTER}${value}` } : { primary: `${OPENROUTER}${value}` };
        },
      };
    }
    if (kind === "connector" && target !== null) {
      const connector = connectorsOf(config()).find((one) => one.id === target);
      if (!connector) refuse("no such connector on this gateway");
      if (value !== "on" && value !== "off") refuse("a connector is on or off");
      return { write: (draft) => switchConnector(draft, connector, value === "on") };
    }
    if (kind === "notifications" && target !== null) {
      if (!CONVERSATIONS.has(target)) refuse("no such conversation");
      if (!CHOICES.includes(value)) refuse("notifications are all, mentions or off");
      if (!phone) refuse("only a paired phone has notification choices");
      return { keep: () => store.setNotification(phone, target, value) };
    }
    return refuse("unknown setting");
  }

  return {
    view,

    async change(params, phone) {
      const { at, field, value, signature } = params ?? {};
      if (!Number.isSafeInteger(at) || Math.abs(at - now()) > SIGNED_WITHIN_MS) refuse("change time out of range");
      if (typeof field !== "string" || !field || field.length > MAX_FIELD || !LINE.test(field)) refuse("unknown setting");
      if (typeof value !== "string" || value.length > MAX_VALUE || !LINE.test(value)) refuse("a value is one line");
      if (!isTextSignedBy(settingsText({ at, field, value }), signature, await phoneKeys())) {
        refuse("a settings change must carry the signature of one of the owner's phones");
      }
      const step = await plan(field, value, phone);
      if (!store.acceptChangeAt(at)) refuse("the gateway already has a newer settings change");
      if (step.keep) step.keep();
      if (step.write) {
        await mutateConfig(step.write);
        changed(field.split(".")[0]);
      }
      return view(phone, params);
    },

    // The standing instruction for every turn: the name the config holds now, and how to
    // talk once the phone has chosen.
    guidance(cfg) {
      const naming = `Your name is ${nameOf(cfg)}.`;
      if (store.value("tone") === null && store.value("length") === null) return naming;
      const words = TONES.find(([highest]) => tone() <= highest)[1];
      return `${naming} Talk in a ${words} way, and ${LENGTH_WORDS[length()]}.`;
    },
  };
}
