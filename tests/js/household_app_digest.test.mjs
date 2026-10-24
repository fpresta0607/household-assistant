// The Sunday night digest, from deploy/openclaw/plugins/household-app/digest.js: about ten
// lines from each parent's own assistant, the week and the decisions from its scheduled run,
// and what is slipping, the litter's weight trend, the cart and the open promises from the
// household note and the cart themselves, so the run never reads words someone else wrote.
//
// Run with `node --test tests/js/household_app_digest.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { test } from "node:test";

import { DIGEST_TOOL, composeDigest, createDigestTool, trendOf } from "../../deploy/openclaw/plugins/household-app/digest.js";
import { runningChannel, until } from "./fixtures/household-app-channel.mjs";

// Sunday 25 October 2026, 7 PM in Chicago.
const SUNDAY = Date.UTC(2026, 9, 26, 0, 0);
const WEIGH_INS = {
  topic: "Kitten weights",
  rows: [
    { item: "Mochi", text: "205 g", day: "2026-10-18" },
    { item: "Pepper", text: "219 g", day: "2026-10-18" },
    { item: "Mochi", text: "242 g", day: "2026-10-25" },
    { item: "Pepper", text: "250 g", day: "2026-10-25" },
    { item: "Olive", text: "252 g", day: "2026-10-25" },
  ],
};
const DUE = {
  overdue: [{ topic: "Kitten milestones", text: "Second deworming dose" }],
  soon: [],
  promises: [
    { topic: "Promises", text: "Book the litter's first shots", owner: "Corey", standing: "overdue" },
    { topic: "Promises", text: "Order more kitten formula", owner: "Denise" },
  ],
  later: 0,
};

test("a log's trend is its latest weigh-in, its average and the change since the one before", () => {
  assert.equal(trendOf(WEIGH_INS), "Kitten weights: 3 on Sun, Oct 25, average 248 g, up 36 g since Sun, Oct 18.");
  assert.equal(trendOf({ topic: "Kitten weights", rows: WEIGH_INS.rows.slice(0, 2) }), "Kitten weights: 2 on Sun, Oct 18, average 212 g.");
  assert.equal(trendOf({ topic: "Kitten weights", rows: [{ text: "weighed later", day: "2026-10-25" }] }), null);
  assert.equal(trendOf(null), null);
});

test("the digest is about ten lines: the week, what is slipping, the trend, the cart, the promises and the decisions", () => {
  // Act
  const lines = composeDigest({
    week: ["Mon 9:00 Vet visit for the litter", "Wed 3:30 Dentist", "Sat 10:00 Church bake sale"],
    decide: ["Who takes the litter to the vet Monday", "Whether to keep the Saturday slot"],
    due: DUE,
    log: WEIGH_INS,
    cartItems: 4,
    now: SUNDAY,
    timeZone: "America/Chicago",
  });

  // Assert
  assert.deepEqual(lines, [
    "Sunday digest, the week of Mon, Oct 26",
    "- Mon 9:00 Vet visit for the litter",
    "- Wed 3:30 Dentist",
    "- Sat 10:00 Church bake sale",
    "Slipping: \"Second deworming dose\" (Kitten milestones), \"Book the litter's first shots\" (Promises).",
    "Kitten weights: 3 on Sun, Oct 25, average 248 g, up 36 g since Sun, Oct 18.",
    "Cart: 4 items waiting to be ordered.",
    "Promises: 2 open, first \"Book the litter's first shots\" (Promises), Corey.",
    "To decide:",
    "- Who takes the litter to the vet Monday",
    "- Whether to keep the Saturday slot",
  ]);
});

test("a quiet week still reads in a few lines", () => {
  const lines = composeDigest({ week: [], decide: [], due: { overdue: [], soon: [], promises: [], later: 0 }, log: null, cartItems: 0, now: SUNDAY, timeZone: "America/Chicago" });
  assert.deepEqual(lines, ["Sunday digest, the week of Mon, Oct 26", "- Nothing on the calendar.", "Slipping: nothing.", "Cart: empty.", "Promises: none open."]);
});

