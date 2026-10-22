// OpenRouter's public model lists, for the text, image and video pickers in Settings and
// for pricing Talk's speech. The lists are public, so they are read with no key, and
// each at most once an hour.
//
// The text picker offers only text models that take tool calls, since the assistants'
// skills and connectors are tools. The image picker offers what OpenRouter lists as
// making images, and the video picker its list of video models, each of which
// household-pictures calls directly. Each model is named by its company, with the
// company's own icon where the app has one, and its price in the unit OpenRouter bills
// it by: tokens in and out for text, image tokens for a picture, and a second or video
// tokens for a video.

export const MODELS_URL = "https://openrouter.ai/api/v1/models";
export const SPEECH_MODELS_URL = `${MODELS_URL}?output_modalities=speech`;
export const IMAGE_MODELS_URL = `${MODELS_URL}?output_modalities=image`;
export const VIDEO_MODELS_URL = "https://openrouter.ai/api/v1/videos/models";
const KEPT_MS = 3_600_000;
const PER_MILLION = 1_000_000;
// Output at or over this many dollars a million tokens is a large model.
const SMART_OUTPUT_PER_MILLION = 10;
const FAST = /\b(flash|mini|nano|lite|haiku|turbo|fast)\b/i;
const OTHER_ICON = "symbol:cpu";
// Companies by the first part of an OpenRouter id, with the app's icon for each.
const COMPANIES = {
  "z-ai": { company: "Z.ai", icon: "zai" },
  anthropic: { company: "Anthropic", icon: "anthropic" },
  openai: { company: "OpenAI", icon: "openai" },
  google: { company: "Google", icon: "googlegemini" },
  deepseek: { company: "DeepSeek", icon: "deepseek" },
  perplexity: { company: "Perplexity", icon: "perplexity" },
};

const dollarsPerMillion = (perToken) => Math.round(Number(perToken) * PER_MILLION * 10_000) / 10_000;

function badgeFor(name, inputPerMillion, outputPerMillion) {
  if (inputPerMillion === 0 && outputPerMillion === 0) return "free";
  if (FAST.test(name)) return "fast";
  if (outputPerMillion >= SMART_OUTPUT_PER_MILLION) return "smart";
  return null;
}

// A model's id, its name without the company OpenRouter puts before it, its company and
// its icon, or null for an entry with no id or name.
function choiceOf({ id, name } = {}) {
  if (typeof id !== "string" || typeof name !== "string") return null;
  const [prefix, rest] = name.includes(": ") ? [name.slice(0, name.indexOf(": ")), name.slice(name.indexOf(": ") + 2)] : [null, name];
  const known = COMPANIES[id.split("/")[0]];
  return { id, name: rest, company: known?.company ?? prefix ?? id.split("/")[0], icon: known?.icon ?? OTHER_ICON };
}

// One model as the text picker shows it, or null for one it does not offer.
function describe(raw) {
  const { architecture, pricing, supported_parameters: parameters } = raw ?? {};
  const choice = choiceOf(raw ?? {});
  if (!choice) return null;
  const isText = architecture?.input_modalities?.includes("text") &&
    Array.isArray(architecture.output_modalities) && architecture.output_modalities.join() === "text";
  if (!isText || !parameters?.includes("tools")) return null;
  const inputPerMillion = dollarsPerMillion(pricing?.prompt);
  const outputPerMillion = dollarsPerMillion(pricing?.completion);
  // OpenRouter prices a router that picks a model as -1: there is no price to show.
  if (!(inputPerMillion >= 0) || !(outputPerMillion >= 0)) return null;
  return { ...choice, inputPerMillion, outputPerMillion, badge: badgeFor(choice.name, inputPerMillion, outputPerMillion) };
}

// A price OpenRouter lists, in dollars, or null for none: it writes prices as strings, and
// -1 for a router that has no price of its own.
function listedDollars(value) {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const dollars = Number(value);
  return value !== "" && Number.isFinite(dollars) && dollars >= 0 ? dollars : null;
}

// What a picture costs: OpenRouter bills an image model by the image tokens it makes, so
// dollars a million of those, or null when it lists no such price.
function imagePrice(pricing) {
  const perToken = listedDollars(pricing?.image_output);
  return perToken === null ? null : { dollars: dollarsPerMillion(perToken), per: "million image tokens" };
}

