// OpenClaw's approvals in the app, from deploy/openclaw/plugins/household-app: a step of
// the assistant's run that waits for the owner's yes shows as a card in the owner's own
// thread, and only the owner's phone, signing like it signs a message, can answer it. A
// calendar or reminder change in that thread is such a step.
//
// Run with `node --test tests/js/household_app_approvals.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { ASKING_TOOLS, askBeforeChange } from "../../deploy/openclaw/plugins/household-app/approval-asks.js";
import {
  APPROVAL_SIGNATURE_VERSION,
  approvalCard,
  approvalNativeRuntime,
  approvalText,
  createApprovals,
} from "../../deploy/openclaw/plugins/household-app/approvals.js";
import { createMediaStore } from "../../deploy/openclaw/plugins/household-app/media.js";
import { createRoom } from "../../deploy/openclaw/plugins/household-app/room.js";
import { isTextSignedBy } from "../../deploy/openclaw/plugins/household-app/signature.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";
import { stubChannelSdk } from "./fixtures/openclaw-channel-sdk.mjs";

const PLUGIN = new URL("../../deploy/openclaw/plugins/household-app/", import.meta.url);
const NOW = Date.UTC(2026, 9, 15, 17, 0);
const SESSION_KEYS = { family: "agent:main:household:group:family", direct: "agent:main:household:direct:franco" };
const PHONE_TOKEN = "a1".repeat(32);

function phone() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    key: publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64url"),
    signText: (text) => sign(null, Buffer.from(text, "utf8"), privateKey).toString("base64url"),
  };
}

const FRANCO = phone();
const GIA = phone();

// A plugin approval as OpenClaw 2026.9.4 hands it to a channel's native runtime: the
// request, and the view its approval-view-model builds from it.
function pluginApproval({ id = "plugin:5f0c1d9e-6a2b-4c4e-9d55-0b7f3e2a1c10", turnSourceChannel = "household", sessionKey = SESSION_KEYS.direct } = {}) {
  const request = {
    id,
    request: {
      title: "Add to the family calendar",
      description: "Soccer pickup, Saturday 5:45 to 6:15 PM, with a reminder at 5:30.",
      severity: "warning",
      toolName: "calendar_add",
      pluginId: "family-calendar",
      agentId: "main",
      sessionKey,
      ...(turnSourceChannel ? { turnSourceChannel, turnSourceTo: `${turnSourceChannel}:franco`, turnSourceAccountId: "default" } : {}),
    },
    createdAtMs: NOW,
    expiresAtMs: NOW + 120_000,
    approvalKind: "plugin",
  };
  const view = {
    approvalId: id,
    approvalKind: "plugin",
    phase: "pending",
    title: request.request.title,
    description: request.request.description,
    metadata: [],
    agentId: "main",
    pluginId: "family-calendar",
    toolName: "calendar_add",
    severity: "warning",
    actions: [
      { decision: "allow-once", label: "Allow Once", style: "success" },
      { decision: "allow-always", label: "Allow Always", style: "primary" },
      { decision: "deny", label: "Deny", style: "danger" },
    ],
    expiresAtMs: request.expiresAtMs,
  };
  return { request, view };
}

function execApproval() {
  const id = "0d6b7c1a-2f4e-4b8a-a1c3-5e9f7d2b4a60";
  const commandText = "python3 ~/.openclaw/workspace/skills/apple-cal-anywhere/cal.py add --title 'Soccer pickup'";
  return {
    request: {
      id,
      request: { command: commandText, agentId: "main", sessionKey: SESSION_KEYS.direct, turnSourceChannel: "household" },
      createdAtMs: NOW,
      expiresAtMs: NOW + 120_000,
    },
    view: {
      approvalId: id,
      approvalKind: "exec",
      phase: "pending",
      title: "Exec Approval Required",
      description: "A command needs your approval.",
      commandText,
      commandPreview: commandText,
      actions: [
        { decision: "allow-once", label: "Allow Once" },
        { decision: "deny", label: "Deny" },
      ],
      expiresAtMs: NOW + 120_000,
    },
  };
}

