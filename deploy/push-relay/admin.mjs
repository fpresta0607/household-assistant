#!/usr/bin/env node
// Who the push relay lets in, kept in its households file, as root on the relay's box:
//
//   node admin.mjs add marina-steve MCowBQYDK2VwAyEA...   let a household in by its public key
//   node admin.mjs add marina-steve MCow... --replace     a household's new key, after it rotated
//   node admin.mjs remove marina-steve                    let it in no more
//   node admin.mjs list                                   who is let in, with each key's fingerprint
//
// The key is the line scripts/household-push-key.py printed on the household's box: the
// public half of its Ed25519 key, as base64 or as PEM. It is not a secret, so it may come by
// any message; the private half never leaves that box. The relay reads the file again on
// its next request, so nothing restarts. PUSH_RELAY_HOUSEHOLDS names another file.

import { createHash, createPublicKey } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const HOUSEHOLD = /^[a-z][a-z0-9-]{0,31}$/;
export const HOUSEHOLDS_FILE = "/etc/push-relay/households.json";

// The key as the relay keeps it, PEM, from either form a household may send.
export function publicKeyPem(text) {
  const trimmed = String(text).trim();
  const key = trimmed.startsWith("-----BEGIN")
    ? createPublicKey(trimmed)
    : createPublicKey({ key: Buffer.from(trimmed, "base64"), format: "der", type: "spki" });
  if (key.asymmetricKeyType !== "ed25519") throw new Error("the key is not an Ed25519 public key");
  return key.export({ format: "pem", type: "spki" });
}

export function fingerprint(pem) {
  const der = createPublicKey(pem).export({ format: "der", type: "spki" });
  return `SHA256:${createHash("sha256").update(der).digest("base64").replace(/=+$/, "")}`;
}

function read(file) {
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8"));
    return parsed && typeof parsed.households === "object" && !Array.isArray(parsed.households) ? parsed : { households: {} };
  } catch (error) {
    if (error.code === "ENOENT") return { households: {} };
    throw new Error(`${file} cannot be read: ${error.message}`);
  }
}

// Written whole beside itself and renamed into place, so the relay never reads half a file.
function write(file, value) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o755 });
  const temporary = `${file}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o644 });
  renameSync(temporary, file);
}

export function addHousehold(file, household, key, { replace = false, now = () => new Date() } = {}) {
  if (!HOUSEHOLD.test(household)) throw new Error(`${household} is not a household name: lower-case letters, digits and dashes`);
  const pem = publicKeyPem(key);
  const kept = read(file);
  const existing = kept.households[household];
  if (existing && !replace) throw new Error(`${household} is let in already; --replace gives it this key instead`);
  kept.households[household] = { publicKey: pem, enabled: true, added: now().toISOString().slice(0, 10) };
  write(file, kept);
  return fingerprint(pem);
}

export function removeHousehold(file, household) {
  const kept = read(file);
  if (!(household in kept.households)) throw new Error(`${household} is not let in`);
  delete kept.households[household];
  write(file, kept);
}

export function listHouseholds(file) {
  return Object.entries(read(file).households).map(([household, entry]) => {
    let print = "a key that cannot be read";
    try {
      print = fingerprint(entry.publicKey);
    } catch {
      // Listed anyway, so the publisher sees it and can replace it.
    }
    return { household, enabled: entry.enabled !== false, added: entry.added ?? "", fingerprint: print };
  });
}

export function main(argv = process.argv.slice(2), { file = process.env.PUSH_RELAY_HOUSEHOLDS || HOUSEHOLDS_FILE, out = console.log } = {}) {
  const [command, household, ...rest] = argv;
  if (command === "add" && household && rest.length >= 1) {
    const replace = rest.includes("--replace");
    const key = rest.filter((word) => word !== "--replace").join("\n");
    out(`${household} is let in, key ${addHousehold(file, household, key, { replace })}`);
    return 0;
  }
  if (command === "remove" && household && rest.length === 0) {
    removeHousehold(file, household);
    out(`${household} is let in no more`);
    return 0;
  }
  if (command === "list" && !household) {
    for (const row of listHouseholds(file)) {
      out(`${row.household}\t${row.enabled ? "let in" : "switched off"}\t${row.added}\t${row.fingerprint}`);
    }
    return 0;
  }
  console.error("usage: admin.mjs add <household> <public key> [--replace] | remove <household> | list");
  return 2;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.exitCode = main();
  } catch (error) {
    console.error(`push-relay: ${error.message}`);
    process.exitCode = 1;
  }
}
