// Where the owner is, from deploy/openclaw/plugins/household-app: what the owner's phone
// may tell the gateway, what the gateway keeps and for how long, and the turns in which
// the assistant's household_location tool answers.
//
// Run with `node --test tests/js/household_app_location.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { test } from "node:test";

import { createLocation, locationText } from "../../deploy/openclaw/plugins/household-app/location.js";
import { LOCATION_TOOL, createLocationTool } from "../../deploy/openclaw/plugins/household-app/location-tool.js";

const NOW = Date.UTC(2026, 9, 15, 21, 52);
const HOUR = 3_600_000;

function phone() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    key: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url"),
    sign: (report) => sign(null, Buffer.from(locationText(report), "utf8"), privateKey).toString("base64url"),
  };
}

const FRANCO = phone();
const GIA = phone();

// Franco on Maple Street, eighteen minutes from home, sharing with Corey for an hour.
const POSITION = { latitudeE6: 39_768_403, longitudeE6: -86_158_068, accuracy: 65, at: NOW - 60_000 };
const SHARE = { at: NOW - 1000, sharing: "assistant", until: NOW + HOUR, position: POSITION };
const STOP = { at: NOW, sharing: "off", until: null, position: null };

function signed(report, by = FRANCO) {
  return { ...report, signature: by.sign(report) };
}

function setup({ keys = [FRANCO.key] } = {}) {
  let clock = NOW;
  const timers = [];
  const location = createLocation({
    phoneKeys: async () => keys,
    now: () => clock,
    setTimer: (run, delay) => {
      const timer = { run, delay, isCleared: false };
      timers.push(timer);
      return timer;
    },
    clearTimer: (timer) => {
      timer.isCleared = true;
    },
  });
  return {
    location,
    timers,
    advance: (milliseconds) => {
      clock += milliseconds;
    },
  };
}

// MARK: - What the phone signs

test("the signed text is one line per field, integers only, so the phone and the gateway write it alike", () => {
  assert.equal(
    locationText(SHARE),
    "household-app/location/v1\n1792101119000\nassistant\n1792104720000\n1792101060000\n39768403\n-86158068\n65",
  );
  assert.equal(locationText({ ...SHARE, until: null }).split("\n")[3], "", "always has no end");
  assert.equal(locationText(STOP), "household-app/location/v1\n1792101120000\noff\n\n\n\n\n");
});

// MARK: - The method

test("a share the owner's phone signed is kept, with its time and accuracy", async () => {
  const { location } = setup();
  assert.deepEqual(await location.report(signed(SHARE)), { sharing: "assistant", until: NOW + HOUR });
  assert.deepEqual(location.current(), {
    latitude: 39.768403,
    longitude: -86.158068,
    accuracy: 65,
    at: NOW - 60_000,
    audience: "assistant",
    until: NOW + HOUR,
  });
});

test("only the latest position is kept", async () => {
  const { location } = setup();
  await location.report(signed(SHARE));
  const nearer = { ...SHARE, at: NOW, position: { ...POSITION, latitudeE6: 39_790_000, at: NOW - 5000 } };
  await location.report(signed(nearer));
  assert.equal(location.current().latitude, 39.79);
  assert.equal(location.current().at, NOW - 5000);
});

test("a position nobody's phone signed, or another person's phone signed, is refused and nothing is kept", async () => {
  const { location } = setup();
  for (const [label, params] of [
    ["unsigned", { ...SHARE }],
    ["a signature that is not one", { ...SHARE, signature: "not-a-signature" }],
    ["Gia's phone", signed(SHARE, GIA)],
    ["a position moved after it was signed", { ...signed(SHARE), position: { ...POSITION, latitudeE6: 40_000_000 } }],
    ["shared with the family after it was signed for the assistant", { ...signed(SHARE), sharing: "family" }],
    ["an end moved after it was signed", { ...signed(SHARE), until: null }],
  ]) {
    await assert.rejects(location.report(params), { code: "INVALID_REQUEST", message: /signature/ }, label);
  }
  assert.equal(location.current(), null);
});

test("a phone paired after the keys were read is believed once the gateway lists it", async () => {
  const newPhone = phone();
  const { location } = setup({ keys: [newPhone.key] });
  await location.report(signed(SHARE, newPhone));
  assert.equal(location.current().audience, "assistant");
});

