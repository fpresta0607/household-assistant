import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";

import plugin from "../../deploy/openclaw/plugins/household-family-room/index.js";
import { HISTORY_TEXT_CASES, mockHistoryTextSdk } from "./fixtures/openclaw-history-text.mjs";
import telegramContexts from "./fixtures/openclaw-telegram-contexts.json" with { type: "json" };

mockHistoryTextSdk();

const GROUP = "-7000000002";
const SENDER = "7000000001";
const START = 1_790_000_000_000;
// The household app's people on this gateway: its owner and the person on the other one.
const APP_OWNER = "sam";
const APP_PEER = "alex";
const APP_FAMILY_TURN = {
  messageChannel: "household", nativeChannelId: undefined, requesterSenderId: APP_PEER,
  sessionKey: "agent:main:household:group:family",
  deliveryContext: { channel: "household", accountId: "default", to: "household:family" },
};
const APP_PRIVATE_TURN = {
  messageChannel: "household", nativeChannelId: undefined, requesterSenderId: APP_OWNER,
  sessionKey: `agent:main:household:direct:${APP_OWNER}`,
  deliveryContext: { channel: "household", accountId: "default", to: `household:${APP_OWNER}` },
};
const SCHEMA = `
  CREATE TABLE conversations (
    conversation_id TEXT PRIMARY KEY, channel TEXT NOT NULL, account_id TEXT NOT NULL,
    kind TEXT NOT NULL, peer_id TEXT NOT NULL, thread_id TEXT
  );
  CREATE TABLE session_conversations (
    session_id TEXT NOT NULL, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
    PRIMARY KEY (session_id, conversation_id, role)
  );
  CREATE TABLE transcript_events (
    session_id TEXT NOT NULL, seq INTEGER NOT NULL, event_json TEXT NOT NULL,
    created_at INTEGER NOT NULL, PRIMARY KEY (session_id, seq)
  );
`;

function human(text) {
  return { type: "message", message: {
    role: "user", content: [{ type: "text", text }],
    __openclaw: { senderName: "Test Person", senderIdentity: { id: SENDER, senderKind: "human" } },
  } };
}

async function fixture(context, { hasDatabase = true } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "family-history-"));
  context.after(async () => { await rm(directory, { recursive: true, force: true }); });
  const databasePath = path.join(directory, "agents", "main", "agent", "openclaw-agent.sqlite");
  await mkdir(path.dirname(databasePath), { recursive: true });
  if (hasDatabase) {
    const database = new DatabaseSync(databasePath);
    database.exec(SCHEMA);
    database.prepare("INSERT INTO conversations VALUES (?, ?, ?, ?, ?, ?)")
      .run("family", "telegram", "default", "group", GROUP, null);
    database.prepare("INSERT INTO session_conversations VALUES (?, ?, ?)")
      .run("family-session", "family", "primary");
    database.prepare("INSERT INTO conversations VALUES (?, ?, ?, ?, ?, ?)")
      .run("app-family", "household", "default", "group", "family", null);
    database.prepare("INSERT INTO session_conversations VALUES (?, ?, ?)")
      .run("app-family-session", "app-family", "primary");
    database.prepare("INSERT INTO conversations VALUES (?, ?, ?, ?, ?, ?)")
      .run("app-private", "household", "default", "direct", APP_OWNER, null);
    database.prepare("INSERT INTO session_conversations VALUES (?, ?, ?)")
      .run("app-private-session", "app-private", "primary");
    database.close();
  }
  const runtime = { value: {
    plugins: { entries: { "household-family-room": { enabled: true, config: { groupChatId: GROUP } } } },
    channels: {
      telegram: { groups: { [GROUP]: { allowFrom: [SENDER] } } },
      household: { enabled: true, owner: { id: APP_OWNER }, peer: { person: { id: APP_PEER } } },
    },
    session: { dmScope: "per-channel-peer", groupScope: "per-group" },
  } };
  const registered = { hooks: new Map(), tools: [], methods: new Map() };
  const api = {
    pluginConfig: { groupChatId: GROUP },
    logger: { error() {}, warn() {} },
    runtime: {
      state: { resolveStateDir: () => directory },
      config: { current: () => runtime.value },
    },
    registerHook: (name, handler) => registered.hooks.set(name, handler),
    on() {},
    registerGatewayMethod: (name, handler) => registered.methods.set(name, handler),
    registerTool: (factory, options) => registered.tools.push({ factory, options }),
  };
  plugin.register(api);
  const turn = {
    messageChannel: "telegram", agentAccountId: "default", agentId: "main",
    nativeChannelId: GROUP, requesterSenderId: SENDER,
    sessionKey: `agent:main:telegram:group:${GROUP}`, conversationReadOrigin: "delegated",
    deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${GROUP}` },
    getRuntimeConfig: () => runtime.value,
  };
  function discover(overrides = {}) {
    assert.equal(registered.tools.length, 1, "family_history factory must be registered");
    return registered.tools[0].factory({ ...turn, ...overrides });
  }
  function insert(events) {
    const database = new DatabaseSync(databasePath);
    try {
      for (const [session, sequence, event, at = START + sequence] of events) {
        database.prepare("INSERT INTO transcript_events VALUES (?, ?, ?, ?)")
          .run(session, sequence, typeof event === "string" ? event : JSON.stringify(event), at);
      }
    } finally { database.close(); }
  }
  return { api, runtime, registered, turn, discover, insert, directory, databasePath };
}

async function page(tool, args = {}) {
  assert.ok(tool, "trusted turn must receive family_history");
  const result = await tool.execute("test-call", args);
  assert.notEqual(result.isError, true, result.content?.[0]?.text);
  assert.ok(Buffer.byteLength(result.content[0].text) <= 24_000);
  return JSON.parse(result.content[0].text);
}

test("family history registers its manifest contract and bounded input schema", async (context) => {
  const { discover, registered } = await fixture(context);
  const tool = discover();
  const manifest = JSON.parse(await readFile(
    new URL("../../deploy/openclaw/plugins/household-family-room/openclaw.plugin.json", import.meta.url), "utf8",
  ));

  assert.equal(tool.name, "family_history");
  assert.deepEqual(manifest.contracts.tools, [tool.name]);
  assert.deepEqual(registered.tools[0].options.names, [tool.name]);
  assert.equal(tool.parameters.additionalProperties, false);
  assert.deepEqual(Object.keys(tool.parameters.properties).sort(), ["limit", "offset", "source"]);
});

test("family history admits the exact family and isolated private routes", async (context) => {
  const setup = await fixture(context);
  setup.insert([["family-session", 1, human("Family plans")]]);
  for (const overrides of [
    {},
    { nativeChannelId: `telegram:${GROUP}` },
    { nativeChannelId: undefined },
    { nativeChannelId: SENDER, sessionKey: `agent:main:telegram:direct:${SENDER}`,
      deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${SENDER}` } },
    { nativeChannelId: `telegram:${SENDER}`, requesterSenderId: `telegram:${SENDER}`,
      sessionKey: `agent:main:telegram:direct:${SENDER}`,
      deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${SENDER}` } },
    { nativeChannelId: undefined, sessionKey: `agent:main:telegram:direct:${SENDER}`,
      deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${SENDER}` } },
  ]) {
    assert.deepEqual((await page(setup.discover(overrides))).entries.map((entry) => entry.text), ["Family plans"]);
  }
});

