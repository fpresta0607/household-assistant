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

// `attempts` of 5 ms each; a wait on the inbox, which a busy machine may scan only every two
// seconds, takes more.
export async function until(what, condition, { attempts = 400 } = {}) {
  for (let attemptsLeft = attempts; attemptsLeft > 0; attemptsLeft -= 1) {
    if (await condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail(`timed out waiting for ${what}`);
}

// `sdk` names more SDK functions to behave, as stubChannelSdk takes them; the first channel
// a test file runs fixes them for the file, since the plugin's entry is imported once.
// `transcribeAudioFile` stands in for OpenClaw's speech-to-text. `stateDir` starts it on the
// state an earlier channel left, as a gateway restart does. `dispatch` stands in for
// OpenClaw's run of an admitted turn, such as one that delivers a final reply.
export async function runningChannel(cfg, {
  sdk = {},
  transcribeAudioFile,
  stateDir: earlierState,
  dispatch = async () => ({ admission: { kind: "dispatch" } }),
} = {}) {
  // The plugin reads OpenRouter's model list as it starts.
  globalThis.fetch = async () => {
    throw new Error("no network in tests");
  };
  stubChannelSdk(fileURLToPath(new URL("index.js", PLUGIN)), {
    resolveChannelInboundRouteEnvelope: `({ peer }) => ({ route: { agentId: "main", dmScope: "per-channel-peer", sessionKey: "agent:main:household:" + (peer.kind === "group" ? "group:" : "direct:") + peer.id } })`,
    waitUntilAbort: `(signal) => new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }))`,
    ...sdk,
  });
  const { default: entry, resolveAccount } = await import(new URL("index.js", PLUGIN));
  const stateDir = earlierState ?? await mkdtemp(path.join(tmpdir(), "household-app-channel-"));
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
      // OpenClaw keeps a method's first registration, so a second one of a name would never
      // answer on a gateway; the stand-in refuses it rather than keep the later one.
      registerGatewayMethod: (name, handler) => {
        if (methods.has(name)) throw new Error(`${name} is registered twice`);
        methods.set(name, handler);
      },
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
  const dispatches = [];
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
        dispatch: async (params) => {
          dispatches.push(params);
          return dispatch(params);
        },
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
    dispatches,
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
    // Every handler the plugin registered for a hook with no matcher, such as cron_changed, in
    // the order it registered them, each awaited.
    async hook(name, event, context) {
      for (const hook of hooks) if (hook.name === name) await hook.handler(event, context);
    },
    async stop() {
      abort.abort();
      await stopped;
    },
  };
}