async function setup({ resolve } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-approvals-"));
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const seen = { events: [], outboxes: [], pushes: [], resolved: [] };
  const room = createRoom({
    identity: {
      owner: { id: "franco", name: "Franco", keys: [FRANCO.key] },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia", keys: [GIA.key] }, assistant: { id: "denise", name: "Denise" } },
    },
    sessionKeys: SESSION_KEYS,
    store,
    media: createMediaStore(directory),
    now: () => NOW,
    emit: (name, payload) => seen.events.push([name, payload]),
    writeOutbox: (outbox) => seen.outboxes.push(outbox),
    push: {
      async notify(phones, note) {
        seen.pushes.push(note);
        return phones.map((device) => ({ token: device.token, ok: true }));
      },
    },
    dispatch: async () => {},
    isAddressed: async () => false,
    log: { warn() {}, info() {} },
  });
  room.registerDevice({ token: PHONE_TOKEN, environment: "production", key: randomBytes(32).toString("base64") });
  const approvals = createApprovals({
    store,
    assistant: { id: "corey" },
    sessionKeys: SESSION_KEYS,
    now: () => NOW,
    announce: (entry) => room.announce(entry),
    ownerKeys: () => room.refreshPhoneKeys(),
    isSignedBy: isTextSignedBy,
    resolve: resolve ?? (async (answer) => {
      seen.resolved.push(answer);
      return { applied: true };
    }),
  });
  return { room, store, approvals, seen };
}

// What the native runtime does with a request OpenClaw routed to this channel.
async function present(approvals, { request, view }) {
  const card = await approvalNativeRuntime.presentation.buildPendingPayload({ request, approvalKind: view.approvalKind, view });
  return approvalNativeRuntime.transport.deliverPending({
    context: { approvals },
    plannedTarget: { surface: "approver-dm", target: { to: "household:franco", accountId: "default" } },
    preparedTarget: { to: "household:franco", accountId: "default" },
    request,
    approvalKind: view.approvalKind,
    view,
    pendingPayload: card,
  });
}

function answerFrom(person, message, decision, overrides = {}) {
  const text = approvalText({ approvalId: message.approval.id, decision });
  return { messageId: message.id, decision, signature: person.signText(text), ...overrides };
}

test("an approval OpenClaw routes here is a card in the owner's own thread, and the owner's phone is told", async () => {
  const { store, approvals, seen } = await setup();
  const asked = pluginApproval();

  const entry = await present(approvals, asked);

  const card = store.message(entry.messageId);
  assert.equal(card.conversation, "direct");
  assert.equal(card.author, "corey");
  assert.deepEqual(card.approval, {
    id: asked.request.id,
    kind: "plugin",
    title: "Add to the family calendar",
    detail: "Soccer pickup, Saturday 5:45 to 6:15 PM, with a reminder at 5:30.",
    decisions: ["allow-once", "deny"],
  });
  assert.equal(card.text, "Needs your OK: Add to the family calendar\nSoccer pickup, Saturday 5:45 to 6:15 PM, with a reminder at 5:30.");
  assert.deepEqual(seen.events.at(-1), ["changed", { rev: card.rev }]);
  assert.equal(seen.pushes.length, 1);
  assert.equal(seen.pushes[0].conversation, "direct");
  assert.equal(seen.pushes[0].messageId, card.id);
  assert.equal(seen.outboxes.length, 0, "the owner's own thread never reaches the relay");
});

test("an approval OpenClaw hands over again, after a restart, is still one card", async () => {
  const { store, approvals, seen } = await setup();
  const asked = pluginApproval();

  const first = await present(approvals, asked);
  const again = await present(approvals, asked);

  assert.equal(again.messageId, first.messageId);
  assert.equal(store.history("direct").messages.length, 1);
  assert.equal(seen.pushes.length, 1);
});

test("a command waiting for approval shows the command it would run", () => {
  const { view } = execApproval();
  assert.deepEqual(approvalCard(view), {
    title: "Run a command",
    detail: view.commandText,
    decisions: ["allow-once", "deny"],
  });
});

test("the card offers only Approve and Deny, of what the request allows", () => {
  const { view } = pluginApproval();
  assert.deepEqual(approvalCard({ ...view, actions: view.actions.filter((action) => action.decision !== "deny") }).decisions, ["allow-once"]);
  assert.deepEqual(approvalCard({ ...view, actions: [{ decision: "allow-always" }, { decision: "deny" }] }).decisions, ["deny"]);
});

