// What a run changed, kept on its reply as the `did` list the app shows as chips, from
// deploy/openclaw/plugins/household-app/did.js: each change a run's tool calls made, keyed
// to the turn that names the run, nothing for a read, and the list carried to the other
// gateway with a family-room reply.
//
// Run with `node --test tests/js/household_app_did.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { cleanDid, createDid } from "../../deploy/openclaw/plugins/household-app/did.js";
import { createHandovers } from "../../deploy/openclaw/plugins/household-app/handovers.js";
import { createMediaStore } from "../../deploy/openclaw/plugins/household-app/media.js";
import { createRoom } from "../../deploy/openclaw/plugins/household-app/room.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";

const NOW = Date.UTC(2026, 9, 15, 18, 0);
const ZONE = "America/Chicago";
const APPLECAL = "python3 ~/.openclaw/workspace/skills/apple-cal-anywhere/scripts/applecal.py --apple-id franco@example.com";

// A tool call as OpenClaw 2026.9.4's after_tool_call hook hands it over: a command that
// exited 0, a tool that answered, or one that failed.
const EXITED_0 = { content: [{ type: "text", text: "ok" }], details: { status: "completed", exitCode: 0 } };
const exec = (command, result = EXITED_0) => ({ toolName: "exec", params: { command }, result });
const automations = (params) => ({ toolName: "automations", params, result: { content: [], details: { id: "job-7" } } });
const cart = (params) => ({ toolName: "household_cart", params, result: { content: [{ type: "text", text: "{}" }] } });

// One turn's changes, as the household channel collects them: the turn names its run, the
// run's tool calls end, and its reply takes what they changed.
function changesOf(...calls) {
  const did = createDid({ timeZone: ZONE });
  const turn = did.turn();
  turn.name("run-1");
  for (const call of calls) did.toolEnded("run-1", call);
  return turn.take();
}

test("each change a run made is one item of its reply's did list", () => {
  for (const [call, expected] of [
    [
      exec("gog calendar create primary --summary 'Movie night' --from 2026-10-16T19:00:00-05:00 --to 2026-10-16T21:00:00-05:00"),
      { kind: "event", change: "added", title: "Movie night", at: "2026-10-17T00:00:00.000Z" },
    ],
    [
      exec("gog calendar create primary --summary 'Movie night' --from 2026-10-16T19:00:00"),
      { kind: "event", change: "added", title: "Movie night", at: "2026-10-17T00:00:00.000Z" },
    ],
    [
      exec(`${APPLECAL} events create --calendar Family --summary "Fall fair" --start 2026-10-17 --end 2026-10-18 --all-day`),
      { kind: "event", change: "added", title: "Fall fair", day: "2026-10-17" },
    ],
    [
      exec("gog calendar update primary evt42 --summary Dentist --from=2026-10-20T15:00:00-05:00"),
      { kind: "event", change: "moved", title: "Dentist", at: "2026-10-20T20:00:00.000Z" },
    ],
    [
      exec(`${APPLECAL} events update --calendar Family --uid abc-1 --start 2026-10-20T20:00:00 --end 2026-10-20T21:00:00`),
      { kind: "event", change: "moved", at: "2026-10-20T20:00:00.000Z" },
    ],
    [exec("gog calendar update primary evt42 --event-color 4"), { kind: "event", change: "changed" }],
    [exec("gog calendar delete primary evt42"), { kind: "event", change: "deleted" }],
    [
      automations({
        action: "add",
        job: { name: "Pickup", schedule: { kind: "at", at: "2026-10-15T20:45:00Z" }, payload: { kind: "systemEvent", text: "Leave for soccer pickup" } },
      }),
      { kind: "reminder", change: "added", title: "Leave for soccer pickup", at: "2026-10-15T20:45:00.000Z" },
    ],
    [
      automations({ action: "add", job: { name: "Bins", schedule: { kind: "cron", expr: "0 19 * * 2" }, payload: { kind: "systemEvent", text: "Bins out" } } }),
      { kind: "reminder", change: "added", title: "Bins out" },
    ],
    [
      automations({ action: "update", jobId: "job-7", job: { schedule: { kind: "at", at: "2026-10-21T14:00:00-05:00" } } }),
      { kind: "reminder", change: "moved", at: "2026-10-21T19:00:00.000Z" },
    ],
    [automations({ action: "update", id: "job-7", job: { enabled: false } }), { kind: "reminder", change: "changed" }],
    [automations({ action: "remove", jobId: "job-7" }), { kind: "reminder", change: "deleted" }],
    [exec("openclaw cron add --name 'Bins out' --cron '0 19 * * 2' --system-event 'Bins'"), { kind: "reminder", change: "added", title: "Bins out" }],
    [cart({ action: "add", name: "Birthday candles" }), { kind: "list", change: "added", title: "Birthday candles" }],
    [cart({ action: "remove", item: "item-3" }), { kind: "list", change: "deleted" }],
    [cart({ action: "quantity", item: "item-3", quantity: 2 }), { kind: "list", change: "changed" }],
    [
      exec("gog gmail drafts create --to gia@example.com --subject 'Field trip form' --body-file -"),
      { kind: "message", change: "drafted", title: "Field trip form" },
    ],
  ]) {
    assert.deepEqual(changesOf(call), [expected], JSON.stringify(call.params));
  }
});

