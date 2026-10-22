import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { OWNER_META, callKeyHolder } from "../../deploy/openclaw/plugins/pocket-piggies/client.mjs";
import { register } from "../../deploy/openclaw/plugins/pocket-piggies/index.mjs";
import { FAMILY_GROUP, FINANCE_SAFE_GATEWAY_CONFIG, OWNER } from "./fixtures/gateway.mjs";

const CONFIG = { ownerTelegramId: OWNER, accountLabel: "corey" };
const REQUEST = "0b4d3c1e-5f6a-4b7c-8d9e-0f1a2b3c4d5e";
const SECRET = `ppa_ro_${"S".repeat(43)}`;
const PRIVATE_TURN = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "telegram",
  requesterSenderId: OWNER,
  nativeChannelId: `telegram:${OWNER}`,
  sessionKey: `agent:main:telegram:direct:${OWNER}`,
  deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${OWNER}` },
};
const PRIVATE_COMMAND = {
  channel: "telegram",
  senderId: OWNER,
  from: `telegram:${OWNER}`,
  to: `telegram:${OWNER}`,
  isAuthorizedSender: true,
  sessionKey: `agent:main:telegram:direct:${OWNER}`,
};
// The owner's own thread in the Steward AI app, as household-app starts it for a message one
// of the owner's paired phones signed: the household channel names the owner as the sender.
const APP_OWNER = "franco";
const APP_CONFIG = { ...CONFIG, ownerHouseholdPersonId: APP_OWNER };
const APP_TURN = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  requesterSenderId: APP_OWNER,
  nativeChannelId: APP_OWNER,
  sessionKey: `agent:main:household:direct:${APP_OWNER}`,
  deliveryContext: { channel: "household", accountId: "default", to: `household:${APP_OWNER}` },
};

function socketPath() {
  return process.platform === "win32"
    ? `\\\\.\\pipe\\pocketpiggies-test-${randomUUID()}`
    : join(tmpdir(), `pp-${randomUUID().slice(0, 8)}.sock`);
}

/** A fake key holder speaking MCP over a real socket, answering from `answer`. */
async function keyHolder(t, answer, { protocolVersion = "2025-11-25", raw, owner = OWNER } = {}) {
  const path = socketPath();
  const calls = [];
  const server = createServer((socket) => {
    // The client hangs up on oversized or unwanted answers; that is the behaviour under test.
    socket.on("error", () => {});
    let buffered = "";
    socket.on("data", (chunk) => {
      buffered += chunk;
      let newline;
      while ((newline = buffered.indexOf("\n")) >= 0) {
        const message = JSON.parse(buffered.slice(0, newline));
        buffered = buffered.slice(newline + 1);
        if (raw) {
          socket.write(raw);
          continue;
        }
        if (message.method === "initialize") {
          socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: {
            protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "fake", version: "1" },
            _meta: { [OWNER_META]: owner },
          } })}\n`);
        } else if (message.method === "tools/call") {
          calls.push({ name: message.params.name, arguments: message.params.arguments });
          const [value, isError] = answer(message.params.name, message.params.arguments);
          socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: {
            content: [{ type: "text", text: JSON.stringify(value) }], ...(isError ? { isError: true } : {}),
          } })}\n`);
        }
      }
    });
  });
  await new Promise((resolve) => server.listen(path, resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return { path, calls };
}

function plugin({ path, config = FINANCE_SAFE_GATEWAY_CONFIG, pluginConfig = CONFIG }) {
  const registered = { commands: {}, tools: null, warnings: [] };
  const api = {
    pluginConfig: { ...pluginConfig },
    config,
    logger: { warn: (message) => registered.warnings.push(message) },
    registerCommand: (command) => { registered.commands[command.name] = command; },
    registerTool: (factory) => { registered.tools = factory; },
  };
  register(api, { invoke: (name, args, options = {}) => callKeyHolder(name, args, { ...options, socketPath: path }) });
  return { api, registered };
}

const readAnswer = (name, args) => name === "pocketpiggies_read"
  ? [{ source: "PocketPiggies", read: args.read, data: { safeCents: 12345, note: `echo ${SECRET}` } }, false]
  : [{ code: "unknown_tool", message: "no" }, true];

test("only the owner's isolated private Telegram turn discovers the three finance tools", async (t) => {
  const { path } = await keyHolder(t, readAnswer);
  const { registered } = plugin({ path });
  assert.deepEqual(registered.tools(PRIVATE_TURN).map((tool) => tool.name),
    ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]);
  const queued = { ...PRIVATE_TURN, nativeChannelId: undefined };
  assert.equal(registered.tools(queued).length, 3, "a queued turn uses the trusted delivery destination");
  for (const change of [
    { nativeChannelId: undefined, deliveryContext: { ...PRIVATE_TURN.deliveryContext, to: `telegram:${FAMILY_GROUP}` } },
    { deliveryContext: { ...PRIVATE_TURN.deliveryContext, to: `telegram:${FAMILY_GROUP}` } },
    { deliveryContext: { ...PRIVATE_TURN.deliveryContext, to: "telegram:654321" } },
    { deliveryContext: { ...PRIVATE_TURN.deliveryContext, channel: "webchat" } },
    { deliveryContext: { ...PRIVATE_TURN.deliveryContext, accountId: "second" } },
    { deliveryContext: { ...PRIVATE_TURN.deliveryContext, threadId: 7 } },
    { deliveryContext: undefined },
    { nativeChannelId: undefined, deliveryContext: undefined },
    { requesterSenderId: "654321" },
    { nativeChannelId: `telegram:${FAMILY_GROUP}` },
    { sessionKey: `agent:main:telegram:group:${FAMILY_GROUP}` },
    { sessionKey: "agent:main:main" },
    { sessionKey: "agent:main:cron:job" },
    { sessionKey: `agent:main:subagent:${OWNER}` },
    { messageChannel: "webchat" },
    { agentId: "other" },
    { agentAccountId: "second" },
    { oneShotCliRun: true },
    { sessionKey: `agent:other:telegram:direct:${OWNER}` },
    { sessionKey: `agent:main:telegram:default:direct:${OWNER}` },
  ]) {
    assert.equal(registered.tools({ ...PRIVATE_TURN, ...change }), null, JSON.stringify(change));
  }
  const unsafe = plugin({ path, config: { ...FINANCE_SAFE_GATEWAY_CONFIG, channels: { telegram: {
    ...FINANCE_SAFE_GATEWAY_CONFIG.channels.telegram, dmPolicy: "pairing" } } } });
  assert.equal(unsafe.registered.tools(PRIVATE_TURN), null);
});

test("the owner's own thread in the app discovers the finance tools only where the config names its owner", async (t) => {
  const { path } = await keyHolder(t, readAnswer);
  const { registered } = plugin({ path, pluginConfig: APP_CONFIG });
  assert.deepEqual(registered.tools(APP_TURN).map((tool) => tool.name),
    ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]);
  assert.equal(registered.tools({ ...APP_TURN, nativeChannelId: undefined }).length, 3, "a queued turn has no native chat");
  assert.equal(registered.tools({ ...APP_TURN, requesterSenderId: `household:${APP_OWNER}` }).length, 3);
  assert.equal(registered.tools(PRIVATE_TURN).length, 3, "the owner's Telegram chat keeps them");
  const telegramOnly = plugin({ path });
  assert.equal(telegramOnly.registered.tools(APP_TURN), null, "a gateway whose config names no app owner keeps finance on Telegram");
});

test("the owner's own words in the app's family room, in their own session of it, discover the finance tools, as in their thread", async (t) => {
  const { path } = await keyHolder(t, readAnswer);
  const { registered } = plugin({ path, pluginConfig: APP_CONFIG });
  const family = { channel: "household", accountId: "default", to: "household:family" };
  const turn = { ...APP_TURN, sessionKey: `agent:main:household:group:family:sender:${APP_OWNER}`, nativeChannelId: "family", deliveryContext: family };
  assert.deepEqual(registered.tools(turn).map((tool) => tool.name),
    ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]);
  assert.equal(registered.tools({ ...turn, nativeChannelId: undefined }).length, 3, "a queued turn has no native chat");
});

test("the app's finance refuses anyone else in the family room, other people, other sessions and channels, and every unsigned path", async (t) => {
  const { path, calls } = await keyHolder(t, readAnswer);
  const { registered } = plugin({ path, pluginConfig: APP_CONFIG });
  const family = { channel: "household", accountId: "default", to: "household:family" };
  for (const [label, change] of [
    // The family room: the room's shared session, which everyone's turns read, and anyone
    // but the owner in the owner's own session of it.
    ["the owner in the room's shared session", {
      sessionKey: "agent:main:household:group:family", nativeChannelId: "family", deliveryContext: family,
    }],
    ["the other person in the owner's own session of the room", {
      requesterSenderId: "gia", sessionKey: `agent:main:household:group:family:sender:${APP_OWNER}`, nativeChannelId: "family", deliveryContext: family,
    }],
    ["another sender's session of the room", {
      requesterSenderId: "gia", sessionKey: "agent:main:household:group:family:sender:gia", nativeChannelId: "family", deliveryContext: family,
    }],
    ["the other person in the family room", {
      requesterSenderId: "gia", sessionKey: "agent:main:household:group:family", nativeChannelId: "family", deliveryContext: family,
    }],
    ["the other assistant's handover in the family room", {
      requesterSenderId: "denise", sessionKey: "agent:main:household:group:family", nativeChannelId: "family", deliveryContext: family,
    }],
    ["the family room's session with the owner's thread as its route", { sessionKey: "agent:main:household:group:family" }],
    ["the owner's thread's session with the family room as its native chat", {
      sessionKey: "agent:main:household:group:family", nativeChannelId: APP_OWNER, deliveryContext: family,
    }],
    ["a reply routed to the family room", { deliveryContext: family }],
    ["a native chat that is not the owner's", { nativeChannelId: "family" }],
    // Another person's thread, wherever it is routed.
    ["the other person's own thread", {
      requesterSenderId: "gia", sessionKey: "agent:main:household:direct:gia", nativeChannelId: "gia",
      deliveryContext: { channel: "household", accountId: "default", to: "household:gia" },
    }],
    ["the other person in the owner's thread", { requesterSenderId: "gia" }],
    // Unsigned paths into the owner's session: a gateway client's chat.send names its own
    // client id as the sender, the agent method and automations name none.
    ["chat.send from the phone's own connection", { requesterSenderId: "openclaw-ios" }],
    ["chat.send from the command line", { requesterSenderId: "cli" }],
    ["a turn with no sender", { requesterSenderId: undefined }],
    ["an empty sender", { requesterSenderId: "" }],
    ["a sender spelled as a Telegram chat", { requesterSenderId: `telegram:${APP_OWNER}` }],
    // Other sessions and channels.
    ["the shared main session", { sessionKey: "agent:main:main" }],
    ["an automation", { sessionKey: "agent:main:cron:job" }],
    ["a sub-agent", { sessionKey: `agent:main:subagent:${APP_OWNER}` }],
    ["another agent", { sessionKey: `agent:other:household:direct:${APP_OWNER}` }],
    ["an account-scoped session", { sessionKey: `agent:main:household:default:direct:${APP_OWNER}` }],
    ["web chat", { messageChannel: "webchat" }],
    ["Telegram", { messageChannel: "telegram" }],
    ["a reply routed to web chat", { deliveryContext: { ...APP_TURN.deliveryContext, channel: "webchat" } }],
    ["a reply routed to Telegram", { deliveryContext: { channel: "telegram", accountId: "default", to: `telegram:${OWNER}` } }],
    ["a reply routed to another person", { deliveryContext: { ...APP_TURN.deliveryContext, to: "household:gia" } }],
    ["a second account", { deliveryContext: { ...APP_TURN.deliveryContext, accountId: "second" } }],
    ["a thread", { deliveryContext: { ...APP_TURN.deliveryContext, threadId: 7 } }],
    ["no route", { deliveryContext: undefined }],
    ["another agent id", { agentId: "other" }],
    ["another agent account", { agentAccountId: "second" }],
    ["a one-shot command line run", { oneShotCliRun: true }],
  ]) {
    assert.equal(registered.tools({ ...APP_TURN, ...change }), null, label);
  }
  assert.deepEqual(calls, []);
});

test("an owner the config cannot name safely turns the app's finance off", async (t) => {
  const { path } = await keyHolder(t, readAnswer);
  for (const person of ["cli", "openclaw-ios", "webchat", "Franco", "", 7]) {
    const { registered } = plugin({ path, pluginConfig: { ...CONFIG, ownerHouseholdPersonId: person } });
    const turn = {
      ...APP_TURN,
      requesterSenderId: person,
      nativeChannelId: undefined,
      sessionKey: `agent:main:household:direct:${person}`,
      deliveryContext: { ...APP_TURN.deliveryContext, to: `household:${person}` },
    };
    assert.equal(registered.tools(turn), null, String(person));
    assert.equal(registered.tools(PRIVATE_TURN).length, 3, "Telegram is unaffected");
  }
});

test("an app read reaches the key holder as the Telegram owner the config maps the household person to", async (t) => {
  const { path, calls } = await keyHolder(t, readAnswer);
  const { registered } = plugin({ path, pluginConfig: APP_CONFIG });
  const read = registered.tools(APP_TURN).find((tool) => tool.name === "pocketpiggies_read");
  const result = await read.execute("call-app", { read: "account.safe_to_transfer", params: {} });
  assert.equal(result.isError, undefined);
  assert.equal(result.details.data.safeCents, 12345);
  assert.deepEqual(calls, [{ name: "pocketpiggies_read", arguments: { read: "account.safe_to_transfer", params: {} } }]);
  const someoneElses = await keyHolder(t, readAnswer, { owner: "654321" });
  const elsewhere = plugin({ path: someoneElses.path, pluginConfig: APP_CONFIG });
  const refused = await elsewhere.registered.tools(APP_TURN).find((tool) => tool.name === "pocketpiggies_read")
    .execute("call-app-2", { read: "account.safe_to_transfer" });
  assert.match(refused.content[0].text, /belongs to someone else/);
  assert.deepEqual(someoneElses.calls, []);
});

test("an app tool rechecks its owner before any key holder call", async (t) => {
  const { path, calls } = await keyHolder(t, readAnswer);
  const { api, registered } = plugin({ path, pluginConfig: APP_CONFIG });
  const read = registered.tools(APP_TURN).find((tool) => tool.name === "pocketpiggies_read");
  api.pluginConfig = { ...APP_CONFIG, ownerHouseholdPersonId: "gia" };
  const swapped = await read.execute("call-app-3", { read: "account.safe_to_transfer" });
  assert.equal(swapped.isError, true);
  assert.match(swapped.content[0].text, /private_chat_required/);
  assert.equal(registered.tools({ ...APP_TURN, requesterSenderId: "gia", sessionKey: "agent:main:household:direct:gia",
    nativeChannelId: "gia", deliveryContext: { ...APP_TURN.deliveryContext, to: "household:gia" } }), null,
  "a config changed after start names nobody until the gateway restarts");
  assert.deepEqual(calls, []);
});

test("a read reaches the key holder over MCP and returns its figures with credentials removed", async (t) => {
  const { path, calls } = await keyHolder(t, readAnswer);
  const { registered } = plugin({ path });
  const read = registered.tools(PRIVATE_TURN).find((tool) => tool.name === "pocketpiggies_read");
  const result = await read.execute("call-1", { read: "account.safe_to_transfer", params: {} });
  assert.equal(result.isError, undefined);
  assert.deepEqual(calls, [{ name: "pocketpiggies_read", arguments: { read: "account.safe_to_transfer", params: {} } }]);
  assert.equal(result.details.data.safeCents, 12345);
  assert.doesNotMatch(JSON.stringify(result), /ppa_ro_S/);
});

test("the read tools offer a sync the key holder decides on, and the catalog offers none", async (t) => {
  const { path, calls } = await keyHolder(t, (name, args) => [{ source: "PocketPiggies", [name]: args }, false]);
  const { registered } = plugin({ path });
  const byName = Object.fromEntries(registered.tools(PRIVATE_TURN).map((tool) => [tool.name, tool]));
  for (const name of ["pocketpiggies_read", "pocketpiggies_records"]) {
    assert.deepEqual(byName[name].parameters.properties.sync.enum, ["if_stale", "now"], name);
    assert.match(byName[name].description, /freshness/);
  }
  assert.equal(byName.pocketpiggies_catalog.parameters.properties.sync, undefined);

  await byName.pocketpiggies_read.execute("call-1", { read: "plaid.status", sync: "now" });
  await byName.pocketpiggies_records.execute("call-2", { table: "transactions", sync: "if_stale" });

  // The plugin passes the choice on as is: the cooling-off window lives in the key holder,
  // where the model's own shell cannot reset it.
  assert.deepEqual(calls, [
    { name: "pocketpiggies_read", arguments: { read: "plaid.status", sync: "now" } },
    { name: "pocketpiggies_records", arguments: { table: "transactions", sync: "if_stale" } },
  ]);
});

test("a stale tool rechecks the owner and the gateway policy before any key holder call", async (t) => {
  const { path, calls } = await keyHolder(t, readAnswer);
  const { api, registered } = plugin({ path });
  const read = registered.tools(PRIVATE_TURN).find((tool) => tool.name === "pocketpiggies_read");
  api.config = { ...FINANCE_SAFE_GATEWAY_CONFIG, channels: { telegram: {
    ...FINANCE_SAFE_GATEWAY_CONFIG.channels.telegram,
    groups: { [FAMILY_GROUP]: { tools: { allow: ["web_search", "exec"] } } } } } };
  const drifted = await read.execute("call-2", { read: "account.safe_to_transfer" });
  assert.equal(drifted.isError, true);
  assert.match(drifted.content[0].text, /private_chat_required/);
  api.config = FINANCE_SAFE_GATEWAY_CONFIG;
  api.pluginConfig = { ...CONFIG, ownerTelegramId: "654321" };
  const swapped = await read.execute("call-3", { read: "account.safe_to_transfer" });
  assert.equal(swapped.isError, true);
  assert.deepEqual(calls, []);
});

test("a key holder pinned to someone else is refused before any call", async (t) => {
  const { path, calls } = await keyHolder(t, readAnswer, { owner: "654321" });
  const { registered } = plugin({ path });
  const read = registered.tools(PRIVATE_TURN).find((tool) => tool.name === "pocketpiggies_read");
  const result = await read.execute("call-5", { read: "account.safe_to_transfer" });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /belongs to someone else/);
  const connect = await registered.commands.pocketpiggies.handler({ ...PRIVATE_COMMAND, args: "connect" });
  assert.equal(connect.isError, true);
  assert.deepEqual(calls, []);
});

test("drift turns finance off and is reported once until it is repaired", async (t) => {
  const { path } = await keyHolder(t, readAnswer);
  const { api, registered } = plugin({ path });
  api.config = { ...FINANCE_SAFE_GATEWAY_CONFIG, session: { ...FINANCE_SAFE_GATEWAY_CONFIG.session, scope: "global" } };
  assert.equal(registered.tools(PRIVATE_TURN), null);
  assert.equal(registered.tools(PRIVATE_TURN), null);
  assert.equal(registered.warnings.length, 1);
  assert.match(registered.warnings[0], /finance is off/);
  api.config = FINANCE_SAFE_GATEWAY_CONFIG;
  assert.equal(registered.tools(PRIVATE_TURN).length, 3);
});

test("key holder refusals reach the model as their code and message, never as figures", async (t) => {
  const { path } = await keyHolder(t, () => [{ code: "connection_required", message: `Connect first ${SECRET}` }, true]);
  const { registered } = plugin({ path });
  const records = registered.tools(PRIVATE_TURN).find((tool) => tool.name === "pocketpiggies_records");
  const result = await records.execute("call-4", { table: "transactions" });
  assert.equal(result.isError, true);
  assert.deepEqual(JSON.parse(result.content[0].text), { code: "connection_required", message: "Connect first [redacted]" });
});

test("connect shows a PocketPiggies button and the deep link finishes the same request", async (t) => {
  const { path, calls } = await keyHolder(t, (name) => ({
    link_start: [{ text: "Connect your account.", url: `https://pocketpiggies.app/assistant/connect?request=${REQUEST}` }, false],
    link_complete: [{ text: "Connected." }, false],
    link_status: [{ text: "Saved connection." }, false],
    link_disconnect: [{ text: "Disconnected." }, false],
  })[name]);
  const { registered } = plugin({ path });
  const connect = await registered.commands.pocketpiggies.handler({ ...PRIVATE_COMMAND, args: "connect" });
  assert.deepEqual(connect.channelData.telegram.buttons, [[{
    text: "Connect PocketPiggies", url: `https://pocketpiggies.app/assistant/connect?request=${REQUEST}`,
  }]]);
  const fromDeepLink = await registered.commands.start.handler({ ...PRIVATE_COMMAND, args: "pp_connect" });
  assert.equal(fromDeepLink.channelData.telegram.buttons.length, 1);
  assert.deepEqual(await registered.commands.start.handler({ ...PRIVATE_COMMAND, args: `pp_${REQUEST}` }), { text: "Connected." });
  assert.deepEqual(await registered.commands.pocketpiggies.handler({ ...PRIVATE_COMMAND, args: "status" }), { text: "Saved connection." });
  assert.deepEqual(await registered.commands.pocketpiggies.handler({ ...PRIVATE_COMMAND, args: "disconnect" }), { text: "Disconnected." });
  assert.deepEqual(calls.map((call) => call.name), ["link_start", "link_start", "link_complete", "link_status", "link_disconnect"]);
  assert.deepEqual(calls[2].arguments, { requestId: REQUEST });
});

