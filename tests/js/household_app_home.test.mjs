// The house's thermostat and music, from deploy/openclaw/plugins/household-app: the turns in
// which household_home answers, what each action asks the home key holder, and what the
// client does with a key holder that is missing, slow or wrong.
//
// Run with `node --test tests/js/household_app_home.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { HomeUnavailable, callHome } from "../../deploy/openclaw/plugins/household-app/home-client.js";
import { HOME_TOOL, createHomeTool } from "../../deploy/openclaw/plugins/household-app/home-tool.js";

const DIRECT = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  deliveryContext: { channel: "household", accountId: "default", to: "household:franco" },
  requesterSenderId: "franco",
  sessionKey: "agent:main:household:direct:franco",
};
const FAMILY = {
  ...DIRECT,
  deliveryContext: { ...DIRECT.deliveryContext, to: "household:family" },
  requesterSenderId: "gia",
  sessionKey: "agent:main:household:group:family",
};
const PLAYLIST = "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M";

const text = (value) => ({ content: [{ type: "text", text: JSON.stringify(value) }] });

function tool(context, answer = () => text({ thermostat: { temperature: 71.7 } })) {
  const calls = [];
  const found = createHomeTool({
    context,
    owner: "franco",
    people: ["franco", "gia"],
    call: async (name, args, options) => {
      calls.push({ name, args, hasSignal: "signal" in options });
      return answer(name, args);
    },
  });
  return { found, calls };
}

async function run(found, args) {
  const result = await found.execute("call-1", args, undefined);
  return { ...JSON.parse(result.content[0].text), isError: result.isError === true };
}

// MARK: - The turns it answers in

test("the tool is offered in the owner's own thread and in the family room", () => {
  for (const context of [DIRECT, FAMILY]) {
    const { found } = tool(context);
    assert.equal(found.name, HOME_TOOL);
    assert.equal(HOME_TOOL, "household_home");
    assert.equal(found.parameters.additionalProperties, false);
  }
});

for (const [why, context] of [
  ["Telegram", { ...DIRECT, messageChannel: "telegram", deliveryContext: { ...DIRECT.deliveryContext, channel: "telegram" } }],
  ["an automation with no sender", { ...DIRECT, requesterSenderId: undefined }],
  ["a gateway client speaking as itself", { ...DIRECT, requesterSenderId: "openclaw-ios", deliveryContext: { ...DIRECT.deliveryContext, to: "household:openclaw-ios" } }],
  ["the other person in the owner's thread", { ...DIRECT, requesterSenderId: "gia" }],
  ["a stranger in the family room", { ...FAMILY, requesterSenderId: "mallory" }],
  ["a turn the other assistant's @mention started", { ...FAMILY, requesterSenderId: "denise" }],
  ["another agent", { ...DIRECT, agentId: "helper" }],
]) {
  test(`the tool is not offered to ${why}`, () => {
    assert.equal(tool(context).found, null);
  });
}

// MARK: - What each action asks the key holder

const ASKS = [
  [{ action: "status" }, "home_status", {}],
  [{ action: "thermostat", low: 68, high: 73 }, "home_thermostat", { low: 68, high: 73, confirmed: false }],
  [{ action: "thermostat", low: 68, high: 73, confirmed: true }, "home_thermostat", { low: 68, high: 73, confirmed: true }],
  [{ action: "thermostat", target: 73 }, "home_thermostat", { target: 73, confirmed: false }],
  [{ action: "volume", percent: 55, confirmed: "yes" }, "home_volume", { percent: 55, confirmed: false }],
  [{ action: "volume", step: "down" }, "home_volume", { step: "down", confirmed: false }],
  [{ action: "music", control: "pause" }, "home_music", { action: "pause" }],
  [{ action: "play", link: PLAYLIST }, "home_play", { link: PLAYLIST }],
  [{ action: "play", query: "Shake It Off Taylor Swift", kind: "track" }, "home_play", { query: "Shake It Off Taylor Swift", kind: "track" }],
  [{ action: "open_spotify" }, "home_open_spotify", {}],
  [{ action: "youtube", link: "https://youtu.be/n0FBb6hnwTo" }, "home_youtube", { link: "https://youtu.be/n0FBb6hnwTo" }],
  [{ action: "video", control: "pause" }, "home_video", { control: "pause" }],
  [{ action: "video", control: "seek", seconds: -30 }, "home_video", { control: "seek", seconds: -30 }],
  [{ action: "tv", power: "off" }, "home_tv", { power: "off" }],
];

for (const [args, name, sent] of ASKS) {
  test(`${JSON.stringify(args)} asks the key holder for ${name}`, async () => {
    const { found, calls } = tool(DIRECT);
    await found.execute("call-1", args, undefined);
    assert.deepEqual(calls, [{ name, args: sent, hasSignal: true }]);
  });
}

// Corey's gateway runs this plugin for Franco and Denise's for Gia, so no difference
// between the two assistants' home controls can come from here.
test("Corey and Denise offer the same tool and ask their key holders the same", async () => {
  const sides = [["franco", "gia"], ["gia", "franco"]].map(([owner, peer]) => {
    const calls = [];
    const own = {
      ...DIRECT,
      deliveryContext: { ...DIRECT.deliveryContext, to: `household:${owner}` },
      requesterSenderId: owner,
      sessionKey: `agent:main:household:direct:${owner}`,
    };
    const tools = [own, { ...FAMILY, requesterSenderId: peer }].map((context) =>
      createHomeTool({ context, owner, people: [owner, peer], call: async (name, args) => (calls.push({ name, args }), text({})) }),
    );
    return { tools, calls };
  });
  const [corey, denise] = sides.map(({ tools }) => tools.map(({ name, label, description, parameters }) => ({ name, label, description, parameters })));
  assert.equal(corey.length, 2);
  assert.ok(corey.every((offered) => offered.name === HOME_TOOL));
  assert.deepEqual(denise, corey);
  for (const { tools } of sides) {
    for (const offered of tools) for (const [args] of ASKS) await offered.execute("call-1", args, undefined);
  }
  assert.equal(sides[0].calls.length, 2 * ASKS.length);
  assert.deepEqual(sides[1].calls, sides[0].calls);
});

