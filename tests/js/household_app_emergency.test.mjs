// The emergency card, from deploy/openclaw/plugins/household-app/emergency.js: its entries are
// the household note's "Emergency card" lines, which both assistants keep current, and
// /emergency answers with them at once, with no model, in the order a panic reads them.
//
// Run with `node --test tests/js/household_app_emergency.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { test } from "node:test";

import { EMERGENCY_TOPIC, cardOf } from "../../deploy/openclaw/plugins/household-app/emergency.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const row = (item, text) => ({ item, text, day: "2026-10-22" });

test("the card reads in a panic's order, with poison control's public number when the family kept none", () => {
  // Act
  const lines = cardOf({
    topic: EMERGENCY_TOPIC,
    rows: [row("Neighbor", "Pat next door, 555-0102"), row("Insurance", "Member 000-11, group 22, 555-0103"), row("Vet", "Oak Street Animal Clinic, 555-0100"), row("Pediatrician", "Dr. Example, 555-0101")],
  });

  // Assert
  assert.deepEqual(lines, [
    "Emergency: call 911 first.",
    "Vet: Oak Street Animal Clinic, 555-0100",
    "Poison control: 1-800-222-1222",
    "Pediatrician: Dr. Example, 555-0101",
    "Insurance: Member 000-11, group 22, 555-0103",
    "Neighbor: Pat next door, 555-0102",
  ]);
});

test("a kept poison control number, and any other contact, stay as the family wrote them", () => {
  const lines = cardOf({ topic: EMERGENCY_TOPIC, rows: [row("Babysitter", "Sam, 555-0104"), row("Poison control", "Regional line, 555-0105")] });
  assert.deepEqual(lines, ["Emergency: call 911 first.", "Poison control: Regional line, 555-0105", "Babysitter: Sam, 555-0104"]);
});

test("an empty card still gives 911 and poison control, and says how to fill it", () => {
  const lines = cardOf(null);
  assert.equal(lines[0], "Emergency: call 911 first.");
  assert.equal(lines[1], "Poison control: 1-800-222-1222");
  assert.match(lines[2], /keep the vet, the pediatrician, insurance and a neighbor under "Emergency card"/);
});

// Through the plugin's own entry: the vet kept in Franco's thread and the neighbor Denise kept
// on her side, both in the card /emergency answers with, with no turn started.
test("through the plugin, /emergency answers at once with both sides' entries and starts no turn", async () => {
  // Arrange
  const channel = await runningChannel({
    channels: {
      household: {
        owner: { id: "franco", name: "Franco" },
        assistant: { id: "corey", name: "Corey" },
        peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
      },
    },
  });
  try {
    const note = channel.tools.find(({ options }) => options.names.includes("household_note")).factory({
      agentId: "main",
      agentAccountId: "default",
      messageChannel: "household",
      deliveryContext: { channel: "household", accountId: "default", to: "household:franco" },
      requesterSenderId: "franco",
      sessionKey: "agent:main:household:direct:franco",
    });
    await note.execute("call-1", { action: "add", topic: EMERGENCY_TOPIC, item: "Vet", text: "Oak Street Animal Clinic, 555-0100" });
    await writeFile(
      path.join(channel.stateDir, "household-app", "inbox", "0001-from-denise.json"),
      JSON.stringify({ from: "denise", batch: { entries: [], notes: [{
        id: "ns-00000000-0000-4000-8000-000000000001", at: Date.now() - 1000, author: "denise", kind: "add",
        line: { id: "hn-3a000001", topic: EMERGENCY_TOPIC, item: "Neighbor", text: "Pat next door, 555-0102", for: "gia" },
      }] } }),
    );
    await until("Denise's entry in the note", async () => JSON.stringify(JSON.parse((await note.execute("call-2", { action: "view", topic: EMERGENCY_TOPIC })).content[0].text)).includes("Pat next door"));

    // Act
    const answer = await channel.commands.get("emergency").handler({ channel: "household", senderId: "franco" });

    // Assert
    assert.equal(answer.text, [
      "Emergency: call 911 first.",
      "Vet: Oak Street Animal Clinic, 555-0100",
      "Poison control: 1-800-222-1222",
      "Neighbor: Pat next door, 555-0102",
    ].join("\n"));
    assert.equal(channel.dispatches.length, 0, "no model, no turn");
    assert.equal(channel.commands.get("emergency").acceptsArgs, false);
  } finally {
    await channel.stop();
  }
});

test("the note tool tells the assistant where the card lives and to say it aloud when asked by voice", async () => {
  const channel = await runningChannel({
    channels: {
      household: {
        owner: { id: "franco", name: "Franco" },
        assistant: { id: "corey", name: "Corey" },
        peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
      },
    },
  });
  try {
    const note = channel.tools.find(({ options }) => options.names.includes("household_note")).factory({
      agentId: "main",
      agentAccountId: "default",
      messageChannel: "household",
      deliveryContext: { channel: "household", accountId: "default", to: "household:family" },
      requesterSenderId: "gia",
      sessionKey: "agent:main:household:group:family",
    });
    assert.match(note.description, /emergency card is the household note's topic "Emergency card"/);
    assert.match(note.description, /when they asked by voice, also read it aloud with speak/);
  } finally {
    await channel.stop();
  }
});
