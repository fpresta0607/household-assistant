// Which family-room posts belong to a turn the other assistant's @mention started, from
// deploy/openclaw/plugins/household-app/handovers.js: a tool's post during such a turn is
// marked and starts nothing on the other gateway, and any other turn's post is not.
//
// Run with `node --test tests/js/household_app_handovers.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { createHandovers } from "../../deploy/openclaw/plugins/household-app/handovers.js";
import { createMediaStore } from "../../deploy/openclaw/plugins/household-app/media.js";
import { createRoom } from "../../deploy/openclaw/plugins/household-app/room.js";
import { openRoomStore } from "../../deploy/openclaw/plugins/household-app/store.js";

const NOW = Date.UTC(2026, 9, 15, 23, 0);

// One gateway's family room, with what it relays and the turns it starts.
async function gateway({ person, assistant, peerPerson, peerAssistant }) {
  const directory = await mkdtemp(path.join(tmpdir(), "household-app-handovers-"));
  const outboxes = [];
  const dispatched = [];
  const room = createRoom({
    identity: {
      owner: { id: person.toLowerCase(), name: person, keys: [] },
      assistant: { id: assistant.toLowerCase(), name: assistant },
      peer: { person: { id: peerPerson.toLowerCase(), name: peerPerson, keys: [] }, assistant: { id: peerAssistant.toLowerCase(), name: peerAssistant } },
    },
    store: openRoomStore(path.join(directory, "room.sqlite")),
    media: createMediaStore(directory),
    now: () => NOW,
    emit() {},
    writeOutbox: (outbox) => outboxes.push(outbox),
    push: { notify: async () => [] },
    dispatch: async (turn) => dispatched.push(turn),
    isAddressed: async () => false,
    log: { warn() {}, info() {} },
  });
  return { room, outboxes, dispatched };
}

// What the household channel's sender does with a tool's post to the family room.
async function toolPost(corey, handovers, text) {
  return corey.room.reply({ conversation: "family", text, handedOver: handovers.marks("family") });
}

async function relayed(from, to) {
  return to.room.acceptPeer({ entries: from.outboxes.at(-1).entries });
}

async function bothGateways() {
  const corey = await gateway({ person: "Franco", assistant: "Corey", peerPerson: "Gia", peerAssistant: "Denise" });
  const denise = await gateway({ person: "Gia", assistant: "Denise", peerPerson: "Franco", peerAssistant: "Corey" });
  return { corey, denise };
}

test("a tool's post during a handed-over turn is marked, and starts at most one final answer on the other gateway", async () => {
  const { corey, denise } = await bothGateways();
  const handovers = createHandovers();
  let post;
  await handovers.during(async (named) => {
    named("run-1");
    handovers.toolStarted("run-1", "call-1");
    post = await toolPost(corey, handovers, "@Denise can you check Gia's calendar?");
    handovers.toolEnded("run-1", "call-1");
  });
  assert.equal(post.handedOver, true);
  await relayed(corey, denise);
  assert.deepEqual(denise.dispatched.map((turn) => turn.handedOver), ["final"]);
});

test("a tool's post during a final turn is final, and starts nothing on the other gateway", async () => {
  const { corey, denise } = await bothGateways();
  const handovers = createHandovers();
  let post;
  await handovers.during(async (named) => {
    named("run-1");
    handovers.toolStarted("run-1", "call-1");
    post = await toolPost(corey, handovers, "@Denise thanks, it is on the calendar.");
    handovers.toolEnded("run-1", "call-1");
  }, "final");
  assert.deepEqual([post.handedOver, post.final], [true, true]);
  await relayed(corey, denise);
  assert.equal(denise.dispatched.length, 0);
});

test("a person-started turn's tool post is not marked, and its @mention hands over", async () => {
  const { corey, denise } = await bothGateways();
  const handovers = createHandovers();
  handovers.toolStarted("run-9", "call-1");
  const post = await toolPost(corey, handovers, "@Denise can you check Gia's calendar?");
  handovers.toolEnded("run-9", "call-1");
  assert.equal("handedOver" in post, false);
  await relayed(corey, denise);
  assert.equal(denise.dispatched.length, 1);
});

test("while a handed-over turn runs, another run's tool post is still not its", async () => {
  const handovers = createHandovers();
  await handovers.during(async (named) => {
    named("run-1");
    handovers.toolStarted("run-2", "call-7");
    assert.equal(handovers.marks("family"), false);
  });
});

test("only a tool call under way marks a post, and every run a turn starts counts", async () => {
  const handovers = createHandovers();
  await handovers.during(async (named) => {
    named("run-1");
    named("run-1-retry");
    assert.equal(handovers.marks("family"), false, "the turn's own reply is marked where it is delivered");
    handovers.toolStarted("run-1-retry", "call-2");
    assert.equal(handovers.marks("family"), true);
    handovers.toolEnded("run-1-retry", "call-2");
    assert.equal(handovers.marks("family"), false);
  });
});

test("a post to the owner's own thread is never marked", async () => {
  const handovers = createHandovers();
  await handovers.during(async (named) => {
    named("run-1");
    handovers.toolStarted("run-1", "call-1");
    assert.equal(handovers.marks("direct"), false);
  });
});

test("when the turn ends, a tool call whose end never came marks nothing more", async () => {
  const handovers = createHandovers();
  await handovers.during(async (named) => {
    named("run-1");
    handovers.toolStarted("run-1", "call-1");
  });
  assert.equal(handovers.marks("family"), false);
});

test("a turn that fails still ends", async () => {
  const handovers = createHandovers();
  await assert.rejects(handovers.during(async (named) => {
    named("run-1");
    handovers.toolStarted("run-1", "call-1");
    throw new Error("the model was unavailable");
  }), /unavailable/);
  assert.equal(handovers.marks("family"), false);
});
