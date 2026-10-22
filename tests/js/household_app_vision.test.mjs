import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { createImageUnderstanding, imageSource, MAX_IMAGE_INPUT_BYTES } from "../../deploy/openclaw/plugins/household-app/image-understanding.js";
import { createModelCatalog } from "../../deploy/openclaw/plugins/household-app/models.js";

async function fixture(t, options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "steward-vision-"));
  const bytes = Buffer.from("image fixture bytes");
  const id = createHash("sha256").update(bytes).digest("hex");
  await writeFile(path.join(directory, id), bytes);
  const cfg = { agents: { defaults: { model: "openrouter/text-only/chat", imageModel: { primary: "openrouter/acme/vision-a", fallbacks: ["openrouter/acme/hidden"] }, mediaModels: { image: "openrouter/acme/generator" } } } };
  const calls = [];
  const reader = createImageUnderstanding({
    directory, config: () => cfg, media: { size: async () => bytes.length, path: (id) => path.join(directory, id) },
    log: { warn() {} }, apiKey: () => "fixture-key",
    request: async (url, init) => {
      calls.push(JSON.parse(init.body));
      return { ok: true, json: async () => ({ choices: [{ message: { content: "The chart shows 42 units." }, finish_reason: "stop" }], usage: { cost: 0.002 } }) };
    },
    ...options,
  });
  t.after(async () => { await reader.close(); await rm(directory, { recursive: true, force: true }); });
  return { cfg, calls, reader, bytes, message: { id: "image-1", conversation: "direct", media: [{ id, kind: "photo", mime: "image/png" }] } };
}

test("the exact selected Vision model receives actual bytes and the question; changes apply to the next request", async (t) => {
  const f = await fixture(t);
  const result = await f.reader.describe(f.message, "What does the chart show?");
  assert.match(result, /42 units/);
  assert.equal(f.calls[0].model, "acme/vision-a");
  assert.equal(f.calls[0].models, undefined);
  assert.equal(f.calls[0].reasoning, undefined, "do not disable mandatory reasoning");
  assert.equal(f.calls[0].messages[1].content[0].text, "What does the chart show?");
  assert.equal(f.calls[0].messages[1].content[2].image_url.url, `data:image/png;base64,${f.bytes.toString("base64")}`);
  f.cfg.agents.defaults.imageModel = "openrouter/acme/vision-b";
  await f.reader.describe(f.message, "What does the chart show?");
  assert.deepEqual(f.calls.map((call) => call.model), ["acme/vision-a", "acme/vision-b"]);
  assert.equal(f.reader.spentSince("2000-01-01"), 0.004);
});

test("image files and multiple screenshots are all read together", async (t) => {
  const f = await fixture(t);
  f.message.media.push({ ...f.message.media[0], kind: "file", mime: "image/jpeg" });
  await f.reader.describe(f.message);
  assert.equal(f.calls[0].messages[1].content.filter((part) => part.type === "image_url").length, 2);
});

test("reply-to image lookup cannot cross rooms", () => {
  const parent = { conversation: "direct", media: [{ kind: "photo", mime: "image/png" }] };
  const store = { message: () => parent };
  assert.equal(imageSource({ conversation: "direct", replyTo: "parent", media: [] }, store), parent);
  assert.equal(imageSource({ conversation: "family", replyTo: "parent", media: [] }, store), null);
});

test("a provider failure is explicit and never calls the hidden fallback", async (t) => {
  let calls = 0;
  const f = await fixture(t, { request: async () => { calls += 1; throw new Error("unavailable"); } });
  assert.match(await f.reader.describe(f.message), /not analyzed/);
  assert.equal(calls, 1);
});

test("missing vision selection does not use the text or image-generation models", async (t) => {
  const f = await fixture(t);
  delete f.cfg.agents.defaults.imageModel;
  assert.match(await f.reader.describe(f.message), /Models > Vision/);
  assert.equal(f.calls.length, 0);
});

test("invalid, unsupported and oversized image data is refused before a model call", async (t) => {
  const f = await fixture(t);
  f.message.media[0].mime = "image/heic";
  assert.match(await f.reader.describe(f.message), /not analyzed/);
  f.message.media[0].mime = "image/png";
  f.message.media[0].id = "../../private";
  assert.match(await f.reader.describe(f.message), /not analyzed/);
  assert.equal(f.calls.length, 0);
  const large = await fixture(t, { media: { size: async () => MAX_IMAGE_INPUT_BYTES + 1, path() { assert.fail("must not read oversized data"); } } });
  assert.match(await large.reader.describe(large.message), /20 MB/);
  assert.equal(large.calls.length, 0);
});

test("the Vision catalog only lists image-reading text models, including ones without tools", async () => {
  const raw = (id, input, output, prompt = "0.000001") => ({ id, name: id, architecture: { input_modalities: input, output_modalities: output }, pricing: { prompt, completion: "0.000002" } });
  const catalog = createModelCatalog({ fetchFn: async () => ({ ok: true, json: async () => ({ data: [
    raw("acme/reader", ["text", "image"], ["text"]),
    raw("acme/text", ["text"], ["text"]),
    raw("acme/generator", ["text", "image"], ["image", "text"]),
    raw("openrouter/auto", ["text", "image"], ["text"], "-1"),
  ] }) }) });
  assert.deepEqual((await catalog.visionModels()).map((model) => model.id), ["acme/reader"]);
});
