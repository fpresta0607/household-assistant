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

// The 22 October duplicate: Gia gave Denise the weigh-in in her own thread, and Corey's turn in
// the family room had to say the same numbers without anyone sending them again.
test("a weigh-in Denise keeps as rows reaches Corey's family-room turn through the inbox, with what is due", async () => {
  // Arrange
  const channel = await runningChannel(CFG);
  const at = Date.now();
  const step = (index, line) => ({ id: `ns-00000000-0000-4000-8000-00000000000${index}`, at: at + index, author: "denise", kind: "add", line });
  const fromDenise = [
    step(1, { id: "hn-1a000001", topic: "Kitten weights", item: "Mochi", text: "212 g", day: "2026-10-21", for: "gia" }),
    step(2, { id: "hn-1a000002", topic: "Kitten weights", item: "Pepper", text: "198 g", day: "2026-10-21", for: "gia" }),
    step(3, { id: "hn-1a000003", topic: "Kitten milestones", text: "Second deworming dose", due: "2026-10-01", for: "gia" }),
  ];

  try {
    // Act
    await writeFile(
      path.join(channel.stateDir, "household-app", "inbox", "0001-from-denise.json"),
      JSON.stringify({ from: "denise", batch: { entries: [], notes: fromDenise } }),
    );
    await until("Denise's weigh-in in the note", async () =>
      (await channel.promptBuild({ prompt: "" }, { agentId: "main", ...FAMILY_ROOM })).prependContext?.includes("198 g") === true);
    const room = (await channel.promptBuild({ prompt: "What did the kittens weigh?" }, { agentId: "main", ...FAMILY_ROOM })).prependContext;

    // Assert
    assert.match(room, /\nDue now or within a week:\n- hn-1a000003, "Kitten milestones", [A-Z][a-z]{2}, [A-Z][a-z]{2} \d+: "Second deworming dose", overdue since Thu, Oct 1 \(Gia asked Denise\)/);
    assert.match(room, /\nKitten weights\n- hn-1a000001, Wed, Oct 21: "Mochi": "212 g" \(Gia asked Denise\)\n- hn-1a000002, Wed, Oct 21: "Pepper": "198 g"/);
  } finally {
    await channel.stop();
  }
});

