// The assistant's day at a glance above the pins on Chats, from
// deploy/openclaw/plugins/household-app/today.js: the household_today tool it writes it with,
// what is kept and how a later card keeps the morning's verse, the brief written beside it
// for the phones from before the card, the turns it is offered in, and the event and method
// that bring it to the phones.
//
// Run with `node --test tests/js/household_app_today.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { BRIEF_TOOL, MAX_BRIEF_CHARACTERS, createBrief } from "../../deploy/openclaw/plugins/household-app/brief.js";
import { openSettingsStore } from "../../deploy/openclaw/plugins/household-app/settings-store.js";
import {
  MOST_ITEMS,
  TODAY_TOOL,
  createToday,
  createTodayTool,
} from "../../deploy/openclaw/plugins/household-app/today.js";
import { stubChannelSdk } from "./fixtures/openclaw-channel-sdk.mjs";

const PLUGIN = new URL("../../deploy/openclaw/plugins/household-app/", import.meta.url);
// Local times, so the day is the gateway's whatever zone the test runs in.
const MORNING = new Date(2026, 9, 15, 6, 45).getTime();
const EVENING = new Date(2026, 9, 15, 16, 45).getTime();
const NEXT_MORNING = new Date(2026, 9, 16, 6, 45).getTime();
const FRANCO_TELEGRAM = "7100000001";
const OWNERS = ["household:franco"];
const VERSE = {
  text: "Be still, and know that I am God.",
  reference: "Psalm 46:10",
  link: "https://www.bible.com/bible/3034/PSA.46.10.BSB",
};

const pad = (number) => String(Math.abs(number)).padStart(2, "0");

// 15 or 16 October 2026 at `hour`:`minute` on the gateway's clock, with its offset, as the
// assistant writes a start.
function at(day, hour, minute = 0, { seconds = true } = {}) {
  const offset = -new Date(2026, 9, day, hour, minute).getTimezoneOffset();
  const zone = `${offset >= 0 ? "+" : "-"}${pad(Math.trunc(offset / 60))}:${pad(offset % 60)}`;
  return `2026-10-${pad(day)}T${pad(hour)}:${pad(minute)}${seconds ? ":00" : ""}${zone}`;
}

const DAY = [
  { start: at(15, 7, 45), title: "School drop off", detail: "Leave by 7:30, the roads are light" },
  { start: at(15, 9), title: "Dentist" },
  { start: at(15, 12, 30), title: "Lunch with Gia" },
  { start: at(16, 8), title: "Soccer" },
];

async function setup() {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-today-"));
  const store = openSettingsStore(path.join(directory, "settings.sqlite"));
  const clock = { now: MORNING };
  const told = [];
  const brief = createBrief({ store, now: () => clock.now });
  const today = createToday({ store, brief, now: () => clock.now, changed: (written) => told.push(written) });
  return { today, brief, store, clock, told };
}

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

function toolFor(context, today) {
  return createTodayTool({ context, owner: "franco", write: (card) => today.write(card) });
}

async function answer(found, args) {
  const result = await found.execute("call-1", args);
  return { isError: result.isError === true, payload: JSON.parse(result.content[0].text) };
}

// MARK: - What is kept

test("the card is kept as the latest, its things the soonest first, each start with its seconds", async () => {
  const { today } = await setup();
  const given = [DAY[2], { ...DAY[0], start: at(15, 7, 45, { seconds: false }) }, DAY[3], DAY[1]];
  const { isError, payload } = await answer(toolFor(OWN_THREAD, today), { items: given, verse: VERSE });
  assert.equal(isError, false);
  assert.deepEqual(payload.today, { day: "2026-10-15", at: MORNING, items: DAY, verse: VERSE });
  assert.deepEqual(today.latest(), payload.today);
});

test("there is no card until one is written", async () => {
  const { today } = await setup();
  assert.equal(today.latest(), null);
});

test("the evening's card keeps the morning's verse, and the next morning's starts without it", async () => {
  const { today, clock } = await setup();
  today.write({ items: DAY, verse: VERSE });
  clock.now = EVENING;
  assert.deepEqual(today.write({ items: [DAY[3]] }).verse, VERSE);
  clock.now = NEXT_MORNING;
  assert.equal("verse" in today.write({ items: [DAY[3]] }), false, "yesterday's verse is not today's");
});

