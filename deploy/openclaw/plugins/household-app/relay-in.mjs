// The receiving end of the family room's relay. The host relay runs this inside the
// receiving gateway's container, as the gateway's own user, with the other gateway's
// new family-room entries and their attachments on standard input:
//
//   docker exec -i -u node openclaw-denise node /opt/household-plugins/household-app/relay-in.mjs
//
// It writes each attachment under its hash, refusing one whose bytes do not match, then
// the batch into the plugin's inbox, where the running gateway picks it up. Writing as
// the gateway's user, into its own state, is what lets the relay deliver without root
// ever opening a path inside a directory an assistant controls.
//
// Whether an entry is believed is not decided here: the plugin checks every one,
// signatures included, when it reads the inbox.

import { randomUUID } from "node:crypto";
import { mkdir, rename, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { createMediaStore, isMediaId } from "./media.js";

const MAX_INPUT_BYTES = 200 * 1024 * 1024;
const SENDER = /^[a-z][a-z0-9-]{0,31}$/;

async function readInput() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_INPUT_BYTES) throw new Error("relay input over its size bound");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function main() {
  const input = await readInput();
  const { from, batch, media } = input ?? {};
  if (typeof from !== "string" || !SENDER.test(from)) throw new Error("bad sender");
  if (!batch || !Array.isArray(batch.entries)) throw new Error("batch has no entries");
  const attachments = Object.entries(media ?? {});
  for (const [id, data] of attachments) {
    if (!isMediaId(id) || typeof data !== "string") throw new Error("bad attachment");
  }

  const state = process.env.OPENCLAW_STATE_DIR || path.join(os.homedir(), ".openclaw");
  const directory = path.join(state, "household-app");
  const store = createMediaStore(directory);
  for (const [id, data] of attachments) await store.putBytes(Buffer.from(data, "base64"), id);

  const inbox = path.join(directory, "inbox");
  await mkdir(inbox, { recursive: true, mode: 0o700 });
  const name = `${Date.now()}-${randomUUID()}.json`;
  const temporary = path.join(inbox, `.${name}.tmp`);
  await writeFile(temporary, JSON.stringify({ from, batch }), { mode: 0o600, flag: "wx" });
  await rename(temporary, path.join(inbox, name));
  process.stdout.write(`${JSON.stringify({ ok: true, entries: batch.entries.length, media: attachments.length })}\n`);
}

main().catch((error) => {
  process.stderr.write(`household-app relay-in: ${error.message}\n`);
  process.exit(1);
});
