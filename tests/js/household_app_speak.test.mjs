// A sentence spoken by the gateway for the phone, from
// deploy/openclaw/plugins/household-app/speak.js: a voice's sample in Settings, and
// every sentence Talk says. OpenClaw's speech is a fake that records what it was asked.
//
// Run with `node --test tests/js/household_app_speak.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { createMediaStore } from "../../deploy/openclaw/plugins/household-app/media.js";
import { openSettingsStore } from "../../deploy/openclaw/plugins/household-app/settings-store.js";
import { MAX_SPOKEN, TALK_DAILY_CHARACTERS, createSpeak } from "../../deploy/openclaw/plugins/household-app/speak.js";

const NOW = new Date(2026, 9, 15, 17, 0).getTime();
const AUDIO = Buffer.from("ID3 pretend mp3 audio");

function onTheBox(household = {}) {
  return {
    tts: { provider: "openrouter", providers: { openrouter: { model: "elevenlabs/eleven-v4-turbo", speakerVoice: "will" } } },
    channels: { household: { assistant: { id: "corey", name: "Corey" }, ...household } },
  };
}

async function setup({ config = onTheBox(), succeeds = true } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-speak-"));
  const audioPath = path.join(directory, "voice.mp3");
  await writeFile(audioPath, AUDIO);
  const store = openSettingsStore(path.join(directory, "settings.sqlite"));
  const media = createMediaStore(directory);
  const clock = { now: NOW };
  const asked = [];
  const speak = createSpeak({
    store,
    media,
    config: () => config,
    tts: async (request) => {
      asked.push(request);
      return succeeds ? { success: true, audioPath } : { success: false, error: "provider said no" };
    },
    now: () => clock.now,
  });
  return { speak, store, media, asked, clock };
}

test("the words are spoken by the gateway's own speech and kept as media the phone reads", async () => {
  const { speak, media, asked } = await setup();
  const answer = await speak({ text: "Hi Franco, this is how I sound." });
  const id = createHash("sha256").update(AUDIO).digest("hex");
  assert.deepEqual(answer, { media: { id, mime: "audio/mpeg", bytes: AUDIO.length } });
  assert.equal((await media.read(id, 0, 100)).data, AUDIO.toString("base64"));
  assert.equal(asked[0].text, "Hi Franco, this is how I sound.");
  assert.equal(asked[0].agentId, "main");
  assert.equal(asked[0].cfg.tts.providers.openrouter.speakerVoice, "will");
});

// household-speech makes the voice replies the app plays as voice notes for this same
// target, so Talk's audio comes in a format the phone already plays.
test("the words are spoken for the household channel's default account", async () => {
  const { speak, asked } = await setup();
  await speak({ text: "Standup at 9." });
  assert.equal(asked[0].channel, "household");
  assert.equal(asked[0].accountId, "default");
});

test("another voice from the list is spoken in that voice, and the config is left as it was", async () => {
  const config = onTheBox();
  const { speak, asked } = await setup({ config });
  await speak({ text: "Hello, I'm Denise.", voice: "jessica" });
  assert.equal(asked[0].cfg.tts.providers.openrouter.speakerVoice, "jessica");
  assert.equal(asked[0].cfg.tts.providers.openrouter.model, "elevenlabs/eleven-v4-turbo");
  assert.equal(config.tts.providers.openrouter.speakerVoice, "will");
});

for (const [label, params] of [
  ["no words", { text: "   " }],
  ["words that are not text", { text: 42 }],
  [`more than ${MAX_SPOKEN} characters`, { text: "a".repeat(MAX_SPOKEN + 1) }],
  ["a voice not in the list", { text: "Hello", voice: "morgan" }],
]) {
  test(`a request with ${label} is refused and nothing is spoken`, async () => {
    const { speak, asked } = await setup();
    await assert.rejects(speak(params), { code: "INVALID_REQUEST" });
    assert.equal(asked.length, 0);
  });
}

test("Talk's day has a ceiling of 20,000 characters unless the channel sets one", async () => {
  assert.equal(TALK_DAILY_CHARACTERS, 20000);
  const { speak, store, asked } = await setup();
  store.chargeTalk("2026-10-15", 19_990);
  await speak({ text: "Ten chars." });
  await assert.rejects(speak({ text: "A" }), { code: "LIMIT", message: /^Talk has reached today's limit of 20,000 characters\. It starts again tomorrow\.$/ });
  assert.equal(asked.length, 1);
});

test("the channel's own ceiling is the one kept", async () => {
  const { speak, asked } = await setup({ config: onTheBox({ talkDailyCharacters: 30 }) });
  await speak({ text: "a".repeat(20) });
  await assert.rejects(speak({ text: "a".repeat(11) }), { code: "LIMIT", message: /limit of 30 characters/ });
  await speak({ text: "a".repeat(10) });
  assert.equal(asked.length, 2);
});

test("every character asked for counts, even when the provider fails, and the count starts again the next day", async () => {
  const { speak, store, clock } = await setup({ succeeds: false });
  await assert.rejects(speak({ text: "Twelve chars" }), /speech/);
  assert.equal(store.talkSpent("2026-10-15"), 12);
  clock.now += 24 * 3_600_000;
  assert.equal(store.talkSpent("2026-10-16"), 0);
});

test("two requests at once cannot both pass the ceiling", async () => {
  const { speak } = await setup({ config: onTheBox({ talkDailyCharacters: 10 }) });
  const results = await Promise.allSettled([speak({ text: "a".repeat(6) }), speak({ text: "b".repeat(6) })]);
  assert.deepEqual(results.map((result) => result.status).sort(), ["fulfilled", "rejected"]);
});
