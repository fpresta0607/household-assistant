#!/usr/bin/env node
// The app publisher's push relay: an HTTP server on loopback in front of relay.mjs, which
// decides, and household-app's apple-push.js, which sends. docs/deploy/push-relay.md says
// how the publisher runs it and puts it behind HTTPS.
//
// It reads its settings from the environment, which push-relay.service takes from the
// root-only /etc/push-relay/push-relay.env:
//   APNS_KEY_ID, APNS_TEAM_ID   the app's push key in Apple's developer account
//   APNS_PRIVATE_KEY            that key's .p8, its line breaks written as \n
//   APNS_TOPIC                  the app's bundle id, com.siqstack.stewardai when unset
//   PUSH_RELAY_HOUSEHOLDS       the households file admin.mjs writes,
//                               /etc/push-relay/households.json when unset
//   PUSH_RELAY_HOST, PUSH_RELAY_PORT   where it listens, 127.0.0.1:8787 when unset
//   PUSH_RELAY_PER_MINUTE       each household's requests a minute, 120 when unset

import http from "node:http";
import { pathToFileURL } from "node:url";

import { createAppleSender, createHttp2Transport } from "../openclaw/plugins/household-app/apple-push.js";
import { MAX_REQUEST_BYTES, PER_MINUTE, createRelay, householdsFrom } from "./relay.mjs";

const ROUTES = new Set(["/v1/push", "/v1/check"]);

function answer(response, status, body) {
  const text = JSON.stringify(body);
  response.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(text), "cache-control": "no-store" });
  response.end(text);
}

// Only POST /v1/push, POST /v1/check and GET /healthz, each body read whole up to
// MAX_REQUEST_BYTES and refused past it before the relay sees any of it.
export function createRelayServer({ relay, maxRequestBytes = MAX_REQUEST_BYTES, log }) {
  const server = http.createServer((request, response) => {
    const path = new URL(request.url ?? "/", "http://relay").pathname;
    if (path === "/healthz") {
      if (request.method !== "GET") return answer(response, 405, { reason: "only GET" });
      return answer(response, 200, { ok: true });
    }
    if (!ROUTES.has(path)) return answer(response, 404, { reason: "nothing here" });
    if (request.method !== "POST") return answer(response, 405, { reason: "only POST" });
    const declared = Number(request.headers["content-length"] ?? 0);
    if (declared > maxRequestBytes) {
      answer(response, 413, { reason: "the request is too large" });
      request.resume();
      return undefined;
    }
    const chunks = [];
    let size = 0;
    let refused = false;
    request.on("data", (chunk) => {
      if (refused) return;
      size += chunk.length;
      if (size > maxRequestBytes) {
        refused = true;
        answer(response, 413, { reason: "the request is too large" });
        request.resume();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      if (refused) return;
      relay
        .handle({ path, headers: request.headers, body: Buffer.concat(chunks) })
        .then((result) => answer(response, result.status, result.body))
        .catch((error) => {
          log?.warn?.(`push-relay: a request failed: ${error?.message ?? error}`);
          answer(response, 500, { reason: "the relay failed" });
        });
    });
    return undefined;
  });
  // A slow client is dropped rather than held: a notification is a few kilobytes.
  server.requestTimeout = 10_000;
  server.headersTimeout = 5_000;
  server.keepAliveTimeout = 5_000;
  return server;
}

function required(environment, name) {
  const value = environment[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

export function main(environment = process.env) {
  const log = { info: (line) => console.log(line), warn: (line) => console.error(line) };
  const sender = createAppleSender({
    keyId: required(environment, "APNS_KEY_ID"),
    teamId: required(environment, "APNS_TEAM_ID"),
    privateKey: required(environment, "APNS_PRIVATE_KEY").replaceAll("\\n", "\n"),
    topic: environment.APNS_TOPIC || "com.siqstack.stewardai",
    transport: createHttp2Transport(),
  });
  const relay = createRelay({
    households: householdsFrom(environment.PUSH_RELAY_HOUSEHOLDS || "/etc/push-relay/households.json", { log }),
    sender,
    perMinute: Number(environment.PUSH_RELAY_PER_MINUTE) || PER_MINUTE,
    log,
  });
  const host = environment.PUSH_RELAY_HOST || "127.0.0.1";
  const port = Number(environment.PUSH_RELAY_PORT) || 8787;
  const server = createRelayServer({ relay, log });
  server.listen(port, host, () => log.info(`push-relay: listening on ${host}:${port}`));
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(`push-relay: ${error.message}`);
    process.exit(1);
  }
}
