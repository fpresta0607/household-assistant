// A question the owner asks their own assistant in the family room works exactly as it
// does in their own thread: the same tools, the plugin's included, the same sender and
// command rights, and an answer in the conversation it was asked in. Anyone else's
// question in the family room gets The Fam's list and none of the owner's own tools.
// Driven through the plugin's own entry, with each turn's tools offered the way OpenClaw
// 2026.9.4 offers them: from the turn's own sender, session and route.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdir, rename, writeFile } from "node:fs/promises";
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

const THE_FAMS_TOOLS = ["web_search", "web_fetch", "speak", "family_history", "household_cart", "household_home"];
const CFG = {
  agents: { entries: { main: { identity: { name: "Corey" } } } },
  channels: {
    household: {
      owner: { id: "franco", name: "Franco", deviceKeys: [FRANCO.raw] },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia", deviceKeys: [GIA.raw] }, assistant: { id: "denise", name: "Denise" } },
      familyTools: THE_FAMS_TOOLS,
    },
  },
};
// OpenClaw's own rule for a typed name, as in household_app_voice_notes.test.mjs.
const MENTION_RULE = {
  buildMentionRegexes: `(cfg) => [new RegExp("(?<![\\\\p{L}\\\\p{N}])" + cfg.agents.entries.main.identity.name + "(?![\\\\p{L}\\\\p{N}])", "iu")]`,
  matchesMentionWithExplicit: `({ text, mentionRegexes, transcript }) => { const check = (text ?? "").toLowerCase() || (transcript ?? "").toLowerCase(); return mentionRegexes.some((re) => re.test(check)); }`,
  implicitMentionKindWhen: `(kind, when) => (when ? [kind] : [])`,
  resolveInboundMentionDecision: `({ facts }) => ({ shouldSkip: !facts.wasMentioned && facts.implicitMentionKinds.length === 0 })`,
};

let sequence = 0;
const said = (conversation, text) => ({ conversation, id: `p-${String(++sequence).padStart(8, "0")}`, at: Date.now(), replyTo: null, text, media: [] });

// What OpenClaw hands a tool factory and the group adapter for the turn `ctx` started.
const toolContextOf = (ctx) => ({
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  requesterSenderId: ctx.sender.id,
  sessionKey: ctx.route.dispatchSessionKey,
  nativeChannelId: ctx.conversation.id,
  deliveryContext: { channel: "household", accountId: "default", to: ctx.reply.to },
});
// The group policy OpenClaw 2026.9.4 resolves for the turn (resolveGroupToolPolicy): it asks
// the adapter only for a session whose key names a group, about each group the key names,
// the per-sender one first (buildScopedGroupIdCandidates), and takes the first policy.
const groupPolicyOf = (channel, ctx) => {
  const group = /^agent:main:household:group:(.+)$/.exec(ctx.route.dispatchSessionKey)?.[1];
  const candidates = !group ? [] : group.includes(":sender:") ? [group, group.split(":sender:")[0]] : [group];
  for (const groupId of candidates) {
    const policy = channel.plugin.groups.resolveToolPolicy({ cfg: CFG, groupId, accountId: "default", senderId: ctx.sender.id, senderPolicyMode: "always" });
    if (policy) return policy;
  }
  return undefined;
};
// Whether a policy leaves every tool the turn's other layers allow.
const restrictsNothing = (policy) => policy === undefined || (policy.allow === undefined && policy.deny?.length === 0);
const pluginToolsOf = (channel, ctx) =>
  channel.tools.map(({ factory }) => factory(toolContextOf(ctx))).filter(Boolean).map((tool) => tool.name).sort();

