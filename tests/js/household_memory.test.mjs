// What a family member asks an assistant to keep, and finding older chats, as the
// household-memory OpenClaw plugin does it. tests/test_household_plugins.py runs this
// file under pytest.

import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";

import plugin, {
  backfillKept,
  isKeepRequest,
  isRecallQuestion,
  parseConfig,
} from "../../deploy/openclaw/plugins/household-memory/index.js";

// Everyone by their household person id, as the app's channel names them.
const OWNER = "sam";
const SPOUSE = "alex";
const STRANGER = "pat";
const CONFIG = { ownerPersonId: OWNER, people: { [OWNER]: "Sam", [SPOUSE]: "Alex" } };
const FAMILY_SESSION = "agent:main:household:group:family";
// The owner's family-room turns run in the owner's own session of the room.
const OWNERS_FAMILY_SESSION = "agent:main:household:group:family:sender:sam";
const PRIVATE_SESSION = "agent:main:household:direct:sam";
// What the plugin's config held while the family used Telegram, and its sessions then.
const OWNER_TELEGRAM = "7000000001";
const SPOUSE_TELEGRAM = "7000000003";
const TELEGRAM_GROUP = "-7000000002";
const TELEGRAM_CONFIG = {
  groupChatId: TELEGRAM_GROUP,
  ownerTelegramId: OWNER_TELEGRAM,
  people: { [OWNER_TELEGRAM]: "Sam", [SPOUSE_TELEGRAM]: "Alex" },
  appPeople: { [OWNER_TELEGRAM]: OWNER, [SPOUSE_TELEGRAM]: SPOUSE },
};
const START = Date.UTC(2026, 9, 14, 3, 0);
const DAY = 86_400_000;
const MANIFEST = JSON.parse(
  await readFile(new URL("../../deploy/openclaw/plugins/household-memory/openclaw.plugin.json", import.meta.url), "utf8"),
);

const SCHEMA = `
  CREATE TABLE conversations (
    conversation_id TEXT PRIMARY KEY, channel TEXT NOT NULL, account_id TEXT NOT NULL,
    kind TEXT NOT NULL, peer_id TEXT NOT NULL, thread_id TEXT
  );
  CREATE TABLE session_conversations (
    session_id TEXT NOT NULL, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
    PRIMARY KEY (session_id, conversation_id, role)
  );
  CREATE TABLE session_windows (session_id TEXT PRIMARY KEY, session_key TEXT NOT NULL);
  CREATE VIRTUAL TABLE session_transcript_fts USING fts5(
    text, session_id UNINDEXED, message_id UNINDEXED, role UNINDEXED, timestamp UNINDEXED,
    tokenize = 'unicode61 remove_diacritics 2'
  );
`;

function capture(config) {
  const registered = { hooks: [], tools: [] };
  const errors = [];
  plugin.register({
    pluginConfig: config,
    logger: { info() {}, warn() {}, error: (message) => errors.push(message) },
    runtime: { state: { resolveStateDir: () => tmpdir() } },
    on: (name, handler) => registered.hooks.push({ name, handler }),
    registerHook() {},
    registerTool: (factory, options) => registered.tools.push({ factory, options }),
  });
  return { registered, errors };
}