test("family history admits recorded pinned fresh and queued Telegram construction paths", async (context) => {
  const setup = await fixture(context);
  setup.insert([["family-session", 1, human("Retained family plans")]]);

  for (const recorded of telegramContexts.cases) {
    const tool = setup.registered.tools[0].factory(recorded.context);
    assert.deepEqual((await page(tool)).entries.map((entry) => entry.text), ["Retained family plans"], recorded.name);
  }
});

test("family history preserves the original isolated audience during steering", async (context) => {
  const setup = await fixture(context);
  setup.insert([["family-session", 1, human("Retained family plans")]]);
  const original = structuredClone(telegramContexts.cases.find((entry) => entry.name === "fresh-family").context);
  const tool = setup.registered.tools[0].factory(original);

  // Pinned activeSession.steer carries message content, not a replacement tool factory context.
  assert.deepEqual((await page(tool)).entries.map((entry) => entry.text), ["Retained family plans"]);
  setup.runtime.value.channels.telegram.groups[GROUP].allowFrom = [];
  assert.equal(JSON.parse((await tool.execute("steered-call", {})).content[0].text).code, "access_denied");
  assert.equal(setup.registered.tools[0].factory({
    ...original, sessionKey: "agent:main:main", nativeChannelId: undefined, deliveryContext: undefined,
  }), null, "a Telegram steer cannot confer route authority on an old shared-main factory");
});