// The owner says it from their phone; the other person's words arrive over the relay, as
// relay-in.mjs leaves them in the plugin's inbox.
async function turnFor(channel, person, message) {
  const before = channel.contexts.length;
  if (person === FRANCO) {
    await channel.send(signedBy(FRANCO, message));
  } else {
    const inbox = path.join(channel.stateDir, "household-app", "inbox");
    await mkdir(inbox, { recursive: true });
    await writeFile(path.join(inbox, ".batch.tmp"), JSON.stringify({ from: "denise", batch: { entries: [{ kind: "message", author: "gia", ...signedBy(GIA, message) }] } }));
    await rename(path.join(inbox, ".batch.tmp"), path.join(inbox, `${Date.now()}-${message.id}.json`));
  }
  await until("the turn", () => channel.contexts.length === before + 1);
  return channel.contexts.at(-1);
}

test("the owner's question in the family room gets the same tools and answer shape as in their own thread", async () => {
  // Arrange
  const channel = await runningChannel(CFG, { sdk: MENTION_RULE });
  try {
    const inThread = await turnFor(channel, FRANCO, said("direct", "What's on my calendar tomorrow?"));
    const inRoom = await turnFor(channel, FRANCO, said("family", "Corey, what's on my calendar tomorrow?"));

    // Act
    const tools = [inThread, inRoom].map((ctx) => ({ group: groupPolicyOf(channel, ctx), plugin: pluginToolsOf(channel, ctx) }));

    // Assert
    assert.equal(inRoom.route.dispatchSessionKey, "agent:main:household:group:family:sender:franco", "the owner's own session of the room");
    assert.equal(restrictsNothing(tools[0].group) && restrictsNothing(tools[1].group), true, "every tool the thread has, none held back by The Fam's list");
    // The document vault alone keeps to the thread: a photo in the room has reached the other side.
    assert.deepEqual(tools[1].plugin, tools[0].plugin.filter((name) => name !== "household_vault"));
    assert.ok(tools[0].plugin.includes("household_vault"));
    assert.ok(tools[1].plugin.includes("household_today") && tools[1].plugin.includes("household_brief"));
    const shape = (ctx) => ({ sender: ctx.sender, access: { commands: ctx.access.commands }, extra: ctx.extra });
    assert.deepEqual(shape(inRoom), shape(inThread));
    assert.deepEqual([inThread.reply.to, inRoom.reply.to], ["household:franco", "household:family"], "each answered where it was asked");
    assert.match(inRoom.supplemental.groupSystemPrompt, /Franco, your own person, wrote this in the family room, which Gia and Denise read too/);
    assert.match(inRoom.supplemental.groupSystemPrompt, /only as far as their question asks/);
  } finally {
    await channel.stop();
  }
});

test("the other person's same question in the family room gets The Fam's list and none of the owner's own tools", async () => {
  // Arrange
  const channel = await runningChannel(CFG, { sdk: MENTION_RULE });
  try {
    const byOwner = await turnFor(channel, FRANCO, said("family", "Corey, what's on my calendar tomorrow?"));
    const byGia = await turnFor(channel, GIA, said("family", "Corey, what's on my calendar tomorrow?"));

    // Act
    const policy = groupPolicyOf(channel, byGia);
    const giasTools = pluginToolsOf(channel, byGia);

    // Assert
    assert.equal(byGia.route.dispatchSessionKey, "agent:main:household:group:family", "the room's shared session, never the owner's");
    assert.notEqual(byOwner.route.dispatchSessionKey, byGia.route.dispatchSessionKey, "what the owner's tools return is never in Gia's turn");
    assert.deepEqual(policy, { allow: THE_FAMS_TOOLS });
    assert.equal(giasTools.includes("household_today") || giasTools.includes("household_brief"), false);
    assert.ok(pluginToolsOf(channel, byOwner).length > giasTools.length);
    assert.equal(byGia.sender.id, "gia");
    assert.deepEqual(byGia.extra, { CommandInterpretationSuppressed: true });
    assert.match(byGia.supplemental.groupSystemPrompt, /Gia wrote this in the family room\. Answer them for the family; Franco's private things/);
  } finally {
    await channel.stop();
  }
});