for (const [label, change] of [
  ["signed more than five minutes ago", { at: NOW - 6 * 60_000 }],
  ["signed in the future", { at: NOW + 6 * 60_000 }],
  ["a time that is not a whole number", { at: NOW + 0.5 }],
  ["an unknown audience", { sharing: "everyone" }],
  ["a share with no position", { position: null }],
  ["a share already over", { until: NOW - 1 }],
  ["a share that ends more than a day out", { until: NOW + 27 * HOUR }],
  ["a latitude off the globe", { position: { ...POSITION, latitudeE6: 90_000_001 } }],
  ["a longitude off the globe", { position: { ...POSITION, longitudeE6: -180_000_001 } }],
  ["a latitude in degrees, not millionths", { position: { ...POSITION, latitudeE6: 39.768403 } }],
  ["no accuracy", { position: { ...POSITION, accuracy: 0 } }],
  ["an accuracy wider than a city", { position: { ...POSITION, accuracy: 100_001 } }],
  ["a position from yesterday", { position: { ...POSITION, at: NOW - 25 * HOUR } }],
  ["a position from the future", { position: { ...POSITION, at: NOW + 6 * 60_000 } }],
  ["a stop that carries a position", { sharing: "off", until: null }],
  ["a stop with an end", { sharing: "off", until: NOW + HOUR, position: null }],
]) {
  test(`a report ${label} is refused`, async () => {
    const { location } = setup();
    const report = { ...SHARE, ...change };
    await assert.rejects(location.report(signed(report)), { code: "INVALID_REQUEST" });
    assert.equal(location.current(), null);
  });
}

test("a report the gateway has already had, or one older than it, cannot replace a newer one", async () => {
  const { location } = setup();
  const first = signed(SHARE);
  await location.report(first);
  await location.report(signed({ ...SHARE, at: NOW, position: { ...POSITION, latitudeE6: 39_790_000 } }));
  await assert.rejects(location.report(first), { code: "INVALID_REQUEST", message: /newer/ });
  assert.equal(location.current().latitude, 39.79);
});

test("stopping forgets the position, and the share before it cannot be played back", async () => {
  const { location } = setup();
  const share = signed(SHARE);
  await location.report(share);
  assert.deepEqual(await location.report(signed(STOP)), { sharing: "off", until: null });
  assert.equal(location.current(), null);
  await assert.rejects(location.report(share), { code: "INVALID_REQUEST" });
  assert.equal(location.current(), null);
});

test("a share is forgotten when its time is up, on its own and when read", async () => {
  const { location, timers, advance } = setup();
  await location.report(signed(SHARE));
  assert.equal(timers.length, 1);
  assert.equal(timers[0].delay, HOUR);

  advance(HOUR);
  assert.equal(location.current(), null, "read at its end, it is over");

  await location.report(signed({ ...SHARE, at: NOW + HOUR, until: NOW + 2 * HOUR, position: { ...POSITION, at: NOW + HOUR } }));
  assert.equal(timers[1].delay, HOUR);
  timers[1].run();
  assert.equal(location.current(), null, "the timer forgets it, before anybody reads it at its end");
});

test("a newer report or a stop clears the timer of the share before it", async () => {
  const { location, timers } = setup();
  await location.report(signed(SHARE));
  await location.report(signed({ ...SHARE, at: NOW - 500, until: null }));
  assert.equal(timers[0].isCleared, true);
  assert.equal(timers.length, 1, "always sets no timer");
  await location.report(signed(STOP));
  assert.equal(location.current(), null);
});

test("forget clears the position and its timer, as when the channel stops", async () => {
  const { location, timers } = setup();
  await location.report(signed(SHARE));
  location.forget();
  assert.equal(location.current(), null);
  assert.equal(timers[0].isCleared, true);
});

// MARK: - The tool

const PEOPLE = { owner: "franco", ownerName: "Franco", people: ["franco", "gia"] };
const OWN_THREAD = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  requesterSenderId: "franco",
  nativeChannelId: "franco",
  sessionKey: "agent:main:household:direct:franco",
  deliveryContext: { channel: "household", accountId: "default", to: "household:franco" },
};
const ROOM_ROUTE = { channel: "household", accountId: "default", to: "household:family" };
const FAMILY_ROOM = {
  ...OWN_THREAD,
  requesterSenderId: "gia",
  nativeChannelId: "family",
  sessionKey: "agent:main:household:group:family",
  deliveryContext: ROOM_ROUTE,
};

async function sharing(audience, { until = NOW + HOUR } = {}) {
  const { location, advance } = setup();
  await location.report(signed({ ...SHARE, sharing: audience, until }));
  return { location, advance };
}

function tool(context, location, { now = () => NOW, identity = PEOPLE } = {}) {
  return createLocationTool({ context, ...identity, current: () => location.current(), now });
}

async function answer(found, args = {}) {
  const result = await found.execute("call-1", args);
  return { ...result, payload: JSON.parse(result.content[0].text) };
}

