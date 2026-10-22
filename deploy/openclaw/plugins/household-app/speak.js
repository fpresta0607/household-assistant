// A few words spoken by this gateway for its phone: a voice's sample in Settings, and
// each sentence Talk says. They go through OpenClaw's own speech, on the speech provider
// the gateway is configured with, so the voices never need a key on the phone. The audio
// is kept in the media store, and the phone reads it like any other attachment.
//
// Talk has its own ceiling, a number of characters a day, beside the one for voice notes
// in Telegram. Every character asked for counts before the provider is called, so a call
// that fails after it was billed is still under the ceiling.
//
// Speech is made for the household channel's account, as household-speech makes the
// voice replies the app already plays as voice notes, so the same channel's speech
// settings and audio format apply to both.

import { readFile as readFileFromDisk } from "node:fs/promises";
import path from "node:path";

import { RoomError } from "./room.js";
import { dayOf } from "./settings-store.js";
import { VOICES } from "./settings.js";

export const MAX_SPOKEN = 400;
export const TALK_DAILY_CHARACTERS = 20000;
const AGENT = "main";
const CHANNEL = "household";
const ACCOUNT = "default";
const SPEECH_TIMEOUT_MS = 30_000;
const MIMES = { ".mp3": "audio/mpeg", ".opus": "audio/ogg", ".ogg": "audio/ogg", ".wav": "audio/wav", ".m4a": "audio/mp4" };

const refuse = (message) => {
  throw new RoomError("INVALID_REQUEST", message);
};

// The config with one voice in place of the configured one, for this call only.
function withVoice(cfg, voice) {
  if (!voice) return cfg;
  const openrouter = { ...cfg?.tts?.providers?.openrouter, speakerVoice: voice };
  return { ...cfg, tts: { ...cfg?.tts, providers: { ...cfg?.tts?.providers, openrouter } } };
}

// `tts` is OpenClaw's `textToSpeech`, and `config` answers with the gateway's current config.
export function createSpeak({ store, media, tts, config, readFile = readFileFromDisk, now = Date.now }) {
  return async function speak(params) {
    const { text: raw, voice } = params ?? {};
    const text = typeof raw === "string" ? raw.trim() : "";
    if (!text) refuse("there are no words to speak");
    if (text.length > MAX_SPOKEN) refuse(`at most ${MAX_SPOKEN} characters are spoken at once`);
    if (voice != null && !VOICES.some((known) => known.id === voice)) refuse("not one of the voices");
    const cfg = config();
    const ceiling = cfg?.channels?.household?.talkDailyCharacters ?? TALK_DAILY_CHARACTERS;
    const day = dayOf(now());
    if (store.talkSpent(day) + text.length > ceiling) {
      throw new RoomError("LIMIT", `Talk has reached today's limit of ${ceiling.toLocaleString("en-US")} characters. It starts again tomorrow.`);
    }
    store.chargeTalk(day, text.length);
    const result = await tts({
      text,
      cfg: withVoice(cfg, voice),
      channel: CHANNEL,
      accountId: ACCOUNT,
      agentId: AGENT,
      timeoutMs: SPEECH_TIMEOUT_MS,
    });
    if (!result?.success || !result.audioPath) throw new Error(`speech was not made: ${result?.error ?? "no audio"}`);
    const kept = await media.putBytes(await readFile(result.audioPath));
    const mime = MIMES[path.extname(result.audioPath).toLowerCase()] ?? "application/octet-stream";
    return { media: { id: kept.id, mime, bytes: kept.bytes } };
  };
}
