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

const GROUP = "-7000000002";
const OWNER = "7000000001";
const SPOUSE = "7000000003";
const STRANGER = "7000000009";
const FAMILY_SESSION = `agent:main:telegram:group:${GROUP}`;
const PRIVATE_SESSION = `agent:main:telegram:direct:${OWNER}`;
const START = Date.UTC(2026, 9, 14, 3, 0);
const DAY = 86_400_000;
const CONFIG = {
  groupChatId: GROUP,
  ownerTelegramId: OWNER,
  people: { [OWNER]: "Sam", [SPOUSE]: "Alex" },
};
// The same two people in the household app, where they are named by their app ids.
const APP_CONFIG = { ...CONFIG, appPeople: { [OWNER]: "sam", [SPOUSE]: "alex" } };
const APP_FAMILY_SESSION = "agent:main:household:group:family";
// The owner's family-room turns run in the owner's own session of the room.
const APP_OWNERS_FAMILY_SESSION = "agent:main:household:group:family:sender:sam";
const APP_PRIVATE_SESSION = "agent:main:household:direct:sam";
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

async function gateway(context, { config = CONFIG, chats = [] } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-memory-"));
  context.after(async () => { await rm(directory, { recursive: true, force: true }); });
  const databasePath = path.join(directory, "agents", "main", "agent", "openclaw-agent.sqlite");
  await mkdir(path.dirname(databasePath), { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec(SCHEMA);
  const conversation = database.prepare("INSERT INTO conversations VALUES (?, ?, ?, ?, ?, ?)");
  conversation.run("family", "telegram", "default", "group", GROUP, null);
  conversation.run("owner", "telegram", "default", "direct", OWNER, null);
  conversation.run("other-group", "telegram", "default", "group", "-7000000077", null);
  conversation.run("app-family", "household", "default", "group", "family", null);
  conversation.run("app-owner", "household", "default", "direct", "sam", null);
  conversation.run("app-spouse", "household", "default", "direct", "alex", null);
  const link = database.prepare("INSERT INTO session_conversations VALUES (?, ?, 'primary')");
  link.run("family-session", "family");
  link.run("old-main-session", "owner");
  link.run("private-session", "owner");
  link.run("other-group-session", "other-group");
  link.run("app-family-session", "app-family");
  link.run("app-private-session", "app-owner");
  link.run("app-spouse-session", "app-spouse");
  // The owner's own session of the app's family room, linked to the room as OpenClaw links
  // any turn whose conversation is the room.
  link.run("app-owners-family-session", "app-family");
  const windows = database.prepare("INSERT INTO session_windows VALUES (?, ?)");
  windows.run("app-family-session", APP_FAMILY_SESSION);
  windows.run("app-owners-family-session", APP_OWNERS_FAMILY_SESSION);
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
  return { api, clock, directory, errors, registered, turn, tools, stored, again };
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

test("the config is refused unless the group, the owner and the people are plain ids and names", () => {
  assert.deepEqual(parseConfig(CONFIG).value, CONFIG);
  for (const broken of [
    {},
    { ...CONFIG, groupChatId: "The Fam" },
    { ...CONFIG, ownerTelegramId: "-1" },
    { ...CONFIG, people: { [SPOUSE]: "Alex" } },
    { ...CONFIG, people: { [OWNER]: "" } },
    { ...CONFIG, extra: true },
  ]) {
    assert.ok(parseConfig(broken).error, JSON.stringify(broken));
  }
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

test("a private request is kept with who, what, when and where, and survives a reload", async (context) => {
  const setup = await gateway(context);
  const result = await setup.turn("Remember that the dentist moved to Tuesdays at 4");
  assert.match(result.prependContext, /kept/i);
  assert.match(result.prependContext, /dentist moved to Tuesdays at 4/);
  const [item] = await setup.stored();
  assert.deepEqual(
    { who: item.who, whoId: item.whoId, at: item.at, where: item.where, scope: item.scope, text: item.text },
    { who: "Sam", whoId: OWNER, at: START, where: "a private chat", scope: "private", text: "Remember that the dentist moved to Tuesdays at 4" },
  );
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

test("a request in the family group is kept for the family and shown in the private chat", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Don't forget we owe the neighbours a casserole dish", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  const [item] = await setup.stored();
  assert.equal(item.who, "Alex");
  assert.equal(item.scope, "family");
  assert.equal(item.where, "the family group");
  const privately = await setup.turn("What's for dinner tonight?");
  assert.match(privately.prependContext, /casserole dish/);
});

test("a sender id with OpenClaw's channel prefix is still the family member", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Don't forget the casserole dish", { sessionKey: FAMILY_SESSION, senderId: `telegram:${SPOUSE}` });
  assert.equal((await setup.stored())[0].who, "Alex");
});

test("a private item never reaches the family group", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that my shoe size is 10");
  await setup.turn("Remember the bins go out on Wednesdays", { sessionKey: FAMILY_SESSION, senderId: OWNER });
  const inGroup = await setup.turn("What's for dinner tonight?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.match(inGroup.prependContext, /bins go out on Wednesdays/);
  assert.doesNotMatch(inGroup.prependContext, /shoe size/);
});

test("nothing is kept or shown outside the family group, the owner's chat and operator sessions", async (context) => {
  const setup = await gateway(context);
  await setup.turn("Remember that my shoe size is 10");
  for (const ctx of [
    { sessionKey: `agent:main:telegram:direct:${STRANGER}`, senderId: STRANGER },
    { sessionKey: "agent:main:telegram:group:-7000000077", senderId: OWNER },
    { sessionKey: FAMILY_SESSION, senderId: STRANGER },
    { sessionKey: "agent:main:cron:daily-verse", senderId: undefined },
    { sessionKey: PRIVATE_SESSION, trigger: "heartbeat" },
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

test("a full store refuses a new item and says so rather than dropping an old one", async (context) => {
  const setup = await gateway(context);
  const full = Array.from({ length: 2000 }, (_, index) => ({
    id: index + 1, at: START - DAY, who: "Sam", whoId: OWNER, where: "a private chat", scope: "private", text: `item ${index + 1}`,
  }));
  await mkdir(path.join(setup.directory, "household-memory"), { recursive: true });
  await writeFile(path.join(setup.directory, "household-memory", "kept.json"), JSON.stringify(full));
  const result = await setup.turn("Remember that the shed key is under the pot");
  assert.match(result.prependContext, /could not be kept/i);
  const records = await setup.stored();
  assert.equal(records.length, 2000);
  assert.equal(records[0].text, "item 1");
});

test("the list shown is bounded, and items that share words with the message come first", async (context) => {
  const setup = await gateway(context);
  const many = Array.from({ length: 300 }, (_, index) => ({
    id: index + 1, at: START - (300 - index) * 60_000, who: "Sam", whoId: OWNER, where: "a private chat",
    scope: "private", text: `routine note number ${index + 1} about nothing in particular`,
  }));
  many[0].text = "the boiler service code is 4471";
  await mkdir(path.join(setup.directory, "household-memory"), { recursive: true });
  await writeFile(path.join(setup.directory, "household-memory", "kept.json"), JSON.stringify(many));
  const result = await setup.turn("When is the boiler service due?");
  assert.ok(result.prependContext.length < 6000);
  assert.match(result.prependContext, /boiler service code is 4471/);
  assert.equal((await setup.stored()).length, 300);
});

test("a question about the past brings dated lines from that chat's own history", async (context) => {
  const setup = await gateway(context, {
    chats: [
      ["old-main-session", "user", "we picked the heirloom tomato seeds for the garden", START - 40 * DAY],
      ["family-session", "user", "the kittens are going to new homes next month", START - 20 * DAY],
      ["other-group-session", "user", "garden seeds secret from another group", START - 10 * DAY],
    ],
  });
  const privately = await setup.turn("Last time we talked about the garden, which seeds did I pick?");
  assert.match(privately.prependContext, /heirloom tomato seeds/);
  assert.doesNotMatch(privately.prependContext, /another group/);
  const inGroup = await setup.turn("Do you remember which seeds we picked for the garden?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.doesNotMatch(inGroup?.prependContext ?? "", /heirloom/);
  const kittens = await setup.turn("What did we decide about the kittens?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.match(kittens.prependContext, /new homes next month/);
});

test("a message that is not about the past adds no history", async (context) => {
  const setup = await gateway(context, {
    chats: [["old-main-session", "user", "we picked the heirloom tomato seeds for the garden", START - 40 * DAY]],
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
    chats: [["old-main-session", "assistant", "Noted: the boiler service is booked for the first week of March", START - 60 * DAY]],
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

test("recall and forget are private tools: the family group does not get them", async (context) => {
  const setup = await gateway(context);
  assert.deepEqual(Object.keys(setup.tools(FAMILY_SESSION)), []);
  assert.deepEqual(Object.keys(setup.tools(`agent:main:telegram:direct:${STRANGER}`)), []);
  assert.deepEqual(Object.keys(setup.tools()).sort(), ["forget", "recall"]);
});

test("a voice note's transcript is judged by its words", () => {
  assert.equal(isKeepRequest('[Audio transcript (machine-generated, untrusted)]: "Remember that the vet is on Friday."'), true);
  assert.equal(isKeepRequest('[Audio transcript (machine-generated, untrusted)]: "Do you remember the vet?"'), false);
});

function said(text, senderId, senderName) {
  return JSON.stringify({ type: "message", message: {
    role: "user", content: [{ type: "text", text }],
    __openclaw: { senderId, senderName, senderIdentity: { id: senderId, senderKind: "human" } },
  } });
}

test("the backfill keeps earlier requests once, with who asked, when and where", async (context) => {
  const setup = await gateway(context);
  const database = new DatabaseSync(path.join(setup.directory, "agents", "main", "agent", "openclaw-agent.sqlite"));
  database.exec("CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event_json TEXT, created_at INTEGER)");
  const event = database.prepare("INSERT INTO transcript_events VALUES (?, ?, ?, ?)");
  event.run("old-main-session", 1, said("Remember that the boiler code is 4471", OWNER, "Sam S"), START - 30 * DAY);
  event.run("old-main-session", 2, said("Do you remember the boiler code?", OWNER, "Sam S"), START - 29 * DAY);
  event.run("family-session", 1, said("Don't forget the casserole dish goes back Sunday", SPOUSE, "Alex S"), START - 20 * DAY);
  event.run("family-session", 2, said("Remember the stranger's secret", STRANGER, "Stranger"), START - 19 * DAY);
  event.run("other-group-session", 1, said("Remember the other group's plan", OWNER, "Sam S"), START - 18 * DAY);
  event.run("old-main-session", 3, JSON.stringify({ type: "message", message: { role: "assistant", content: "Remember to rest" } }), START - 17 * DAY);
  database.close();

  assert.deepEqual(await backfillKept(setup.directory, CONFIG), { kept: 2 });
  assert.deepEqual(await backfillKept(setup.directory, CONFIG), { kept: 0 });
  const records = await setup.stored();
  assert.deepEqual(records.map(({ who, at, scope, where, text }) => ({ who, at, scope, where, text })), [
    { who: "Sam", at: START - 30 * DAY, scope: "private", where: "a private chat", text: "Remember that the boiler code is 4471" },
    { who: "Alex", at: START - 20 * DAY, scope: "family", where: "the family group", text: "Don't forget the casserole dish goes back Sunday" },
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

test("the app's ids are refused unless they name the configured people, the owner among them", () => {
  assert.deepEqual(parseConfig(APP_CONFIG).value, APP_CONFIG);
  for (const appPeople of [
    { [SPOUSE]: "alex" },
    { [OWNER]: "sam", [STRANGER]: "pat" },
    { [OWNER]: "Sam" },
    { [OWNER]: "sam", [SPOUSE]: "sam" },
    [],
  ]) {
    assert.ok(parseConfig({ ...CONFIG, appPeople }).error, JSON.stringify(appPeople));
  }
});

test("a request in the owner's app thread joins the one kept list the Telegram chat shows", async (context) => {
  const setup = await gateway(context, { config: APP_CONFIG });
  const kept = await setup.turn("Remember that the dentist moved to Tuesdays at 4", { sessionKey: APP_PRIVATE_SESSION, senderId: "sam" });
  assert.match(kept.prependContext, /kept this as #1/);
  const [item] = await setup.stored();
  assert.deepEqual(
    { who: item.who, whoId: item.whoId, scope: item.scope, where: item.where },
    { who: "Sam", whoId: OWNER, scope: "private", where: "a private chat" },
  );
  const onTelegram = await setup.turn("What's for dinner tonight?");
  assert.match(onTelegram.prependContext, /dentist moved to Tuesdays at 4/);
  await setup.turn("Remember that my shoe size is 10");
  const inApp = await setup.turn("What's for dinner tonight?", { sessionKey: APP_PRIVATE_SESSION, senderId: "sam" });
  assert.match(inApp.prependContext, /shoe size is 10/);
});

test("a request in the app's family room is kept for the family under the sender's name", async (context) => {
  const setup = await gateway(context, { config: APP_CONFIG });
  await setup.turn("Remember that my shoe size is 10", { sessionKey: APP_PRIVATE_SESSION, senderId: "sam" });
  await setup.turn("Don't forget we owe the neighbours a casserole dish", { sessionKey: APP_FAMILY_SESSION, senderId: "household:alex" });
  const [, item] = await setup.stored();
  assert.deepEqual(
    { who: item.who, whoId: item.whoId, scope: item.scope, where: item.where },
    { who: "Alex", whoId: SPOUSE, scope: "family", where: "the family group" },
  );
  const inTheFam = await setup.turn("What's for dinner tonight?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.match(inTheFam.prependContext, /casserole dish/);
  const inRoom = await setup.turn("What's for dinner tonight?", { sessionKey: APP_FAMILY_SESSION, senderId: "alex" });
  assert.match(inRoom.prependContext, /casserole dish/);
  assert.doesNotMatch(inRoom.prependContext, /shoe size/);
});

test("app sessions get nothing without the app's ids, and never another person's thread", async (context) => {
  const plain = await gateway(context);
  assert.equal(await plain.turn("Remember the shed key is under the pot", { sessionKey: APP_PRIVATE_SESSION, senderId: "sam" }), undefined);
  assert.deepEqual(Object.keys(plain.tools(APP_PRIVATE_SESSION, "sam")), []);
  const setup = await gateway(context, { config: APP_CONFIG });
  await setup.turn("Remember that my shoe size is 10");
  for (const ctx of [
    { sessionKey: "agent:main:household:direct:alex", senderId: "alex" },
    { sessionKey: APP_FAMILY_SESSION, senderId: "pat" },
    { sessionKey: APP_FAMILY_SESSION, senderId: OWNER },
    { sessionKey: "agent:main:household:group:other", senderId: "sam" },
  ]) {
    assert.equal(await setup.turn("Remember that the shed key is under the pot", ctx), undefined, JSON.stringify(ctx));
  }
  assert.equal((await setup.stored()).length, 1);
});

test("recall and forget are in the owner's own app turns, their thread and their own session of the family room, and nobody else's", async (context) => {
  const setup = await gateway(context, { config: APP_CONFIG });
  assert.deepEqual(Object.keys(setup.tools(APP_PRIVATE_SESSION, "sam")).sort(), ["forget", "recall"]);
  assert.deepEqual(Object.keys(setup.tools(APP_OWNERS_FAMILY_SESSION, "sam")).sort(), ["forget", "recall"]);
  assert.deepEqual(Object.keys(setup.tools(APP_FAMILY_SESSION, "sam")), [], "the room's shared session, which others' turns read");
  assert.deepEqual(Object.keys(setup.tools(APP_OWNERS_FAMILY_SESSION, "alex")), []);
  assert.deepEqual(Object.keys(setup.tools(APP_FAMILY_SESSION, "alex")), []);
  assert.deepEqual(Object.keys(setup.tools(FAMILY_SESSION, OWNER)), [], "The Fam on Telegram is unchanged");
  assert.deepEqual(Object.keys(setup.tools("agent:main:household:direct:alex", "alex")), []);
});

test("the owner's family-room recall finds their private items when asked, and the room is never shown them unasked", async (context) => {
  const setup = await gateway(context, { config: APP_CONFIG });
  await setup.turn("Remember that the anniversary gift is hidden in the garage", { sessionKey: APP_PRIVATE_SESSION, senderId: "sam" });
  const shown = await setup.turn("Corey, what's for dinner?", { sessionKey: APP_OWNERS_FAMILY_SESSION, senderId: "sam" });
  const found = await call(setup.tools(APP_OWNERS_FAMILY_SESSION, "sam").recall, { query: "anniversary gift" });
  assert.doesNotMatch(shown?.prependContext ?? "", /anniversary gift/);
  assert.match(found.payload.kept.join("\n"), /anniversary gift is hidden in the garage/);
});

test("older chats are found across Telegram and the app, each chat seeing only what it may", async (context) => {
  const setup = await gateway(context, {
    config: APP_CONFIG,
    chats: [
      ["app-private-session", "user", "we picked the heirloom tomato seeds for the garden", START - 40 * DAY],
      ["app-family-session", "user", "the kittens are going to new homes next month", START - 20 * DAY],
      ["private-session", "user", "the boiler service is booked for the first week of March", START - 30 * DAY],
      ["app-spouse-session", "user", "garden seeds secret from another thread", START - 10 * DAY],
    ],
  });
  const onTelegram = await setup.turn("Last time we talked about the garden, which seeds did I pick?");
  assert.match(onTelegram.prependContext, /heirloom tomato seeds/);
  assert.doesNotMatch(onTelegram.prependContext, /another thread/);
  const inApp = await setup.turn("What did we say about the boiler service earlier?", { sessionKey: APP_PRIVATE_SESSION, senderId: "sam" });
  assert.match(inApp.prependContext, /first week of March/);
  const inTheFam = await setup.turn("What did we decide about the kittens?", { sessionKey: FAMILY_SESSION, senderId: SPOUSE });
  assert.match(inTheFam.prependContext, /new homes next month/);
  const inRoom = await setup.turn("Do you remember which seeds we picked for the garden?", { sessionKey: APP_FAMILY_SESSION, senderId: "alex" });
  assert.doesNotMatch(inRoom?.prependContext ?? "", /heirloom|another thread/);
});

test("the backfill keeps earlier requests made in the app as well", async (context) => {
  const setup = await gateway(context, { config: APP_CONFIG });
  const database = new DatabaseSync(path.join(setup.directory, "agents", "main", "agent", "openclaw-agent.sqlite"));
  database.exec("CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event_json TEXT, created_at INTEGER)");
  const app = (text, id) => JSON.stringify({ type: "message", message: {
    role: "user", content: text,
    __openclaw: { senderId: id, senderIdentity: { type: "observation", id, pluginId: "household", accountId: "default", senderKind: "unknown" } },
  } });
  const event = database.prepare("INSERT INTO transcript_events VALUES (?, ?, ?, ?)");
  event.run("app-private-session", 1, app("Remember that the boiler code is 4471", "sam"), START - 3 * DAY);
  event.run("app-family-session", 1, app("Don't forget the casserole dish goes back Sunday", "alex"), START - 2 * DAY);
  event.run("app-family-session", 2, app("Remember the stranger's secret", "pat"), START - 2 * DAY + 1);
  event.run("app-spouse-session", 1, app("Remember the other thread's plan", "alex"), START - DAY);
  database.close();

  assert.deepEqual(await backfillKept(setup.directory, APP_CONFIG), { kept: 2 });
  assert.deepEqual(await backfillKept(setup.directory, APP_CONFIG), { kept: 0 });
  assert.deepEqual((await setup.stored()).map(({ who, whoId, scope }) => ({ who, whoId, scope })), [
    { who: "Sam", whoId: OWNER, scope: "private" },
    { who: "Alex", whoId: SPOUSE, scope: "family" },
  ]);
});

test("what the owner's own family-room session wrote beside its tools is found only by the owner's private view", async (context) => {
  const setup = await gateway(context, {
    config: APP_CONFIG,
    chats: [
      ["app-family-session", "assistant", "we said the kittens go to new homes next month", START - 20 * DAY],
      ["app-owners-family-session", "assistant", "your checking account balance is 4213 dollars, checking savings next", START - 10 * DAY],
    ],
  });
  const byAlex = await setup.turn("What did you tell Sam earlier about the checking account balance?", { sessionKey: APP_FAMILY_SESSION, senderId: "alex" });
  const kittens = await setup.turn("What did we decide earlier about the kittens?", { sessionKey: APP_FAMILY_SESSION, senderId: "alex" });
  const found = await call(setup.tools(APP_OWNERS_FAMILY_SESSION, "sam").recall, { query: "checking account balance" });
  assert.doesNotMatch(byAlex?.prependContext ?? "", /4213/);
  assert.match(kittens.prependContext, /new homes next month/, "the room's own shared session is still found");
  assert.match(found.payload.earlierChats.join("\n"), /4213/, "the owner finds their own, when they ask");
});