test("a card's words are bounded the way OpenClaw bounds a plugin's", () => {
  const { view } = pluginApproval();
  const card = approvalCard({ ...view, title: "t".repeat(300), description: "d".repeat(3000) });
  assert.equal(card.title.length, 80);
  assert.equal(card.detail.length, 512);
  assert.equal(approvalCard({ ...view, description: "   " }).detail, undefined);
});

test("only approvals from this channel's turns come here; Telegram keeps its own", async () => {
  const { approvals } = await setup();
  const ours = (change) => approvalNativeRuntime.availability.shouldHandle({ context: { approvals }, request: pluginApproval(change).request, approvalKind: "plugin" });

  assert.equal(ours({}), true);
  assert.equal(ours({ sessionKey: SESSION_KEYS.family }), true, "the family room's turns are the owner's assistant's too");
  assert.equal(ours({ turnSourceChannel: "telegram" }), false);
  assert.equal(ours({ turnSourceChannel: "telegram", sessionKey: SESSION_KEYS.direct }), false, "the turn's channel decides, not the session");
  assert.equal(ours({ turnSourceChannel: "HOUSEHOLD " }), true);
  assert.equal(ours({ turnSourceChannel: null }), true, "a turn with no channel, in this channel's session");
  assert.equal(ours({ turnSourceChannel: null, sessionKey: "agent:main:telegram:direct:123" }), false);
  assert.equal(approvalNativeRuntime.availability.shouldHandle({ context: undefined, request: pluginApproval().request }), false);
  assert.equal(approvalNativeRuntime.availability.isConfigured({ context: { approvals } }), true);
  assert.equal(approvalNativeRuntime.availability.isConfigured({ context: undefined }), false);
  assert.deepEqual(approvalNativeRuntime.eventKinds, ["exec", "plugin"]);
});

test("the owner's phone answers with its signature, and OpenClaw hears the answer", async () => {
  const { approvals, seen } = await setup();
  const asked = pluginApproval();
  const { messageId } = await present(approvals, asked);

  const card = { id: messageId, approval: { id: asked.request.id } };
  assert.deepEqual(await approvals.answer(answerFrom(FRANCO, card, "allow-once")), { answered: true });

  assert.deepEqual(seen.resolved, [{ approvalId: asked.request.id, approvalKind: "plugin", decision: "allow-once" }]);
});

test("a denial is answered the same way", async () => {
  const { approvals, seen } = await setup();
  const asked = execApproval();
  const { messageId } = await present(approvals, asked);

  await approvals.answer(answerFrom(FRANCO, { id: messageId, approval: { id: asked.request.id } }, "deny"));

  assert.deepEqual(seen.resolved, [{ approvalId: asked.request.id, approvalKind: "exec", decision: "deny" }]);
});

test("an answer nobody's phone signed, or another phone signed, is refused and OpenClaw hears nothing", async () => {
  const { approvals, seen } = await setup();
  const asked = pluginApproval();
  const { messageId } = await present(approvals, asked);
  const card = { id: messageId, approval: { id: asked.request.id } };
  const someoneElse = phone();

  for (const [label, answer] of [
    ["no signature", { messageId, decision: "allow-once" }],
    ["an empty signature", answerFrom(FRANCO, card, "allow-once", { signature: "" })],
    ["Gia's phone", answerFrom(GIA, card, "allow-once")],
    ["a phone nobody paired", answerFrom(someoneElse, card, "allow-once")],
    ["a signed deny sent as an approve", answerFrom(FRANCO, card, "deny", { decision: "allow-once" })],
    ["a signature for another approval", { messageId, decision: "allow-once", signature: FRANCO.signText(approvalText({ approvalId: "plugin:another", decision: "allow-once" })) }],
    ["a message's signature", { messageId, decision: "allow-once", signature: FRANCO.signText(`household-app/v1\ndirect\n${messageId}`) }],
  ]) {
    await assert.rejects(approvals.answer(answer), (error) => error.code === "INVALID_REQUEST" && /signature/.test(error.message), label);
  }
  assert.deepEqual(seen.resolved, []);
});

