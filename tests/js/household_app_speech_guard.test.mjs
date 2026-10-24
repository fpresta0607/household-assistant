// Speech in Steward is Speak and Talk, never a voice note a chat tool makes: the guard in
// deploy/openclaw/plugins/household-app/speech-guard.js, as the household-app plugin runs it.
// It replaced the household-speech plugin when Telegram was retired.
//
// Run with `node --test tests/js/household_app_speech_guard.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  HOW_TO_HEAR, REPLY_IN_TEXT, SPEECH_TOOLS, claimTtsCommand, refuseSpeechTool,
} from "../../deploy/openclaw/plugins/household-app/speech-guard.js";
import { runningChannel } from "./fixtures/household-app-channel.mjs";

const COREY = {
  agents: { entries: { main: { identity: { name: "Corey" } } } },
  channels: {
    household: {
      owner: { id: "franco", name: "Franco" },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};
const OWN_THREAD = { agentId: "main", sessionKey: "agent:main:household:direct:franco", messageChannel: "household" };

test("the built-in tts and the old speak are refused with how to hear a message", () => {
  assert.deepEqual(SPEECH_TOOLS, ["tts", "speak"]);
  for (const toolName of SPEECH_TOOLS) {
    assert.deepEqual(refuseSpeechTool({ toolName }), { block: true, blockReason: HOW_TO_HEAR });
  }
  assert.equal(refuseSpeechTool({ toolName: "message" }), undefined);
  assert.match(HOW_TO_HEAR, /long-press it and choose Speak/);
});

test("every /tts is claimed before the built-in can answer it, and nothing else is", () => {
  for (const content of ["/tts", "/tts on", " /TTS latest", "/tts audio Read this", "/tts:status", "/tts@corey_bot on"]) {
    assert.deepEqual(claimTtsCommand({ content }), { handled: true, text: HOW_TO_HEAR }, content);
  }
  for (const content of ["/ttsx", "please /tts on", "tts on", "", undefined]) {
    assert.equal(claimTtsCommand({ content }), undefined, String(content));
  }
});

test("the household app runs the guard: the tools, /tts and the turn's instructions", async () => {
  const channel = await runningChannel(COREY);
  try {
    for (const toolName of SPEECH_TOOLS) {
      assert.equal((await channel.beforeToolCall({ toolName, params: { text: "Hi" } }, OWN_THREAD))?.block, true, toolName);
    }
    assert.deepEqual(await channel.beforeDispatch({ content: "/tts on" }, OWN_THREAD), { handled: true, text: HOW_TO_HEAR });
    assert.equal(await channel.beforeDispatch({ content: "What's on today?" }, OWN_THREAD), undefined);
    const built = await channel.promptBuild({ prompt: "Send me a voice note of that" }, OWN_THREAD);
    assert.ok(built.appendSystemContext.includes(REPLY_IN_TEXT));
  } finally {
    await channel.stop();
  }
});
