// The assistant's one line for the day above the pins on Chats, from
// deploy/openclaw/plugins/household-app/brief.js: the household_brief tool it writes it
// with, the turns it is offered in, household-app.brief's answers across a day change,
// and the event that tells the phones.
//
// Run with `node --test tests/js/household_app_brief.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { BRIEF_TOOL, MAX_BRIEF_CHARACTERS, createBrief, createBriefTool } from "../../deploy/openclaw/plugins/household-app/brief.js";
import { openSettingsStore } from "../../deploy/openclaw/plugins/household-app/settings-store.js";
import { stubChannelSdk } from "./fixtures/openclaw-channel-sdk.mjs";

const PLUGIN = new URL("../../deploy/openclaw/plugins/household-app/", import.meta.url);
// Local times, so the day is the gateway's whatever zone the test runs in.
const MORNING = new Date(2026, 9, 15, 6, 30).getTime();
const LATE = new Date(2026, 9, 15, 23, 59).getTime();
const MIDNIGHT = new Date(2026, 9, 16, 0, 0).getTime();
const FRANCO_TELEGRAM = "7100000001";
const GIA_TELEGRAM = "7100000002";
const OWNERS = ["household:franco"];

async function setup() {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-brief-"));
  const store = openSettingsStore(path.join(directory, "settings.sqlite"));
  const clock = { now: MORNING };
  const told = [];
  const brief = createBrief({ store, now: () => clock.now, changed: (written) => told.push(written) });
  return { brief, store, clock, told };
}

// MARK: - What is kept, and what the method answers

test("the brief written this morning is today's, with its day and the time it was written", async () => {
  const { brief } = await setup();
  const written = brief.write("Gia lands at 4:10. Soccer pickup at 5:45.");
  assert.deepEqual(written, { text: "Gia lands at 4:10. Soccer pickup at 5:45.", day: "2026-10-15", at: MORNING });
  assert.deepEqual(brief.today(), written);
});

test("there is no brief until one is written", async () => {
  const { brief } = await setup();
  assert.equal(brief.today(), null);
});

test("a new brief replaces today's, and only one is kept", async () => {
  const { brief, clock, store } = await setup();
  brief.write("Dentist at 3:30.");
  clock.now = MORNING + 3_600_000;
  brief.write("Dentist moved to 4:00.");
  assert.deepEqual(brief.today(), { text: "Dentist moved to 4:00.", day: "2026-10-15", at: MORNING + 3_600_000 });
  assert.equal(store.value("brief"), JSON.stringify(brief.today()));
});

test("the day's brief lasts until midnight, and after it there is none until the next is written", async () => {
  const { brief, clock } = await setup();
  brief.write("Soccer pickup at 5:45.");
  clock.now = LATE;
  assert.equal(brief.today()?.text, "Soccer pickup at 5:45.", "still today a minute before midnight");
  clock.now = MIDNIGHT;
  assert.equal(brief.today(), null, "yesterday's is not today's");
  brief.write("Book club at 7.");
  assert.deepEqual(brief.today(), { text: "Book club at 7.", day: "2026-10-16", at: MIDNIGHT });
});

test("a brief written just before midnight belongs to the day it was written on", async () => {
  const { brief, clock } = await setup();
  clock.now = LATE;
  assert.equal(brief.write("Bins out tonight.").day, "2026-10-15");
});

test("each new brief is handed on to tell the phones, the same as the method answers", async () => {
  const { brief, told } = await setup();
  const written = brief.write("Dentist at 3:30.");
  assert.deepEqual(told, [written]);
});

// MARK: - The tool's limits

