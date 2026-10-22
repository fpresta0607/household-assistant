import { createConnection } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { ConnectorError } from "./tools.mjs";

/** The host key holder binds its socket directory here, inside the gateway's own state. */
export const KEY_HOLDER_SOCKET = join(homedir(), ".openclaw", "pocketpiggies", "broker.sock");
const PROTOCOL = "2025-11-25";
/** The key holder names its owner here, from its root-written unit, never from gateway config. */
export const OWNER_META = "household.pocketpiggies/ownerTelegramId";
const MAX_RESPONSE_BYTES = 3 * 1024 * 1024;

/**
 * One MCP session with the key holder per call: initialize, then one tools/call.
 * The call is sent only when the key holder's owner is the turn's sender.
 */
export function callKeyHolder(
  name,
  args,
  { owner, socketPath = KEY_HOLDER_SOCKET, signal, timeoutMs = 60000, connect = createConnection } = {},
) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new ConnectorError("request_cancelled", "The PocketPiggies read was cancelled."));
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
    const abort = () => stop(new ConnectorError("request_cancelled", "The PocketPiggies read was cancelled."));
    const timer = setTimeout(
      () => stop(new ConnectorError("request_timeout", "The PocketPiggies read timed out.")),
      timeoutMs,
    );
    signal?.addEventListener("abort", abort, { once: true });
    socket.on("error", () => stop(new ConnectorError(
      "key_holder_unavailable",
      "PocketPiggies is not available on this assistant right now. No financial figure is available.",
    )));
    socket.on("close", () => stop(new ConnectorError(
      "key_holder_unavailable",
      "The PocketPiggies connection closed before answering.",
    )));
    socket.on("data", (chunk) => {
      buffered += decoder.write(chunk);
      if (Buffer.byteLength(buffered) > MAX_RESPONSE_BYTES) {
        stop(new ConnectorError("response_too_large", "The PocketPiggies answer exceeded its limit."));
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
          stop(new ConnectorError("mcp_transport_error", "The PocketPiggies answer was invalid."));
          return;
        }
        if (message?.jsonrpc !== "2.0" || message.id !== stage || message.error || !message.result) {
          stop(new ConnectorError("mcp_transport_error", "The PocketPiggies answer did not match its request."));
          return;
        }
        if (stage === 1) {
          if (message.result.protocolVersion !== PROTOCOL || !message.result.capabilities?.tools) {
            stop(new ConnectorError("mcp_transport_error", "The PocketPiggies MCP protocol could not be negotiated."));
            return;
          }
          if (typeof owner !== "string" || message.result._meta?.[OWNER_META] !== owner) {
            stop(new ConnectorError("private_chat_required", "This PocketPiggies connection belongs to someone else."));
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
      params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: "steward-openclaw", version: "2.0.0" } },
    }));
  });
}
