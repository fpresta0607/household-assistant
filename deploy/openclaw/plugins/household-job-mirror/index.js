// A scheduled message that reaches a family member on Telegram reaches them in the
// household app as well.
//
// Every briefing and reminder on both gateways is an automation that delivers to a
// Telegram chat: the owner's private chat or The Fam. An automation has one delivery
// target, so on its own it would go silent the day Telegram is turned off, and until
// then the app never hears of it. This plugin copies each one, word for word, into the
// app's conversation for the same people: the owner's own thread, or the family room.
// The app's channel keeps it and notifies the phone, as for any assistant message.
//
// `llm_output` carries the complete ordered words. The matching `cron_changed` event says
// the run succeeded, but its summary is truncated and cannot supply message text. Whether
// Telegram took it does not matter: once Telegram is off (issue #6) every such delivery fails,
// and the app is where the words belong. Only a run that chose to stay silent, such as one
// that answered NO_REPLY, which OpenClaw records as a suppression reason, is not copied.
// Both hooks identify the run's session. The scheduler supplies each job's delivery,
// and a removed one-time reminder's routing is kept until its finished event arrives.
//
// A reminder's copy is marked time sensitive for the app's channel, whose push then gets
// through a Focus. A reminder is a job made in a conversation, one-time or recurring,
// "every Monday, bins out" included. A job the household's scripts install carries a
// declaration key, such as `household-app:daily-brief`, and is pushed as any message is.
// The scheduler's list does not say who made a job (OpenClaw keeps the creator off the
// public record), so every job without a declaration key counts as a reminder.

import { readFileSync } from "node:fs";

export const PLUGIN_ID = "household-job-mirror";
const APP_CHANNEL = "household";
const MAX_JOBS = 1000;
const MAX_REMEMBERED_RUNS = 500;
const SHARED_STATE = Symbol.for("household-job-mirror.state");

const CONFIG_SCHEMA = JSON.parse(
  readFileSync(new URL("./openclaw.plugin.json", import.meta.url), "utf8"),
).configSchema;
const CHAT = new RegExp(CONFIG_SCHEMA.properties.targets.propertyNames.pattern);
const APP_TARGET = new RegExp(CONFIG_SCHEMA.properties.targets.additionalProperties.pattern);

export function parseConfig(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "expected a config object" };
  const unknown = Object.keys(raw).filter((key) => !(key in CONFIG_SCHEMA.properties));
  if (unknown.length > 0) return { error: `unknown config keys: ${unknown.join(", ")}` };
  const { targets } = raw;
  if (!targets || typeof targets !== "object" || Array.isArray(targets) || Object.keys(targets).length === 0 ||
    Object.entries(targets).some(([chat, target]) => !CHAT.test(chat) || typeof target !== "string" || !APP_TARGET.test(target))) {
    return { error: "targets must map Telegram chat ids to the app's family room or a person's app id" };
  }
  return { value: { targets } };
}

const configSchema = {
  safeParse(value) {
    const parsed = parseConfig(value);
    if (parsed.error) return { success: false, error: { issues: [{ path: [], message: parsed.error }] } };
    return { success: true, data: value };
  },
  jsonSchema: CONFIG_SCHEMA,
};

function telegramChat(value) {
  return typeof value === "string" ? /^(?:(?:telegram|tg):)?(-?[1-9]\d*)$/i.exec(value)?.[1] : undefined;
}

function remember(map, key, value, limit) {
  map.delete(key);
  map.set(key, value);
  if (map.size > limit) map.delete(map.keys().next().value);
}

