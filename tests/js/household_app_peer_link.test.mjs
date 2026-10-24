// The family room between the two gateways with no relay: each publishes its half in a share
// folder (share.js), and the other reads it straight from a read-only mount (peer-link.js).
// Every message, face and step here is made up.
//
// Run with `node --test tests/js/household_app_peer_link.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { link, mkdir, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { carried, createPeerLink, waiting } from "../../deploy/openclaw/plugins/household-app/peer-link.js";
import { createShare, sharedMediaIds } from "../../deploy/openclaw/plugins/household-app/share.js";
import { signedText } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const PEER = { person: "gia", assistant: "denise" };
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

async function folder(context, name = "share-") {
  const directory = await mkdtemp(path.join(tmpdir(), name));
  context.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

function message(rev, overrides = {}) {
  return { kind: "message", conversation: "family", author: "gia", id: `m-0000000${rev}`, rev, at: 1_790_000_000_000 + rev, text: `note ${rev}`, media: [], ...overrides };
}

// A share as the other gateway writes it: its outbox, and the attachments it names.
async function writeShare(directory, outbox, media = {}) {
  await mkdir(path.join(directory, "media"), { recursive: true });
  for (const [id, bytes] of Object.entries(media)) await writeFile(path.join(directory, "media", id), bytes);
  await writeFile(path.join(directory, "outbox.json"), JSON.stringify({ persona: "denise", ...outbox }));
}

function reader(directory, cursorDirectory, overrides = {}) {
  const batches = [];
  const kept = new Map();
  const warnings = [];
  const link = createPeerLink({
    folder: directory,
    cursorFile: path.join(cursorDirectory, "peer-cursor.json"),
    peer: PEER,
    owner: "franco",
    putMedia: async (bytes, id) => {
      assert.equal(hash(bytes), id);
      kept.set(id, bytes);
    },
    ingest: async (batch) => batches.push(batch),
    log: { warn: (line) => warnings.push(line) },
    watch: () => ({ close() {}, on() {} }),
    ...overrides,
  });
  return { link, batches, kept, warnings };
}

// MARK: - What may cross

test("only the other side's own person and assistant, in the family room, cross", () => {
  const entries = [
    message(3),
    message(1, { author: "denise" }),
    message(2, { author: "franco" }),
    message(4, { conversation: "direct" }),
    message(5, { kind: "approval" }),
    message(6, { rev: "6" }),
    { kind: "avatar", conversation: "family", author: "family", rev: 7, media: [] },
    { kind: "profile", conversation: "family", author: "family", rev: 8 },
  ];
  assert.deepEqual(carried({ entries }, PEER).map((entry) => entry.rev), [1, 3, 7]);
  assert.deepEqual(carried({ entries: "nope" }, PEER), []);
});

test("sign-ins cross for the other side's person, approvals for this side's", () => {
  const outbox = {
    signIns: [{ person: "gia", nonce: "a" }, { person: "franco", nonce: "b" }],
    approvals: [{ person: "franco", id: "c" }, { person: "gia", id: "d" }],
  };
  assert.deepEqual(waiting(outbox, PEER, "franco"), { signIns: [{ person: "gia", nonce: "a" }], approvals: [{ person: "franco", id: "c" }] });
});

// MARK: - Reading the other side's share

test("a new outbox is read once, with its attachments checked against their names, and the cursor kept", async (context) => {
  const share = await folder(context);
  const state = await folder(context, "state-");
  const photo = Buffer.from("a made-up photo");
  const forged = Buffer.from("not what the name says");
  const forgedId = "f".repeat(64);
  await writeShare(share, {
    entries: [
      message(1, { media: [{ id: hash(photo), kind: "photo" }] }),
      message(2, { media: [{ id: forgedId, kind: "photo" }] }),
      message(3, { conversation: "direct", text: "PRIVATE" }),
    ],
    typing: { gia: { conversation: "family", until: 1 } },
    identity: { assistant: { id: "denise", name: "Denise" } },
    cart: [{ author: "denise", id: "c1" }, { author: "corey", id: "c2" }],
  }, { [hash(photo)]: photo, [forgedId]: forged });
  const { link, batches, kept } = reader(share, state);

  await link.poke();
  await link.poke();

  assert.equal(batches.length, 1, "an unchanged share is not read again");
  const [batch] = batches;
  assert.deepEqual(batch.entries.map((entry) => entry.rev), [1, 2]);
  assert.doesNotMatch(JSON.stringify(batch), /PRIVATE/);
  assert.deepEqual([...kept.keys()], [hash(photo)], "the attachment that does not hash to its name is left");
  assert.deepEqual(batch.cart, [{ author: "denise", id: "c1" }]);
  assert.deepEqual(batch.identity, { assistant: { id: "denise", name: "Denise" } });
  assert.equal(JSON.parse(await readFile(path.join(state, "peer-cursor.json"), "utf8")).rev, 2);

  // A restart reads what is new since the cursor, and nothing twice.
  const again = reader(share, state);
  await writeShare(share, { entries: [message(1), message(2), message(4)], typing: { gia: { conversation: "family", until: 1 } }, cart: [{ author: "denise", id: "c1" }] });
  await again.link.poke();
  assert.deepEqual(again.batches.map((each) => each.entries.map((entry) => entry.rev)), [[4]]);
});

test("a change of typing alone is carried, with no entries", async (context) => {
  const share = await folder(context);
  const state = await folder(context, "state-");
  const { link, batches } = reader(share, state);
  await writeShare(share, { entries: [message(1)], typing: {} });
  await link.poke();
  await writeShare(share, { entries: [message(1)], typing: { denise: { conversation: "family", until: 99 } } });
  await link.poke();
  assert.deepEqual(batches.map((batch) => [batch.entries.length, batch.typing]), [[1, {}], [0, { denise: { conversation: "family", until: 99 } }]]);
});

test("a long backlog crosses in batches of a hundred", async (context) => {
  const share = await folder(context);
  const state = await folder(context, "state-");
  const { link, batches } = reader(share, state);
  await writeShare(share, { entries: Array.from({ length: 250 }, (_, index) => message(index + 1)) });
  await link.poke();
  assert.deepEqual(batches.map((batch) => batch.entries.length), [100, 100, 50]);
});

test("an outbox that starts over is read from its start again", async (context) => {
  const share = await folder(context);
  const state = await folder(context, "state-");
  await writeFile(path.join(state, "peer-cursor.json"), JSON.stringify({ rev: 900 }));
  const { link, batches } = reader(share, state);
  await writeShare(share, { entries: [message(1), message(2)] });
  await link.poke();
  assert.deepEqual(batches[0].entries.map((entry) => entry.rev), [1, 2]);
});

test("a share that is not the other assistant's, a link in place of the outbox or one too large is refused", async (context) => {
  const share = await folder(context);
  const state = await folder(context, "state-");
  const { link, batches, warnings } = reader(share, state);
  await writeFile(path.join(share, "outbox.json"), JSON.stringify({ persona: "someone", entries: [message(1)] }));
  await link.poke();
  assert.match(warnings.at(-1), /not the other assistant's/);

  const elsewhere = path.join(state, "private.json");
  await writeFile(elsewhere, JSON.stringify({ persona: "denise", entries: [message(1)] }));
  await rm(path.join(share, "outbox.json"));
  await symlink(elsewhere, path.join(share, "outbox.json"));
  await link.poke();
  assert.match(warnings.at(-1), /cannot be read/);
  assert.equal(batches.length, 0);

  const bounded = reader(share, state, {});
  await rm(path.join(share, "outbox.json"));
  await mkdir(path.join(share, "outbox.json"));
  await bounded.link.poke();
  assert.match(bounded.warnings.at(-1), /not a regular file/);
});

test("an ingest that fails leaves the cursor where it was, so the same batch comes again", async (context) => {
  const share = await folder(context);
  const state = await folder(context, "state-");
  let fails = true;
  const batches = [];
  const { link } = reader(share, state, {
    ingest: async (batch) => {
      if (fails) throw new Error("store busy");
      batches.push(batch);
    },
  });
  await writeShare(share, { entries: [message(1)] });
  await link.poke();
  fails = false;
  await link.poke();
  assert.deepEqual(batches.map((batch) => batch.entries.map((entry) => entry.rev)), [[1]]);
});

test("a change is read as the folder's watch reports it", async (context) => {
  const share = await folder(context);
  const state = await folder(context, "state-");
  const { link, batches } = reader(share, state, { watch: undefined });
  const stop = new AbortController();
  context.after(() => stop.abort());
  await link.start(stop.signal);
  await writeShare(share, { entries: [message(1)] });
  await until("the change read through the watch", () => batches.length === 1, { attempts: 200 });
});

// MARK: - Publishing this side's

test("the share holds the outbox and only the attachments it names, linked rather than copied", async (context) => {
  const directory = await folder(context, "app-");
  const media = path.join(directory, "media");
  await mkdir(media);
  const family = Buffer.from("family photo");
  const own = Buffer.from("the owner's own photo");
  await writeFile(path.join(media, hash(family)), family);
  await writeFile(path.join(media, hash(own)), own);
  const share = createShare({ directory, mediaPath: (id) => path.join(media, id) });
  const entries = [{ kind: "message", conversation: "family", media: [{ id: hash(family) }, { id: "not-a-hash" }] }];

  await share.write(JSON.stringify({ entries }), entries);

  assert.deepEqual(await readdir(path.join(share.folder, "media")), [hash(family)]);
  const [linked, original] = await Promise.all([stat(path.join(share.folder, "media", hash(family))), stat(path.join(media, hash(family)))]);
  assert.equal(linked.ino, original.ino);
  assert.deepEqual(JSON.parse(await readFile(path.join(share.folder, "outbox.json"), "utf8")), { entries });

  // An attachment the outbox no longer names leaves the share, and stays in the store.
  await share.write(JSON.stringify({ entries: [] }), []);
  assert.deepEqual(await readdir(path.join(share.folder, "media")), []);
  assert.equal((await stat(path.join(media, hash(family)))).size, family.length);
  assert.deepEqual([...sharedMediaIds(entries)], [hash(family)]);
});

test("an attachment already in the share is left as it is", async (context) => {
  const directory = await folder(context, "app-");
  const media = path.join(directory, "media");
  await mkdir(path.join(directory, "share", "media"), { recursive: true });
  await mkdir(media);
  const bytes = Buffer.from("photo");
  await writeFile(path.join(media, hash(bytes)), bytes);
  await link(path.join(media, hash(bytes)), path.join(directory, "share", "media", hash(bytes)));
  const share = createShare({ directory, mediaPath: (id) => path.join(media, id) });
  const entries = [{ media: [{ id: hash(bytes) }] }];
  await share.write("{}", entries);
  assert.deepEqual(await readdir(path.join(directory, "share", "media")), [hash(bytes)]);
});

// MARK: - Both gateways

const keyPair = () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { privateKey, raw: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url") };
};
const FRANCO = keyPair();
const signedBy = (person, entry) => ({
  ...entry,
  signature: sign(null, Buffer.from(signedText(entry), "utf8"), person.privateKey).toString("base64url"),
});

test("Franco's family message on Corey's gateway is in Denise's family room once she reads Corey's share", async (context) => {
  const coreyState = await folder(context, "corey-");
  const deniseState = await folder(context, "denise-");
  await mkdir(path.join(coreyState, "household-app"), { recursive: true });
  await mkdir(path.join(deniseState, "household-app"), { recursive: true });
  const coreyShare = path.join(coreyState, "household-app", "share");
  const deniseShare = path.join(deniseState, "household-app", "share");

  const corey = await runningChannel({
    agents: { entries: { main: { identity: { name: "Corey" } } } },
    channels: { household: {
      owner: { id: "franco", name: "Franco", deviceKeys: [FRANCO.raw] },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
      peerShare: deniseShare,
    } },
  }, { stateDir: coreyState });
  try {
    const sent = await corey.send(signedBy(FRANCO, {
      conversation: "family", id: "m-00000101", at: Date.now(), replyTo: null, text: "Dinner at six?", media: [],
    }));
    assert.equal(sent.ok, true, JSON.stringify(sent));
    await until("Corey's share", async () =>
      (JSON.parse(await readFile(path.join(coreyShare, "outbox.json"), "utf8").catch(() => "{}")).entries ?? [])
        .some((entry) => entry.id === "m-00000101"));
  } finally {
    await corey.stop();
  }

  const denise = await runningChannel({
    agents: { entries: { main: { identity: { name: "Denise" } } } },
    channels: { household: {
      owner: { id: "gia", name: "Gia" },
      assistant: { id: "denise", name: "Denise" },
      peer: { person: { id: "franco", name: "Franco" }, assistant: { id: "corey", name: "Corey" } },
      peerShare: coreyShare,
    } },
  }, { stateDir: deniseState });
  try {
    await until("Franco's message in Denise's room", async () =>
      ((await denise.call("household-app.sync", { since: 0 })).payload?.entries ?? [])
        .some((entry) => entry.kind === "message" && entry.author === "franco" && entry.text === "Dinner at six?"));
  } finally {
    await denise.stop();
  }
});
