// The household-job-mirror OpenClaw plugin: a scheduled message that reached a family
// member on Telegram reaches them in the household app as well.
//
// The hook fields follow OpenClaw 2026.9.4's public contract. The integration case
// retains complete scheduled output through the real room and SQLite store.

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { createRoom } from "../../deploy/openclaw/plugins/household-app/room.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";
import plugin, { parseConfig } from "../../deploy/openclaw/plugins/household-job-mirror/index.js";

const OWNER = "7000000001";
const GROUP = "-7000000002";
const CONFIG = { targets: { [OWNER]: "sam", [GROUP]: "family" } };
const MANIFEST = JSON.parse(
  await readFile(new URL("../../deploy/openclaw/plugins/household-job-mirror/openclaw.plugin.json", import.meta.url), "utf8"),
);

function job(id, delivery) {
  return { id, agentId: "main", enabled: true, schedule: { kind: "cron", expr: "30 6 * * *" }, sessionTarget: "current", delivery };
}

const JOBS = [
  job("briefing", { mode: "announce", channel: "telegram", to: OWNER, accountId: "default" }),
  job("sunday-post", { mode: "announce", channel: "telegram", to: GROUP }),
  job("other-chat", { mode: "announce", channel: "telegram", to: "7000000009" }),
  job("tidy-up", { mode: "none" }),
  job("webhook", { mode: "webhook", to: "https://example.invalid/hook" }),
  job("app-only", { mode: "announce", channel: "household", to: "household:sam" }),
];

function gateway({ config = CONFIG, jobs = JOBS, adapter, loadAdapter, stateDirectory = randomUUID(), definition = plugin } = {}) {
  const hooks = new Map();
  const sent = [];
  const warnings = [];
  const store = { jobs: structuredClone(jobs) };
  const scheduler = { list: async () => structuredClone(store.jobs) };
  const app = adapter ?? {
    async sendText(params) {
      sent.push(params);
      return { channel: "household", messageId: `app-${sent.length}` };
    },
  };
  const api = {
    pluginConfig: config,
    logger: { info() {}, warn: (line) => warnings.push(line), error: (line) => warnings.push(line) },
    runtime: {
      state: { resolveStateDir: () => stateDirectory },
      config: { current: () => ({ channels: { household: {} } }) },
      channel: { outbound: { loadAdapter: loadAdapter ?? (async (channel) => (channel === "household" ? app : undefined)) } },
    },
    on: (name, handler) => hooks.set(name, handler),
  };
  definition.register(api);
  const abort = new AbortController();
  const setup = {
    hooks, sent, warnings, store, abort,
    reconcile: () => hooks.get("cron_reconciled")({ reason: "startup", enabled: true }, { getCron: () => scheduler, abortSignal: abort.signal }),
    changed: (event) => hooks.get("cron_changed")(event, {}),
    output: (event, context) => hooks.get("llm_output")?.(event, context),
    async complete(event, texts = ["Good morning. Here is the day."]) {
      await setup.output(...output(event, texts));
      await setup.changed(event);
    },
  };
  return setup;
}

const finished = (jobId, overrides = {}) => ({
  action: "finished", jobId, status: "ok", delivered: true, deliveryStatus: "delivered",
  sessionId: `session-${jobId}`, sessionKey: `agent:main:cron:${jobId}:run:session-${jobId}`,
  agentId: "main", runId: `cron:${jobId}:1792000000000`,
  runAtMs: 1_792_000_000_000, summary: "Good morning. Here is the day.", ...overrides,
});

function output(event, assistantTexts = ["Complete scheduled answer."]) {
  return [
    { runId: event.sessionId, sessionId: event.sessionId, provider: "fixture", model: "fixture", assistantTexts },
    { runId: event.sessionId, sessionId: event.sessionId, sessionKey: event.sessionKey, agentId: "main", trigger: "cron" },
  ];
}