test("connection commands outside the owner's private chat never reach the key holder", async (t) => {
  const { path, calls } = await keyHolder(t, () => [{ text: "no" }, false]);
  const { registered } = plugin({ path });
  for (const change of [
    { senderId: "654321", from: "telegram:654321" },
    { to: `telegram:${FAMILY_GROUP}`, sessionKey: `agent:main:telegram:group:${FAMILY_GROUP}` },
    { isAuthorizedSender: false },
    { sessionKey: "agent:main:main" },
  ]) {
    const result = await registered.commands.pocketpiggies.handler({ ...PRIVATE_COMMAND, ...change, args: "connect" });
    assert.equal(result.isError, true, JSON.stringify(change));
    assert.match(result.text, /private Telegram chat/);
  }
  assert.deepEqual(calls, []);
});

test("a connect link that is not PocketPiggies' own consent page is refused", async (t) => {
  for (const url of [
    "https://evil.example/assistant/connect?request=" + REQUEST,
    "http://pocketpiggies.app/assistant/connect?request=" + REQUEST,
    "https://pocketpiggies.app/assistant/connect?request=" + REQUEST + "&next=https://evil.example",
    undefined,
  ]) {
    const { path } = await keyHolder(t, () => [{ text: "Connect.", url }, false]);
    const { registered } = plugin({ path });
    const result = await registered.commands.pocketpiggies.handler({ ...PRIVATE_COMMAND, args: "connect" });
    assert.equal(result.isError, true, String(url));
    assert.equal(result.channelData, undefined);
  }
});