// Corey's weekly family posts were automations of his alone, delivered to The Fam, so Denise
// never knew they existed.
test("Corey's automations that post in the family room reach Denise's family-room turns by name and schedule, never their prompt, and go when deleted", async () => {
  // Arrange
  const cfg = { ...CFG, plugins: { entries: { "household-family-room": { config: { groupChatId: "-5100000001" } } } } };
  const job = (id, name, delivery, extra = {}) => ({
    id, name, agentId: "main", enabled: true, delivery,
    schedule: { kind: "cron", expr: "40 16 * * 6", tz: "America/Chicago" },
    payload: { kind: "agentTurn", message: "PRIVATE PROMPT WORDS" },
    ...extra,
  });
  const jobs = [
    job("job-fam", "Saturday supplies reminder", { mode: "announce", channel: "telegram", to: "-5100000001" }),
    job("job-room", "Sunday plan for the week", { mode: "announce", channel: "household", to: "household:family" }),
    job("job-own", "Franco's morning brief", { mode: "announce", channel: "telegram", to: "7100000001" }),
    job("job-off", "Paused family post", { mode: "announce", channel: "telegram", to: "-5100000001" }, { enabled: false }),
    job("job-other", "Another agent's post", { mode: "announce", channel: "telegram", to: "-5100000001" }, { agentId: "money" }),
  ];
  const scheduler = { list: async () => structuredClone(jobs) };
  const abort = new AbortController();
  const corey = await runningChannel(cfg);
  const outbox = path.join(corey.stateDir, "household-app", "outbox.json");
  let mirrored;
  try {
    // Act: OpenClaw reconciles the scheduler as the gateway starts, and a job is later deleted.
    await corey.hook("cron_reconciled", { reason: "startup", enabled: true }, { getCron: () => scheduler, abortSignal: abort.signal });
    await until("the automations in the outbox", async () => JSON.parse(await readFile(outbox, "utf8").catch(() => "{}")).notes?.length === 2);
    mirrored = JSON.parse(await readFile(outbox, "utf8")).notes;
    jobs.splice(1, 1);
    await corey.hook("cron_changed", { action: "removed", jobId: "job-room" });
    await until("the deleted automation removed", async () => JSON.parse(await readFile(outbox, "utf8")).notes.length === 3);

    // Assert
    assert.deepEqual(mirrored.map((step) => [step.kind, step.line.text, step.line.automation]), [
      ["add", "Saturday supplies reminder", { job: "job-fam", schedule: "on the schedule 40 16 * * 6 (America/Chicago)" }],
      ["add", "Sunday plan for the week", { job: "job-room", schedule: "on the schedule 40 16 * * 6 (America/Chicago)" }],
    ]);
    assert.equal(JSON.parse(await readFile(outbox, "utf8")).notes[2].kind, "remove");
    assert.doesNotMatch(await readFile(outbox, "utf8"), /PRIVATE PROMPT WORDS|morning brief|Paused|Another agent/);
  } finally {
    abort.abort();
    await corey.stop();
  }

  const denise = await runningChannel({
    channels: {
      household: {
        owner: { id: "gia", name: "Gia" },
        assistant: { id: "denise", name: "Denise" },
        peer: { person: { id: "franco", name: "Franco" }, assistant: { id: "corey", name: "Corey" } },
      },
    },
  });
  try {
    // Act: the relay carries Corey's steps to Denise's gateway.
    await writeFile(
      path.join(denise.stateDir, "household-app", "inbox", "0001-from-corey.json"),
      JSON.stringify({ from: "corey", batch: { entries: [], notes: JSON.parse(await readFile(outbox, "utf8")).notes } }),
    );
    await until("Corey's automation in Denise's note", async () =>
      (await denise.promptBuild({ prompt: "" }, { agentId: "main", ...FAMILY_ROOM })).prependContext?.includes("Saturday supplies reminder") === true);
    const room = (await denise.promptBuild({ prompt: "What posts on its own?" }, { agentId: "main", ...FAMILY_ROOM })).prependContext;

    // Assert
    assert.match(room, /\nFamily automations, which post on their own:\n- hn-[0-9a-f]{8}, "Family automations", "Saturday supplies reminder", runs on the schedule 40 16 \* \* 6 \(America\/Chicago\), an automation of Corey's that posts in the family room\n/);
    assert.doesNotMatch(room, /Sunday plan for the week/);
  } finally {
    await denise.stop();
  }
});

test("a promise made in the owner's thread survives a restart and starts the family room's next turn until it is done", async () => {
  // Arrange: Franco asks Corey in passing, in his own thread, and the gateway restarts.
  const first = await runningChannel(CFG);
  let promise;
  try {
    promise = (await run(noteTool(first, OWNERS_THREAD), { action: "promise", text: "Book the litter's first shots", due: "2026-10-30" })).lines[0].id;
  } finally {
    await first.stop();
  }
  const channel = await runningChannel(CFG, { stateDir: first.stateDir });

  try {
    // Act
    const room = (await channel.promptBuild({ prompt: "Anything open?" }, { agentId: "main", ...FAMILY_ROOM })).prependContext;
    await run(noteTool(channel, OWNERS_THREAD), { action: "done", line: promise });
    const after = (await channel.promptBuild({ prompt: "Anything open?" }, { agentId: "main", ...FAMILY_ROOM })).prependContext;

    // Assert
    assert.match(room, new RegExp(`\\nPromises still open:\\n- ${promise}, "Promises", [A-Z][a-z]{2}, [A-Z][a-z]{2} \\d+: "Book the litter's first shots", due Fri, Oct 30, Corey to do \\(Franco asked Corey\\)\\n`));
    assert.equal(room.split(promise).length, 2, "a promise listed above is not shown again under its topic");
    assert.doesNotMatch(after, /Promises still open/);
    assert.match(after, /\nPromises\n- hn-[0-9a-f]{8}, [A-Z][a-z]{2}, [A-Z][a-z]{2} \d+: "Book the litter's first shots", due Fri, Oct 30, done [A-Z][a-z]{2}, [A-Z][a-z]{2} \d+ by Corey, Corey to do/);
  } finally {
    await channel.stop();
  }
});