test("only a card this gateway showed can be answered, with an answer it offered", async () => {
  const { room, store, approvals, seen } = await setup();
  const asked = pluginApproval();
  const { messageId } = await present(approvals, asked);
  const card = { id: messageId, approval: { id: asked.request.id } };
  const said = await room.reply({ conversation: "direct", text: "Done." });
  store.addMessage({ id: "a-family-0001", conversation: "family", author: "corey", at: NOW, text: "hi", media: [], replyTo: null, origin: "local" });

  for (const [label, answer, pattern] of [
    ["no message", answerFrom(FRANCO, card, "allow-once", { messageId: undefined }), /approval/],
    ["an unknown message", answerFrom(FRANCO, card, "allow-once", { messageId: "a-00000000-unknown" }), /no such approval/],
    ["an ordinary reply", answerFrom(FRANCO, card, "allow-once", { messageId: said.id }), /no such approval/],
    ["a family message", answerFrom(FRANCO, card, "allow-once", { messageId: "a-family-0001" }), /no such approval/],
    ["allow always", answerFrom(FRANCO, card, "allow-always"), /not offered/],
    ["a made-up answer", answerFrom(FRANCO, card, "yes please"), /not offered/],
  ]) {
    await assert.rejects(approvals.answer(answer), (error) => error.code === "INVALID_REQUEST" && pattern.test(error.message), label);
  }
  assert.deepEqual(seen.resolved, []);
});

test("an approval that has ended cannot be answered again", async () => {
  const { approvals, seen } = await setup();
  const asked = pluginApproval();
  const entry = await present(approvals, asked);
  await approvalNativeRuntime.transport.updateEntry({ context: { approvals }, entry, payload: { state: "expired" } });

  await assert.rejects(
    approvals.answer(answerFrom(FRANCO, { id: entry.messageId, approval: { id: asked.request.id } }, "allow-once")),
    /no longer waiting/,
  );
  assert.deepEqual(seen.resolved, []);
});

test("how an approval ended reaches the phone, once, whoever answered it", async () => {
  const { store, approvals, seen } = await setup();
  const approved = await present(approvals, pluginApproval());
  const denied = await present(approvals, pluginApproval({ id: "plugin:denied-1" }));
  const expired = await present(approvals, pluginApproval({ id: "plugin:expired-1" }));
  const pushes = seen.pushes.length;

  for (const [entry, decision] of [[approved, "allow-once"], [denied, "deny"]]) {
    const result = await approvalNativeRuntime.presentation.buildResolvedResult({ view: { decision }, resolved: { decision }, entry });
    await approvalNativeRuntime.transport.updateEntry({ context: { approvals }, entry, payload: result.payload });
  }
  const timedOut = await approvalNativeRuntime.presentation.buildExpiredResult({ view: {}, entry: expired });
  await approvalNativeRuntime.transport.updateEntry({ context: { approvals }, entry: expired, payload: timedOut.payload });
  await approvalNativeRuntime.transport.updateEntry({ context: { approvals }, entry: approved, payload: { state: "denied" } });

  assert.equal(store.approvalState(approved.messageId), "approved");
  assert.equal(store.approvalState(denied.messageId), "denied");
  assert.equal(store.approvalState(expired.messageId), "expired");
  const ended = store.changesSince(0).entries.filter((entry) => entry.kind === "approval");
  assert.deepEqual(ended.map((entry) => [entry.messageId, entry.state, entry.conversation]), [
    [approved.messageId, "approved", "direct"],
    [denied.messageId, "denied", "direct"],
    [expired.messageId, "expired", "direct"],
  ]);
  assert.equal(seen.events.at(-1)[1].rev, ended.at(-1).rev);
  assert.equal(seen.pushes.length, pushes, "how it ended is not pushed again");
});

test("a run that was stopped while it waited ends its card as no longer waiting", async () => {
  const result = await approvalNativeRuntime.presentation.buildResolvedResult({ view: {}, resolved: { decision: "deny", terminalStatus: "cancelled" } });
  assert.deepEqual(result, { kind: "update", payload: { state: "expired" } });
  const allowed = await approvalNativeRuntime.presentation.buildResolvedResult({ view: { decision: "allow-always" }, resolved: { decision: "allow-always" } });
  assert.deepEqual(allowed.payload, { state: "approved" });
});

