// OpenRouter's public model list as the phone's model picker sees it, from
// deploy/openclaw/plugins/household-app/models.js. OpenRouter is never reached: each
// test hands in its own answer.
//
// Run with `node --test tests/js/household_app_models.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { test } from "node:test";

import { dollarsPerSecond } from "../../deploy/openclaw/plugins/household-pictures/index.js";
import {
  IMAGE_MODELS_URL,
  MODELS_URL,
  SPEECH_MODELS_URL,
  VIDEO_MODELS_URL,
  createModelCatalog,
  modelCard,
} from "../../deploy/openclaw/plugins/household-app/models.js";

const HOUR = 3_600_000;
const START = Date.UTC(2026, 9, 15, 17, 0);

function listed(id, name, { input = "0.0000001", output = "0.0000004", imageOutput, tools = true, inputs = ["text"], outputs = ["text"] } = {}) {
  return {
    id,
    name,
    architecture: { input_modalities: inputs, output_modalities: outputs },
    pricing: { prompt: input, completion: output, ...(imageOutput === undefined ? {} : { image_output: imageOutput }) },
    supported_parameters: tools ? ["tools", "tool_choice", "temperature"] : ["temperature"],
  };
}

const OPENROUTER = [
  listed("z-ai/glm-5.3-flash", "Z.ai: GLM 5.3 Flash"),
  listed("anthropic/claude-sonnet-5", "Anthropic: Claude Sonnet 5", { input: "0.000003", output: "0.000015" }),
  listed("openai/gpt-5.4-mini", "OpenAI: GPT-5.4 Mini", { input: "0.00000025", output: "0.000002" }),
  listed("google/gemini-3.5-flash", "Google: Gemini 3.5 Flash", { input: "0.0000003", output: "0.0000025", inputs: ["text", "image"] }),
  listed("deepseek/deepseek-v4-flash-0731:free", "DeepSeek: DeepSeek V4 Flash (free)", { input: "0", output: "0" }),
  listed("mistralai/mistral-large-3", "Mistral: Mistral Large 3", { input: "0.000002", output: "0.000006" }),
  listed("thudm/glm-z1-32b", "THUDM: GLM Z1 32B", { tools: false }),
  listed("openai/gpt-5.4-image-2", "OpenAI: GPT-5.4 Image 2", { outputs: ["image", "text"] }),
  listed("openai/whisper-large-v3-turbo", "OpenAI: Whisper", { inputs: ["audio"] }),
  listed("openrouter/auto", "Auto Router", { input: "-1", output: "-1" }),
];
const SPEECH = [
  { id: "elevenlabs/eleven-v4-turbo", name: "ElevenLabs: Eleven v4 Turbo", pricing: { prompt: "0.00002", completion: "0" } },
  { id: "hexgrad/kokoro-82m", name: "Kokoro", pricing: { prompt: "0.00000062", completion: "0" } },
];