test("family history denies untrusted routes before accessing storage", async (context) => {
  const setup = await fixture(context);
  setup.api.runtime.state.resolveStateDir = () => { assert.fail("denied context accessed storage"); };
  const denied = [
    { messageChannel: "cli" }, { messageChannel: "webchat" }, { messageChannel: undefined },
    { requesterSenderId: undefined }, { requesterSenderId: "654321" },
    { nativeChannelId: "-999999" }, { nativeChannelId: null },
    { deliveryContext: undefined },
    { deliveryContext: { channel: "telegram", to: GROUP } },
    { deliveryContext: { channel: "telegram", accountId: "default" } },
    { deliveryContext: { channel: "webchat", accountId: "default", to: GROUP } },
    { deliveryContext: { channel: "telegram", accountId: "other", to: GROUP } },
    { deliveryContext: { channel: "telegram", accountId: "default", to: "-999999" } },
    { deliveryContext: { channel: "telegram", accountId: "default", to: SENDER } },
    { deliveryContext: { channel: "telegram", accountId: "default", to: GROUP, threadId: "9" } },
    { agentAccountId: "other" }, { agentAccountId: undefined }, { agentId: "other" },
    { sessionKey: "agent:main:main" }, { sessionKey: undefined },
    { sessionKey: "agent:main:subagent:child" },
    { sessionKey: `agent:other:telegram:group:${GROUP}` },
    { sessionKey: `agent:main:telegram:group:${GROUP}:subagent:child` },
    { sessionKey: "agent:main:telegram:group:-999999" },
    { nativeChannelId: SENDER, sessionKey: "agent:main:telegram:direct:654321" },
    { nativeChannelId: SENDER },
    { sessionKey: `agent:main:telegram:direct:${SENDER}` },
    { oneShotCliRun: true },
  ];

  for (const overrides of denied) assert.equal(setup.discover(overrides), null, JSON.stringify(overrides));
});

test("family history requires explicit group membership and current isolated policy", async (context) => {
  const setup = await fixture(context);
  const original = structuredClone(setup.runtime.value);
  const mutations = [
    (config) => { config.channels.telegram.groups[GROUP].allowFrom = ["*"]; },
    (config) => { delete config.channels.telegram.groups[GROUP].allowFrom; },
    (config) => { config.channels.telegram.groups = { "*": { allowFrom: [SENDER] } }; },
    (config) => { config.channels.telegram.enabled = false; },
    (config) => { config.channels.telegram.groups[GROUP].enabled = false; },
    (config) => { config.channels.telegram.accounts = { other: {} }; },
    (config) => { config.session.dmScope = "main"; },
    (config) => { config.session.groupScope = "global"; },
    (config) => { config.plugins.entries["household-family-room"].enabled = false; },
    (config) => { config.plugins.entries["household-family-room"].config.groupChatId = "-999999"; },
  ];
  for (const mutate of mutations) {
    setup.runtime.value = structuredClone(original);
    mutate(setup.runtime.value);
    assert.equal(setup.discover(), null);
  }
  setup.runtime.value = undefined;
  assert.equal(setup.discover(), null);
});

test("family history rechecks revocation after tool discovery before storage access", async (context) => {
  const setup = await fixture(context);
  const tool = setup.discover();
  setup.runtime.value.channels.telegram.groups[GROUP].allowFrom = [];
  setup.api.runtime.state.resolveStateDir = () => { assert.fail("revoked tool accessed storage"); };

  const result = await tool.execute("test-call", {});

  assert.equal(result.isError, true);
  assert.equal(JSON.parse(result.content[0].text).code, "access_denied");
});

test("family history honors disabled policies and unavailable runtime configuration after discovery", async (context) => {
  const setup = await fixture(context);
  const original = structuredClone(setup.runtime.value);
  const tool = setup.discover();
  setup.api.runtime.state.resolveStateDir = () => { assert.fail("disabled policy accessed storage"); };
  for (const mutate of [
    (config) => { config.channels.telegram.groupPolicy = "disabled"; },
    (config) => { config.channels.telegram.groups[GROUP].groupPolicy = "disabled"; },
    (config) => { config.plugins.enabled = false; },
    (config) => { config.plugins.entries["household-family-room"].enabled = false; },
    (config) => { config.session.dmScope = "main"; },
  ]) {
    setup.runtime.value = structuredClone(original);
    mutate(setup.runtime.value);
    assert.equal(setup.discover(), null);
    const result = await tool.execute("test-call", {});
    assert.equal(result.isError, true);
    assert.equal(JSON.parse(result.content[0].text).code, "access_denied");
  }
  setup.runtime.value = undefined;
  assert.equal(JSON.parse((await tool.execute("test-call", {})).content[0].text).code, "access_denied");
});