const SCHEDULED = { agentId: "main", agentAccountId: "default", sessionKey: "agent:main:cron:job-7" };
const FAMILY_ROOM = {
  agentId: "main",
  agentAccountId: "default",
  messageChannel: "household",
  deliveryContext: { channel: "household", accountId: "default", to: "household:family" },
  requesterSenderId: "gia",
  sessionKey: "agent:main:household:group:family",
};

test("the tool is offered to a scheduled run and the owner's own turns, never the room's shared session, and takes one-line lists", async () => {
  // Arrange
  const posted = [];
  const offer = (context) => createDigestTool({ context, owner: "franco", post: async (week, decide) => (posted.push({ week, decide }), 9) });
  const tool = offer(SCHEDULED);

  // Act
  const bad = JSON.parse((await tool.execute("call-1", { week: ["line one\nline two"], decide: [] })).content[0].text);
  const tooMany = JSON.parse((await tool.execute("call-2", { week: [], decide: ["a", "b", "c", "d"] })).content[0].text);
  const good = JSON.parse((await tool.execute("call-3", { week: [" Wed 3:30 Dentist "], decide: [] })).content[0].text);

  // Assert
  assert.equal(tool.name, DIGEST_TOOL);
  assert.equal(offer(FAMILY_ROOM), null);
  assert.equal(bad.code, "invalid_arguments");
  assert.equal(tooMany.code, "invalid_arguments");
  assert.deepEqual(good, { posted: true, lines: 9 });
  assert.deepEqual(posted, [{ week: ["Wed 3:30 Dentist"], decide: [] }]);
});

// Through the plugin's own entry: Denise's weigh-in arrives over the relay, Corey's Sunday run
// calls the tool, and Franco's thread gets the digest, with the run told only how many lines.
test("through the plugin, the Sunday run's digest reaches the owner's thread with the other side's weigh-in, and the run hears only a count", async () => {
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
  const at = Date.now();
  const step = (index, line) => ({ id: `ns-00000000-0000-4000-8000-00000000000${index}`, at: at + index, author: "denise", kind: "add", line });
  try {
    await writeFile(
      path.join(channel.stateDir, "household-app", "inbox", "0001-from-denise.json"),
      JSON.stringify({ from: "denise", batch: { entries: [], notes: [
        step(1, { id: "hn-2a000001", topic: "Kitten weights", item: "Mochi", text: "205 g", day: "2026-10-18", for: "gia" }),
        step(2, { id: "hn-2a000002", topic: "Kitten weights", item: "Mochi", text: "242 g", day: "2026-10-25", for: "gia" }),
        step(3, { id: "hn-2a000003", topic: "Promises", text: "Order more kitten formula", owner: "denise", for: "gia" }),
      ] } }),
    );
    await until("Denise's weigh-in in the note", async () =>
      (await channel.promptBuild({ prompt: "" }, { agentId: "main", sessionKey: "agent:main:household:group:family" })).prependContext?.includes("242 g") === true);
    const tool = channel.tools.find(({ options }) => options.names.includes(DIGEST_TOOL)).factory(SCHEDULED);

    // Act
    const answer = (await tool.execute("call-1", { week: ["Mon 9:00 Vet visit for the litter"], decide: ["Who takes the litter Monday"] })).content[0].text;
    const thread = (await channel.call("household-app.history", { conversation: "direct" })).payload.messages;

    // Assert
    const digest = thread.at(-1);
    assert.equal(digest.author, "corey");
    assert.match(digest.text, /^Sunday digest, the week of [A-Z][a-z]{2}, [A-Z][a-z]{2} \d+\n- Mon 9:00 Vet visit for the litter\n/);
    assert.match(digest.text, /\nKitten weights: 1 on Sun, Oct 25, average 242 g, up 37 g since Sun, Oct 18\.\n/);
    assert.match(digest.text, /\nPromises: 1 open, first "Order more kitten formula" \(Promises\), Denise\.\n/);
    assert.match(digest.text, /\nTo decide:\n- Who takes the litter Monday$/);
    assert.doesNotMatch(answer, /kitten|formula|242/i, "the run with every tool hears a count, not the note's words");
    assert.deepEqual(JSON.parse(answer), { posted: true, lines: 8 });
  } finally {
    await channel.stop();
  }
});