test("a page of the owner's thread says how each of its approvals ended", async () => {
  const { room, approvals } = await setup();
  const ended = await present(approvals, pluginApproval());
  const waiting = await present(approvals, pluginApproval({ id: "plugin:waiting-1" }));
  await approvalNativeRuntime.transport.updateEntry({ context: { approvals }, entry: ended, payload: { state: "denied" } });

  const page = room.history({ conversation: "direct" });

  assert.deepEqual(page.approvals, { [ended.messageId]: "denied" });
  assert.ok(page.messages.some((message) => message.id === waiting.messageId));
  assert.deepEqual(room.history({ conversation: "family" }).approvals, {});
});

test("an answer OpenClaw refuses is the phone's to hear as a failure, and changes nothing here", async () => {
  const { store, approvals } = await setup({
    resolve: async () => {
      throw new Error("unknown or expired approval id");
    },
  });
  const asked = pluginApproval();
  const { messageId } = await present(approvals, asked);

  await assert.rejects(
    approvals.answer(answerFrom(FRANCO, { id: messageId, approval: { id: asked.request.id } }, "allow-once")),
    (error) => error.code !== "INVALID_REQUEST",
  );
  assert.equal(store.approvalState(messageId), null);
});

test("the signed answer is one line per field, exactly as the phone builds it", () => {
  assert.equal(APPROVAL_SIGNATURE_VERSION, "household-app/approval/v1");
  assert.equal(approvalText({ approvalId: "plugin:abc", decision: "deny" }), "household-app/approval/v1\nplugin:abc\ndeny");
  assert.equal(approvalText({ approvalId: "plugin:abc\nallow-once", decision: "deny" }), null);
  assert.equal(approvalText({ approvalId: 7, decision: "deny" }), null);
});

test("the channel delivers approvals to the owner's own thread and lets only the owner answer them", async () => {
  stubChannelSdk(fileURLToPath(new URL("index.js", PLUGIN)));
  const { householdChannel } = await import(new URL("index.js", PLUGIN));
  const cfg = {
    channels: {
      household: {
        owner: { id: "franco", name: "Franco" },
        assistant: { id: "corey", name: "Corey" },
        peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
      },
    },
  };
  const capability = householdChannel.approvalCapability;
  const asked = pluginApproval().request;

  const authorize = (senderId, approvalKind = "plugin") =>
    capability.authorizeActorAction({ cfg, accountId: "default", senderId, action: "approve", approvalKind }).authorized;
  assert.equal(authorize("franco"), true);
  assert.equal(authorize("franco", "exec"), true);
  for (const someone of ["gia", "corey", "denise", "", undefined, "Franco"]) {
    assert.equal(authorize(someone), false, String(someone));
  }
  assert.equal(capability.authorizeActorAction({ cfg: {}, accountId: "default", senderId: "franco", action: "approve", approvalKind: "plugin" }).authorized, false);

  const plan = { cfg, accountId: "default", approvalKind: "plugin", request: asked };
  assert.deepEqual(capability.native.describeDeliveryCapabilities(plan), {
    enabled: true,
    preferredSurface: "approver-dm",
    supportsOriginSurface: false,
    supportsApproverDmSurface: true,
    notifyOriginWhenDmOnly: false,
  });
  assert.deepEqual(capability.native.resolveApproverDmTargets(plan), [{ to: "household:franco", accountId: "default" }]);
  assert.equal(capability.native.describeDeliveryCapabilities({ ...plan, cfg: {} }).enabled, false);
  assert.deepEqual(capability.native.resolveApproverDmTargets({ ...plan, cfg: {} }), []);
  assert.equal(capability.nativeRuntime, approvalNativeRuntime);
  const prepared = await capability.nativeRuntime.transport.prepareTarget({ plannedTarget: { target: { to: "household:franco", accountId: "default" } } });
  assert.deepEqual(prepared, { dedupeKey: "household:franco", target: { to: "household:franco", accountId: "default" } });
});