test("family history reads latest runtime config for both supported isolated DM policies", async (context) => {
  const setup = await fixture(context);
  setup.runtime.value.channels.telegram.groups[GROUP].allowFrom = [`TG:${SENDER}`];
  for (const scope of ["per-channel-peer", "per-account-channel-peer"]) {
    setup.runtime.value.session.dmScope = scope;
    const account = scope === "per-account-channel-peer" ? "default:" : "";
    const tool = setup.discover({
      getRuntimeConfig: undefined, nativeChannelId: SENDER,
      sessionKey: `agent:main:telegram:${account}direct:${SENDER}`,
      deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${SENDER}` },
    });
    await page(tool);
    setup.runtime.value.channels.telegram.groups[GROUP].allowFrom = [];
    const result = await tool.execute("test-call", {});
    assert.equal(result.isError, true);
    setup.runtime.value.channels.telegram.groups[GROUP].allowFrom = [SENDER];
  }
});

test("family history excludes all private foreign and multiply linked transcripts", async (context) => {
  const setup = await fixture(context);
  const database = new DatabaseSync(setup.databasePath);
  const otherConversations = [
    ["private", "telegram", "default", "direct", SENDER],
    ["foreign", "telegram", "default", "group", "-999999"],
    ["other-account", "telegram", "other", "group", GROUP],
    ["other-channel", "discord", "default", "group", GROUP],
  ];
  for (const conversation of otherConversations) {
    database.prepare("INSERT INTO conversations VALUES (?, ?, ?, ?, ?, NULL)").run(...conversation);
    database.prepare("INSERT INTO session_conversations VALUES (?, ?, 'primary')")
      .run(conversation[0], conversation[0]);
  }
  for (const [session, conversation, role] of [
    ["mixed", "family", "primary"], ["mixed", "private", "participant"],
    ["duplicate", "family", "primary"], ["duplicate", "family", "related"],
    ["dangling", "family", "primary"], ["dangling", "missing-conversation", "related"],
  ]) database.prepare("INSERT INTO session_conversations VALUES (?, ?, ?)").run(session, conversation, role);
  database.close();
  setup.insert([
    ["family-session", 1, human("Safe family text")],
    ...[...otherConversations.map(([name]) => name), "mixed", "duplicate", "dangling"]
      .map((session) => [session, 1, human(`POCKETPIGGIES_PRIVATE_SENTINEL ${session}`)]),
  ]);

  const result = await page(setup.discover());

  assert.deepEqual(result.entries.map((entry) => entry.text), ["Safe family text"]);
  assert.doesNotMatch(JSON.stringify(result), /SENTINEL/);
});

test("family history paginates every retained session without dropping boundary entries", async (context) => {
  const setup = await fixture(context);
  const database = new DatabaseSync(setup.databasePath);
  database.prepare("INSERT INTO session_conversations VALUES (?, ?, 'primary')")
    .run("second-session", "family");
  database.close();
  const expected = Array.from({ length: 11 }, (_, index) => `message ${index}`);
  setup.insert(expected.map((text, index) => [
    index % 2 ? "second-session" : "family-session", index + 1, human(text), START + index,
  ]));
  const tool = setup.discover();
  const entries = [];
  let offset = 0;
  for (let attempt = 0; attempt < 6; attempt += 1) {
    const result = await page(tool, { limit: 2, offset });
    entries.push(...result.entries.map((entry) => entry.text));
    assert.equal(result.oldestRetainedEventAt, START);
    if (!result.hasMore) {
      assert.equal(result.nextOffset, null);
      break;
    }
    assert.ok(result.nextOffset > offset);
    offset = result.nextOffset;
  }
  assert.deepEqual(entries, expected);
});

test("family history returns visible human assistant and media content only", async (context) => {
  const setup = await fixture(context);
  const person = human("Caption");
  person.message.content.push({ type: "image", data: "PRIVATE_BINARY", mimeType: "image/png" });
  const narration = { type: "message", message: { role: "assistant", content: [
    { type: "thinking", thinking: "HIDDEN_THOUGHT" },
    { type: "text", text: "HIDDEN_NARRATION" },
    { type: "toolCall", arguments: { text: "HIDDEN_TOOL_CALL" } },
  ] } };
  const assistant = { type: "message", message: { role: "assistant", content: [
    { type: "thinking", thinking: "HIDDEN_THOUGHT" },
    { type: "text", text: "Visible assistant answer" },
    { type: "audio", url: "HIDDEN_MEDIA_URL" },
  ] } };
  const internal = human("HIDDEN_SYSTEM_NOTICE");
  internal.message.provenance = { kind: "internal_system" };
  const unknown = human("HIDDEN_UNKNOWN_SENDER");
  delete unknown.message.__openclaw;
  setup.insert([
    ["family-session", 1, person], ["family-session", 2, narration],
    ["family-session", 3, { type: "message", message: { role: "toolResult", content: "HIDDEN_TOOL" } }],
    ["family-session", 10, assistant, START + 3],
    ["family-session", 4, { type: "message", message: { role: "system", content: "HIDDEN_SYSTEM" } }],
    ["family-session", 5, internal], ["family-session", 6, unknown],
    ["family-session", 7, { type: "compaction", summary: "HIDDEN_SUMMARY" }],
    ["family-session", 8, { type: "message", message: { role: "assistant", channel: "analysis", content: "HIDDEN_ANALYSIS" } }],
    ["family-session", 9, "{not JSON"],
  ]);

  const result = await page(setup.discover());

  assert.deepEqual(result.entries.map((entry) => entry.role), ["user", "assistant"]);
  assert.equal(result.entries[0].senderId, SENDER);
  assert.match(result.entries[0].text, /Caption[\s\S]*\[image attachment\]/);
  assert.match(result.entries[1].text, /Visible assistant answer[\s\S]*\[audio attachment\]/);
  assert.doesNotMatch(JSON.stringify(result), /HIDDEN_|PRIVATE_BINARY/);
  assert.equal(result.skippedMalformedEvents, 1);
});

test("family history projects assistant text through the pinned visibility contract", async (context) => {
  const setup = await fixture(context);
  setup.insert(HISTORY_TEXT_CASES.flatMap(([text], index) => [
    ["family-session", index * 2, { type: "message", message: { role: "assistant", content: text } }],
    ["family-session", index * 2 + 1, human(text)],
  ]));

  const result = await page(setup.discover());

  assert.deepEqual(result.entries.filter((entry) => entry.role === "assistant").map((entry) => entry.text),
    HISTORY_TEXT_CASES.map(([, text]) => text).filter(Boolean));
  assert.deepEqual(result.entries.filter((entry) => entry.role === "user").map((entry) => entry.text),
    HISTORY_TEXT_CASES.map(([text]) => text));
});

test("family history prefers final answer phases without reviving commentary or legacy blocks", async (context) => {
  const setup = await fixture(context);
  const signature = (phase) => JSON.stringify({ v: 1, id: "test", phase });
  const cases = [
    [{ content: "HIDDEN_COMMENTARY", phase: "commentary" }, null],
    [{ content: "Final string", phase: "final_answer" }, "Final string"],
    [{ text: "Final inline", content: [], phase: "final_answer" }, "Final inline"],
    [{ content: [
      { type: "text", text: "HIDDEN_COMMENTARY", textSignature: signature("commentary") },
      { type: "text", text: "HIDDEN_LEGACY" },
      { type: "output_text", text: "Final ", textSignature: signature("final_answer") },
      { type: "input_text", text: "answer", textSignature: signature("final_answer") },
      { type: "image", data: "HIDDEN_MEDIA" },
    ] }, "Final answer\n[image attachment]"],
    [{ content: [
      { type: "text", text: "HIDDEN_COMMENTARY", textSignature: signature("commentary") },
      { type: "text", text: "HIDDEN_LEGACY" },
    ] }, null],
    [{ phase: "commentary", content: [{ type: "text", text: "HIDDEN_COMMENTARY" }] }, null],
    [{ phase: "final_answer", content: [{ type: "text", text: "Top-level final" }] }, "Top-level final"],
    [{ phase: "commentary", content: [
      { type: "text", text: "Explicit final", textSignature: signature("final_answer") },
    ] }, "Explicit final"],
    [{ content: [{ type: "text", text: "Legacy id", textSignature: "old-signature" }] }, "Legacy id"],
    [{ content: [{ type: "text", text: "Malformed signature", textSignature: "{broken" }] }, "Malformed signature"],
    [{ content: [{ type: "text", text: "Unknown version", textSignature: '{"v":2,"phase":"commentary"}' }] }, "Unknown version"],
  ];
  setup.insert(cases.map(([message], index) => ["family-session", index,
    { type: "message", message: { role: "assistant", ...message } }]));

  const result = await page(setup.discover());

  assert.deepEqual(result.entries.map((entry) => entry.text), cases.map(([, text]) => text).filter(Boolean));
  assert.doesNotMatch(JSON.stringify(result), /HIDDEN_/);
});

test("family history leaves out phase-less narration and unfinished replies", async (context) => {
  const setup = await fixture(context);
  const signature = JSON.stringify({ v: 1, phase: "final_answer" });
  setup.insert([
    ["family-session", 1, { type: "message", message: { role: "assistant", content: [
      { type: "text", text: "HIDDEN_NARRATION Let me check the calendar." },
      { type: "toolCall", id: "call-1", name: "exec", arguments: {} },
    ] } }],
    ["family-session", 2, { type: "message", message: {
      role: "assistant", stopReason: "toolUse", content: "HIDDEN_STRING_NARRATION",
    } }],
    ["family-session", 3, { type: "message", message: { role: "assistant", content: [
      { type: "text", text: "Explicit final beside a call", textSignature: signature },
      { type: "toolCall", id: "call-2", name: "exec", arguments: {} },
    ] } }],
    ["family-session", 4, { type: "message", message: {
      role: "assistant", stopReason: "stop", content: [{ type: "text", text: "Dinner is at six." }],
    } }],
    ["family-session", 5, { type: "message", message: { role: "assistant", content: [
      { type: "text", text: "HIDDEN_SERVER_TOOL_NARRATION" },
      { type: "server_tool_use", id: "call-3", name: "web_search", input: {} },
    ] } }],
    ["family-session", 6, { type: "message", message: {
      role: "assistant", stopReason: "error", content: [{ type: "text", text: "HIDDEN_ERRORED_PARTIAL" }],
    } }],
    ["family-session", 7, { type: "message", message: {
      role: "assistant", stopReason: "aborted", content: "HIDDEN_ABORTED_PARTIAL",
    } }],
    ["family-session", 8, { type: "message", message: {
      role: "assistant", stopReason: "length", content: [{ type: "text", text: "A long answer cut at the limit" }],
    } }],
  ]);

  const result = await page(setup.discover());

  assert.deepEqual(result.entries.map((entry) => entry.text),
    ["Explicit final beside a call", "Dinner is at six.", "A long answer cut at the limit"]);
  assert.doesNotMatch(JSON.stringify(result), /HIDDEN_/);
});

test("family history keeps hidden assistant spans closed across adjacent visible text blocks", async (context) => {
  const setup = await fixture(context);
  const phase = JSON.stringify({ v: 1, phase: "final_answer" });
  setup.insert([["family-session", 1, { type: "message", message: {
    role: "assistant", content: [
      { type: "text", text: "<think>", textSignature: phase },
      { type: "text", text: "HIDDEN_INLINE</think>Visible", textSignature: phase },
    ],
  } }]]);

  assert.deepEqual((await page(setup.discover())).entries.map((entry) => entry.text), ["Visible"]);
});

test("family history advances past bounded invisible event batches", async (context) => {
  const setup = await fixture(context);
  setup.insert([
    ...Array.from({ length: 205 }, (_, index) => ["family-session", index, { type: "session" }]),
    ["family-session", 206, human("Later visible message")],
  ]);

  const first = await page(setup.discover(), { limit: 1 });
  const second = await page(setup.discover(), { limit: 1, offset: first.nextOffset });

  assert.deepEqual(first.entries, []);
  assert.equal(first.hasMore, true);
  assert.equal(first.nextOffset, 200);
  assert.equal(first.scanLimited, true);
  assert.deepEqual(second.entries.map((entry) => entry.text), ["Later visible message"]);
  assert.equal(second.hasMore, false);
});

test("family history bounds text bytes and reports clipping without losing the next row", async (context) => {
  const setup = await fixture(context);
  const texts = Array.from({ length: 5 }, (_, index) => `${index}:` + "\u0000🐷".repeat(2500));
  setup.insert(texts.map((text, index) => ["family-session", index, human(text)]));
  const tool = setup.discover();
  const prefixes = [];
  let offset = 0;
  for (let attempt = 0; attempt < 6; attempt += 1) {
    const result = await page(tool, { limit: 50, offset });
    assert.equal(result.truncated, true);
    for (const entry of result.entries) {
      prefixes.push(entry.text.slice(0, 2));
      assert.equal(entry.truncated, true);
      assert.ok(entry.text.length <= 2000);
      assert.ok(entry.text.isWellFormed());
    }
    if (!result.hasMore) break;
    assert.ok(result.nextOffset > offset);
    offset = result.nextOffset;
  }
  assert.deepEqual(prefixes, ["0:", "1:", "2:", "3:", "4:"]);
});

test("family history rejects malformed pagination and model-selected context before reading", async (context) => {
  const setup = await fixture(context);
  const tool = setup.discover();
  setup.api.runtime.state.resolveStateDir = () => { assert.fail("invalid arguments accessed storage"); };
  for (const args of [
    null, [], "not an object", { limit: 0 }, { limit: 51 }, { limit: 1.5 }, { limit: "2" },
    { limit: NaN }, { offset: -1 }, { offset: 0.5 }, { offset: Infinity }, { offset: "0" },
    { offset: Number.MAX_SAFE_INTEGER }, { source: "private" }, { source: null },
    { sessionKey: "agent:main:main" }, { path: "private.sqlite" }, { sql: "SELECT * FROM secrets" },
    { requesterSenderId: SENDER }, { recipient: SENDER },
  ]) {
    const result = await tool.execute("test-call", args);
    assert.equal(result.isError, true, JSON.stringify(args));
    assert.equal(JSON.parse(result.content[0].text).code, "invalid_arguments");
  }
});

test("family history distinguishes empty missing and unavailable retained storage", async (context) => {
  const setup = await fixture(context);
  const empty = await page(setup.discover());
  assert.deepEqual(empty.entries, []);
  assert.equal(empty.hasMore, false);
  assert.equal(empty.oldestRetainedEventAt, null);
  assert.equal(empty.retention.completeTelegramHistory, false);
  assert.match(empty.retention.note, /never received|pruned/);
  const missing = await fixture(context, { hasDatabase: false });
  const before = await missing.discover().execute("test-call", {});
  assert.equal(before.isError, true);
  assert.equal(JSON.parse(before.content[0].text).code, "history_unavailable");
  await assert.rejects(readFile(missing.databasePath), { code: "ENOENT" });
  await writeFile(missing.databasePath, "not a SQLite database PRIVATE_PATH");
  const corrupt = await missing.discover().execute("test-call", {});
  assert.equal(corrupt.isError, true);
  assert.equal(JSON.parse(corrupt.content[0].text).code, "history_unavailable");
  assert.doesNotMatch(corrupt.content[0].text, /PRIVATE_PATH|openclaw-agent|family-history-/);
});

test("family history reads without modifying SQLite and bounds locked database waits", async (context) => {
  const setup = await fixture(context);
  setup.insert([["family-session", 1, human("A retained message")]]);
  const before = await readFile(setup.databasePath);
  await page(setup.discover());
  assert.deepEqual(await readFile(setup.databasePath), before);
  const database = new DatabaseSync(setup.databasePath);
  try {
    database.exec("BEGIN EXCLUSIVE");
    const result = await setup.discover().execute("test-call", {});
    assert.equal(result.isError, true);
    assert.equal(JSON.parse(result.content[0].text).code, "history_unavailable");
  } finally {
    database.close();
  }
  assert.deepEqual((await page(setup.discover())).entries.map((entry) => entry.text), ["A retained message"]);
});

test("family history applies default and maximum page sizes and safe empty offsets", async (context) => {
  const setup = await fixture(context);
  setup.insert(Array.from({ length: 53 }, (_, index) => ["family-session", index, human(`message ${index}`)]));
  const tool = setup.discover();
  const first = await page(tool);
  assert.equal(first.entries.length, 20);
  assert.equal(first.nextOffset, 20);
  const maximum = await page(tool, { limit: 50 });
  assert.equal(maximum.entries.length, 50);
  const tail = await page(tool, { offset: maximum.nextOffset });
  assert.equal(tail.entries.length, 3);
  assert.equal(tail.hasMore, false);
  for (const offset of [53, 54, 1_000_000]) {
    const empty = await page(tool, { offset });
    assert.deepEqual(empty.entries, []);
    assert.equal(empty.hasMore, false);
    assert.equal(empty.nextOffset, null);
  }
});

test("family history discloses oversized retained events and keeps reading later entries", async (context) => {
  const setup = await fixture(context);
  setup.insert([
    ["family-session", 1, human("x".repeat(300_000))],
    ["family-session", 2, human("After oversized event")],
  ]);

  const result = await page(setup.discover());

  assert.deepEqual(result.entries.map((entry) => entry.text), ["After oversized event"]);
  assert.equal(result.skippedOversizedEvents, 1);
  assert.equal(result.truncated, true);
});

test("family history exposes the retained room supplement with its own limits", async (context) => {
  const setup = await fixture(context);
  const now = Date.now();
  const roomPath = path.join(setup.directory, "household-family-room", "room.json");
  await mkdir(path.dirname(roomPath));
  const records = [
    { key: "voice:1", kind: "voice", at: now - 3000, speaker: "Test Person", text: "Milk please" },
    { key: "photo:1", kind: "photo", at: now - 2000, speaker: "Test Person", text: "A receipt", caption: "Shopping" },
    { key: "peer:Test:1", kind: "peer", at: now - 1000, speaker: "Test Assistant", text: "I can go" },
    { key: "voice:old", kind: "voice", at: now - 25 * 3_600_000, text: "EXPIRED" },
    { key: "other", kind: "tool", at: now, text: "HIDDEN_TOOL" },
  ];
  await writeFile(roomPath, JSON.stringify(records));
  const before = await readFile(roomPath, "utf8");

  const first = await page(setup.discover(), { source: "room", limit: 2 });
  const second = await page(setup.discover(), { source: "room", limit: 2, offset: first.nextOffset });

  assert.deepEqual([...first.entries, ...second.entries].map((entry) => entry.text), ["Milk please", "A receipt", "I can go"]);
  assert.equal(first.entries[0].interpretation, "machine transcript");
  assert.equal(first.entries[1].interpretation, "machine description");
  assert.equal(first.entries[1].caption, "Shopping");
  assert.equal(second.entries[0].role, "assistant");
  assert.equal(first.retention.windowHours, 24);
  assert.equal(first.retention.maximumRecords, 120);
  assert.equal(first.retention.completeTelegramHistory, false);
  assert.match(first.retention.note, /truncat|clip/);
  assert.equal(await readFile(roomPath, "utf8"), before);
});

test("family history room source preserves media priority and bounds corrupt input", async (context) => {
  const setup = await fixture(context);
  const now = Date.now();
  const roomPath = path.join(setup.directory, "household-family-room", "room.json");
  await mkdir(path.dirname(roomPath));
  await writeFile(roomPath, JSON.stringify([
    { key: "voice:1", kind: "voice", at: now - 10_000, speaker: "Test", text: "Keep this note" },
    ...Array.from({ length: 125 }, (_, index) => ({
      key: `peer:${index}`, kind: "peer", at: now - 1000 + index, speaker: "Test", text: `post ${index}`,
    })),
  ]));
  const result = await page(setup.discover(), { source: "room", limit: 1 });
  assert.equal(result.entries[0].text, "Keep this note");
  assert.equal(result.hasMore, true);
  for (const contents of ["{not json", "null", "[]" + " ".repeat(2_100_000)]) {
    await writeFile(roomPath, contents);
    const failed = await setup.discover().execute("test-call", { source: "room" });
    assert.equal(failed.isError, true);
    assert.equal(JSON.parse(failed.content[0].text).code, "history_unavailable");
  }
});

function said(text, id) {
  return { type: "message", message: {
    role: "user", content: text,
    __openclaw: { senderId: id, senderName: id, senderIdentity: { type: "observation", id, pluginId: "household", accountId: "default", senderKind: "unknown" } },
  } };
}

test("family history admits the app's family room and its owner's own thread", async (context) => {
  const setup = await fixture(context);
  setup.insert([["family-session", 1, human("Family plans")]]);
  for (const overrides of [
    APP_FAMILY_TURN,
    { ...APP_FAMILY_TURN, requesterSenderId: APP_OWNER },
    { ...APP_FAMILY_TURN, requesterSenderId: `household:${APP_PEER}`, nativeChannelId: "family" },
    // The owner's family-room turn, in the owner's own session of the room.
    { ...APP_FAMILY_TURN, requesterSenderId: APP_OWNER, sessionKey: `agent:main:household:group:family:sender:${APP_OWNER}` },
    APP_PRIVATE_TURN,
  ]) {
    assert.deepEqual((await page(setup.discover(overrides))).entries.map((entry) => entry.text), ["Family plans"], JSON.stringify(overrides));
  }
});

test("family history denies every other app route before accessing storage", async (context) => {
  const setup = await fixture(context);
  setup.api.runtime.state.resolveStateDir = () => { assert.fail("denied context accessed storage"); };
  for (const overrides of [
    { ...APP_FAMILY_TURN, requesterSenderId: "pat" },
    { ...APP_FAMILY_TURN, requesterSenderId: undefined },
    { ...APP_FAMILY_TURN, nativeChannelId: APP_OWNER },
    { ...APP_FAMILY_TURN, sessionKey: "agent:main:household:group:other" },
    { ...APP_FAMILY_TURN, sessionKey: `agent:main:household:direct:${APP_OWNER}` },
    { ...APP_FAMILY_TURN, sessionKey: `agent:main:household:group:family:sender:${APP_OWNER}` },
    { ...APP_FAMILY_TURN, sessionKey: `agent:main:household:group:family:sender:${APP_PEER}` },
    { ...APP_FAMILY_TURN, deliveryContext: { channel: "household", accountId: "default", to: "household:other" } },
    { ...APP_FAMILY_TURN, deliveryContext: { channel: "household", accountId: "other", to: "household:family" } },
    { ...APP_FAMILY_TURN, deliveryContext: { channel: "telegram", accountId: "default", to: "household:family" } },
    { ...APP_FAMILY_TURN, deliveryContext: { channel: "household", accountId: "default", to: "household:family", threadId: "1" } },
    { ...APP_PRIVATE_TURN, requesterSenderId: APP_PEER },
    { ...APP_PRIVATE_TURN, sessionKey: `agent:main:household:direct:${APP_PEER}`,
      deliveryContext: { channel: "household", accountId: "default", to: `household:${APP_PEER}` } },
    { ...APP_PRIVATE_TURN, sessionKey: "agent:main:main" },
    { ...APP_PRIVATE_TURN, agentId: "other" },
    { ...APP_PRIVATE_TURN, oneShotCliRun: true },
  ]) {
    assert.equal(setup.discover(overrides), null, JSON.stringify(overrides));
  }
  for (const mutate of [
    (config) => { delete config.channels.household; },
    (config) => { config.channels.household.enabled = false; },
    (config) => { config.session.dmScope = "main"; },
    (config) => { config.plugins.entries["household-family-room"].enabled = false; },
  ]) {
    const original = structuredClone(setup.runtime.value);
    mutate(setup.runtime.value);
    assert.equal(setup.discover(APP_FAMILY_TURN), null);
    setup.runtime.value = original;
  }
});

test("family history reads The Fam and the app's family room as one history, never a private thread", async (context) => {
  const setup = await fixture(context);
  setup.insert([
    ["family-session", 1, human("Said in The Fam"), START + 1],
    ["app-family-session", 1, said("Said in the app's family room", APP_PEER), START + 2],
    ["app-family-session", 2, said("Said by someone not in the family", "pat"), START + 3],
    ["app-private-session", 1, said("POCKETPIGGIES_PRIVATE_SENTINEL app thread", APP_OWNER), START + 4],
  ]);
  for (const turn of [{}, APP_FAMILY_TURN, APP_PRIVATE_TURN]) {
    const result = await page(setup.discover(turn));
    assert.deepEqual(result.entries.map((entry) => entry.text), ["Said in The Fam", "Said in the app's family room"]);
    assert.doesNotMatch(JSON.stringify(result), /SENTINEL/);
  }
});
