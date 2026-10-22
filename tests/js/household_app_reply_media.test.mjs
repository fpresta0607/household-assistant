// A reply that carries a file, from deploy/openclaw/plugins/household-app/index.js: OpenClaw
// hands it over as soon as the assistant writes it, as a block even with block streaming off,
// or as a tool's result, and leaves it out of the final. On 22 October such a reply, a chart,
// reached the channel as a block, which it dropped, and the owner got nothing at all. Every
// reply and file here is made up.
//
// Run with `node --test tests/js/household_app_reply_media.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { test } from "node:test";

import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const keyPair = () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { privateKey, raw: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url") };
};
const FRANCO = keyPair();
const signedBy = (person, message) => ({
  ...message,
  signature: sign(null, Buffer.from(signedText(message), "utf8"), person.privateKey).toString("base64url"),
});
const COREY = {
  agents: { entries: { main: { identity: { name: "Corey" } } } },
  channels: {
    household: {
      owner: { id: "franco", name: "Franco", deviceKeys: [FRANCO.raw] },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};
// A 1x1 PNG and a few bytes of a PDF, as OpenClaw's media loader would hand them over.
const PNG = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082";
const SDK = {
  loadOutboundMediaFromUrl: `async (url) => url.endsWith(".pdf")
    ? { buffer: Buffer.from("%PDF-1.4 made up"), contentType: "application/pdf", fileName: url.split("/").pop() }
    : { buffer: Buffer.from("${PNG}", "hex"), contentType: "image/png", fileName: url.split("/").pop() }`,
};

// The assistant's messages in Franco's thread after his one message, with OpenClaw's run
// standing in as `run`: it hands the channel's deliver what OpenClaw would.
async function threadAfter(run) {
  let isRunDone = false;
  const channel = await runningChannel(COREY, {
    sdk: SDK,
    dispatch: async (params) => {
      await run(params.delivery.deliver);
      isRunDone = true;
      return { admission: { kind: "dispatch" } };
    },
  });
  try {
    const message = { conversation: "direct", id: "r-00000001", at: Date.now(), replyTo: null, text: "Can you make me a chart?", media: [] };
    await channel.send(signedBy(FRANCO, message));
    await until("the run's replies", () => isRunDone, { attempts: 2000 });
    const thread = (await channel.call("household-app.history", { conversation: "direct" })).payload.messages;
    return thread.filter((each) => each.author === "corey");
  } finally {
    await channel.stop();
  }
}

test("a reply with a chart handed over as a block, and its final left empty, reaches the thread whole", async () => {
  // Arrange and Act: the 22 October shape, the block and no final.
  const replies = await threadAfter(async (deliver) => {
    await deliver({ text: "Here is the made-up chart.", mediaUrl: "/state/media/tool-image-generation/chart.png", mediaUrls: ["/state/media/tool-image-generation/chart.png"] }, { kind: "block" });
  });

  // Assert
  assert.equal(replies.length, 1);
  assert.equal(replies[0].text, "Here is the made-up chart.");
  assert.deepEqual(replies[0].media.map((item) => [item.kind, item.mime]), [["photo", "image/png"]]);
});

test("a PDF a tool made reaches the thread as a file, and a tool's words alone do not", async () => {
  const replies = await threadAfter(async (deliver) => {
    await deliver({ text: "Ran the script." }, { kind: "tool" });
    await deliver({ mediaUrl: "/state/workspace/made-up-schedule.pdf" }, { kind: "tool" });
    await deliver({ text: "The schedule is above." }, { kind: "final" });
  });
  assert.deepEqual(replies.map((each) => [each.text, each.media.map((item) => `${item.kind}:${item.name ?? ""}`)]), [
    ["", ["file:made-up-schedule.pdf"]],
    ["The schedule is above.", []],
  ]);
});

test("a file a block posted is not posted again with the final", async () => {
  const chart = "/state/media/tool-image-generation/chart.png";
  const replies = await threadAfter(async (deliver) => {
    await deliver({ text: "The made-up chart.", mediaUrl: chart }, { kind: "block" });
    await deliver({ text: "Anything else?", mediaUrls: [chart] }, { kind: "final" });
  });
  assert.deepEqual(replies.map((each) => [each.text, each.media.length]), [["The made-up chart.", 1], ["Anything else?", 0]]);
});

test("reasoning and status blocks still never reach the thread", async () => {
  const replies = await threadAfter(async (deliver) => {
    await deliver({ text: "thinking about charts", isReasoning: true }, { kind: "block" });
    await deliver({ text: "Working on it", isStatusNotice: true }, { kind: "block" });
    await deliver({ text: "Done." }, { kind: "final" });
  });
  assert.deepEqual(replies.map((each) => each.text), ["Done."]);
});
