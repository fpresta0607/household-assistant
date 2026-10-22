// The household-openrouter-video OpenClaw plugin: video understanding through OpenRouter.
//
// The request shape is OpenRouter's chat completions contract: a Bearer key, and a user
// message whose content holds a text part and a `video_url` part carrying a data URL.
// That is the shape that described a real clip on 2026-10-07.

import assert from "node:assert/strict";
import { test } from "node:test";

import plugin, { describeVideo } from "../../deploy/openclaw/plugins/household-openrouter-video/index.js";

const CLIP = Buffer.from("not really an mp4");

function fakeOpenRouter({ status = 200, payload = { choices: [{ message: { content: " A milk carton slides across a table. " } }] } } = {}) {
  const calls = [];
  const fetchFn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return new Response(typeof payload === "string" ? payload : JSON.stringify(payload), { status });
  };
  return { calls, fetchFn };
}

const request = (extra = {}) => ({ buffer: CLIP, timeoutMs: 30_000, ...extra });
const env = { OPENROUTER_API_KEY: "sk-or-test" };

test("a video goes to OpenRouter as a video_url part with the gateway's key", async () => {
  const { calls, fetchFn } = fakeOpenRouter();

  const result = await describeVideo(request({ mime: "video/quicktime" }), { env, fetchFn });

  assert.deepEqual(result, { text: "A milk carton slides across a table.", model: "google/gemini-2.5-flash" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://openrouter.ai/api/v1/chat/completions");
  assert.equal(calls[0].init.headers.Authorization, "Bearer sk-or-test");
  assert.equal(calls[0].body.model, "google/gemini-2.5-flash");
  const [text, video] = calls[0].body.messages[0].content;
  assert.deepEqual(text, { type: "text", text: "Describe the video." });
  assert.deepEqual(video, {
    type: "video_url",
    video_url: { url: `data:video/quicktime;base64,${CLIP.toString("base64")}` },
  });
});

test("the configured model and OpenClaw's prompt are used when given", async () => {
  const { calls, fetchFn } = fakeOpenRouter();

  const result = await describeVideo(
    request({ model: " google/gemini-3.5-flash ", prompt: "What happens?" }),
    { env, fetchFn },
  );

  assert.equal(result.model, "google/gemini-3.5-flash");
  assert.equal(calls[0].body.model, "google/gemini-3.5-flash");
  assert.equal(calls[0].body.messages[0].content[0].text, "What happens?");
  assert.match(calls[0].body.messages[0].content[1].video_url.url, /^data:video\/mp4;base64,/);
});

test("every failure is an error OpenClaw can report, and none carries the key", async () => {
  await assert.rejects(describeVideo(request(), { env: {}, fetchFn: fakeOpenRouter().fetchFn }), /OPENROUTER_API_KEY/);

  const refused = fakeOpenRouter({ status: 402, payload: { error: { message: "Insufficient credits" } } });
  await assert.rejects(describeVideo(request(), { env, fetchFn: refused.fetchFn }), (error) => {
    assert.match(error.message, /\(402\).*Insufficient credits/);
    assert.doesNotMatch(error.message, /sk-or-test/);
    return true;
  });

  const inBody = fakeOpenRouter({ payload: { error: { message: "Provider returned error" } } });
  await assert.rejects(describeVideo(request(), { env, fetchFn: inBody.fetchFn }), /Provider returned error/);

  const empty = fakeOpenRouter({ payload: { choices: [{ message: { content: "  " } }] } });
  await assert.rejects(describeVideo(request(), { env, fetchFn: empty.fetchFn }), /missing text/);

  const notJson = fakeOpenRouter({ payload: "<html>gateway timeout</html>" });
  await assert.rejects(describeVideo(request(), { env, fetchFn: notJson.fetchFn }), /no JSON/);
});

for (const choice of [
  { error: { message: "Provider interrupted" }, finish_reason: "error" },
  { error: { message: "Provider interrupted" }, finish_reason: "stop" },
  { finish_reason: "error" },
]) {
  test(`failed choices reject partial content: ${JSON.stringify(choice)}`, async () => {
    const { fetchFn } = fakeOpenRouter({ payload: { choices: [
      { ...choice, message: { content: "A partial description" } },
    ] } });

    await assert.rejects(describeVideo(request(), { env, fetchFn }), /Video description failed/);
  });
}

for (const content of [null, "", "  ", [{ type: "text", text: "An unsupported array description" }]]) {
  test(`only nonempty string content supplies a description: ${JSON.stringify(content)}`, async () => {
    const { fetchFn } = fakeOpenRouter({ payload: { choices: [{ message: { content } }] } });

    await assert.rejects(describeVideo(request(), { env, fetchFn }), /missing text/);
  });
}

test("a description that never comes is abandoned at OpenClaw's deadline", async () => {
  const hanging = (_url, init) =>
    new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason)));
  // AbortSignal.timeout's timer does not keep node alive, and nothing else here does.
  const hold = setTimeout(() => {}, 5_000);
  try {
    await assert.rejects(describeVideo(request({ timeoutMs: 20 }), { env, fetchFn: hanging }), /timeout|aborted/i);
  } finally {
    clearTimeout(hold);
  }
});

test("registration offers one video provider that needs no OpenClaw auth profile", () => {
  const registered = [];
  plugin.register({ registerMediaUnderstandingProvider: (provider) => registered.push(provider) });

  assert.equal(registered.length, 1);
  assert.equal(registered[0].id, "openrouter-video");
  assert.deepEqual(registered[0].capabilities, ["video"]);
  assert.deepEqual(registered[0].defaultModels, { video: "google/gemini-2.5-flash" });
  assert.equal(registered[0].resolveAuth().kind, "none");
});