test("a run that only read gets no did list", () => {
  const reads = [
    exec("gog calendar events primary --from 2026-10-16T00:00:00-05:00 --to 2026-10-17T00:00:00-05:00"),
    exec(`${APPLECAL} events list --calendar Family --from 2026-10-16T00:00:00Z --to 2026-10-23T00:00:00Z`),
    exec("gog gmail search 'newer_than:7d' --max 10"),
    exec("gog gmail drafts list"),
    exec("openclaw cron list"),
    exec("echo 'gog calendar create primary --summary Movie'"),
    automations({ action: "list" }),
    automations({ action: "run", jobId: "job-7" }),
    cart({ action: "view" }),
    { toolName: "web_search", params: { query: "soccer schedule" }, result: { content: [] } },
    { toolName: "read", params: { path: "MEMORY.md" }, result: { content: [] } },
    { toolName: "constructor", params: {}, result: { content: [] } },
  ];
  assert.deepEqual(changesOf(...reads), []);
});

test("a change that did not happen adds nothing", () => {
  assert.deepEqual(changesOf(
    exec("gog calendar create primary --summary 'Movie night' --from 2026-10-16T19:00:00-05:00", {
      content: [], details: { status: "completed", exitCode: 1 },
    }),
    exec("gog calendar delete primary evt42", { content: [], details: { status: "failed", exitCode: null } }),
    exec("gog calendar delete primary evt42", { content: [], details: { status: "approval-pending" } }),
    { ...automations({ action: "remove", jobId: "job-7" }), error: "Approval denied" },
    { ...cart({ action: "add", name: "Milk" }), result: { content: [], isError: true } },
  ), []);
});

test("a change belongs to the turn that named its run, and to no turn once that turn ends", () => {
  const did = createDid({ timeZone: ZONE });
  const first = did.turn();
  const second = did.turn();
  first.name("run-1");
  second.name("run-2");
  second.name("run-3");

  did.toolEnded("run-1", cart({ action: "add", name: "Milk" }));
  did.toolEnded("run-3", cart({ action: "add", name: "Eggs" }));
  did.toolEnded("run-9", cart({ action: "add", name: "Butter" }));
  did.toolEnded(undefined, cart({ action: "add", name: "Flour" }));
  first.end();
  did.toolEnded("run-1", cart({ action: "add", name: "Sugar" }));

  assert.deepEqual(first.take().map((item) => item.title), ["Milk"]);
  assert.deepEqual(second.take().map((item) => item.title), ["Eggs"]);
});

test("each reply takes what changed since the last one, and a list holds at most eight", () => {
  const did = createDid({ timeZone: ZONE });
  const turn = did.turn();
  turn.name("run-1");
  did.toolEnded("run-1", cart({ action: "add", name: "Milk" }));
  assert.equal(turn.take().length, 1);
  assert.deepEqual(turn.take(), []);

  for (let index = 0; index < 12; index += 1) did.toolEnded("run-1", cart({ action: "add", name: `Item ${index}` }));
  assert.equal(turn.take().length, 8);
});

test("a title is one short line", () => {
  const [item] = changesOf(cart({ action: "add", name: `Birthday\ncandles ${"x".repeat(200)}` }));
  assert.equal(item.title.length, 80);
  assert.ok(item.title.startsWith("Birthday candles "));
});

// Two gateways, as the relay joins them, each with its room and what it relays.
async function gateway({ person, assistant, peerPerson, peerAssistant }) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-did-"));
  const outboxes = [];
  const pushes = [];
  const store = openRoomStore(path.join(directory, "room.sqlite"));
  const room = createRoom({
    identity: {
      owner: { id: person.toLowerCase(), name: person, keys: [] },
      assistant: { id: assistant.toLowerCase(), name: assistant },
      peer: { person: { id: peerPerson.toLowerCase(), name: peerPerson, keys: [] }, assistant: { id: peerAssistant.toLowerCase(), name: peerAssistant } },
    },
    store,
    media: createMediaStore(directory),
    now: () => NOW,
    emit() {},
    writeOutbox: (outbox) => outboxes.push(outbox),
    push: { notify: async (devices, note) => pushes.push(note) },
    dispatch: async () => {},
    isAddressed: async () => false,
    log: { warn() {}, info() {} },
  });
  return { room, store, outboxes };
}

