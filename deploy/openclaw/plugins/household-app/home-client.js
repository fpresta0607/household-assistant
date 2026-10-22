// The home key holder (household/home/server.py) as an MCP client: one session per call,
// initialize, then one tools/call. It runs on the host, holds the Home Assistant token and
// the Apple TV pairing, and binds its socket directory into this gateway's own state.

import { createConnection } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { StringDecoder } from "node:string_decoder";

export const HOME_SOCKET = join(homedir(), ".openclaw", "home", "home.sock");
const PROTOCOL = "2025-11-25";
const MAX_RESPONSE_BYTES = 64 * 1024;
// Longer than the key holder's slowest call, waking the TV and waiting for Spotify to list it.
const TIMEOUT_MS = 160_000;

export class HomeUnavailable extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export function callHome(name, args, { socketPath = HOME_SOCKET, signal, timeoutMs = TIMEOUT_MS, connect = createConnection } = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new HomeUnavailable("request_cancelled", "The request to the house was cancelled."));
      return;
    }
    const socket = connect({ path: socketPath });
    const decoder = new StringDecoder("utf8");
    let buffered = "";
    let finished = false;
    let stage = 1;
    const send = (value) => socket.write(`${JSON.stringify(value)}\n`);
    const stop = (error, result) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      socket.destroy();
      if (error) reject(error);
      else resolve(result);
    };
    const abort = () => stop(new HomeUnavailable("request_cancelled", "The request to the house was cancelled."));
    const timer = setTimeout(() => stop(new HomeUnavailable("request_timeout", "The house did not answer in time.")), timeoutMs);
    signal?.addEventListener("abort", abort, { once: true });
    socket.on("error", () => stop(new HomeUnavailable("home_unavailable", "Home control is not available on this assistant right now.")));
    socket.on("close", () => stop(new HomeUnavailable("home_unavailable", "The house closed the connection before answering.")));
    socket.on("data", (chunk) => {
      buffered += decoder.write(chunk);
      if (Buffer.byteLength(buffered) > MAX_RESPONSE_BYTES) {
        stop(new HomeUnavailable("response_too_large", "The house's answer was too large."));
        return;
      }
      let newline;
      while (!finished && (newline = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          stop(new HomeUnavailable("mcp_transport_error", "The house's answer was invalid."));
          return;
        }
        if (message?.jsonrpc !== "2.0" || message.id !== stage || message.error || !message.result) {
          stop(new HomeUnavailable("mcp_transport_error", "The house's answer did not match its request."));
          return;
        }
        if (stage === 1) {
          if (message.result.protocolVersion !== PROTOCOL || !message.result.capabilities?.tools) {
            stop(new HomeUnavailable("mcp_transport_error", "The house's MCP protocol could not be agreed."));
            return;
          }
          stage = 2;
          send({ jsonrpc: "2.0", method: "notifications/initialized" });
          send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } });
        } else stop(null, message.result);
      }
    });
    socket.on("connect", () => send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: "household-app", version: "1.0.0" } },
    }));
  });
}
