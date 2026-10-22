// Who is on it, across a restart: a question the other person asks both assistants is left to
// theirs, and this assistant takes it over only when the bound passes with no sign of that
// one's answer. The bound is kept in the household note's file, so a gateway that restarts
// inside it still takes the question over, once. Driven through the plugin's own entry, with
// the real 20 second bound.
//
// Run with `node --test tests/js/household_app_claims.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { test } from "node:test";

import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const GIA_KEY = publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url");
const signedByGia = (message) => ({
  ...message,
  signature: sign(null, Buffer.from(signedText(message), "utf8"), privateKey).toString("base64url"),
});

const CFG = {
  agents: { entries: { main: { identity: { name: "Corey" } } } },
  channels: {
    household: {
      owner: { id: "franco", name: "Franco" },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia", deviceKeys: [GIA_KEY] }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};
// OpenClaw's own rule for a typed name, as in household_app_family_parity.test.mjs.
const MENTION_RULE = {
  buildMentionRegexes: `(cfg) => [new RegExp("(?<![\\\\p{L}\\\\p{N}])" + cfg.agents.entries.main.identity.name + "(?![\\\\p{L}\\\\p{N}])", "iu")]`,
  matchesMentionWithExplicit: `({ text, mentionRegexes, transcript }) => { const check = (text ?? "").toLowerCase() || (transcript ?? "").toLowerCase(); return mentionRegexes.some((re) => re.test(check)); }`,
  implicitMentionKindWhen: `(kind, when) => (when ? [kind] : [])`,
  resolveInboundMentionDecision: `({ facts }) => ({ shouldSkip: !facts.wasMentioned && facts.implicitMentionKinds.length === 0 })`,
};
const BOUND_MS = 20_000;

const stepsOut = async (channel) =>
  JSON.parse(await readFile(path.join(channel.stateDir, "household-app", "outbox.json"), "utf8").catch(() => "{}")).notes ?? [];

test("a gateway that restarts inside the bound of a question it stood down from still takes it over, once", { timeout: 60_000 }, async () => {
  // Arrange: Gia asks both assistants, over the relay, and Corey stands down.
  const first = await runningChannel(CFG, { sdk: MENTION_RULE });
  const asked = { conversation: "family", id: "m-00000020", at: Date.now(), replyTo: null, media: [], text: "Corey and Denise, is church at ten?" };
  const inbox = path.join(first.stateDir, "household-app", "inbox");
  try {
    await mkdir(inbox, { recursive: true });
    await writeFile(path.join(inbox, ".batch.tmp"), JSON.stringify({ from: "denise", batch: { entries: [{ kind: "message", author: "gia", ...signedByGia(asked) }] } }));
    await rename(path.join(inbox, ".batch.tmp"), path.join(inbox, `${Date.now()}-${asked.id}.json`));
    await until("Gia's question kept", async () =>
      (await first.call("household-app.sync", { since: 0 })).payload.entries.some((entry) => entry.id === asked.id));
    assert.equal(first.dispatches.length, 0, "Corey stands down");
  } finally {
    // Act: the gateway restarts inside the bound.
    await first.stop();
  }
  const second = await runningChannel(CFG, { sdk: MENTION_RULE, stateDir: first.stateDir });

  try {
    // Assert: nothing before the bound, then one takeover.
    assert.equal(second.dispatches.length, 0);
    await until("the takeover", async () => second.dispatches.length > 0, { attempts: (BOUND_MS + 10_000) / 5 });
    await new Promise((resolve) => setTimeout(resolve, 500));
    assert.equal(second.dispatches.length, 1, "taken over once");
    assert.deepEqual((await stepsOut(second)).map((step) => [step.kind, step.message]), [["took", asked.id]]);
  } finally {
    await second.stop();
  }
});