export function createMirror(api, { targets }) {
  // Gateway and agent generations register separate plugin instances in one process.
  // Share only data within the same gateway and routing configuration.
  const states = globalThis[SHARED_STATE] ??= new Map();
  const key = JSON.stringify([api.runtime.state.resolveStateDir(), Object.entries(targets).sort(([left], [right]) => left.localeCompare(right))]);
  if (!states.has(key)) states.set(key, { jobs: new Map(), runs: new Map() });
  const { jobs, runs } = states.get(key);
  let scheduler = null;

  async function readJobs() {
    const current = scheduler;
    if (!current || current.signal?.aborted) return;
    try {
      for (const job of await current.cron.list({ includeDisabled: true })) {
        if (typeof job?.id === "string") {
          const isDeclared = typeof job.declarationKey === "string" && job.declarationKey.trim() !== "";
          remember(jobs, job.id, { delivery: job.delivery, agentId: job.agentId, isReminder: !isDeclared }, MAX_JOBS);
        }
      }
    } catch {
      api.logger.warn(`${PLUGIN_ID}: the automations could not be read`);
    }
  }

  async function onReconciled(event, context) {
    const cron = event?.enabled === false ? undefined : context?.getCron?.();
    scheduler = cron ? { cron, signal: context.abortSignal } : null;
    await readJobs();
  }

  function warn(reason) {
    api.logger.warn(`${PLUGIN_ID}: scheduled output was not copied: ${reason}`);
  }

  function runFor(sessionId, sessionKey) {
    if (typeof sessionId !== "string" || !sessionId.trim() || typeof sessionKey !== "string" || !sessionKey.trim()) {
      warn("missing run session identity");
      return;
    }
    const key = JSON.stringify([sessionId, sessionKey]);
    const run = runs.get(key) ?? {};
    remember(runs, key, run, MAX_REMEMBERED_RUNS);
    return run;
  }

  async function copy(run) {
    if (run.isCopied || run.isCopying || run.isAmbiguous || !run.output?.text || !run.finished) return;
    const { output, finished } = run;
    if ((output.jobId !== undefined && output.jobId !== finished.jobId) ||
      (finished.agentId !== undefined && output.agentId !== finished.agentId)) {
      run.isAmbiguous = true;
      warn("run agent or job identity disagrees");
      return;
    }
    if ((output.channel !== undefined && output.channel !== "telegram") ||
      [output.chatId, output.channelId].some((chat) => chat !== undefined && telegramChat(chat) !== finished.chat) ||
      (output.accountId !== undefined && finished.accountId !== undefined && output.accountId !== finished.accountId)) {
      run.isAmbiguous = true;
      warn("run delivery identity disagrees");
      return;
    }
    run.isCopying = true;
    try {
      const adapter = await api.runtime.channel.outbound.loadAdapter(APP_CHANNEL);
      if (run.isAmbiguous) return;
      if (!adapter?.sendText) throw new Error("the household app's channel has no adapter");
      await adapter.sendText({
        cfg: api.runtime.config.current(),
        to: `${APP_CHANNEL}:${finished.target}`,
        text: output.text,
        accountId: "default",
        ...(finished.isReminder ? { isTimeSensitive: true } : {}),
      });
      run.isCopied = true;
      delete run.output;
    } catch {
      warn("household channel delivery failed");
    } finally {
      run.isCopying = false;
    }
  }

  async function onOutput(event, context) {
    if (context?.trigger !== "cron") return;
    // The cron executor uses its session UUID as the agent run id. The scheduler's
    // separate execution id in cron_changed.runId belongs to a different namespace.
    if (typeof event?.runId !== "string" || event.runId !== event.sessionId ||
      event.sessionId !== context.sessionId ||
      (context.runId !== undefined && context.runId !== event.runId)) {
      warn("LLM run and session identity disagree");
      return;
    }
    const run = runFor(event.sessionId, context.sessionKey);
    if (!run || run.isCopied || run.isAmbiguous) return;
    const hasValidTexts = Array.isArray(event.assistantTexts) && event.assistantTexts.every((text) => typeof text === "string");
    if (!hasValidTexts) {
      warn("complete output is malformed");
    }
    const text = hasValidTexts ? event.assistantTexts.join("\n\n") : "";
    const isFailedAttempt = ["error", "aborted"].includes(event.lastAssistant?.stopReason);
    const output = {
      text: text.trim() && !isFailedAttempt ? text : "", agentId: context.agentId, jobId: context.jobId,
      channel: context.channel, chatId: context.chatId, channelId: context.channelId, accountId: context.accountId,
    };
    // Provider retries replace attempt text before delivery finishes, not run identity.
    if (run.output && Object.keys(output).some((field) =>
      (field !== "text" || run.finished) && run.output[field] !== output[field])) {
      run.isAmbiguous = true;
      warn("multiple outputs disagree for one run");
      return;
    }
    run.output = output;
    await copy(run);
  }

  async function onChanged(event) {
    if (event?.action !== "finished") {
      await readJobs();
      return;
    }
    if (event.status !== "ok" || event.deliverySuppressionReason || event.deliveryStatus === "not-requested") return;
    const job = jobs.get(event.jobId);
    const delivery = job?.delivery;
    if (delivery?.mode !== "announce" || delivery.channel !== "telegram") return;
    const chat = telegramChat(delivery.to);
    if (!chat || !Object.hasOwn(targets, chat)) return;
    const run = runFor(event.sessionId, event.sessionKey);
    if (!run || run.isCopied || run.isAmbiguous) return;
    const agents = [job.agentId, event.agentId, event.job?.agentId].filter((agent) => agent !== undefined);
    if (agents.some((agent) => typeof agent !== "string" || !agent || agent !== agents[0]) ||
      (event.job !== undefined && event.job.id !== event.jobId)) {
      run.isAmbiguous = true;
      warn("finished job identity disagrees");
      return;
    }
    const finished = {
      jobId: event.jobId, agentId: agents[0], runId: event.runId,
      target: targets[chat], chat, accountId: delivery.accountId, isReminder: job.isReminder,
    };
    if (run.finished && JSON.stringify(run.finished) !== JSON.stringify(finished)) {
      run.isAmbiguous = true;
      warn("multiple finished events disagree for one run");
      return;
    }
    run.finished = finished;
    if (!run.output?.text) warn("complete output for the finished run has not arrived");
    await copy(run);
  }

  return { onReconciled, onChanged, onOutput };
}

export default {
  id: PLUGIN_ID,
  name: "Household job mirror",
  description: "Copies each scheduled message a family member gets on Telegram into the household app.",
  configSchema,
  register(api) {
    const parsed = parseConfig(api.pluginConfig);
    if (parsed.error) {
      api.logger.error(`${PLUGIN_ID}: not started, ${parsed.error}`);
      return;
    }
    const mirror = createMirror(api, parsed.value);
    api.on("cron_reconciled", mirror.onReconciled);
    api.on("cron_changed", mirror.onChanged);
    api.on("llm_output", mirror.onOutput);
  },
};