test("the key holder's answer is passed on as it read the house back", async () => {
  const { found } = tool(FAMILY, () => text({ needs_yes: "Turn the TV up to 55%?" }));
  assert.deepEqual(await run(found, { action: "volume", percent: 55 }), { needs_yes: "Turn the TV up to 55%?", isError: false });
});

test("the key holder's refusal stays a refusal", async () => {
  const { found } = tool(DIRECT, () => ({ ...text({ code: "not_spotify", message: "Give a full open.spotify.com link." }), isError: true }));
  assert.deepEqual(await run(found, { action: "play", link: "https://example.com/x" }), {
    code: "not_spotify",
    message: "Give a full open.spotify.com link.",
    isError: true,
  });
});

for (const [why, args] of [
  ["an unknown action", { action: "unlock" }],
  ["no action", {}],
  ["another action's field", { action: "status", percent: 10 }],
  ["a field from play on open_spotify", { action: "open_spotify", query: "Shake It Off" }],
  ["a Spotify query on youtube", { action: "youtube", link: "https://youtu.be/n0FBb6hnwTo", query: "x" }],
  ["a field no action has", { action: "tv", power: "on", entity_id: "lock.front_door" }],
]) {
  test(`${why} is refused before the key holder`, async () => {
    const { found, calls } = tool(DIRECT);
    const answer = await run(found, args);
    assert.equal(answer.code, "invalid_arguments");
    assert.equal(answer.isError, true);
    assert.deepEqual(calls, []);
  });
}

for (const [why, answer] of [
  ["no content", {}],
  ["two blocks", { content: [{ type: "text", text: "{}" }, { type: "text", text: "{}" }] }],
  ["an image", { content: [{ type: "image", data: "", mimeType: "image/png" }] }],
]) {
  test(`an answer with ${why} is not passed on`, async () => {
    const { found } = tool(DIRECT, () => answer);
    assert.equal((await run(found, { action: "status" })).code, "mcp_transport_error");
  });
}

test("a key holder that is not there is said plainly", async () => {
  const { found } = tool(DIRECT, () => {
    throw new HomeUnavailable("home_unavailable", "Home control is not available on this assistant right now.");
  });
  assert.deepEqual(await run(found, { action: "status" }), {
    code: "home_unavailable",
    message: "Home control is not available on this assistant right now.",
    isError: true,
  });
});

// MARK: - The client, against a fake key holder on a real socket

function socketPath() {
  return process.platform === "win32"
    ? `\\\\.\\pipe\\household-home-test-${randomUUID()}`
    : join(tmpdir(), `home-${randomUUID().slice(0, 8)}.sock`);
}

async function keyHolder(t, { protocolVersion = "2025-11-25", raw, silent = false } = {}) {
  const path = socketPath();
  const calls = [];
  const server = createServer((socket) => {
    socket.on("error", () => {});
    let buffered = "";
    socket.on("data", (chunk) => {
      buffered += chunk;
      let newline;
      while ((newline = buffered.indexOf("\n")) >= 0) {
        const message = JSON.parse(buffered.slice(0, newline));
        buffered = buffered.slice(newline + 1);
        if (silent) continue;
        if (raw) {
          socket.write(raw);
          continue;
        }
        if (message.method === "initialize") {
          socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: {
            protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "household-home", version: "1.0.0" },
          } })}\n`);
        } else if (message.method === "tools/call") {
          calls.push(message.params);
          socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: text({ tv: "on" }) })}\n`);
        }
      }
    });
  });
  await new Promise((resolve) => server.listen(path, resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return { path, calls };
}

test("the client calls one tool after initializing", async (t) => {
  const { path, calls } = await keyHolder(t);
  assert.deepEqual(await callHome("home_tv", { power: "on" }, { socketPath: path }), text({ tv: "on" }));
  assert.deepEqual(calls, [{ name: "home_tv", arguments: { power: "on" } }]);
});

test("a key holder that is missing, wrong, silent or too large is a coded refusal", async (t) => {
  const failed = (promise) => promise.then(() => null, (error) => error);
  const missing = await failed(callHome("home_status", {}, { socketPath: socketPath() }));
  assert.ok(missing instanceof HomeUnavailable);
  assert.equal(missing.code, "home_unavailable");
  const wrongProtocol = await keyHolder(t, { protocolVersion: "2024-11-05" });
  assert.equal((await failed(callHome("home_status", {}, { socketPath: wrongProtocol.path }))).code, "mcp_transport_error");
  const garbage = await keyHolder(t, { raw: "not json\n" });
  assert.equal((await failed(callHome("home_status", {}, { socketPath: garbage.path }))).code, "mcp_transport_error");
  const silent = await keyHolder(t, { silent: true });
  assert.equal((await failed(callHome("home_status", {}, { socketPath: silent.path, timeoutMs: 200 }))).code, "request_timeout");
  const huge = await keyHolder(t, { raw: "x".repeat(70 * 1024) });
  assert.equal((await failed(callHome("home_status", {}, { socketPath: huge.path }))).code, "response_too_large");
  const aborted = new AbortController();
  aborted.abort();
  assert.equal((await failed(callHome("home_status", {}, { socketPath: silent.path, signal: aborted.signal }))).code, "request_cancelled");
});