const OWN_THREAD = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  requesterSenderId: "franco",
  nativeChannelId: "franco",
  sessionKey: "agent:main:household:direct:franco",
  deliveryContext: { channel: "household", accountId: "default", to: "household:franco" },
};
const FAMILY_ROOM = {
  ...OWN_THREAD,
  requesterSenderId: "gia",
  nativeChannelId: "family",
  sessionKey: "agent:main:household:group:family",
  deliveryContext: { channel: "household", accountId: "default", to: "household:family" },
};
// The owner's family-room turn, which runs in the owner's own session of the room.
const OWNERS_FAMILY_TURN = { ...FAMILY_ROOM, requesterSenderId: "franco", sessionKey: "agent:main:household:group:family:sender:franco" };
const OWNERS_TELEGRAM = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "telegram",
  requesterSenderId: FRANCO_TELEGRAM,
  nativeChannelId: FRANCO_TELEGRAM,
  sessionKey: `agent:main:telegram:direct:${FRANCO_TELEGRAM}`,
  deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${FRANCO_TELEGRAM}` },
};
const THE_FAM = {
  ...OWNERS_TELEGRAM,
  nativeChannelId: "-5100000001",
  sessionKey: "agent:main:telegram:group:-5100000001",
  deliveryContext: { channel: "telegram", accountId: "default", to: "telegram:-5100000001" },
};
// An isolated scheduled run of the main agent names no sender.
const SCHEDULED_RUN = { agentId: "main", sessionKey: "agent:main:cron:6f1c2a:run:91b0" };

function toolFor(context, brief) {
  return createBriefTool({ context, owner: "franco", write: (text) => brief.write(text) });
}

async function answer(found, args) {
  const result = await found.execute("call-1", args);
  return { isError: result.isError === true, payload: JSON.parse(result.content[0].text) };
}

test("the tool keeps the brief it is given, trimmed, and answers it", async () => {
  const { brief } = await setup();
  const { isError, payload } = await answer(toolFor(OWN_THREAD, brief), { text: "  Gia lands at 4:10.  " });
  assert.equal(isError, false);
  assert.deepEqual(payload, { brief: { text: "Gia lands at 4:10.", day: "2026-10-15", at: MORNING } });
  assert.deepEqual(brief.today(), payload.brief);
});

test("a brief of exactly 140 characters is kept, counting an emoji as one", async () => {
  const { brief } = await setup();
  const longest = `${"a".repeat(MAX_BRIEF_CHARACTERS - 1)}🦉`;
  assert.equal(MAX_BRIEF_CHARACTERS, 140);
  const { isError } = await answer(toolFor(OWN_THREAD, brief), { text: longest });
  assert.equal(isError, false);
  assert.equal(brief.today().text, longest);
});

for (const [label, args] of [
  ["nothing", {}],
  ["no arguments at all", undefined],
  ["empty words", { text: "" }],
  ["only spaces", { text: "   " }],
  ["141 characters", { text: "a".repeat(141) }],
  ["two lines", { text: "Gia lands at 4:10.\nSoccer pickup at 5:45." }],
  ["a tab", { text: "Gia lands\tat 4:10." }],
  ["a line separator", { text: `Gia lands at 4:10.${String.fromCharCode(0x2028)}Soccer at 5:45.` }],
  ["a number", { text: 410 }],
  ["null", { text: null }],
  ["a field beside the words", { text: "Soccer at 5:45.", day: "2026-10-16" }],
]) {
  test(`the tool refuses ${label}, keeps the brief before it and tells nobody`, async () => {
    const { brief, told } = await setup();
    brief.write("Dentist at 3:30.");
    const { isError, payload } = await answer(toolFor(OWN_THREAD, brief), args);
    assert.equal(isError, true);
    assert.equal(payload.code, "invalid_arguments");
    assert.match(payload.message, /140/);
    assert.equal(brief.today().text, "Dentist at 3:30.");
    assert.equal(told.length, 1);
  });
}

test("the tool asks for the words alone and says what they are for", async () => {
  const { brief } = await setup();
  const found = toolFor(OWN_THREAD, brief);
  assert.equal(found.name, BRIEF_TOOL);
  assert.equal(BRIEF_TOOL, "household_brief");
  assert.deepEqual(found.parameters.required, ["text"]);
  assert.deepEqual(Object.keys(found.parameters.properties), ["text"]);
  assert.equal(found.parameters.properties.text.maxLength, 140);
  assert.equal(found.parameters.additionalProperties, false);
  assert.match(found.description, /140 characters/);
  assert.match(found.description, /plain text/i);
  assert.match(found.description, /messages nobody/i);
});

// MARK: - Where it is offered

test("the tool is offered in the owner's own turns in the app and a scheduled run", async () => {
  const { brief } = await setup();
  for (const [label, turn] of [
    ["the owner's own thread in the app", OWN_THREAD],
    ["a queued turn in the owner's thread with no native chat", { ...OWN_THREAD, nativeChannelId: undefined }],
    ["the family room, the owner speaking, in the owner's own session of it", OWNERS_FAMILY_TURN],
    ["a scheduled run of the main agent", SCHEDULED_RUN],
    ["a scheduled run by its job's own session", { ...SCHEDULED_RUN, sessionKey: "agent:main:cron:6f1c2a" }],
    ["a scheduled run on the default account", { ...SCHEDULED_RUN, agentAccountId: "default" }],
  ]) {
    assert.equal(toolFor(turn, brief)?.name, BRIEF_TOOL, label);
  }
});

test("the tool is not offered in anyone else's family-room turn, on Telegram or in any turn that is not the main agent's own", async () => {
  const { brief } = await setup();
  for (const [label, turn] of [
    ["the family room, the other person speaking", FAMILY_ROOM],
    ["the family room, the other assistant handing over", { ...FAMILY_ROOM, requesterSenderId: "denise" }],
    ["the owner in the room's shared session", { ...FAMILY_ROOM, requesterSenderId: "franco" }],
    ["the other person in the owner's own session of the room", { ...OWNERS_FAMILY_TURN, requesterSenderId: "gia" }],
    ["The Fam on Telegram, the owner speaking", THE_FAM],
    ["The Fam on Telegram, the other person speaking", { ...THE_FAM, requesterSenderId: GIA_TELEGRAM }],
    ["the other person's private chat with this assistant", {
      ...OWNERS_TELEGRAM, requesterSenderId: GIA_TELEGRAM, nativeChannelId: GIA_TELEGRAM,
      sessionKey: `agent:main:telegram:direct:${GIA_TELEGRAM}`,
      deliveryContext: { ...OWNERS_TELEGRAM.deliveryContext, to: `telegram:${GIA_TELEGRAM}` },
    }],
    ["the owner's private chat on Telegram, which the household retired", OWNERS_TELEGRAM],
    ["a queued Telegram turn with no native chat", { ...OWNERS_TELEGRAM, nativeChannelId: undefined }],
    ["someone else in the owner's Telegram chat", { ...OWNERS_TELEGRAM, requesterSenderId: GIA_TELEGRAM }],
    ["the owner's Telegram id in a shared session", { ...OWNERS_TELEGRAM, sessionKey: "agent:main:main" }],
    ["a Telegram topic", { ...OWNERS_TELEGRAM, deliveryContext: { ...OWNERS_TELEGRAM.deliveryContext, threadId: 7 } }],
    ["a second Telegram bot", { ...OWNERS_TELEGRAM, deliveryContext: { ...OWNERS_TELEGRAM.deliveryContext, accountId: "second" } }],
    ["a Telegram native chat that is not the route's", { ...OWNERS_TELEGRAM, nativeChannelId: GIA_TELEGRAM }],
    ["the other person's own thread in the app", {
      ...OWN_THREAD, requesterSenderId: "gia", nativeChannelId: "gia", sessionKey: "agent:main:household:direct:gia",
      deliveryContext: { ...OWN_THREAD.deliveryContext, to: "household:gia" },
    }],
    ["chat.send from the phone's own connection", { ...OWN_THREAD, requesterSenderId: "openclaw-ios" }],
    ["chat.send from web chat", { ...OWN_THREAD, messageChannel: "webchat", requesterSenderId: "webchat-ui" }],
    ["a scheduled run that names a sender", { ...SCHEDULED_RUN, requesterSenderId: GIA_TELEGRAM }],
    ["another agent's scheduled run", { ...SCHEDULED_RUN, agentId: "other", sessionKey: "agent:other:cron:6f1c2a" }],
    ["a scheduled run on another account", { ...SCHEDULED_RUN, agentAccountId: "second" }],
    ["a session dressed as a scheduled run", { ...SCHEDULED_RUN, sessionKey: "agent:main:cron:6f1c2a:telegram:group:-5100000001" }],
    ["the shared main session", { agentId: "main", sessionKey: "agent:main:main" }],
    ["a sub-agent", { agentId: "main", sessionKey: "agent:main:subagent:brief" }],
    ["a one-shot command line run", { ...SCHEDULED_RUN, oneShotCliRun: true }],
    ["a one-shot run in the owner's thread", { ...OWN_THREAD, oneShotCliRun: true }],
    ["no context at all", undefined],
  ]) {
    assert.equal(toolFor(turn, brief), null, label);
  }
});

test("the plugin's manifest declares the tool, which OpenClaw requires of every registered tool", () => {
  const manifest = JSON.parse(readFileSync(new URL("openclaw.plugin.json", PLUGIN), "utf8"));
  assert.ok(manifest.contracts.tools.includes(BRIEF_TOOL));
  assert.deepEqual(manifest.toolMetadata[BRIEF_TOOL], { optional: true, replaySafe: true, sideEffecting: true });
});

// MARK: - Through the plugin

// The plugin as the gateway registers it, with its own store in a throwaway state
// directory and its event service started.
async function registered(config) {
  stubChannelSdk(fileURLToPath(new URL("index.js", PLUGIN)));
  const { default: entry, PLUGIN_ID } = await import(new URL("index.js", PLUGIN));
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-brief-plugin-"));
  const tools = [];
  const methods = new Map();
  const services = [];
  const events = [];
  entry.setRuntime({
    config: { current: () => config },
    state: { resolveStateDir: () => directory },
    events: { onSessionTranscriptUpdate: () => () => {} },
  });
  const api = new Proxy(
    {
      registerTool: (factory, options) => tools.push({ factory, options }),
      registerGatewayMethod: (name, handler, options) => methods.set(name, { handler, options }),
      registerService: (service) => services.push(service),
      session: { workflow: {} },
      logger: {},
    },
    { get: (target, key) => (key in target ? target[key] : () => {}) },
  );
  entry.registerFull(api);
  const service = services.find((one) => one.id === `${PLUGIN_ID}-events`);
  service.start({ gatewayEvents: { emit: (name, payload, options) => events.push({ name, payload, options }) } });
  const briefTool = tools.find((one) => one.options.names?.includes(BRIEF_TOOL));
  return {
    PLUGIN_ID,
    briefTool,
    methods,
    events,
    async stop() {
      service.stop();
      await rm(directory, { recursive: true, force: true });
    },
  };
}

const ON_THE_BOX = {
  commands: { ownerAllowFrom: OWNERS },
  channels: {
    household: {
      owner: { id: "franco", name: "Franco" },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};

test("a brief the assistant writes reaches the phones that follow as an event, with no pull", async () => {
  const plugin = await registered(ON_THE_BOX);
  try {
    assert.deepEqual(plugin.briefTool.options, { names: [BRIEF_TOOL], optional: true });
    const found = plugin.briefTool.factory(OWN_THREAD);
    const { payload } = await answer(found, { text: "Gia lands at 4:10. Soccer pickup at 5:45." });
    assert.deepEqual(plugin.events, [
      { name: "brief", payload: { brief: payload.brief }, options: { scope: "operator.read" } },
    ]);
    assert.equal(payload.brief.text, "Gia lands at 4:10. Soccer pickup at 5:45.");
  } finally {
    await plugin.stop();
  }
});

test("the plugin offers nothing in the family room, and nothing before the channel names its owner", async () => {
  const plugin = await registered(ON_THE_BOX);
  try {
    assert.equal(plugin.briefTool.factory(FAMILY_ROOM), null);
    assert.equal(plugin.briefTool.factory(THE_FAM), null);
  } finally {
    await plugin.stop();
  }
  const unnamed = await registered({ commands: { ownerAllowFrom: OWNERS } });
  try {
    assert.equal(unnamed.briefTool.factory(OWNERS_TELEGRAM), null);
  } finally {
    await unnamed.stop();
  }
});

test("the phone reads today's brief with operator.read", async () => {
  const plugin = await registered(ON_THE_BOX);
  try {
    const method = plugin.methods.get(`${plugin.PLUGIN_ID}.brief`);
    assert.deepEqual(method.options, { scope: "operator.read" });
    // With the channel stopped it says so, as every other method does.
    const answers = [];
    await method.handler({ params: {}, respond: (...parts) => answers.push(parts), client: {} });
    assert.deepEqual(answers, [[false, undefined, { code: "UNAVAILABLE", message: "the household app channel is not running" }]]);
  } finally {
    await plugin.stop();
  }
});