// What a second of video costs at the size household-pictures asks for, 720p or else the
// first size listed, the dearest of the prices for it, so the price shown is the one its
// cap counts (household-pictures' dollarsPerSecond). A price named for no size is the
// default, and continuing a video, which that tool never does, is left out. A model
// billed by video tokens costs dollars a million of those instead, and one with neither
// has no price.
function videoPrice(raw) {
  const sizes = Array.isArray(raw?.supported_resolutions) ? raw.supported_resolutions : [];
  const size = sizes.includes("720p") ? "720p" : sizes[0] ?? null;
  const skus = raw?.pricing_skus ?? {};
  const seconds = Object.entries(skus)
    .filter(([name]) => /second/.test(name) && !/continuation/.test(name))
    .map(([name, value]) => [name, listedDollars(value)])
    .filter(([, value]) => value !== null)
    .map(([name, value]) => [name, name.startsWith("cents_") ? value / 100 : value]);
  const sized = size ? seconds.filter(([name]) => name.toLowerCase().endsWith(`_${size.toLowerCase()}`)) : [];
  const pool = sized.length > 0 ? sized : seconds.filter(([name]) => !/_\d+(?:p|k)$/i.test(name));
  if (pool.length > 0) {
    const [name, dollars] = pool.reduce((dearest, price) => (price[1] > dearest[1] ? price : dearest));
    const per = name.includes("megapixel") ? "megapixel second" : sized.length > 0 ? `second at ${size}` : "second";
    return { dollars, per };
  }
  const perToken = listedDollars(skus.video_tokens);
  return perToken === null ? null : { dollars: dollarsPerMillion(perToken), per: "million video tokens" };
}

// One model as the image picker shows it, with its price, or null for a router, which
// OpenRouter prices as -1 and whose images household-pictures cannot ask for by name.
function describeImageModel(raw) {
  const outputs = raw?.architecture?.output_modalities;
  if (!Array.isArray(outputs) || !outputs.includes("image") || !(Number(raw?.pricing?.prompt) >= 0)) return null;
  const choice = choiceOf(raw);
  return choice && { ...choice, price: imagePrice(raw.pricing) };
}

function describeVideoModel(raw) {
  const choice = choiceOf(raw ?? {});
  return choice && { ...choice, price: videoPrice(raw) };
}

// Image input and a text answer, not an image-generation model or an auto router.
// Reading an image does not require tool-calling support.
function describeVisionModel(raw) {
  if (!raw?.architecture?.input_modalities?.includes("image") ||
      raw?.architecture?.output_modalities?.join() !== "text") return null;
  const choice = choiceOf(raw);
  const prompt = listedDollars(raw.pricing?.prompt);
  const completion = listedDollars(raw.pricing?.completion);
  if (!choice || prompt === null || completion === null) return null;
  return { ...choice, price: { dollars: dollarsPerMillion(prompt), per: "million input tokens" } };
}

// A model's name, company and icon from the picker's list, or from its own id when the
// list does not offer it, as for a free fallback that takes no tool calls.
export function modelCard(id, list) {
  const listed = list.find((model) => model.id === id);
  if (listed) return { id, name: listed.name, company: listed.company, icon: listed.icon };
  const [prefix, ...rest] = id.split("/");
  const known = COMPANIES[prefix];
  return { id, name: rest.join("/") || id, company: known?.company ?? prefix, icon: known?.icon ?? OTHER_ICON };
}

export function createModelCatalog({ fetchFn = fetch, now = Date.now } = {}) {
  const lists = new Map();

  // One public list, kept for an hour once read. Two callers at once share one read, and
  // a read that failed is tried again by the next caller.
  function read(url) {
    const kept = lists.get(url);
    if (kept && (kept.pending || now() - kept.at < KEPT_MS)) return kept.pending ?? Promise.resolve(kept.data);
    const pending = (async () => {
      const answer = await fetchFn(url, { headers: { Accept: "application/json" } });
      if (!answer.ok) throw new Error(`OpenRouter answered ${answer.status} for its model list`);
      const body = await answer.json();
      if (!Array.isArray(body?.data)) throw new Error("OpenRouter's model list has no models");
      return body.data;
    })();
    lists.set(url, { pending });
    pending.then(
      (data) => lists.set(url, { at: now(), data }),
      () => lists.delete(url),
    );
    return pending;
  }

  return {
    async models() {
      return (await read(MODELS_URL)).map(describe).filter(Boolean);
    },

    async imageModels() {
      return (await read(IMAGE_MODELS_URL)).map(describeImageModel).filter(Boolean);
    },

    async visionModels() {
      return (await read(MODELS_URL)).map(describeVisionModel).filter(Boolean);
    },

    // Every model OpenRouter's video API lists, which may be none.
    async videoModels() {
      return (await read(VIDEO_MODELS_URL)).map(describeVideoModel).filter(Boolean);
    },

    // Dollars for each character a speech model speaks, by its OpenRouter id.
    async speechPrice(model) {
      const id = model.replace(/^openrouter\//, "");
      const listed = (await read(SPEECH_MODELS_URL)).find((entry) => entry?.id === id);
      const price = Number(listed?.pricing?.prompt);
      if (!listed || !(price >= 0)) throw new Error(`OpenRouter lists no price for the speech model ${id}`);
      return price;
    },
  };
}