// What asks. A tool call as OpenClaw 2026.9.4 hands it to a `before_tool_call` hook, from a
// turn the owner's phone started in the owner's own thread, with times shown in Central.
const OWNER_TURN = { agentId: "main", sessionKey: SESSION_KEYS.direct, requester: { channel: "household", accountId: "default", senderId: "franco" } };
const ZONE = "America/Chicago";
const APPLECAL = "python3 ~/.openclaw/workspace/skills/apple-cal-anywhere/scripts/applecal.py --apple-id franco@example.com";

// The owner's own session of the family room, which only the owner's turns run in.
const OWNERS_FAMILY_SESSION = "agent:main:household:group:family:sender:franco";
const ask = (toolName, params, context = OWNER_TURN, ownerSession = SESSION_KEYS.direct) =>
  askBeforeChange({ toolName, params }, context, {
    ownerSession,
    ownersFamilySession: ownerSession && OWNERS_FAMILY_SESSION,
    timeZone: ZONE,
  });

test("each calendar or reminder change in the owner's own thread asks, saying what changes and where", () => {
  for (const [toolName, params, title, description] of [
    [
      "automations",
      { action: "add", job: { name: "Dentist", schedule: { kind: "at", at: "2026-10-20T19:00:00Z" }, payload: { kind: "systemEvent", text: "Leave for the dentist" } } },
      "Add a reminder, Tuesday 20 October, 2 pm",
      "Dentist: Leave for the dentist",
    ],
    [
      "automations",
      { action: "add", job: { schedule: { kind: "every", everyMs: 7_200_000 }, payload: { kind: "agentTurn", message: "Check the oven" } } },
      "Add a reminder, every 2 hours",
      "Check the oven",
    ],
    [
      "automations",
      { action: "add", job: { name: "Bins", schedule: { kind: "cron", expr: "0 19 * * 2", tz: ZONE }, payload: { kind: "systemEvent", text: "Bins out" } } },
      "Add a reminder, on the schedule 0 19 * * 2",
      "Bins: Bins out",
    ],
    [
      "automations",
      { action: "update", jobId: "job-7", job: { schedule: { kind: "at", at: "2026-10-21T14:00:00-05:00" } } },
      "Move a reminder to Wednesday 21 October, 2 pm",
      "Reminder job-7",
    ],
    ["automations", { action: "update", id: "job-7", job: { enabled: false } }, "Change a reminder", "Reminder job-7"],
    ["automations", { action: "remove", jobId: "job-7" }, "Delete a reminder", "Reminder job-7"],
    ["exec", { command: "openclaw cron add --name Bins --cron '0 19 * * 2' --system-event 'Bins out'" }, "Add a reminder", "Reminder Bins"],
    ["exec", { command: "openclaw automations edit job-7 --message 'Bins out tonight'" }, "Change a reminder", "Reminder job-7"],
    ["exec", { command: "node dist/index.js automations remove job-7" }, "Delete a reminder", "Reminder job-7"],
    [
      "exec",
      { command: "gog calendar create primary --summary 'Movie night' --from 2026-10-16T19:00:00-05:00 --to 2026-10-16T21:00:00-05:00" },
      "Add Movie night, Friday 16 October, 7 pm",
      "On the primary calendar in Google.",
    ],
    [
      "exec",
      { command: "gog calendar update primary evt42 --summary Dentist --from=2026-10-20T15:00:00-05:00" },
      "Move Dentist to Tuesday 20 October, 3 pm",
      "On the primary calendar in Google.",
    ],
    ["exec", { command: "gog calendar update primary evt42 --event-color 4" }, "Change an event", "On the primary calendar in Google."],
    ["exec", { command: "gog calendar delete primary evt42" }, "Delete an event", "On the primary calendar in Google."],
    ["exec", { command: "gog --account franco@example.com calendar respond primary evt42 --status accepted" }, "Change the calendar", "On the primary calendar in Google."],
    [
      "exec",
      { command: `${APPLECAL} events create --calendar Family --summary "Movie night" --start 2026-10-17T00:00:00Z --end 2026-10-17T02:00:00Z` },
      "Add Movie night, Friday 16 October, 7 pm",
      "On the Family calendar in iCloud.",
    ],
    [
      "exec",
      { command: `${APPLECAL} events create --calendar Family --summary Soccer --start 2026-10-17T22:30:00 --end 2026-10-17T23:30:00` },
      "Add Soccer, Saturday 17 October, 5:30 pm",
      "On the Family calendar in iCloud.",
    ],
    [
      "exec",
      { command: `${APPLECAL} events create --calendar Family --summary "Fall fair" --start 2026-10-17 --end 2026-10-18 --all-day` },
      "Add Fall fair, Saturday 17 October",
      "On the Family calendar in iCloud.",
    ],
    [
      "exec",
      { command: `${APPLECAL} events update --calendar Family --uid abc-1 --start 2026-10-20T20:00:00Z --end 2026-10-20T21:00:00Z` },
      "Move an event to Tuesday 20 October, 3 pm",
      "On the Family calendar in iCloud.",
    ],
    [
      "exec",
      { command: `cd ~/.openclaw/workspace/skills/apple-cal-anywhere && ${APPLECAL} events delete --calendar Family --uid abc-1` },
      "Delete an event",
      "On the Family calendar in iCloud.",
    ],
    ["exec", { command: `${APPLECAL} attach add --calendar Family --uid abc-1 --file /tmp/tickets.pdf` }, "Change the calendar", "On the Family calendar in iCloud."],
    ["exec", { command: `${APPLECAL} events purge --uid abc-1` }, "Change the calendar", "On a calendar in iCloud."],
  ]) {
    const asked = ask(toolName, params)?.requireApproval;
    assert.equal(asked?.title, title, JSON.stringify(params));
    assert.equal(asked.description, description, title);
  }
});

