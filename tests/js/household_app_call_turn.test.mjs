// A turn said on a voice call with the assistant. The phone marks each message said on a
// call beside the fields it signs, and that turn alone asks the model for an answer made to
// be heard, with one short line said before anything slow. Driven through the plugin's own
// entry, from the gateway method the phone calls to the context OpenClaw is handed.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { test } from "node:test";

import { CALL_TURN_INSTRUCTION } from "../../deploy/openclaw/plugins/household-app/call-log.js";
import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const PHONE_KEY = publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url");
const signed = (message) => ({
  ...message,
  signature: sign(null, Buffer.from(signedText(message), "utf8"), privateKey).toString("base64url"),
});

const CFG = {
  channels: {
    household: {
      owner: { id: "franco", name: "Franco", deviceKeys: [PHONE_KEY] },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};

test("a turn said on a call asks for a spoken answer, and a typed turn asks nothing more", async () => {
  // Arrange
  const channel = await runningChannel(CFG);
  const spoken = { conversation: "direct", id: "d-00000101", at: Date.now(), replyTo: null, media: [], text: "Is it cold in the house?" };
  const typed = { conversation: "direct", id: "d-00000102", at: Date.now(), replyTo: null, media: [], text: "And tomorrow?" };

  try {
    // Act
    const spokenAnswer = await channel.send({ ...signed(spoken), call: true });
    await until("the call turn's context", () => channel.contexts.length === 1);
    const typedAnswer = await channel.send(signed(typed));
    await until("the typed turn's context", () => channel.contexts.length === 2);

    // Assert
    assert.equal(spokenAnswer.ok, true);
    assert.equal(typedAnswer.ok, true);
    const [call, chat] = channel.contexts;
    assert.equal(call.messageId, "d-00000101");
    assert.deepEqual(call.supplemental, { groupSystemPrompt: CALL_TURN_INSTRUCTION });
    assert.equal(call.message.bodyForAgent, "Is it cold in the house?", "the person's own words stay as they were said");
    assert.equal(chat.messageId, "d-00000102");
    assert.equal(chat.supplemental, undefined);
  } finally {
    await channel.stop();
  }
});

test("the call instruction asks for a short spoken answer and a line before anything slow", () => {
  assert.match(CALL_TURN_INSTRUCTION, /voice call/);
  assert.match(CALL_TURN_INSTRUCTION, /short/);
  assert.match(CALL_TURN_INSTRUCTION, /short first sentence/);
  assert.match(CALL_TURN_INSTRUCTION, /one or two sentences/);
  assert.match(CALL_TURN_INSTRUCTION, /contractions, everyday words/);
  assert.match(CALL_TURN_INSTRUCTION, /Never claim you checked or completed something before its result is back/);
  assert.match(CALL_TURN_INSTRUCTION, /no lists, tables, cards, links, code or emoji/);
  assert.match(CALL_TURN_INSTRUCTION, /Before you use any tool, or start anything that takes more than a moment, first say one brief natural line/);
  const emDash = String.fromCodePoint(0x2014);
  assert.ok(!CALL_TURN_INSTRUCTION.includes(";") && !CALL_TURN_INSTRUCTION.includes(emDash), "no semicolon or em dash in words the owner may read");
});