test("a missing, silent or malformed key holder fails closed with no figure", async (t) => {
  const missing = await callKeyHolder("pocketpiggies_catalog", {}, { owner: OWNER, socketPath: socketPath() }).catch((error) => error);
  assert.equal(missing.code, "key_holder_unavailable");
  const wrongProtocol = await keyHolder(t, readAnswer, { protocolVersion: "2024-11-05" });
  assert.equal((await callKeyHolder("pocketpiggies_catalog", {}, { owner: OWNER, socketPath: wrongProtocol.path }).catch((error) => error)).code,
    "mcp_transport_error");
  const garbage = await keyHolder(t, readAnswer, { raw: "not json\n" });
  assert.equal((await callKeyHolder("pocketpiggies_catalog", {}, { owner: OWNER, socketPath: garbage.path }).catch((error) => error)).code,
    "mcp_transport_error");
  const silent = await keyHolder(t, readAnswer, { raw: " " });
  assert.equal((await callKeyHolder("pocketpiggies_catalog", {}, { owner: OWNER, socketPath: silent.path, timeoutMs: 200 }).catch((error) => error)).code,
    "request_timeout");
  const huge = await keyHolder(t, readAnswer, { raw: "x".repeat(4 * 1024 * 1024) });
  assert.equal((await callKeyHolder("pocketpiggies_catalog", {}, { owner: OWNER, socketPath: huge.path }).catch((error) => error)).code,
    "response_too_large");
  const aborted = new AbortController();
  aborted.abort();
  assert.equal((await callKeyHolder("pocketpiggies_catalog", {}, { owner: OWNER, socketPath: silent.path, signal: aborted.signal }).catch((error) => error)).code,
    "request_cancelled");
});