test("reading a calendar or the reminders never asks, nor does anything else", () => {
  for (const [toolName, params] of [
    ["automations", { action: "list" }],
    ["automations", { action: "status" }],
    ["automations", { action: "get", jobId: "job-7" }],
    ["automations", { action: "runs", jobId: "job-7" }],
    ["automations", { action: "run", jobId: "job-7", runMode: "force" }],
    ["automations", { action: "wake", text: "Check the oven" }],
    ["automations", {}],
    ["exec", { command: "gog calendar events primary --from 2026-10-16T00:00:00-05:00 --to 2026-10-17T00:00:00-05:00" }],
    ["exec", { command: "gog --account franco@example.com calendar events primary" }],
    ["exec", { command: "gog calendar colors" }],
    ["exec", { command: "gog calendar --help" }],
    ["exec", { command: "gog gmail send --to gia@example.com --subject calendar --body create" }],
    ["exec", { command: `${APPLECAL} events list --calendar Family --from 2026-10-16T00:00:00Z --to 2026-10-23T00:00:00Z` }],
    ["exec", { command: `${APPLECAL} freebusy --calendar Family --from 2026-10-16T00:00:00Z --to 2026-10-17T00:00:00Z` }],
    ["exec", { command: `${APPLECAL} calendars list` }],
    ["exec", { command: `${APPLECAL} doctor` }],
    ["exec", { command: "openclaw cron list" }],
    ["exec", { command: "openclaw automations runs job-7" }],
    ["exec", { command: "echo 'gog calendar create primary --summary Movie'" }],
    ["exec", { command: "cat ~/.openclaw/workspace/skills/gog/SKILL.md" }],
    ["exec", { command: "date -d 'next friday' -Is" }],
    ["exec", {}],
  ]) {
    assert.equal(ask(toolName, params), undefined, JSON.stringify(params));
  }
});

test("a change in a family-room turn the owner started asks too, as in their own thread, whatever sender the hook is told", () => {
  const ownersFamilyTurn = { agentId: "main", sessionKey: OWNERS_FAMILY_SESSION, requester: { channel: "household", accountId: "default", senderId: "franco" } };
  for (const context of [ownersFamilyTurn, { ...ownersFamilyTurn, requester: { channel: "household" } }]) {
    assert.ok(ask("automations", { action: "remove", jobId: "job-7" }, context)?.requireApproval);
    assert.ok(ask("exec", { command: "gog calendar delete primary evt42" }, context)?.requireApproval);
  }
});

