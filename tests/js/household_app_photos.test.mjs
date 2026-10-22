// Image requests use the selected Vision reader before the text-only turn.

import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { test } from "node:test";

import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const keyPair = () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { privateKey, raw: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url") };
};
const FRANCO = keyPair();
const GIA = keyPair();
const signedBy = (person, message) => ({
  ...message,
  signature: sign(null, Buffer.from(signedText(message), "utf8"), person.privateKey).toString("base64url"),
});

const COREY = {
  agents: { defaults: { imageModel: { primary: "openrouter/acme/selected-vision" } }, entries: { main: { identity: { name: "Corey" } } } },
  channels: {
    household: {
      owner: { id: "franco", name: "Franco", deviceKeys: [FRANCO.raw] },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia", deviceKeys: [GIA.raw] }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};

// An attachment's bytes, kept where the plugin keeps media, as the phone describes it.
async function kept(channel, kind, mime, label) {
  const bytes = Buffer.from(`${kind}: ${label}`);
  const id = createHash("sha256").update(bytes).digest("hex");
  const folder = path.join(channel.stateDir, "household-app", "media");
  await mkdir(folder, { recursive: true });
  await writeFile(path.join(folder, id), bytes);
  return { id, kind, mime, bytes: bytes.length, ...(kind === "photo" ? { width: 1170, height: 2532 } : {}) };
}

for (const conversation of ["direct", "family"]) {
  test(`a screenshot in ${conversation} is read by selected Vision and never by the chat model`, async () => {
    const channel = await runningChannel(COREY);
    const oldKey = process.env.OPENROUTER_API_KEY;
    process.env.OPENROUTER_API_KEY = "fixture-key";
    const requests = [];
    globalThis.fetch = async (url, init) => {
      requests.push(JSON.parse(init.body));
      return { ok: true, json: async () => ({ choices: [{ message: { content: "A chart labeled sales shows 42." }, finish_reason: "stop" }] }) };
    };
    try {
      const screenshot = await kept(channel, "photo", "image/png", "a text from Mike");
      const message = { conversation, id: "p-00000001", at: Date.now(), replyTo: null, text: "@Corey Help me read this chart", media: [screenshot] };
      await channel.send(signedBy(FRANCO, message));
      await until("the turn", () => channel.contexts.length === 1);
      assert.equal(requests.length, 1);
      assert.equal(requests[0].model, "acme/selected-vision");
      assert.match(requests[0].messages[1].content[2].image_url.url, /^data:image\/png;base64,/);
      assert.equal(channel.contexts[0].media.length, 0, "chat model cannot bypass the selected Vision reader");
      assert.match(channel.contexts[0].message.bodyForAgent, /sales shows 42/);
    } finally {
      if (oldKey === undefined) delete process.env.OPENROUTER_API_KEY;
      else process.env.OPENROUTER_API_KEY = oldKey;
      await channel.stop();
    }
  });
}

test("a file in the owner's own thread names no root of its own, as before", async () => {
  // Arrange
  const channel = await runningChannel(COREY);
  try {
    const file = { ...(await kept(channel, "file", "application/pdf", "a field trip form")), name: "Field trip.pdf" };
    const message = { conversation: "direct", id: "f-00000001", at: Date.now(), replyTo: null, text: "Can you read this?", media: [file] };

    // Act
    await channel.send(signedBy(FRANCO, message));
    await until("the turn", () => channel.contexts.length === 1);

    // Assert
    const [fact] = channel.contexts[0].media;
    assert.equal(fact.kind, "document");
    assert.equal(fact.workspaceDir, undefined);
  } finally {
    await channel.stop();
  }
});
