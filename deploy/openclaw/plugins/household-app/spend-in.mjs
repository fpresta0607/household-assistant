// The receiving end of the box's spend job. scripts/household-spend.py runs this inside
// each gateway's container, as the gateway's own user, with the household's month on
// standard input:
//
//   docker exec -i -u node openclaw-gateway node /opt/household-plugins/household-app/spend-in.mjs
//
// It checks the month as the plugin reads it (spend.js), its lines adding up to its total
// included, and writes it to household-app/spend.json, where `household-app.spend` reads
// it. Writing as the gateway's user, into its own state, is what lets the job deliver
// without root ever opening a path inside a directory an assistant controls.

import { mkdir, rename, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { cleanReport } from "./spend.js";

const MAX_INPUT_BYTES = 64 * 1024;

async function readInput() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_INPUT_BYTES) throw new Error("spend input over its size bound");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function main() {
  const report = cleanReport(await readInput());
  const state = process.env.OPENCLAW_STATE_DIR || path.join(os.homedir(), ".openclaw");
  const directory = path.join(state, "household-app");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, "spend.json");
  const temporary = path.join(directory, `.spend.json.${process.pid}.tmp`);
  await writeFile(temporary, JSON.stringify(report), { mode: 0o600 });
  await rename(temporary, file);
  process.stdout.write(`${JSON.stringify({ ok: true, month: report.month, at: report.at })}\n`);
}

main().catch((error) => {
  process.stderr.write(`spend-in: ${error?.message ?? error}\n`);
  process.exit(1);
});
