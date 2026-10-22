// The household note in the turns that read it, driven through the plugin's own entry: a
// line written in one turn starts every app turn after it, the family room's shared session
// included, crosses to the other gateway in the outbox, and comes back from it through the
// inbox. Telegram's turns are not given it.
//
// Run with `node --test tests/js/household_app_note_turns.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { test } from "node:test";

import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

const CFG = {
  channels: {
    household: {
      owner: { id: "franco", name: "Franco" },
      assistant: { id: "corey", name: "Corey" },
      peer: { person: { id: "gia", name: "Gia" }, assistant: { id: "denise", name: "Denise" } },
    },
  },
};

const OWNERS_THREAD = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  deliveryContext: { channel: "household", accountId: "default", to: "household:franco" },
  requesterSenderId: "franco",
  sessionKey: "agent:main:household:direct:franco",
};
const FAMILY_ROOM = { sessionKey: "agent:main:household:group:family" };
const OWNERS_FAMILY_ROOM = { sessionKey: "agent:main:household:group:family:sender:franco" };
const THE_FAM = { sessionKey: "agent:main:telegram:group:-5100000001" };
const TELEGRAM_DM = { sessionKey: "agent:main:telegram:direct:7100000001" };

function noteTool(channel, context) {
  const registered = channel.tools.find(({ options }) => options.names.includes("household_note"));
  return registered.factory(context);
}

async function run(tool, args) {
  return JSON.parse((await tool.execute("call-1", args)).content[0].text);
}

test("a line kept in the owner's own thread starts every app turn after it, the family room's included, and no Telegram turn", async () => {
  // Arrange: Franco asks Corey, in his own thread, to tell Denise the kitten weights.
  const channel = await runningChannel(CFG);

  try {
    await run(noteTool(channel, OWNERS_THREAD), { action: "add", topic: "Kitten weights", text: "Mochi 410 g, Pepper 395 g" });

    // Act
    const turns = {};
    for (const [name, context] of Object.entries({ OWNERS_THREAD, FAMILY_ROOM, OWNERS_FAMILY_ROOM, THE_FAM, TELEGRAM_DM })) {
      turns[name] = await channel.promptBuild({ prompt: "Put the kitten weights together" }, { agentId: "main", ...context });
    }

    // Assert
    for (const name of ["OWNERS_THREAD", "FAMILY_ROOM", "OWNERS_FAMILY_ROOM"]) {
      assert.match(turns[name].prependContext ?? "", /^The household note, which Franco, Gia, Corey and Denise all read/, name);
      assert.match(turns[name].prependContext, /\nKitten weights\n- hn-[0-9a-f]{8}, [A-Z][a-z]{2}, [A-Z][a-z]{2} \d+: "Mochi 410 g, Pepper 395 g" \(Franco asked Corey\)/, name);
    }
    for (const name of ["THE_FAM", "TELEGRAM_DM"]) {
      assert.equal(turns[name].prependContext, undefined, name);
      assert.ok(turns[name].appendSystemContext, `${name} still gets how the assistant talks`);
    }
  } finally {
    await channel.stop();
  }
});

test("another agent's turn is not given the note", async () => {
  const channel = await runningChannel(CFG);
  try {
    await run(noteTool(channel, OWNERS_THREAD), { action: "add", topic: "Dates", text: "Dentist Monday 9 am" });
    assert.deepEqual(await channel.promptBuild({ prompt: "dentist" }, { agentId: "helper", ...FAMILY_ROOM }), {});
  } finally {
    await channel.stop();
  }
});

test("a line crosses to the other gateway in the outbox, and the other gateway's lines come back through the inbox", async () => {
  // Arrange
  const channel = await runningChannel(CFG);
  const outbox = path.join(channel.stateDir, "household-app", "outbox.json");
  const fromDenise = {
    id: "ns-00000000-0000-4000-8000-000000000001",
    at: Date.now(),
    author: "denise",
    kind: "add",
    line: { id: "hn-0a0b0c0d", topic: "Kitten weights", text: "Pepper 400 g this morning", for: "gia" },
  };

  try {
    // Act
    await run(noteTool(channel, OWNERS_THREAD), { action: "add", topic: "Kitten weights", text: "Mochi 410 g" });
    await until("the note in the outbox", async () => (await readFile(outbox, "utf8").catch(() => "")).includes("Mochi 410 g"));
    await writeFile(
      path.join(channel.stateDir, "household-app", "inbox", "0001-from-denise.json"),
      JSON.stringify({ from: "denise", batch: { entries: [], notes: [fromDenise] } }),
    );
    await until("Denise's line in the note", async () =>
      (await channel.promptBuild({ prompt: "" }, { agentId: "main", ...FAMILY_ROOM })).prependContext?.includes("Pepper 400 g") === true);

    // Assert
    const { notes } = JSON.parse(await readFile(outbox, "utf8"));
    assert.deepEqual(notes.map((step) => [step.author, step.kind, step.line.text]), [["corey", "add", "Mochi 410 g"]], "only this assistant's own steps go out");
    // In Franco's own thread, which holds every tool, her line is named, not shown.
    const owners = (await channel.promptBuild({ prompt: "" }, { agentId: "main", ...OWNERS_THREAD })).prependContext;
    assert.match(owners, /"Mochi 410 g"/);
    assert.doesNotMatch(owners, /Pepper 400 g/);
    assert.match(owners, /It also holds 1 line written in other chats, which this chat does not show/);
    // Denise's step was taken before Corey's line, so it reads first.
    const view = await run(noteTool(channel, OWNERS_THREAD), { action: "view", topic: "kitten weights" });
    assert.deepEqual(view.lines.map(({ text, for: forName, by }) => [text, forName, by]), [
      ["Pepper 400 g this morning", "Gia", "Denise"],
      ["Mochi 410 g", "Franco", "Corey"],
    ]);
  } finally {
    await channel.stop();
  }
});