test("in the owner's own thread the tool says where the owner is, how exactly and how long ago", async () => {
  const { location } = await sharing("assistant");
  const found = tool(OWN_THREAD, location);
  assert.equal(found.name, LOCATION_TOOL);
  assert.equal(found.name, "household_location");
  const { payload, isError } = await answer(found);
  assert.equal(isError, undefined);
  assert.deepEqual(payload, {
    shared: true,
    person: "Franco",
    latitude: 39.768403,
    longitude: -86.158068,
    accuracyMeters: 65,
    measuredAt: "2026-10-15T21:51:00.000Z",
    minutesAgo: 1,
    sharedWith: "assistant",
    sharingUntil: "2026-10-15T22:52:00.000Z",
  });
});

test("the tool measures the straight-line distance to a place it is given, such as home", async () => {
  const { location } = await sharing("assistant");
  const { payload } = await answer(tool(OWN_THREAD, location), { to: { latitude: 39.8684, longitude: -86.158068 } });
  assert.equal(payload.distanceKm, 11.1);
});

for (const [label, args] of [
  ["a place with no longitude", { to: { latitude: 39.8 } }],
  ["a latitude off the globe", { to: { latitude: 91, longitude: 0 } }],
  ["a place given as words", { to: "home" }],
  ["an argument it does not take", { person: "gia" }],
]) {
  test(`the tool refuses ${label}`, async () => {
    const { location } = await sharing("assistant");
    const { payload, isError } = await answer(tool(OWN_THREAD, location), args);
    assert.equal(isError, true);
    assert.equal(payload.code, "invalid_arguments");
    assert.equal(payload.latitude, undefined);
  });
}

test("in the owner's own thread with nothing shared, the tool says how to turn sharing on", async () => {
  const { location } = setup();
  const { payload } = await answer(tool(OWN_THREAD, location));
  assert.equal(payload.shared, false);
  assert.match(payload.message, /Settings/);
  assert.equal(payload.latitude, undefined);
});

test("once the share is over the tool says nothing is shared", async () => {
  const { location, advance } = await sharing("assistant");
  const found = tool(OWN_THREAD, location);
  advance(HOUR);
  const { payload } = await answer(found);
  assert.equal(payload.shared, false);
  assert.equal(payload.latitude, undefined);
});

test("in the family room the tool answers either person while the owner shares with the family", async () => {
  const { location } = await sharing("family");
  for (const sender of ["gia", "franco", "household:gia"]) {
    const { payload } = await answer(tool({ ...FAMILY_ROOM, requesterSenderId: sender }, location));
    assert.equal(payload.shared, true, sender);
    assert.equal(payload.sharedWith, "family");
  }
});

test("the owner's own family-room turn reads a share with the assistant, as their thread does, only in their own session of the room", async () => {
  const { location } = await sharing("assistant");
  const ownSession = { ...FAMILY_ROOM, requesterSenderId: "franco", sessionKey: "agent:main:household:group:family:sender:franco" };
  const { payload } = await answer(tool(ownSession, location));
  const shared = await answer(tool({ ...FAMILY_ROOM, requesterSenderId: "franco" }, location));
  assert.equal(payload.shared, true);
  assert.equal(payload.sharedWith, "assistant");
  assert.equal(shared.payload.shared, false, "the room's shared session, which others' turns read, never gets it");
});

test("anyone else's family-room turn tells nothing while the owner shares only with the assistant, or not at all", async () => {
  const assistantOnly = await sharing("assistant");
  const nothing = setup();
  const answers = [];
  for (const location of [assistantOnly.location, nothing.location]) {
    const { payload } = await answer(tool(FAMILY_ROOM, location));
    assert.equal(payload.shared, false);
    assert.equal(payload.latitude, undefined);
    answers.push(payload.message);
  }
  assert.equal(answers[0], answers[1], "the room cannot tell sharing with the assistant from not sharing");
});

test("in the family room the tool tells nothing once a family share has run out or been stopped", async () => {
  const ranOut = await sharing("family");
  const ranOutTool = tool(FAMILY_ROOM, ranOut.location);
  ranOut.advance(HOUR);
  const stopped = await sharing("family");
  await stopped.location.report(signed(STOP));
  for (const [label, found] of [["run out", ranOutTool], ["stopped", tool(FAMILY_ROOM, stopped.location)]]) {
    const { payload } = await answer(found);
    assert.equal(payload.shared, false, label);
    assert.equal(payload.latitude, undefined, label);
  }
});