test("a complete 17754-unit scheduled answer survives the real room and SQLite reopening", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "job-mirror-complete-"));
  const database = path.join(directory, "room.sqlite");
  const finalParagraph = "The unique final paragraph survives scheduled delivery and reopening.";
  const fullText = "Synthetic scheduled answer. ".repeat(700).slice(0, 17754 - finalParagraph.length - 2) + "\n\n" + finalParagraph;
  assert.equal(fullText.length, 17754);
  let store = openRoomStore(database);
  const room = createRoom({
    identity: {
      owner: { id: "sam", name: "Sam", keys: [] },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia", keys: [] }, assistant: { id: "denise", name: "Denise" } },
    },
    store,
    emit() {},
    writeOutbox() {},
  });
  const setup = gateway({ adapter: { sendText: ({ to, text, isTimeSensitive }) => room.reply({
    conversation: to === "household:family" ? "family" : "direct", text, isTimeSensitive,
  }) } });
  try {
    await setup.reconcile();
    await setup.complete(finished("briefing", { summary: fullText.slice(0, 2001) }), [fullText]);
    assert.equal(store.history("direct").messages[0]?.text.length, 17754);
    store.close();
    store = openRoomStore(database);
    const kept = store.history("direct").messages;
    assert.equal(kept.length, 1);
    assert.equal(kept[0].text, fullText);
    assert.equal(kept[0].text.split(finalParagraph).length, 2);
    assert.equal(store.changesSince(0).entries[0].text, fullText);
  } finally {
    store.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("the manifest names the plugin, and it registers no tool", () => {
  assert.equal(MANIFEST.id, "household-job-mirror");
  assert.equal(MANIFEST.contracts, undefined);
});

test("the config maps each Telegram chat to the app's conversation for it", () => {
  assert.deepEqual(parseConfig(CONFIG).value, CONFIG);
  for (const broken of [
    {},
    { targets: {} },
    { targets: { [OWNER]: "Sam" } },
    { targets: { "telegram:7000000001": "sam" } },
    { targets: { [OWNER]: "sam" }, extra: true },
    { targets: [] },
  ]) {
    assert.ok(parseConfig(broken).error, JSON.stringify(broken));
  }
});

test("a scheduled message delivered to the owner's Telegram chat lands in their app thread with the same words", async () => {
  const setup = gateway();
  await setup.reconcile();

  await setup.complete(finished("briefing"));

  assert.equal(setup.sent.length, 1);
  assert.equal(setup.sent[0].to, "household:sam");
  assert.equal(setup.sent[0].text, "Good morning. Here is the day.");
  assert.equal(setup.sent[0].accountId, "default");
});

test("a scheduled post to The Fam lands in the app's family room", async () => {
  const setup = gateway();
  await setup.reconcile();

  await setup.complete(finished("sunday-post"));

  assert.deepEqual(setup.sent.map((send) => send.to), ["household:family"]);
});

test("nothing is copied unless the run succeeded, chose to speak, carried words, and went to a mapped chat", async () => {
  const setup = gateway();
  await setup.reconcile();

  for (const event of [
    finished("briefing", { delivered: false, deliveryStatus: "not-delivered", deliverySuppressionReason: "silent" }),
    finished("briefing", { delivered: false, deliveryStatus: "not-requested" }),
    finished("briefing", { status: "error" }),
    { ...finished("briefing"), action: "started" },
    finished("other-chat"),
    finished("tidy-up"),
    finished("webhook"),
    finished("app-only"),
    finished("unknown-job"),
  ]) {
    await setup.complete(event);
  }

  assert.equal(setup.sent.length, 0);
});

test("one run is copied once, and the next run of the same job is copied again", async () => {
  const setup = gateway();
  await setup.reconcile();

  await setup.complete(finished("briefing"));
  await setup.complete(finished("briefing"));
  await setup.complete(finished("briefing", {
    sessionId: "next-session", sessionKey: "agent:main:cron:briefing:run:next-session",
    runId: "cron:briefing:1792086400000", runAtMs: 1_792_086_400_000,
  }));

  assert.equal(setup.sent.length, 2);
});

test("a one-time reminder is copied even when the scheduler has already deleted it", async () => {
  const setup = gateway({ jobs: [] });
  await setup.reconcile();
  setup.store.jobs.push(job("reminder", { mode: "announce", channel: "telegram", to: `telegram:${OWNER}` }));
  await setup.changed({ action: "added", jobId: "reminder" });
  setup.store.jobs.length = 0;
  await setup.changed({ action: "removed", jobId: "reminder" });

  await setup.complete(finished("reminder"));

  assert.deepEqual(setup.sent.map((send) => send.to), ["household:sam"]);
});

// A reminder is a job made in a conversation, one-time or recurring. A job the household's
// scripts install carries a declaration key, and stays at the normal level.
test("a reminder's copy is time sensitive, one-time or recurring, so it gets through a Focus", async () => {
  const leave = { ...job("leave", { mode: "announce", channel: "telegram", to: OWNER }), schedule: { kind: "at", at: "2026-10-15T20:45:00Z" } };
  const bins = { ...job("bins", { mode: "announce", channel: "telegram", to: GROUP }), schedule: { kind: "cron", expr: "0 19 * * 1" } };
  const setup = gateway({ jobs: [leave, bins] });
  await setup.reconcile();

  await setup.complete(finished("leave"), ["Time to leave for soccer pickup."]);
  await setup.complete(finished("bins"), ["Bins out tonight."]);

  assert.deepEqual(setup.sent.map((send) => send.isTimeSensitive), [true, true]);
});

test("a declared job's copy is pushed as any message is", async () => {
  const declared = { ...job("morning-post", { mode: "announce", channel: "telegram", to: GROUP }), declarationKey: "household-app:morning-post" };
  const setup = gateway({ jobs: [declared] });
  await setup.reconcile();

  await setup.complete(finished("morning-post"));

  assert.equal(setup.sent.length, 1);
  assert.equal("isTimeSensitive" in setup.sent[0], false);
});

test("a job whose delivery changed is copied to where it goes now", async () => {
  const setup = gateway();
  await setup.reconcile();
  setup.store.jobs[0].delivery = { mode: "announce", channel: "telegram", to: GROUP };
  await setup.changed({ action: "updated", jobId: "briefing" });

  await setup.complete(finished("briefing"));

  assert.deepEqual(setup.sent.map((send) => send.to), ["household:family"]);
});

test("before the scheduler is known nothing is copied, and a stale scheduler is let go", async () => {
  const early = gateway();
  await early.complete(finished("briefing"));
  assert.equal(early.sent.length, 0);

  const setup = gateway();
  await setup.reconcile();
  setup.abort.abort();
  setup.store.jobs[0].delivery = { mode: "announce", channel: "telegram", to: GROUP };
  await setup.changed({ action: "updated", jobId: "briefing" });
  await setup.complete(finished("briefing"));
  assert.deepEqual(setup.sent.map((send) => send.to), ["household:sam"]);
});

test("an app that cannot take the copy is logged and never stops the gateway", async () => {
  const setup = gateway({ adapter: { async sendText() { throw new Error("the household app channel is not running"); } } });
  await setup.reconcile();

  await setup.complete(finished("briefing"));

  assert.equal(setup.warnings.length, 1);
  assert.doesNotMatch(setup.warnings[0], /Good morning/);
  const missing = gateway({ adapter: {} });
  await missing.reconcile();
  await missing.complete(finished("briefing"));
  assert.equal(missing.warnings.length, 1);
});

test("the plugin does not start on a config it cannot read", () => {
  const hooks = new Map();
  const errors = [];
  plugin.register({ pluginConfig: { targets: {} }, logger: { error: (line) => errors.push(line) }, on: (name, handler) => hooks.set(name, handler) });
  assert.equal(hooks.size, 0);
  assert.equal(errors.length, 1);
});

test("only the three public hooks needed for complete scheduled output are registered", () => {
  assert.deepEqual([...gateway().hooks.keys()].sort(), ["cron_changed", "cron_reconciled", "llm_output"]);
});

test("multipart output keeps every paragraph in order during duplicate finish concurrency", async () => {
  const setup = gateway();
  await setup.reconcile();
  const event = finished("briefing", { summary: "A shortened summary." });
  const parts = ["  First paragraph with spacing.  ", "Second paragraph.", "Unique final paragraph."];
  await setup.output(...output(event, parts));

  await Promise.all([setup.changed(event), setup.changed(event), setup.changed(event)]);
  await setup.output(...output(event, parts));
  await setup.changed(event);

  assert.deepEqual(setup.sent.map(({ text }) => text), [parts.join("\n\n")]);
});

test("a finished run waits for its exact late complete output without copying the summary", async () => {
  const setup = gateway();
  await setup.reconcile();
  const event = finished("briefing");

  await setup.changed(event);
  assert.equal(setup.sent.length, 0);
  await setup.output(...output(event, ["The late complete output."]));

  assert.deepEqual(setup.sent.map(({ text }) => text), ["The late complete output."]);
  assert.ok(setup.warnings.length > 0);
  assert.ok(setup.warnings.every((line) => !line.includes(event.summary)));
});

test("a failed app send can retry the same completed run once", async () => {
  const sent = [];
  let shouldFail = true;
  const setup = gateway({ adapter: { async sendText(params) {
    if (shouldFail) throw new Error("Sensitive contents of failed outbound request");
    sent.push(params);
  } } });
  await setup.reconcile();
  const event = finished("briefing");
  await setup.complete(event, ["Complete retryable answer."]);
  assert.equal(sent.length, 0);
  assert.equal(setup.warnings.length, 1);
  assert.doesNotMatch(setup.warnings[0], /Sensitive contents|Complete retryable/);
  shouldFail = false;

  await Promise.all([setup.changed(event), setup.changed(event)]);
  await setup.changed(event);

  assert.deepEqual(sent.map(({ text }) => text), ["Complete retryable answer."]);
});

for (const [name, change] of [
  ["wrong event run", (event) => { event.runId = "wrong-run"; }],
  ["wrong event session", (event) => { event.sessionId = "wrong-session"; }],
  ["wrong context run", (_event, context) => { context.runId = "wrong-run"; }],
  ["wrong context session", (_event, context) => { context.sessionId = "wrong-session"; }],
  ["wrong context session key", (_event, context) => { context.sessionKey = "agent:main:cron:another-job"; }],
  ["wrong agent", (_event, context) => { context.agentId = "another-agent"; }],
  ["wrong explicit job", (_event, context) => { context.jobId = "another-job"; }],
  ["missing event run", (event) => { delete event.runId; }],
  ["missing event session", (event) => { delete event.sessionId; }],
  ["missing context session", (_event, context) => { delete context.sessionId; }],
  ["missing context session key", (_event, context) => { delete context.sessionKey; }],
  ["non-cron trigger", (_event, context) => { context.trigger = "user"; }],
  ["empty complete output", (event) => { event.assistantTexts = ["   ", ""]; }],
  ["malformed complete output", (event) => { event.assistantTexts = ["valid", null]; }],
]) {
  test(`${name} never supplies a scheduled app message`, async () => {
    const setup = gateway();
    await setup.reconcile();
    const event = finished("briefing");
    const candidate = output(event, ["Synthetic private complete text."]);
    change(...candidate);

    await setup.output(...candidate);
    await setup.changed(event);

    assert.equal(setup.sent.length, 0);
    assert.ok(setup.warnings.length > 0);
    assert.ok(setup.warnings.every((line) => !/Synthetic private|Good morning/.test(line)));
  });
}

for (const field of ["sessionId", "sessionKey"]) {
  test(`missing finished ${field} refuses output even when the summary matches`, async () => {
    const setup = gateway();
    await setup.reconcile();
    const event = finished("briefing");
    await setup.output(...output(event, [event.summary]));
    delete event[field];

    await setup.changed(event);

    assert.equal(setup.sent.length, 0);
    assert.ok(setup.warnings.length > 0);
  });
}

for (const stopReason of [undefined, "error", "aborted"]) {
  test(`a provider retry replaces the ${stopReason ?? "earlier"} attempt with all final parts`, async () => {
    const setup = gateway();
    await setup.reconcile();
    const event = finished("briefing");
    const [attempt, context] = output(event, ["Partial output before the provider retry."]);
    if (stopReason) attempt.lastAssistant = { role: "assistant", stopReason };
    await setup.output(attempt, context);
    assert.deepEqual(setup.sent, []);

    await setup.output(...output(event, ["Complete replacement.", "Final paragraph."]));
    await Promise.all([setup.changed(event), setup.changed(event)]);
    await setup.output(...output(event, ["Complete replacement.", "Final paragraph."]));

    assert.deepEqual(setup.sent.map(({ text }) => text), ["Complete replacement.\n\nFinal paragraph."]);
  });
}

for (const [name, change] of [
  ["empty", (event) => { event.assistantTexts = ["  "]; }],
  ["malformed", (event) => { event.assistantTexts = [null]; }],
  ["error", (event) => { event.lastAssistant = { role: "assistant", stopReason: "error" }; }],
  ["aborted", (event) => { event.lastAssistant = { role: "assistant", stopReason: "aborted" }; }],
]) {
  test(`an ${name} final attempt never copies earlier or failed output`, async () => {
    const setup = gateway();
    await setup.reconcile();
    const event = finished("briefing");
    await setup.output(...output(event, ["Earlier attempt."]));
    const candidate = output(event, ["Earlier attempt."]);
    change(candidate[0]);

    await setup.output(...candidate);
    await setup.changed(event);

    assert.deepEqual(setup.sent, []);
  });
}

for (const [field, value] of [
  ["agentId", "another-agent"],
  ["jobId", "another-job"],
  ["channel", "discord"],
  ["chatId", GROUP],
  ["channelId", GROUP],
  ["accountId", "another-account"],
]) {
  test(`conflicting output ${field} stays ambiguous across provider retries`, async () => {
    const setup = gateway();
    await setup.reconcile();
    const event = finished("briefing");
    await setup.output(...output(event, ["First attempt."]));
    const [attempt, context] = output(event, ["Different attempt."]);
    context[field] = value;

    await setup.output(attempt, context);
    await setup.output(...output(event, ["Final attempt."]));
    await setup.changed(event);

    assert.equal(setup.sent.length, 0);
    assert.ok(setup.warnings.length > 0);
  });
}

// Issue #6: with Telegram off, every Telegram delivery fails, and the app is where the words go.
test("a run Telegram did not take is still copied to the app, once, even when its output arrives late", async () => {
  const setup = gateway();
  await setup.reconcile();
  const event = finished("briefing", { delivered: false, deliveryStatus: "not-delivered", deliveryError: "telegram channel is not running" });

  await setup.changed(event);
  await setup.output(...output(event));
  await setup.changed(event);

  assert.equal(setup.sent.length, 1);
  assert.equal(setup.sent[0].text, "Complete scheduled answer.");
});

test("a run that chose silence is never copied, whatever its delivery says", async () => {
  const setup = gateway();
  await setup.reconcile();
  const event = finished("briefing", { delivered: false, deliveryStatus: "not-delivered", deliverySuppressionReason: "silent" });

  await setup.changed(event);
  await setup.output(...output(event, ["NO_REPLY"]));

  assert.equal(setup.sent.length, 0);
});

test("explicit agent and job facts must agree across finished event and cached job", async () => {
  for (const overrides of [{ agentId: "wrong-agent" }, { job: { id: "another-job", agentId: "main" } }]) {
    const setup = gateway();
    await setup.reconcile();

    await setup.complete(finished("briefing", overrides));

    assert.equal(setup.sent.length, 0);
    assert.ok(setup.warnings.length > 0);
  }
});

for (const hook of ["output", "finished"]) {
  test(`conflicting ${hook} during adapter loading cancels the pending copy`, async () => {
    let releaseAdapter;
    const adapterReady = new Promise((resolve) => { releaseAdapter = resolve; });
    const sent = [];
    const setup = gateway({ loadAdapter: () => adapterReady });
    await setup.reconcile();
    const event = finished("briefing");
    await setup.output(...output(event, ["First output."]));

    const pendingCopy = setup.changed(event);
    if (hook === "output") await setup.output(...output(event, ["Conflicting output."]));
    else await setup.changed({ ...event, runId: "another-scheduler-execution" });
    releaseAdapter({ async sendText(params) { sent.push(params); } });
    await pendingCopy;

    assert.deepEqual(sent, []);
    assert.ok(setup.warnings.length > 0);
  });
}

test("scheduler read failures log metadata without exposing private error text", async () => {
  const setup = gateway();
  Object.defineProperty(setup.store, "jobs", { get() { throw new Error("Private configuration and chat contents"); } });

  await setup.reconcile();

  assert.equal(setup.warnings.length, 1);
  assert.doesNotMatch(setup.warnings[0], /Private configuration|chat contents/);
});

for (const isOutputLate of [false, true]) {
  test(`separate gateway and agent registrations correlate output with late output ${isOutputLate}`, async () => {
    const stateDirectory = randomUUID();
    const duplicateModule = await import(`../../deploy/openclaw/plugins/household-job-mirror/index.js?registration=${isOutputLate}`);
    const scheduler = gateway({ stateDirectory });
    const agent = gateway({ stateDirectory, definition: duplicateModule.default });
    const event = finished("briefing");
    await scheduler.reconcile();

    if (isOutputLate) await scheduler.changed(event);
    await agent.output(...output(event, ["Complete output across scoped plugin registrations."]));
    if (!isOutputLate) await scheduler.changed(event);
    await agent.changed(event);
    await scheduler.changed(event);

    assert.deepEqual([...scheduler.sent, ...agent.sent].map(({ text }) => text), [
      "Complete output across scoped plugin registrations.",
    ]);
  });
}

for (const isolation of ["gateway state directory", "target configuration"]) {
  test(`complete output cannot cross a different ${isolation}`, async () => {
    const stateDirectory = randomUUID();
    const source = gateway({ stateDirectory });
    const other = gateway({
      stateDirectory: isolation === "gateway state directory" ? randomUUID() : stateDirectory,
      config: isolation === "target configuration" ? { targets: { [OWNER]: "someone-else" } } : CONFIG,
    });
    await source.reconcile();
    await other.reconcile();
    const event = finished("briefing");

    await source.output(...output(event));
    await other.changed(event);

    assert.deepEqual(other.sent, []);
    assert.deepEqual(source.sent, []);
  });
}

for (const [field, value] of [
  ["channel", "discord"],
  ["chatId", GROUP],
  ["channelId", GROUP],
  ["accountId", "different-account"],
]) {
  test(`explicit output ${field} must match the mapped Telegram delivery`, async () => {
    const setup = gateway();
    await setup.reconcile();
    const event = finished("briefing");
    const [result, context] = output(event);
    Object.assign(context, { channel: "telegram", chatId: OWNER, channelId: OWNER, accountId: "default", [field]: value });

    await setup.output(result, context);
    await setup.changed(event);

    assert.deepEqual(setup.sent, []);
    assert.ok(setup.warnings.length > 0);
    assert.ok(setup.warnings.every((line) => !line.includes(OWNER) && !line.includes(GROUP)));
  });
}

test("a delivery target changed during the run cannot redirect the completed answer", async () => {
  const setup = gateway();
  await setup.reconcile();
  const event = finished("briefing");
  const [result, context] = output(event);
  Object.assign(context, { channel: "telegram", chatId: OWNER, channelId: OWNER });
  await setup.output(result, context);
  setup.store.jobs[0].delivery.to = GROUP;
  await setup.changed({ action: "updated", jobId: "briefing" });

  await setup.changed(event);

  assert.deepEqual(setup.sent, []);
  assert.ok(setup.warnings.length > 0);
});

test("matching explicit output routing permits the complete scheduled copy", async () => {
  const setup = gateway();
  await setup.reconcile();
  const event = finished("briefing");
  const [result, context] = output(event);
  Object.assign(context, { channel: "telegram", chatId: OWNER, channelId: OWNER, accountId: "default" });

  await setup.output(result, context);
  await setup.changed(event);

  assert.deepEqual(setup.sent.map(({ to, text }) => ({ to, text })), [{
    to: "household:sam", text: "Complete scheduled answer.",
  }]);
});