// OpenRouter's lists of models that make images and of video models, as it answered on
// 17 and 18 October 2026, cut down.
const IMAGES = [
  listed("openai/gpt-image-2.5-flare", "OpenAI: GPT Image 2.5 Flare", { input: "0.000008", imageOutput: "0.00003", inputs: ["text", "image"], outputs: ["image"] }),
  listed("google/gemini-3.1-flash-image", "Google: Nano Banana 2 (Gemini 3.1 Flash Image)", { imageOutput: "0.00006", inputs: ["image", "text"], outputs: ["image", "text"] }),
  listed("black-forest-labs/flux-3-image", "Black Forest Labs: FLUX 3 Image", { input: "0", output: "0", imageOutput: "0.00000982035928143713", inputs: ["text", "image"], outputs: ["image"] }),
  listed("acme/no-price-image", "Acme: Unpriced Image", { input: "0", output: "0", outputs: ["image"] }),
  listed("openrouter/auto", "Auto Router", { input: "-1", output: "-1", outputs: ["text", "image"] }),
];
const VEO = {
  id: "google/veo-3.1-fast",
  name: "Google: Veo 3.1 Fast",
  supported_durations: [4, 6, 8],
  supported_resolutions: ["720p", "1080p", "4K"],
  pricing_skus: {
    duration_seconds_with_audio: "0.12",
    duration_seconds_with_audio_4k: "0.30",
    duration_seconds_without_audio: "0.10",
    duration_seconds_with_audio_720p: "0.10",
    duration_seconds_without_audio_4k: "0.25",
    duration_seconds_without_audio_720p: "0.08",
  },
};
const GROK = {
  id: "x-ai/grok-imagine-video-1.5",
  name: "SpaceXAI: Grok Imagine Video 1.5",
  supported_resolutions: ["480p", "720p", "1080p"],
  pricing_skus: {
    cents_per_image_input: "1",
    cents_per_video_output_second_480p: "8",
    cents_per_video_output_second_720p: "14",
    cents_per_video_output_second_1080p: "25",
  },
};
const VIDEOS = [VEO, GROK];
// One of each way OpenRouter's video list prices a model.
const VIDEO_PRICES = [
  [VEO, { dollars: 0.1, per: "second at 720p" }],
  [GROK, { dollars: 0.14, per: "second at 720p" }],
  [
    {
      id: "black-forest-labs/flux-3-video",
      name: "Black Forest Labs: FLUX 3 Video",
      supported_resolutions: ["720p", "1080p", "2K", "4K"],
      pricing_skus: { cents_per_second_output: "17", cents_per_second_output_720p: "17", cents_per_second_video_continuation_720p: "41" },
    },
    { dollars: 0.17, per: "second at 720p" },
  ],
  [{ id: "runway/gen-4.5", name: "Runway: Gen-4.5", supported_resolutions: ["720p"], pricing_skus: { cents_per_second_output: "12" } }, { dollars: 0.12, per: "second" }],
  [{ id: "minimax/hailuo-2.3", name: "MiniMax: Hailuo 2.3", supported_resolutions: ["1080p"], pricing_skus: { duration_seconds: "0.0817" } }, { dollars: 0.0817, per: "second" }],
  [
    {
      id: "heygen/heygen-video-1",
      name: "HeyGen: HeyGen Video",
      supported_resolutions: ["480p", "768p", "2K"],
      pricing_skus: { duration_seconds_2k: "0.1", duration_seconds_480p: "0.02", reference_input_images: "0.04", reference_duration_seconds_480p: "0.07" },
    },
    { dollars: 0.07, per: "second at 480p" },
  ],
  [
    { id: "black-forest-labs/flux-video-upscale", name: "Black Forest Labs: FLUX Video Upscale", pricing_skus: { cents_per_megapixel_second_precise: "3.5", cents_per_megapixel_second_creative: "5" } },
    { dollars: 0.05, per: "megapixel second" },
  ],
  [
    { id: "bytedance/seedance-2.0-fast", name: "ByteDance: Seedance 2.0 Fast", supported_resolutions: ["480p", "720p"], pricing_skus: { video_tokens: "0.0000042", video_tokens_with_video_input: "0.000002475" } },
    { dollars: 4.2, per: "million video tokens" },
  ],
  [{ id: "acme/no-price-video", name: "Acme: Unpriced Video", pricing_skus: { minimum_cents_per_generation: "56" } }, null],
  [{ id: "acme/bare-video", name: "Acme: Bare Video" }, null],
];

function fakeOpenRouter({ models = OPENROUTER, speech = SPEECH, images = IMAGES, videos = VIDEOS, status = 200 } = {}) {
  const asked = [];
  return {
    asked,
    fetchFn: async (url, init) => {
      asked.push({ url, init });
      const data = { [SPEECH_MODELS_URL]: speech, [IMAGE_MODELS_URL]: images, [VIDEO_MODELS_URL]: videos }[url] ?? models;
      return { ok: status === 200, status, json: async () => ({ data }) };
    },
  };
}

test("only text models that call tools are listed, with dollars per million tokens", async () => {
  const openRouter = fakeOpenRouter();
  const models = await createModelCatalog({ fetchFn: openRouter.fetchFn, now: () => START }).models();
  assert.deepEqual(models.map((model) => model.id), [
    "z-ai/glm-5.3-flash",
    "anthropic/claude-sonnet-5",
    "openai/gpt-5.4-mini",
    "google/gemini-3.5-flash",
    "deepseek/deepseek-v4-flash-0731:free",
    "mistralai/mistral-large-3",
  ]);
  assert.deepEqual(models[0], {
    id: "z-ai/glm-5.3-flash",
    name: "GLM 5.3 Flash",
    company: "Z.ai",
    icon: "zai",
    inputPerMillion: 0.1,
    outputPerMillion: 0.4,
    badge: "fast",
  });
});