test("a card that brings its own verse replaces the morning's", async () => {
  const { today, clock } = await setup();
  today.write({ items: DAY, verse: VERSE });
  clock.now = EVENING;
  const other = { ...VERSE, text: "This is the day the Lord has made.", reference: "Psalm 118:24" };
  assert.deepEqual(today.write({ items: [DAY[3]], verse: other }).verse, other);
});

test("each card is handed on to tell the phones", async () => {
  const { today, told } = await setup();
  const written = today.write({ items: DAY, verse: VERSE });
  assert.deepEqual(told, [written]);
});

// MARK: - The brief beside it, for the phones from before the card

test("each card writes today's brief from the first two things still ahead today", async () => {
  const { today, brief } = await setup();
  today.write({ items: DAY, verse: VERSE });
  assert.equal(brief.today().text, "School drop off at 7:45. Dentist at 9:00.");
});

test("the brief leaves out what has gone by and what is tomorrow's", async () => {
  const { today, brief, clock } = await setup();
  clock.now = new Date(2026, 9, 15, 12, 0).getTime();
  today.write({ items: DAY });
  assert.equal(brief.today().text, "Lunch with Gia at 12:30.");
  clock.now = EVENING;
  today.write({ items: [DAY[3]] });
  assert.equal(brief.today().text, "Nothing else planned today.");
});

test("the brief names something all day without a time, and keeps to one thing when two are too long", async () => {
  const { today, brief } = await setup();
  today.write({ items: [{ start: at(15, 0), title: "Trash day", allDay: true }, DAY[1]] });
  assert.equal(brief.today().text, "Trash day. Dentist at 9:00.");
  const long = "a".repeat(60);
  today.write({ items: [{ start: at(15, 8), title: long }, { start: at(15, 9), title: `${long}bb` }] });
  assert.ok([...brief.today().text].length <= MAX_BRIEF_CHARACTERS);
  assert.equal(brief.today().text, `${long} at 8:00.`);
});

// MARK: - The tool's limits

const VALID = { items: DAY, verse: VERSE };
const tooMany = Array.from({ length: MOST_ITEMS + 1 }, (_, index) => ({ start: at(15, 8, index), title: `Thing ${index}` }));

for (const [label, args] of [
  ["neither things nor a verse", {}],
  ["no arguments at all", undefined],
  [`${MOST_ITEMS + 1} things`, { items: tooMany }],
  ["things that are not a list", { items: "Dentist at 9" }],
  ["a thing with no start", { items: [{ title: "Dentist" }] }],
  ["a start that is no time", { items: [{ start: "tomorrow at 8", title: "Soccer" }] }],
  ["a start with no offset", { items: [{ start: "2026-10-15T09:00:00", title: "Dentist" }] }],
  ["a start on a day that is not one", { items: [{ start: "2026-13-40T09:00:00-05:00", title: "Dentist" }] }],
  ["a title of 61 characters", { items: [{ start: at(15, 9), title: "a".repeat(61) }] }],
  ["a title on two lines", { items: [{ start: at(15, 9), title: "Dentist\nCheck up" }] }],
  ["an empty title", { items: [{ start: at(15, 9), title: "  " }] }],
  ["a detail of 91 characters", { items: [{ start: at(15, 9), title: "Dentist", detail: "a".repeat(91) }] }],
  ["all day as a word", { items: [{ start: at(15, 9), title: "Dentist", allDay: "yes" }] }],
  ["a field on a thing beside its own", { items: [{ start: at(15, 9), title: "Dentist", where: "Main St" }] }],
  ["a verse whose link is not the Bible app's", { items: DAY, verse: { ...VERSE, link: "https://example.com/PSA.46.10" } }],
  ["a verse with no link", { items: DAY, verse: { text: VERSE.text, reference: VERSE.reference } }],
  ["a verse of 241 characters", { items: DAY, verse: { ...VERSE, text: "a".repeat(241) } }],
  ["a field beside the things and the verse", { ...VALID, day: "2026-10-16" }],
]) {
  test(`the tool refuses ${label}, keeps the card before it and tells nobody`, async () => {
    const { today, told } = await setup();
    today.write(VALID);
    const { isError, payload } = await answer(toolFor(OWN_THREAD, today), args);
    assert.equal(isError, true);
    assert.equal(payload.code, "invalid_arguments");
    assert.match(payload.message, /ISO 8601/);
    assert.deepEqual(today.latest().items, DAY);
    assert.equal(told.length, 1);
  });
}

