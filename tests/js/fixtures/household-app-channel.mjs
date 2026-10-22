// The household-app channel running on a stand-in gateway, driven through the plugin's own
// entry: the gateway methods a phone calls, each context the plugin builds for a turn,
// every event it tells the phones, each line it logs, and its tool hooks run as OpenClaw
// runs them. Every turn is admitted without a model, and nothing reaches a network.

import assert from "node:assert/strict";
import { mkdir, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { stubChannelSdk } from "./openclaw-channel-sdk.mjs";

const PLUGIN = new URL("../../../deploy/openclaw/plugins/household-app/", import.meta.url);

export async function until(what, condition) {
  for (let attemptsLeft = 400; attemptsLeft > 0; attemptsLeft -= 1) {
    if (await condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail(`timed out waiting for ${what}`);
}

// `sdk` names more SDK functions to behave, as stubChannelSdk takes them; the first channel
// a test file runs fixes them for the file, since the plugin's entry is imported once.
// `transcribeAudioFile` stands in for OpenClaw's speech-to-text.
export async function runningChannel(cfg, { sdk = {}, transcribeAudioFile } = {}) {
  // The plugin reads OpenRouter's model list as it starts.
  globalThis.fetch = async () => {
    throw new Error("no network in tests");
  };
  stubChannelSdk(fileURLToPath(new URL("index.js", PLUGIN)), {
    resolveChannelInboundRouteEnvelope: `({ peer }) => ({ route: { agentId: "main", dmScope: "per-channel-peer", sessionKey: peer.kind === "group" ? "agent:main:household:group:family" : "agent:main:household:direct:" + peer.id } })`,
    waitUntilAbort: `(signal) => new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }))`,
    ...sdk,
  });
  const { default: entry, resolveAccount } = await import(new URL("index.js", PLUGIN));
  const stateDir = await mkdtemp(path.join(tmpdir(), "household-app-channel-"));
  await mkdir(path.join(stateDir, "household-app"), { recursive: true });
  entry.setRuntime({
    state: { resolveStateDir: () => stateDir },
    config: { current: () => cfg },
    ...(transcribeAudioFile ? { mediaUnderstanding: { transcribeAudioFile } } : {}),
  });

  const methods = new Map();
  const tools = [];
  const hooks = [];
  const pluginLogs = [];
  const api = new Proxy(
    {
      registerGatewayMethod: (name, handler) => methods.set(name, handler),
      registerTool: (factory, options) => tools.push({ factory, options }),
      on: (name, handler, options) => hooks.push({ name, handler, matcher: options?.matcher }),
      session: { workflow: { enqueueNextTurnInjection() {} } },
      logger: { info: (line) => pluginLogs.push(line), warn: (line) => pluginLogs.push(line), error() {} },
    },
    { get: (target, key) => (key in target ? target[key] : () => {}) },
  );
  entry.registerFull(api);
  const call = (name, params) => new Promise((resolve) => {
    void methods.get(name)({ params, client: {}, respond: (ok, payload, error) => resolve({ ok, payload, error }) });
  });

  const contexts = [];
  const events = [];
  const logs = [];
  const abort = new AbortController();
  const stopped = entry.plugin.gateway.startAccount({
    account: resolveAccount(cfg),
    accountId: "default",
    cfg,
    setStatus() {},
    log: { info: (line) => logs.push(line), warn: (line) => logs.push(line), error() {} },
    abortSignal: abort.signal,
    gatewayEvents: { emit: (name, payload) => events.push([name, payload]) },
    channelRuntime: {
      inbound: {
        buildContext: async (params) => {
          contexts.push(params);
          return params;
        },
        dispatch: async () => ({ admission: { kind: "dispatch" } }),
      },
    },
  });
  // The channel answers a read once it runs.
  await until("the channel to run", async () => (await call("household-app.sync", { since: 0 })).ok);
  return {
    stateDir,
    plugin: entry.plugin,
    // The plugin's tool factories, each as OpenClaw offers it to a turn.
    tools,
    contexts,
    events,
    logs,
    pluginLogs,
    call,
    send: (message) => call("household-app.send", message),
    // OpenClaw's before_tool_call for one call: each of the plugin's handlers whose matcher
    // covers the tool, in the order the plugin registered them, until one blocks it.
    async beforeToolCall(event, context = {}) {
      for (const hook of hooks) {
        if (hook.name !== "before_tool_call" || (hook.matcher && !hook.matcher.includes(event.toolName))) continue;
        const result = await hook.handler(event, { ...context, toolName: event.toolName });
        if (result?.block) return result;
      }
      return undefined;
    },
    // OpenClaw's before_prompt_build for one turn: each of the plugin's handlers, in the order
    // the plugin registered them, their context additions joined as OpenClaw joins them.
    async promptBuild(event, context) {
      const joined = {};
      for (const hook of hooks) {
        if (hook.name !== "before_prompt_build") continue;
        for (const [key, value] of Object.entries((await hook.handler(event, context)) ?? {})) {
          joined[key] = joined[key] ? `${joined[key]}\n\n${value}` : value;
        }
      }
      return joined;
    },
    async stop() {
      abort.abort();
      await stopped;
    },
  };
}