// The week drawn the way the Overlord asked for the day snapshot on 22 October: an agenda card,
// each day a calendar mark beside one row for each thing, in bold with its time. Made up.
const EVENTS = [
  { title: "Piano lesson", start: "2026-10-26T16:30:00-05:00" },
  { title: "Dentist", start: "2026-10-26T09:00:00-05:00" },
  { title: "School picture day", day: "2026-10-28" },
  { title: "Bake sale", start: "2026-10-31T10:00:00-05:00" },
];
const agendaOf = (text) => JSON.parse(/```steward-card\n(\{"type":"agenda".*\})\n```/.exec(text)[1]);

test("given the week's events, the digest shows them as an agenda card, each day once with its things in order", () => {
  // Act
  const lines = composeDigest({ week: [], events: EVENTS, decide: [], due: { overdue: [], soon: [], promises: [], later: 0 }, log: null, cartItems: 0, now: SUNDAY, timeZone: "America/Chicago" });

  // Assert
  assert.equal(lines[0], "Sunday digest, the week of Mon, Oct 26");
  assert.deepEqual(agendaOf(lines.join("\n")), {
    type: "agenda",
    title: "The week ahead",
    skill: "calendar",
    days: [
      { date: "2026-10-26", events: [{ title: "Dentist", time: "9:00 AM" }, { title: "Piano lesson", time: "4:30 PM" }] },
      { date: "2026-10-28", events: [{ title: "School picture day" }] },
      { date: "2026-10-31", events: [{ title: "Bake sale", time: "10:00 AM" }] },
    ],
  });
  assert.deepEqual(lines.slice(4), ["Slipping: nothing.", "Cart: empty.", "Promises: none open."], "the rest of the digest as before");
});

test("the tool takes the week's events and refuses one with no start or day, both, or a time with no offset", async () => {
  // Arrange
  const posted = [];
  const tool = createDigestTool({ context: SCHEDULED, owner: "franco", post: async (week, decide, events) => (posted.push({ week, decide, events }), 7) });
  const run = async (args) => JSON.parse((await tool.execute("call-1", args)).content[0].text);

  // Act
  const good = await run({ events: [{ title: " Dentist ", start: "2026-10-26T09:00:00-05:00" }, { title: "Picture day", day: "2026-10-28" }], decide: [] });
  const refused = await Promise.all([
    run({ events: [{ title: "Dentist" }], decide: [] }),
    run({ events: [{ title: "Dentist", start: "2026-10-26T09:00:00-05:00", day: "2026-10-26" }], decide: [] }),
    run({ events: [{ title: "Dentist", start: "2026-10-26T09:00:00" }], decide: [] }),
    run({ events: Array.from({ length: 13 }, () => ({ title: "Dentist", day: "2026-10-26" })), decide: [] }),
    run({ decide: [] }),
  ]);

  // Assert
  assert.deepEqual(good, { posted: true, lines: 7 });
  assert.deepEqual(posted, [{ week: [], decide: [], events: [{ title: "Dentist", start: "2026-10-26T09:00:00-05:00" }, { title: "Picture day", day: "2026-10-28" }] }]);
  assert.deepEqual(refused.map((answer) => answer.code), Array(5).fill("invalid_arguments"));
});

test("through the plugin, the Sunday run's events reach the owner's thread as one agenda card", async () => {
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
    const tool = channel.tools.find(({ options }) => options.names.includes(DIGEST_TOOL)).factory(SCHEDULED);

    // Act
    await tool.execute("call-1", { events: EVENTS, decide: ["Who drives Saturday"] });
    const digest = (await channel.call("household-app.history", { conversation: "direct" })).payload.messages.at(-1);

    // Assert
    assert.equal(digest.author, "corey");
    assert.equal(agendaOf(digest.text).days.length, 3);
    assert.doesNotMatch(digest.text, /^- Dentist/m, "the week is the card, not lines");
    assert.match(digest.text, /\nTo decide:\n- Who drives Saturday$/);
  } finally {
    await channel.stop();
  }
});
