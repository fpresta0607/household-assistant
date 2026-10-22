// What the phones see of a turn while the assistant takes it up: the assistant's read
// marker on the person's message, which the phone shows as Read. Driven through the
// plugin's own entry, from the gateway method the phone calls.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { test } from "node:test";

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

const readsBy = async (channel, author) =>
  (await channel.call("household-app.sync", { since: 0 })).payload.entries.filter((entry) => entry.kind === "read" && entry.author === author);

test("the assistant marks the owner's message read as it takes it up", async () => {
  // Arrange
  const channel = await runningChannel(CFG);
  const asked = { conversation: "direct", id: "d-00000201", at: Date.now(), replyTo: null, media: [], text: "Is it cold in the house?" };

  try {
    // Act
    const answer = await channel.send(signed(asked));
    await until("the turn's context", () => channel.contexts.length === 1);

    // Assert
    assert.equal(answer.ok, true);
    const reads = await readsBy(channel, "corey");
    assert.deepEqual(reads.map((entry) => [entry.conversation, entry.messageId]), [["direct", "d-00000201"]]);
  } finally {
    await channel.stop();
  }
});

test("the owner's phone can say the owner is typing, and a bad typing is refused", async () => {
  // Arrange
  const channel = await runningChannel(CFG);

  try {
    // Act
    const typing = await channel.call("household-app.typing", { conversation: "family", active: true });
    const refused = await channel.call("household-app.typing", { conversation: "family", active: "yes" });

    // Assert
    assert.equal(typing.ok, true);
    assert.equal(refused.ok, false);
    assert.match(refused.error?.message ?? "", /active/);
  } finally {
    await channel.stop();
  }
});