async function gateway(context, { config = CONFIG, chats = [] } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-memory-"));
  context.after(async () => { await rm(directory, { recursive: true, force: true }); });
  const databasePath = path.join(directory, "agents", "main", "agent", "openclaw-agent.sqlite");
  await mkdir(path.dirname(databasePath), { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec(SCHEMA);
  const conversation = database.prepare("INSERT INTO conversations VALUES (?, ?, ?, ?, ?, ?)");
  conversation.run("family", "household", "default", "group", "family", null);
  conversation.run("owner", "household", "default", "direct", OWNER, null);
  conversation.run("spouse", "household", "default", "direct", SPOUSE, null);
  conversation.run("other-room", "household", "default", "group", "other", null);
  // What the gateway's database still holds from Telegram.
  conversation.run("telegram-family", "telegram", "default", "group", TELEGRAM_GROUP, null);
  conversation.run("telegram-owner", "telegram", "default", "direct", OWNER_TELEGRAM, null);
  const link = database.prepare("INSERT INTO session_conversations VALUES (?, ?, 'primary')");
  link.run("family-session", "family");
  link.run("private-session", "owner");
  link.run("spouse-session", "spouse");
  link.run("other-room-session", "other-room");
  link.run("telegram-family-session", "telegram-family");
  link.run("telegram-private-session", "telegram-owner");
  // The owner's own session of the family room, linked to the room as OpenClaw links any
  // turn whose conversation is the room.
  link.run("owners-family-session", "family");
  const windows = database.prepare("INSERT INTO session_windows VALUES (?, ?)");
  windows.run("family-session", FAMILY_SESSION);
  windows.run("owners-family-session", OWNERS_FAMILY_SESSION);
  const line = database.prepare("INSERT INTO session_transcript_fts VALUES (?, ?, ?, ?, ?)");
  chats.forEach(([session, role, text, at], index) => line.run(text, session, `m${index}`, role, at));
  database.close();

  const clock = { now: START };
  const registered = { hooks: [], tools: [] };
  const errors = [];
  const api = {
    pluginConfig: config,
    logger: { info() {}, warn() {}, error: (message) => errors.push(message) },
    runtime: { state: { resolveStateDir: () => directory } },
    on: (name, handler) => registered.hooks.push({ name, handler }),
    registerHook() {},
    registerTool: (factory, options) => registered.tools.push({ factory, options }),
  };
  plugin.register(api, { now: () => clock.now });

  async function turn(prompt, ctx = {}) {
    const build = registered.hooks.find((hook) => hook.name === "before_prompt_build");
    assert.ok(build, "before_prompt_build must be registered");
    return build.handler({ prompt, messages: [] }, { trigger: "user", sessionKey: PRIVATE_SESSION, senderId: OWNER, ...ctx });
  }
  function tools(sessionKey = PRIVATE_SESSION, requesterSenderId = OWNER) {
    return Object.fromEntries(registered.tools.flatMap(({ factory }) => {
      const tool = factory({ sessionKey, requesterSenderId, agentId: "main" });
      return tool ? [[tool.name, tool]] : [];
    }));
  }
  async function stored() {
    return JSON.parse(await readFile(path.join(directory, "household-memory", "kept.json"), "utf8"));
  }
  async function store(records) {
    await mkdir(path.join(directory, "household-memory"), { recursive: true });
    await writeFile(path.join(directory, "household-memory", "kept.json"), JSON.stringify(records));
  }
  function again() {
    const fresh = { hooks: [], tools: [] };
    plugin.register({
      ...api,
      on: (name, handler) => fresh.hooks.push({ name, handler }),
      registerTool: (factory, options) => fresh.tools.push({ factory, options }),
    }, { now: () => clock.now });
    const build = fresh.hooks.find((hook) => hook.name === "before_prompt_build");
    return (prompt, ctx = {}) =>
      build.handler({ prompt, messages: [] }, { trigger: "user", sessionKey: PRIVATE_SESSION, senderId: OWNER, ...ctx });
  }
  return { api, clock, directory, errors, registered, turn, tools, stored, store, again };
}

async function call(tool, args) {
  const result = await tool.execute("call-1", args);
  return { ...result, payload: JSON.parse(result.content[0].text) };
}

test("the manifest declares exactly the tools the plugin registers", async (context) => {
  const setup = await gateway(context);
  const names = setup.registered.tools.map(({ options }) => options.names).flat().sort();
  assert.deepEqual(names, [...MANIFEST.contracts.tools].sort());
  assert.deepEqual(names, ["forget", "recall"]);
});

test("the config is refused unless the owner and the people are household person ids and plain names", () => {
  assert.deepEqual(parseConfig(CONFIG).value, CONFIG);
  for (const broken of [
    {},
    [],
    { ...CONFIG, ownerPersonId: "Sam" },
    { ...CONFIG, ownerPersonId: OWNER_TELEGRAM },
    { ...CONFIG, people: { [SPOUSE]: "Alex" } },
    { ...CONFIG, people: { [OWNER]: "" } },
    { ...CONFIG, people: { [OWNER]: "Sam", [SPOUSE_TELEGRAM]: "Alex" } },
    { ...CONFIG, people: [] },
    { ownerPersonId: "constructor", people: { [OWNER]: "Sam" } },
    { ...CONFIG, extra: true },
  ]) {
    assert.ok(parseConfig(broken).error, JSON.stringify(broken));
  }
});

test("a config that still names Telegram is refused with a line that says what to run, and nothing starts", () => {
  for (const old of [
    TELEGRAM_CONFIG,
    { ...CONFIG, appPeople: TELEGRAM_CONFIG.appPeople },
    { ...CONFIG, groupChatId: TELEGRAM_GROUP, ownerTelegramId: OWNER_TELEGRAM },
  ]) {
    const { registered, errors } = capture(old);
    assert.deepEqual(registered, { hooks: [], tools: [] }, JSON.stringify(old));
    assert.equal(errors.length, 1);
    assert.match(errors[0], /^household-memory: not started, the config still names Telegram \(/);
    assert.match(errors[0], /scripts\/openclaw-memory\.py apply writes ownerPersonId and people in its place$/);
    assert.equal(plugin.configSchema.safeParse(old).success, false);
  }
  assert.match(capture(TELEGRAM_CONFIG).errors[0], /\(groupChatId, ownerTelegramId, appPeople\)/);
});

for (const ask of [
  "Remember that the dentist moved to Tuesdays at 4",
  "remember the garage code is the old one",
  "Remember Pat now has book club every Monday at 7pm so put that on the calendar too",
  "Please keep track of how much the plants get watered",
  "Don't forget we owe the neighbours a casserole dish",
  "Also note that I need to renew the passport before March",
  "Make a note: the blue bin goes out on Wednesdays",
  "Can you remember that my shoe size is 10?",
  "I need you to remember these numbers for the boiler",
  "Remind us to bring the folding chairs on Saturday at 4",
  "Can you remind me to wash the duvet cover at 6:30?",
]) {
  test(`a request to keep is recognised: ${ask}`, () => {
    assert.equal(isKeepRequest(ask), true);
  });
}

for (const question of [
  "Do you remember what the dentist said?",
  "Remember when we went to the lake?",
  "I don't remember the garage code",
  "idk if you remember that trip",
  "What did I ask you to remember about the boiler?",
  "Can you remind me what the boiler code was?",
  "What did I ask you to remind me about?",
  "I'm home now remember… what's next?",
  "No, no, remember we were talking about the trip? and you showed me the map",
  "I wanted to ask about the photos, remember I sent you the list? or maybe you lost it",
  "What's for dinner tonight?",
]) {
  test(`a question or remark is not kept: ${question}`, () => {
    assert.equal(isKeepRequest(question), false);
  });
}

for (const question of [
  "Do you remember what the dentist said?",
  "A few weeks ago I asked you about the boiler. What was it?",
  "What did we decide about the kittens?",
  "Last time we talked about the garden, which seeds did I pick?",
]) {
  test(`a question about the past is recognised: ${question}`, () => {
    assert.equal(isRecallQuestion(question), true);
  });
}

test("a question about now is not treated as one about the past", () => {
  assert.equal(isRecallQuestion("What's the weather tomorrow?"), false);
});

test("a request in the owner's thread is kept with who, what, when and where, and survives a reload", async (context) => {
  const setup = await gateway(context);
  const result = await setup.turn("Remember that the dentist moved to Tuesdays at 4");
  assert.match(result.prependContext, /kept this as #1 for Sam\. Confirm briefly that you will remember it\.$/m);
  assert.match(result.prependContext, /dentist moved to Tuesdays at 4/);
  const [item] = await setup.stored();
  assert.deepEqual(item, {
    id: 1, at: START, who: "Sam", person: OWNER, where: "a private chat", scope: "private",
    text: "Remember that the dentist moved to Tuesdays at 4",
  });
  setup.clock.now = START + 90 * DAY;
  const later = await setup.again()("What's for dinner tonight?");
  assert.match(later.prependContext, /dentist moved to Tuesdays at 4/);
  assert.match(later.prependContext, /Sam/);
});

test("the same request on a retried turn is kept once", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that the dentist moved to Tuesdays at 4");
  await setup.turn("Remember that the dentist moved to Tuesdays at 4");
  assert.equal((await setup.stored()).length, 1);
});

test("a request in the family room is kept for the family under the sender's name, and shown in the owner's thread", async (context) => {
  const setup = await gateway(context);
  const privately = await setup.turn("Remember that my shoe size is 10");
  const forTheFamily = await setup.turn("Don't forget we owe the neighbours a casserole dish", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  // Kept here alone, it would be one assistant's: the household note is the one both read.
  assert.match(forTheFamily.prependContext, /kept this as #2 for Alex\. Confirm briefly that you will remember it\. It is for the family, so also add it to the household note with household_note/);
  assert.doesNotMatch(privately.prependContext, /household note/);
  const [, item] = await setup.stored();
  assert.deepEqual(
    { who: item.who, person: item.person, scope: item.scope, where: item.where },
    { who: "Alex", person: SPOUSE, scope: "family", where: "the family group" },
  );
  const inThread = await setup.turn("What's for dinner tonight?");
  assert.match(inThread.prependContext, /casserole dish/);
  const inRoom = await setup.turn("What's for dinner tonight?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.match(inRoom.prependContext, /casserole dish/);
  assert.doesNotMatch(inRoom.prependContext, /shoe size/);
});

test("a sender id with the app channel's prefix is still the family member", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Don't forget the casserole dish", { sessionKey: FAMILY_SESSION, senderId: `household:${SPOUSE}` });
  assert.equal((await setup.stored())[0].who, "Alex");
});

test("a private item never reaches the family room", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that my shoe size is 10");
  await setup.turn("Remember the bins go out on Wednesdays", { sessionKey: FAMILY_SESSION, senderId: OWNER });
  const inRoom = await setup.turn("What's for dinner tonight?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.match(inRoom.prependContext, /bins go out on Wednesdays/);
  assert.doesNotMatch(inRoom.prependContext, /shoe size/);
});

test("nothing is kept or shown outside the family room, the owner's thread and operator sessions", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that my shoe size is 10");
  for (const ctx of [
    { sessionKey: `agent:main:household:direct:${SPOUSE}`, senderId: SPOUSE },
    { sessionKey: "agent:main:household:group:other", senderId: OWNER },
    { sessionKey: FAMILY_SESSION, senderId: STRANGER },
    { sessionKey: OWNERS_FAMILY_SESSION, senderId: SPOUSE },
    { sessionKey: `${FAMILY_SESSION}:sender:${SPOUSE}`, senderId: SPOUSE },
    { sessionKey: "agent:main:cron:daily-verse", senderId: undefined },
    { sessionKey: PRIVATE_SESSION, trigger: "heartbeat" },
    // Telegram's sessions and ids name nobody now.
    { sessionKey: FAMILY_SESSION, senderId: SPOUSE_TELEGRAM },
    { sessionKey: `agent:main:telegram:direct:${OWNER_TELEGRAM}`, senderId: OWNER_TELEGRAM },
    { sessionKey: `agent:main:telegram:group:${TELEGRAM_GROUP}`, senderId: SPOUSE_TELEGRAM },
  ]) {
    assert.equal(await setup.turn("Remember that the shed key is under the pot", ctx), undefined, JSON.stringify(ctx));
  }
  assert.equal((await setup.stored()).length, 1);
});

test("an operator session belongs to the owner", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that my shoe size is 10");
  const result = await setup.turn("What's for dinner tonight?", { sessionKey: "agent:main:recall-check", senderId: undefined });
  assert.match(result.prependContext, /shoe size is 10/);
});

test("forget marks an item done and keeps it on disk", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that my shoe size is 10");
  await setup.turn("Remember that the shed key is under the pot");
  const { forget } = setup.tools();
  const done = await call(forget, { number: 1 });
  assert.notEqual(done.isError, true);
  const records = await setup.stored();
  assert.equal(records.length, 2);
  assert.equal(records[0].doneAt, START);
  const shown = await setup.turn("What's for dinner tonight?");
  assert.doesNotMatch(shown.prependContext, /shoe size/);
  assert.match(shown.prependContext, /shed key/);
});

test("forget refuses an item the chat cannot see", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that my shoe size is 10");
  const { forget } = setup.tools();
  assert.equal((await call(forget, { number: 7 })).isError, true);
  assert.equal((await call(forget, { number: 1, extra: 1 })).isError, true);
  assert.equal((await setup.stored())[0].doneAt, undefined);
});

test("what was kept while the family used Telegram loads, is shown and forgotten as before, and stays as it was", async (context) => {
  const setup = await gateway(context);
  const old = [
    { id: 1, at: START - 30 * DAY, who: "Sam", whoId: OWNER_TELEGRAM, where: "a private chat", scope: "private", text: "Remember the boiler code is 4471" },
    { id: 2, at: START - 20 * DAY, who: "Alex", whoId: SPOUSE_TELEGRAM, where: "the family group", scope: "family", text: "Don't forget the casserole dish goes back Sunday" },
    { id: 3, at: START - 10 * DAY, who: "Sam", whoId: OWNER_TELEGRAM, where: "a private chat", scope: "private", text: "Remember the shed key is under the pot" },
  ];
  await setup.store(old);
  const inThread = await setup.turn("What's for dinner tonight?");
  assert.match(inThread.prependContext, /#1 Sam, in a private chat, .*boiler code is 4471/);
  assert.match(inThread.prependContext, /#2 Alex, in the family group, .*casserole dish/);
  const inRoom = await setup.turn("What's for dinner tonight?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.match(inRoom.prependContext, /casserole dish/);
  assert.doesNotMatch(inRoom.prependContext, /boiler|shed key/);
  assert.notEqual((await call(setup.tools().forget, { number: 3 })).isError, true);
  const kept = await setup.turn("Remember that the vet is on Friday");
  assert.match(kept.prependContext, /kept this as #4 for Sam/);
  const records = await setup.stored();
  assert.deepEqual(records.slice(0, 2), old.slice(0, 2));
  assert.deepEqual(records[2], { ...old[2], doneAt: START });
  assert.equal(records[3].person, OWNER);
});

test("a full store refuses a new item and says so rather than dropping an old one", async (context) => {
  const setup = await gateway(context);
  await setup.store(Array.from({ length: 2000 }, (_, index) => ({
    id: index + 1, at: START - DAY, who: "Sam", person: OWNER, where: "a private chat", scope: "private", text: `item ${index + 1}`,
  })));
  const result = await setup.turn("Remember that the shed key is under the pot");
  assert.match(result.prependContext, /could not be kept/i);
  const records = await setup.stored();
  assert.equal(records.length, 2000);
  assert.equal(records[0].text, "item 1");
});

test("the list shown is bounded, and items that share words with the message come first", async (context) => {
  const setup = await gateway(context);
  const many = Array.from({ length: 300 }, (_, index) => ({
    id: index + 1, at: START - (300 - index) * 60_000, who: "Sam", person: OWNER, where: "a private chat",
    scope: "private", text: `routine note number ${index + 1} about nothing in particular`,
  }));
  many[0].text = "the boiler service code is 4471";
  await setup.store(many);
  const result = await setup.turn("When is the boiler service due?");
  assert.ok(result.prependContext.length < 6000);
  assert.match(result.prependContext, /boiler service code is 4471/);
  assert.equal((await setup.stored()).length, 300);
});

test("a question about the past brings dated lines from that chat's own history, and never another chat's", async (context) => {
  const setup = await gateway(context, {
    chats: [
      ["private-session", "user", "we picked the heirloom tomato seeds for the garden", START - 40 * DAY],
      ["family-session", "user", "the kittens are going to new homes next month", START - 20 * DAY],
      ["other-room-session", "user", "garden seeds secret from another room", START - 10 * DAY],
      ["spouse-session", "user", "garden seeds secret from another thread", START - 10 * DAY],
    ],
  });
  const privately = await setup.turn("Last time we talked about the garden, which seeds did I pick?");
  assert.match(privately.prependContext, /a private chat, Sam: "we picked the heirloom tomato seeds/);
  assert.doesNotMatch(privately.prependContext, /another room|another thread/);
  const inRoom = await setup.turn("Do you remember which seeds we picked for the garden?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.doesNotMatch(inRoom?.prependContext ?? "", /heirloom|another room|another thread/);
  const kittens = await setup.turn("What did we decide about the kittens?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.match(kittens.prependContext, /the family group, a family member: "the kittens are going to new homes next month"/);
  const fromThread = await setup.turn("What did we decide about the kittens?");
  assert.match(fromThread.prependContext, /new homes next month/);
});

test("chats held only on Telegram are no longer searched", async (context) => {
  const setup = await gateway(context, {
    chats: [
      ["telegram-private-session", "user", "the boiler service is booked for the first week of March", START - 30 * DAY],
      ["telegram-family-session", "user", "the boiler service man asked for the side gate code", START - 20 * DAY],
    ],
  });
  assert.equal(await setup.turn("What did we say about the boiler service earlier?"), undefined);
  const found = await call(setup.tools().recall, { query: "boiler service" });
  assert.deepEqual(found.payload.earlierChats, []);
});

test("a message that is not about the past adds no history", async (context) => {
  const setup = await gateway(context, {
    chats: [["private-session", "user", "we picked the heirloom tomato seeds for the garden", START - 40 * DAY]],
  });
  assert.equal(await setup.turn("Plant the garden seeds tomorrow"), undefined);
});

test("the question just asked is not handed back as its own answer", async (context) => {
  const setup = await gateway(context, {
    chats: [["private-session", "user", "Which seeds did I pick for the garden last time?", START - 5_000]],
  });
  assert.equal(await setup.turn("Which seeds did I pick for the garden last time?"), undefined);
});

test("recall takes only the words to look for, and finds kept items and older chats", async (context) => {
  const setup = await gateway(context, {
    chats: [["private-session", "assistant", "Noted: the boiler service is booked for the first week of March", START - 60 * DAY]],
  });
  await setup.turn("Remember that the boiler code is 4471");
  const { recall } = setup.tools();
  assert.deepEqual(recall.parameters.required, ["query"]);
  assert.deepEqual(Object.keys(recall.parameters.properties), ["query"]);
  const found = await call(recall, { query: "boiler service" });
  assert.notEqual(found.isError, true);
  assert.match(JSON.stringify(found.payload), /boiler code is 4471/);
  assert.match(JSON.stringify(found.payload), /first week of March/);
  assert.equal((await call(recall, { query: "" })).isError, true);
  assert.equal((await call(recall, { query: "boiler", limit: 3 })).isError, true);
});

test("recall and forget are in the owner's own turns, their thread and their own session of the family room, and nobody else's", async (context) => {
  const setup = await gateway(context);
  assert.deepEqual(Object.keys(setup.tools()).sort(), ["forget", "recall"]);
  assert.deepEqual(Object.keys(setup.tools(PRIVATE_SESSION, `household:${OWNER}`)).sort(), ["forget", "recall"]);
  assert.deepEqual(Object.keys(setup.tools(OWNERS_FAMILY_SESSION, OWNER)).sort(), ["forget", "recall"]);
  assert.deepEqual(Object.keys(setup.tools(FAMILY_SESSION, OWNER)), [], "the room's shared session, which others' turns read");
  assert.deepEqual(Object.keys(setup.tools(OWNERS_FAMILY_SESSION, SPOUSE)), []);
  assert.deepEqual(Object.keys(setup.tools(FAMILY_SESSION, SPOUSE)), []);
  assert.deepEqual(Object.keys(setup.tools(`agent:main:household:direct:${SPOUSE}`, SPOUSE)), []);
  assert.deepEqual(Object.keys(setup.tools(`agent:main:telegram:direct:${OWNER_TELEGRAM}`, OWNER_TELEGRAM)), []);
});

test("the owner's family-room recall finds their private items when asked, and the room is never shown them unasked", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that the anniversary gift is hidden in the garage");
  const shown = await setup.turn("Corey, what's for dinner?", { sessionKey: OWNERS_FAMILY_SESSION, senderId: OWNER });
  const found = await call(setup.tools(OWNERS_FAMILY_SESSION, OWNER).recall, { query: "anniversary gift" });
  assert.doesNotMatch(shown?.prependContext ?? "", /anniversary gift/);
  assert.match(found.payload.kept.join("\n"), /anniversary gift is hidden in the garage/);
});

test("what the owner's own family-room session wrote beside its tools is found only by the owner's private view", async (context) => {
  const setup = await gateway(context, {
    chats: [
      ["family-session", "assistant", "we said the kittens go to new homes next month", START - 20 * DAY],
      ["owners-family-session", "assistant", "your checking account balance is 4213 dollars, checking savings next", START - 10 * DAY],
    ],
  });
  const byAlex = await setup.turn("What did you tell Sam earlier about the checking account balance?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  const kittens = await setup.turn("What did we decide earlier about the kittens?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  const found = await call(setup.tools(OWNERS_FAMILY_SESSION, OWNER).recall, { query: "checking account balance" });
  assert.doesNotMatch(byAlex?.prependContext ?? "", /4213/);
  assert.match(kittens.prependContext, /new homes next month/, "the room's own shared session is still found");
  assert.match(found.payload.earlierChats.join("\n"), /4213/, "the owner finds their own, when they ask");
});

test("a voice note's transcript is judged by its words", () => {
  assert.equal(isKeepRequest('[Audio transcript (machine-generated, untrusted)]: "Remember that the vet is on Friday."'), true);
  assert.equal(isKeepRequest('[Audio transcript (machine-generated, untrusted)]: "Do you remember the vet?"'), false);
});

test("the backfill keeps earlier requests made in the app once, with who asked, when and where, and none from Telegram", async (context) => {
  const setup = await gateway(context);
  const database = new DatabaseSync(path.join(setup.directory, "agents", "main", "agent", "openclaw-agent.sqlite"));
  database.exec("CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event_json TEXT, created_at INTEGER)");
  const app = (text, id) => JSON.stringify({ type: "message", message: {
    role: "user", content: text,
    __openclaw: { senderId: id, senderIdentity: { type: "observation", id, pluginId: "household", accountId: "default", senderKind: "unknown" } },
  } });
  const telegram = (text, id) => JSON.stringify({ type: "message", message: {
    role: "user", content: [{ type: "text", text }],
    __openclaw: { senderId: id, senderIdentity: { id, senderKind: "human" } },
  } });
  const event = database.prepare("INSERT INTO transcript_events VALUES (?, ?, ?, ?)");
  event.run("private-session", 1, app("Remember that the boiler code is 4471", OWNER), START - 3 * DAY);
  event.run("private-session", 2, app("Do you remember the boiler code?", OWNER), START - 3 * DAY + 1);
  event.run("family-session", 1, app("Don't forget the casserole dish goes back Sunday", SPOUSE), START - 2 * DAY);
  event.run("family-session", 2, app("Remember the stranger's secret", STRANGER), START - 2 * DAY + 1);
  event.run("spouse-session", 1, app("Remember the other thread's plan", SPOUSE), START - DAY);
  event.run("other-room-session", 1, app("Remember the other room's plan", OWNER), START - DAY);
  event.run("private-session", 3, JSON.stringify({ type: "message", message: { role: "assistant", content: "Remember to rest" } }), START - DAY);
  event.run("telegram-private-session", 1, telegram("Remember the Telegram-only plan", OWNER_TELEGRAM), START - 30 * DAY);
  event.run("telegram-family-session", 1, telegram("Remember the Telegram group's plan", SPOUSE_TELEGRAM), START - 20 * DAY);
  database.close();

  assert.deepEqual(await backfillKept(setup.directory, CONFIG), { kept: 2 });
  assert.deepEqual(await backfillKept(setup.directory, CONFIG), { kept: 0 });
  assert.deepEqual((await setup.stored()).map(({ who, person, at, scope, where, text }) => ({ who, person, at, scope, where, text })), [
    { who: "Sam", person: OWNER, at: START - 3 * DAY, scope: "private", where: "a private chat", text: "Remember that the boiler code is 4471" },
    { who: "Alex", person: SPOUSE, at: START - 2 * DAY, scope: "family", where: "the family group", text: "Don't forget the casserole dish goes back Sunday" },
  ]);
});

test("a missing transcript database leaves keeping and showing working", async (context) => {
  const setup = await gateway(context);
  await rm(path.join(setup.directory, "agents"), { recursive: true, force: true });
  const result = await setup.turn("Remember that my shoe size is 10");
  assert.match(result.prependContext, /shoe size is 10/);
  const recalled = await setup.turn("Do you remember what I said about the shoe size?");
  assert.match(recalled.prependContext, /shoe size is 10/);
});