test("Telegram, anyone else's family-room turn and every other turn never ask, not even for a change", () => {
  const change = { action: "remove", jobId: "job-7" };
  const calendarChange = { command: "gog calendar delete primary evt42" };
  for (const [label, context, ownerSession] of [
    ["a Telegram turn", { sessionKey: "agent:main:telegram:direct:5550101", requester: { channel: "telegram", senderId: "5550101", senderIsOwner: true } }],
    ["a Telegram turn in a session shared with the owner's thread", { sessionKey: SESSION_KEYS.direct, requester: { channel: "telegram", senderId: "5550101" } }],
    ["the other person's family room turn", { sessionKey: SESSION_KEYS.family, requester: { channel: "household", senderId: "gia" } }],
    ["the other assistant's handover", { sessionKey: SESSION_KEYS.family, requester: { channel: "household", senderId: "denise" } }],
    ["a family room run no message started", { sessionKey: SESSION_KEYS.family }],
    ["the owner's id from Telegram in the family room", { sessionKey: SESSION_KEYS.family, requester: { channel: "telegram", senderId: "franco" } }],
    ["the owner in the room's shared session, which has The Fam's tools", { sessionKey: SESSION_KEYS.family, requester: { channel: "household", senderId: "franco" } }],
    ["Telegram in the owner's own session of the room", { sessionKey: OWNERS_FAMILY_SESSION, requester: { channel: "telegram", senderId: "franco" } }],
    ["a run no message started", { sessionKey: SESSION_KEYS.direct }],
    ["another session", { sessionKey: "agent:main:main", requester: { channel: "household", senderId: "franco" } }],
    ["the channel not running", { requester: { channel: "household", senderId: "franco" } }, null],
  ]) {
    const session = ownerSession === null ? undefined : SESSION_KEYS.direct;
    assert.equal(ask("automations", change, context, session), undefined, label);
    assert.equal(ask("exec", calendarChange, context, session), undefined, label);
  }
  assert.ok(ask("automations", change, { ...OWNER_TURN, requester: { channel: " Household " } }), "the channel's id, however OpenClaw cases it");
});

test("a change offers one yes or a no, and is denied when ten minutes pass unanswered", () => {
  const { requireApproval } = ask("exec", { command: "gog calendar delete primary evt42" });

  assert.deepEqual(requireApproval.allowedDecisions, ["allow-once", "deny"]);
  assert.equal(requireApproval.timeoutMs, 600_000);
  assert.deepEqual(Object.keys(requireApproval).sort(), ["allowedDecisions", "description", "timeoutMs", "title"]);
});

test("a change's card says it within OpenClaw's bounds", () => {
  const long = "Movie night ".repeat(20).trim();
  const { requireApproval } = ask("automations", {
    action: "add",
    job: { name: long, schedule: { kind: "at", at: "2026-10-17T00:00:00Z" }, payload: { kind: "systemEvent", text: "x".repeat(2000) } },
  });
  assert.equal(requireApproval.description.length, 512);
  const card = ask("exec", { command: `gog calendar create primary --summary '${long}' --from 2026-10-16T19:00:00-05:00` }).requireApproval;
  assert.equal(card.title.length, 80);
  assert.ok(card.title.startsWith("Add Movie night Movie night"));
});

test("the plugin asks through its own before_tool_call hook, for the scheduler and commands only", async () => {
  stubChannelSdk(fileURLToPath(new URL("index.js", PLUGIN)));
  const { default: entry } = await import(new URL("index.js", PLUGIN));
  const hooks = [];
  const api = new Proxy(
    { on: (name, handler, options) => hooks.push({ name, handler, options }), session: { workflow: {} }, logger: {} },
    { get: (target, key) => (key in target ? target[key] : () => {}) },
  );

  entry.registerFull(api);

  const asks = hooks.find((hook) => hook.name === "before_tool_call" && hook.options?.matcher);
  assert.deepEqual(asks.options, { matcher: ASKING_TOOLS });
  assert.deepEqual(ASKING_TOOLS, ["automations", "exec"]);
  assert.equal(
    asks.handler({ toolName: "automations", params: { action: "remove", jobId: "job-7" } }, { requester: { channel: "household" } }),
    undefined,
    "nothing asks while the channel is not running",
  );
  assert.ok(!hooks.some((hook) => hook.name === "message_sending" || hook.name === "reply_payload_sending"), "Telegram keeps its streaming preview");
});