test("a verse alone, with nothing left ahead, is a card", async () => {
  const { today } = await setup();
  const { isError, payload } = await answer(toolFor(OWN_THREAD, today), { verse: VERSE });
  assert.equal(isError, false);
  assert.deepEqual(payload.today.items, []);
});

test("the tool says what the card is, its limits, and whose day it may draw on", async () => {
  const { today } = await setup();
  const found = toolFor(OWN_THREAD, today);
  assert.equal(found.name, TODAY_TOOL);
  assert.equal(TODAY_TOOL, "household_today");
  assert.deepEqual(Object.keys(found.parameters.properties), ["items", "verse"]);
  assert.equal(found.parameters.properties.items.maxItems, MOST_ITEMS);
  assert.equal(found.parameters.additionalProperties, false);
  assert.match(found.description, /share with you in Steward/);
  assert.match(found.description, /another person's plans only/);
  assert.match(found.description, /Bible app/);
  assert.match(found.description, /messages nobody/i);
  assert.doesNotMatch(found.description, /;/);
});

// MARK: - Where it is offered

test("the tool is offered where the brief is, and not in the family room or on Telegram", async () => {
  const { today } = await setup();
  for (const [label, turn] of [
    ["the owner's own thread in the app", OWN_THREAD],
    ["a scheduled run of the main agent", SCHEDULED_RUN],
  ]) {
    assert.equal(toolFor(turn, today)?.name, TODAY_TOOL, label);
  }
  for (const [label, turn] of [
    ["the family room", FAMILY_ROOM],
    ["The Fam on Telegram", THE_FAM],
    ["the owner's private chat on Telegram, which the household retired", OWNERS_TELEGRAM],
    ["a sub-agent", { agentId: "main", sessionKey: "agent:main:subagent:today" }],
    ["no context at all", undefined],
  ]) {
    assert.equal(toolFor(turn, today), null, label);
  }
});

test("the plugin's manifest declares the tool, which OpenClaw requires of every registered tool", () => {
  const manifest = JSON.parse(readFileSync(new URL("openclaw.plugin.json", PLUGIN), "utf8"));
  assert.ok(manifest.contracts.tools.includes(TODAY_TOOL));
  assert.deepEqual(manifest.toolMetadata[TODAY_TOOL], { optional: true, replaySafe: true, sideEffecting: true });
});

// MARK: - Through the plugin

// The plugin as the gateway registers it, with its own store in a throwaway state
// directory and its event service started.
async function registered(config) {
  stubChannelSdk(fileURLToPath(new URL("index.js", PLUGIN)));
  const { default: entry, PLUGIN_ID } = await import(new URL("index.js", PLUGIN));
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-today-plugin-"));
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
  return {
    PLUGIN_ID,
    todayTool: tools.find((one) => one.options.names?.includes(TODAY_TOOL)),
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

test("a card the assistant writes reaches the phones as an event, its brief beside it for the older ones", async () => {
  const plugin = await registered(ON_THE_BOX);
  try {
    assert.deepEqual(plugin.todayTool.options, { names: [TODAY_TOOL], optional: true });
    const { payload } = await answer(plugin.todayTool.factory(SCHEDULED_RUN), VALID);
    assert.deepEqual(plugin.events.map((event) => event.name), ["brief", "today"]);
    assert.deepEqual(plugin.events[1], { name: "today", payload: { today: payload.today }, options: { scope: "operator.read" } });
    assert.equal(typeof plugin.events[0].payload.brief.text, "string");
    assert.equal(plugin.todayTool.factory(FAMILY_ROOM), null);
    assert.equal(BRIEF_TOOL, "household_brief");
  } finally {
    await plugin.stop();
  }
});

test("the phone reads the card with operator.read", async () => {
  const plugin = await registered(ON_THE_BOX);
  try {
    const method = plugin.methods.get(`${plugin.PLUGIN_ID}.today`);
    assert.deepEqual(method.options, { scope: "operator.read" });
    // With the channel stopped it says so, as every other method does.
    const answers = [];
    await method.handler({ params: {}, respond: (...parts) => answers.push(parts), client: {} });
    assert.deepEqual(answers, [[false, undefined, { code: "UNAVAILABLE", message: "the household app channel is not running" }]]);
  } finally {
    await plugin.stop();
  }
});