async function bothGateways() {
  const corey = await gateway({ person: "Franco", assistant: "Corey", peerPerson: "Gia", peerAssistant: "Denise" });
  const denise = await gateway({ person: "Gia", assistant: "Denise", peerPerson: "Franco", peerAssistant: "Corey" });
  return { corey, denise };
}

test("a family-room reply keeps its did list, and the other gateway keeps it with the message", async () => {
  const { corey, denise } = await bothGateways();
  const did = createDid({ timeZone: ZONE });
  const turn = did.turn();
  turn.name("run-1");
  did.toolEnded("run-1", exec("gog calendar create family --summary 'Gia lands' --from 2026-10-15T16:10:00-05:00"));

  const reply = await corey.room.reply({ conversation: "family", text: "Gia lands at 4:10. It is on the family calendar.", did: turn.take() });
  await denise.room.acceptPeer({ entries: corey.outboxes.at(-1).entries });

  const expected = [{ kind: "event", change: "added", title: "Gia lands", at: "2026-10-15T21:10:00.000Z" }];
  assert.deepEqual(corey.store.message(reply.id).did, expected);
  assert.deepEqual(denise.store.message(reply.id).did, expected);
});

test("a handed-over turn's reply carries its list as well as its mark", async () => {
  const { corey, denise } = await bothGateways();
  const did = createDid({ timeZone: ZONE });
  const handovers = createHandovers();
  const turn = did.turn();
  let reply;
  await handovers.during(async (named) => {
    named("run-1");
    turn.name("run-1");
    did.toolEnded("run-1", cart({ action: "add", name: "Milk" }));
    reply = await corey.room.reply({ conversation: "family", text: "@Denise milk is on the cart.", handedOver: true, did: turn.take() });
  });
  turn.end();
  await denise.room.acceptPeer({ entries: corey.outboxes.at(-1).entries });

  assert.equal(denise.store.message(reply.id).handedOver, true);
  assert.deepEqual(denise.store.message(reply.id).did, [{ kind: "list", change: "added", title: "Milk" }]);
});

test("a reply in the owner's own thread keeps its list, and a reply that changed nothing has none", async () => {
  const { corey } = await bothGateways();
  const changed = await corey.room.reply({ conversation: "direct", text: "Done.", did: changesOf(automations({ action: "remove", jobId: "job-7" })) });
  const read = await corey.room.reply({ conversation: "direct", text: "Your day is clear.", did: [] });

  assert.deepEqual(corey.store.message(changed.id).did, [{ kind: "reminder", change: "deleted" }]);
  assert.equal("did" in corey.store.message(read.id), false);
  assert.equal("did" in (await corey.room.reply({ conversation: "direct", text: "Hello." })), false);
});

test("from the other gateway's assistant only the list items this gateway can read are kept", async () => {
  const { denise } = await bothGateways();
  const at = NOW - 1000;
  const message = (id, author, did) => ({ kind: "message", author, conversation: "family", id, at, replyTo: null, media: [], text: "Done.", did });
  const result = await denise.room.acceptPeer({
    entries: [
      message("a-00000001", "corey", [
        { kind: "event", change: "added", title: "Movie night", at: "2026-10-17T00:00:00.000Z", extra: "dropped" },
        { kind: "event", change: "added", day: "2026-10-17" },
        { kind: "parcel", change: "added" },
        { kind: "event", change: "teleported" },
        { kind: "list", change: "added", title: "two\nlines" },
        { kind: "list", change: "added", title: "x".repeat(81) },
        { kind: "reminder", change: "added", at: "tomorrow" },
        { kind: "reminder", change: "added", at: "2026-10-17T00:00:00.000Z", day: "2026-10-17" },
        "not an item",
      ]),
      message("a-00000002", "corey", { kind: "event", change: "added" }),
    ],
  });

  assert.deepEqual(result, { accepted: 1, refused: 1 });
  assert.deepEqual(denise.store.message("a-00000001").did, [
    { kind: "event", change: "added", title: "Movie night", at: "2026-10-17T00:00:00.000Z" },
    { kind: "event", change: "added", day: "2026-10-17" },
  ]);
  assert.deepEqual(cleanDid(Array.from({ length: 12 }, () => ({ kind: "list", change: "changed" }))).length, 8);
});