test("each company's own icon where the app has one, a symbol where it has none", async () => {
  const openRouter = fakeOpenRouter();
  const models = await createModelCatalog({ fetchFn: openRouter.fetchFn, now: () => START }).models();
  const icons = Object.fromEntries(models.map((model) => [model.id, [model.company, model.icon]]));
  assert.deepEqual(icons["anthropic/claude-sonnet-5"], ["Anthropic", "anthropic"]);
  assert.deepEqual(icons["openai/gpt-5.4-mini"], ["OpenAI", "openai"]);
  assert.deepEqual(icons["google/gemini-3.5-flash"], ["Google", "googlegemini"]);
  assert.deepEqual(icons["deepseek/deepseek-v4-flash-0731:free"], ["DeepSeek", "deepseek"]);
  assert.deepEqual(icons["mistralai/mistral-large-3"], ["Mistral", "symbol:cpu"]);
});

test("a badge says free, fast or smart, and most models have none", async () => {
  const openRouter = fakeOpenRouter();
  const models = await createModelCatalog({ fetchFn: openRouter.fetchFn, now: () => START }).models();
  const badges = Object.fromEntries(models.map((model) => [model.id, model.badge]));
  assert.deepEqual(badges, {
    "z-ai/glm-5.3-flash": "fast",
    "anthropic/claude-sonnet-5": "smart",
    "openai/gpt-5.4-mini": "fast",
    "google/gemini-3.5-flash": "fast",
    "deepseek/deepseek-v4-flash-0731:free": "free",
    "mistralai/mistral-large-3": null,
  });
});

test("the public list is read with no key, at most once an hour", async () => {
  const openRouter = fakeOpenRouter();
  const clock = { now: START };
  const catalog = createModelCatalog({ fetchFn: openRouter.fetchFn, now: () => clock.now });
  await Promise.all([catalog.models(), catalog.models()]);
  clock.now += HOUR - 1;
  await catalog.models();
  assert.equal(openRouter.asked.length, 1);
  assert.equal(openRouter.asked[0].url, MODELS_URL);
  assert.equal(MODELS_URL, "https://openrouter.ai/api/v1/models");
  assert.equal(JSON.stringify(openRouter.asked[0].init ?? {}).includes("uthorization"), false);
  clock.now += 2;
  await catalog.models();
  assert.equal(openRouter.asked.length, 2);
});

test("a list OpenRouter would not give is an error, and the next call asks again", async () => {
  const openRouter = fakeOpenRouter({ status: 503 });
  const catalog = createModelCatalog({ fetchFn: openRouter.fetchFn, now: () => START });
  await assert.rejects(catalog.models(), /OpenRouter/);
  await assert.rejects(catalog.models(), /OpenRouter/);
  assert.equal(openRouter.asked.length, 2);
});

test("a speech model's price is OpenRouter's, in dollars per character", async () => {
  const openRouter = fakeOpenRouter();
  const catalog = createModelCatalog({ fetchFn: openRouter.fetchFn, now: () => START });
  assert.equal(await catalog.speechPrice("elevenlabs/eleven-v4-turbo"), 0.00002);
  assert.equal(await catalog.speechPrice("openrouter/elevenlabs/eleven-v4-turbo"), 0.00002);
  await assert.rejects(catalog.speechPrice("someone/else"), /price/);
  assert.deepEqual(openRouter.asked.map((request) => request.url), [SPEECH_MODELS_URL]);
});

test("a model's card comes from the list, or from its own id when the list does not have it", () => {
  const list = [{ id: "z-ai/glm-5.3", name: "GLM 5.3", company: "Z.ai", icon: "zai", inputPerMillion: 0.6, outputPerMillion: 2.2, badge: null }];
  assert.deepEqual(modelCard("z-ai/glm-5.3", list), { id: "z-ai/glm-5.3", name: "GLM 5.3", company: "Z.ai", icon: "zai" });
  assert.deepEqual(modelCard("openai/o9", list), { id: "openai/o9", name: "o9", company: "OpenAI", icon: "openai" });
  assert.deepEqual(modelCard("acme/brain-1", list), { id: "acme/brain-1", name: "brain-1", company: "acme", icon: "symbol:cpu" });
});