test("the tool is not offered in any turn the owner's consent cannot cover", async () => {
  const { location } = await sharing("family");
  for (const [label, turn] of [
    // The other person's own thread, and the other person speaking in the owner's.
    ["the other person's own thread", {
      ...OWN_THREAD, requesterSenderId: "gia", nativeChannelId: "gia", sessionKey: "agent:main:household:direct:gia",
      deliveryContext: { channel: "household", accountId: "default", to: "household:gia" },
    }],
    ["the other person in the owner's thread", { ...OWN_THREAD, requesterSenderId: "gia" }],
    // Unsigned paths: a gateway client's chat.send names its own client id as the sender,
    // the agent method and automations name none.
    ["chat.send from the phone's own connection", { ...OWN_THREAD, requesterSenderId: "openclaw-ios" }],
    ["chat.send from the command line", { ...OWN_THREAD, requesterSenderId: "cli" }],
    ["chat.send into the family room", { ...FAMILY_ROOM, requesterSenderId: "webchat-ui" }],
    ["the other assistant in the family room", { ...FAMILY_ROOM, requesterSenderId: "denise" }],
    ["a turn with no sender", { ...OWN_THREAD, requesterSenderId: undefined }],
    ["a family turn with no sender", { ...FAMILY_ROOM, requesterSenderId: undefined }],
    ["an empty sender", { ...OWN_THREAD, requesterSenderId: "" }],
    ["a sender spelled as a Telegram chat", { ...OWN_THREAD, requesterSenderId: "telegram:franco" }],
    // The room and the thread crossed.
    ["the family room's session with the owner's thread as its route", { ...OWN_THREAD, sessionKey: "agent:main:household:group:family" }],
    ["the owner's session with the family room as its route", { ...OWN_THREAD, deliveryContext: ROOM_ROUTE }],
    ["a native chat that is not the route's", { ...OWN_THREAD, nativeChannelId: "family" }],
    // Other sessions and channels.
    ["the shared main session", { ...OWN_THREAD, sessionKey: "agent:main:main" }],
    ["an automation", { ...OWN_THREAD, sessionKey: "agent:main:cron:job" }],
    ["a sub-agent", { ...OWN_THREAD, sessionKey: "agent:main:subagent:franco" }],
    ["a sub-agent of the family room", { ...FAMILY_ROOM, sessionKey: "agent:main:subagent:family" }],
    ["another agent", { ...OWN_THREAD, sessionKey: "agent:other:household:direct:franco" }],
    ["web chat", { ...OWN_THREAD, messageChannel: "webchat" }],
    ["Telegram", {
      ...OWN_THREAD, messageChannel: "telegram", requesterSenderId: "7100000001", nativeChannelId: "7100000001",
      sessionKey: "agent:main:telegram:direct:7100000001",
      deliveryContext: { channel: "telegram", accountId: "default", to: "telegram:7100000001" },
    }],
    ["The Fam on Telegram", {
      ...OWN_THREAD, messageChannel: "telegram", requesterSenderId: "7100000002", nativeChannelId: "-5100000001",
      sessionKey: "agent:main:telegram:group:-5100000001",
      deliveryContext: { channel: "telegram", accountId: "default", to: "telegram:-5100000001" },
    }],
    ["a reply routed to Telegram", { ...OWN_THREAD, deliveryContext: { channel: "telegram", accountId: "default", to: "telegram:7100000001" } }],
    ["a second account", { ...OWN_THREAD, deliveryContext: { ...OWN_THREAD.deliveryContext, accountId: "second" } }],
    ["a thread", { ...OWN_THREAD, deliveryContext: { ...OWN_THREAD.deliveryContext, threadId: 7 } }],
    ["no route", { ...OWN_THREAD, deliveryContext: undefined }],
    ["another agent id", { ...OWN_THREAD, agentId: "other" }],
    ["another agent account", { ...OWN_THREAD, agentAccountId: "second" }],
    ["a one-shot command line run", { ...OWN_THREAD, oneShotCliRun: true }],
    ["no context at all", undefined],
  ]) {
    assert.equal(tool(turn, location), null, label);
  }
});

test("an owner the channel cannot name safely gets no tool", async () => {
  const { location } = await sharing("family");
  for (const person of ["cli", "openclaw-ios", "test", "family", "Franco", ""]) {
    const turn = {
      ...OWN_THREAD,
      requesterSenderId: person,
      nativeChannelId: undefined,
      sessionKey: `agent:main:household:direct:${person}`,
      deliveryContext: { ...OWN_THREAD.deliveryContext, to: `household:${person}` },
    };
    const identity = { owner: person, ownerName: "Someone", people: [person, "gia"] };
    assert.equal(tool(turn, location, { identity }), null, person);
    assert.equal(tool(FAMILY_ROOM, location, { identity }), null, `${person} in the family room`);
  }
});

test("a queued turn with no native chat is still the owner's own thread", async () => {
  const { location } = await sharing("assistant");
  const { payload } = await answer(tool({ ...OWN_THREAD, nativeChannelId: undefined }, location));
  assert.equal(payload.shared, true);
});

test("the tool asks for nothing but an optional place, and says what it is for", async () => {
  const { location } = await sharing("assistant");
  const found = tool(OWN_THREAD, location);
  assert.deepEqual(Object.keys(found.parameters.properties), ["to"]);
  assert.equal(found.parameters.additionalProperties, false);
  assert.match(found.description, /Franco/);
  assert.match(found.description, /never/i);
});