test("the image picker lists what OpenRouter says makes images, routers left out, each by its company", async () => {
  const openRouter = fakeOpenRouter();
  const catalog = createModelCatalog({ fetchFn: openRouter.fetchFn, now: () => START });
  assert.deepEqual((await catalog.imageModels()).map(({ price, ...choice }) => choice), [
    { id: "openai/gpt-image-2.5-flare", name: "GPT Image 2.5 Flare", company: "OpenAI", icon: "openai" },
    { id: "google/gemini-3.1-flash-image", name: "Nano Banana 2 (Gemini 3.1 Flash Image)", company: "Google", icon: "googlegemini" },
    { id: "black-forest-labs/flux-3-image", name: "FLUX 3 Image", company: "Black Forest Labs", icon: "symbol:cpu" },
    { id: "acme/no-price-image", name: "Unpriced Image", company: "Acme", icon: "symbol:cpu" },
  ]);
  assert.equal(IMAGE_MODELS_URL, "https://openrouter.ai/api/v1/models?output_modalities=image");
});

test("the video picker lists OpenRouter's video models, which may be none, each list read at most once an hour", async () => {
  const clock = { now: START };
  const openRouter = fakeOpenRouter();
  const catalog = createModelCatalog({ fetchFn: openRouter.fetchFn, now: () => clock.now });
  assert.deepEqual((await catalog.videoModels()).map(({ price, ...choice }) => choice), [
    { id: "google/veo-3.1-fast", name: "Veo 3.1 Fast", company: "Google", icon: "googlegemini" },
    { id: "x-ai/grok-imagine-video-1.5", name: "Grok Imagine Video 1.5", company: "SpaceXAI", icon: "symbol:cpu" },
  ]);
  await catalog.imageModels();
  clock.now += HOUR - 1;
  await catalog.videoModels();
  await catalog.imageModels();
  assert.deepEqual(openRouter.asked.map((request) => request.url), [VIDEO_MODELS_URL, IMAGE_MODELS_URL]);
  assert.equal(VIDEO_MODELS_URL, "https://openrouter.ai/api/v1/videos/models");

  const none = createModelCatalog({ fetchFn: fakeOpenRouter({ videos: [] }).fetchFn, now: () => START });
  assert.deepEqual(await none.videoModels(), []);
});

test("an image model's price is OpenRouter's, in dollars a million of the image tokens it bills, and none when it lists none", async () => {
  const catalog = createModelCatalog({ fetchFn: fakeOpenRouter().fetchFn, now: () => START });
  assert.deepEqual((await catalog.imageModels()).map((model) => [model.id, model.price]), [
    ["openai/gpt-image-2.5-flare", { dollars: 30, per: "million image tokens" }],
    ["google/gemini-3.1-flash-image", { dollars: 60, per: "million image tokens" }],
    ["black-forest-labs/flux-3-image", { dollars: 9.8204, per: "million image tokens" }],
    ["acme/no-price-image", null],
  ]);
});

test("a video model's price is OpenRouter's, a second at the size the video tool asks for, else its video tokens, else none", async () => {
  const videos = VIDEO_PRICES.map(([raw]) => raw);
  const catalog = createModelCatalog({ fetchFn: fakeOpenRouter({ videos }).fetchFn, now: () => START });
  const listed = await catalog.videoModels();
  assert.deepEqual(listed.map((model) => model.id), videos.map((raw) => raw.id));
  for (const [index, [raw, price]] of VIDEO_PRICES.entries()) {
    assert.deepEqual(listed[index].price, price, raw.id);
  }
});

test("a video model's price a second is the one household-pictures counts against its cap", async () => {
  const videos = VIDEO_PRICES.map(([raw]) => raw);
  const catalog = createModelCatalog({ fetchFn: fakeOpenRouter({ videos }).fetchFn, now: () => START });
  for (const [index, model] of (await catalog.videoModels()).entries()) {
    if (!model.price?.per.includes("second")) continue;
    const sizes = videos[index].supported_resolutions ?? [];
    const size = sizes.includes("720p") ? "720p" : sizes[0] ?? null;
    assert.equal(model.price.dollars, dollarsPerSecond(videos[index], size), model.id);
  }
});
