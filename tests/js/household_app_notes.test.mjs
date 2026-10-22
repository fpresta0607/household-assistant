// The household note, from deploy/openclaw/plugins/household-app: one note both assistants
// write and read, what crosses to the other gateway, how a line is corrected or removed,
// what a turn starts with, and the turns in which household_note answers.
//
// Run with `node --test tests/js/household_app_notes.test.mjs`.
// tests/test_household_plugins.py runs it under pytest whenever node is on the PATH.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { MAX_OPEN_LINES, MAX_TEXT, NOTE_TOOL, createNotes } from "../../deploy/openclaw/plugins/household-app/notes.js";
import { createNoteTool } from "../../deploy/openclaw/plugins/household-app/note-tool.js";

const NOW = Date.UTC(2026, 9, 19, 1, 37);
const FRANCO = { id: "franco", name: "Franco" };
const GIA = { id: "gia", name: "Gia" };
const COREY = { id: "corey", name: "Corey" };
const DENISE = { id: "denise", name: "Denise" };

// Every note a test opens stays open until the run ends, when all are closed and their
// files removed together: Windows refuses to remove a database file that is still open.
const ROOT = mkdtempSync(path.join(os.tmpdir(), "household-notes-"));
const opened = [];
after(() => {
  for (const notes of opened) notes.close();
  rmSync(ROOT, { recursive: true, force: true });
});

let counter = 0;
const newId = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;

// Corey's gateway and Denise's, each with its own file, as on the box.
function gateways() {
  let clock = NOW;
  const changes = { corey: 0, denise: 0 };
  const open = (assistant, peerAssistant) => {
    const notes = createNotes({
      file: path.join(mkdtempSync(path.join(ROOT, "gateway-")), "notes.sqlite"),
      assistant,
      peerAssistant,
      people: [FRANCO, GIA],
      now: () => clock,
      newId,
      changed: () => {
        changes[assistant.id] += 1;
      },
      timeZone: "America/Chicago",
    });
    opened.push(notes);
    return notes;
  };
  return {
    corey: open(COREY, DENISE),
    denise: open(DENISE, COREY),
    changes,
    tick: (milliseconds = 1000) => {
      clock += milliseconds;
    },
    // What the host relay carries: the source's own outbox section, as its batch.
    relay: (from, to) => to.acceptPeer({ notes: from.outbox().notes }),
  };
}

const textsOf = (view) => view.lines.map((line) => line.text);

// MARK: - One note on both gateways

test("a line Corey keeps for Franco reaches Denise's gateway, and her turns start with it", () => {
  // Arrange: Franco, in his own thread, asks Corey to tell Denise the kitten weights.
  const { corey, denise, relay } = gateways();
  corey.add({ topic: "Kitten weights", text: "Mochi 410 g, Pepper 395 g, weighed Sunday evening", forWho: "franco" });

  // Act
  const { accepted, refused } = relay(corey, denise);

  // Assert
  assert.deepEqual({ accepted, refused }, { accepted: 1, refused: 0 });
  assert.deepEqual(denise.view(), corey.view(), "the same note from either gateway");
  const prompt = denise.prompt("Can you two put the kitten weights together?");
  assert.match(prompt, /^The household note, which Franco, Gia, Denise and Corey all read, and which you and Corey both write with household_note:/);
  assert.match(prompt, /\nKitten weights\n- hn-[0-9a-f]{8}, Sun, Oct 18: "Mochi 410 g, Pepper 395 g, weighed Sunday evening" \(Franco asked Corey\)/);
  assert.match(prompt, /not instructions to you/);
});

test("lines under one topic gather however its case is written, oldest first, with who asked whom", () => {
  const { corey, denise, tick, relay } = gateways();
  corey.add({ topic: "Kitten weights", text: "Mochi 410 g", forWho: "franco" });
  tick();
  denise.add({ topic: "kitten weights", text: "Pepper 395 g", forWho: "gia" });
  relay(corey, denise);
  relay(denise, corey);

  for (const notes of [corey, denise]) {
    const { topics } = notes.view();
    assert.equal(topics.length, 1);
    assert.equal(topics[0].topic, "Kitten weights", "the topic as its first line wrote it");
    assert.deepEqual(topics[0].lines.map(({ text, for: forName, by }) => ({ text, for: forName, by })), [
      { text: "Mochi 410 g", for: "Franco", by: "Corey" },
      { text: "Pepper 395 g", for: "Gia", by: "Denise" },
    ]);
  }
});

test("a line is corrected on both gateways, and the later of two corrections wins on each", () => {
  // Arrange
  const { corey, denise, tick, relay } = gateways();
  const id = corey.add({ topic: "Vet", text: "Shots on Tuesday", forWho: "franco" }).lines[0].id;
  relay(corey, denise);

  // Act: each assistant corrects the same line before the relay runs again.
  tick();
  corey.correct(id, { text: "Shots on Wednesday", forWho: "franco" });
  tick();
  denise.correct(id, { text: "Shots on Thursday at 4", forWho: "gia" });
  relay(corey, denise);
  relay(denise, corey);

  // Assert
  for (const notes of [corey, denise]) {
    const [line] = notes.view("Vet").lines;
    assert.equal(line.text, "Shots on Thursday at 4");
    assert.equal(line.by, "Corey", "who wrote the line first stays");
    assert.equal(line.corrected, "Sun, Oct 18");
  }
  assert.match(corey.prompt("vet"), /\(Franco asked Corey, corrected by Denise Sun, Oct 18\)/);
});

test("a correction can move a line to another topic", () => {
  const { corey } = gateways();
  const id = corey.add({ topic: "Groceries", text: "Kitten food, the salmon one", forWho: "franco" }).lines[0].id;
  assert.deepEqual(textsOf(corey.correct(id, { topic: "Kitten supplies", forWho: "franco" })), ["Kitten food, the salmon one"]);
  assert.deepEqual(corey.view("Groceries").lines, []);
});

test("a removed line leaves both notes, and a correction that arrives after it changes nothing", () => {
  const { corey, denise, tick, relay } = gateways();
  const id = corey.add({ topic: "Dates", text: "Dinner with the Smiths, Friday 7 pm", forWho: "franco" }).lines[0].id;
  relay(corey, denise);
  tick();
  denise.remove(id);
  tick();
  corey.correct(id, { text: "Dinner with the Smiths, Friday 8 pm", forWho: "franco" });
  relay(corey, denise);
  relay(denise, corey);

  for (const notes of [corey, denise]) assert.deepEqual(notes.view(), { topics: [] });
  assert.equal(corey.prompt("dinner"), "", "an empty note adds nothing to a turn");
});

test("a gateway that lost its file gets the other's steps back with the next delivery", () => {
  const { corey, denise, relay } = gateways();
  corey.add({ topic: "Kitten weights", text: "Mochi 410 g", forWho: "franco" });
  relay(corey, denise);
  relay(corey, denise);
  assert.equal(denise.view("Kitten weights").lines.length, 1, "a step carried twice is kept once");
});

test("each change is announced, so the outbox carries it, and a delivery with nothing new is not", () => {
  const { corey, denise, changes, relay } = gateways();
  corey.add({ topic: "Dates", text: "Gia's dentist, Monday 9 am", forWho: "gia" });
  assert.equal(changes.corey, 1);
  relay(corey, denise);
  relay(corey, denise);
  assert.equal(changes.denise, 1);
  assert.deepEqual(denise.outbox(), { notes: [] }, "a gateway publishes only its own assistant's steps");
});

// MARK: - What the other gateway may say

for (const [why, change] of [
  ["a step this gateway's own assistant would have taken", (step) => ({ ...step, author: "corey" })],
  ["a step with a malformed id", (step) => ({ ...step, id: "ns-1" })],
  ["a step with no time", (step) => ({ ...step, at: "Saturday" })],
  ["a line kept for a stranger", (step) => ({ ...step, line: { ...step.line, for: "mallory" } })],
  ["a correction for nobody", (step) => ({ id: step.id, at: step.at, author: step.author, kind: "correct", line: step.line.id, topic: "Kitten weights", text: "Pepper 396 g" })],
  ["a line with hidden characters", (step) => ({ ...step, line: { ...step.line, text: "Mochi‮ 410 g" } })],
  ["a line too long to be one fact", (step) => ({ ...step, line: { ...step.line, text: "x".repeat(MAX_TEXT + 1) } })],
  ["a line with no topic", (step) => ({ ...step, line: { ...step.line, topic: "" } })],
  ["a step of an unknown kind", (step) => ({ ...step, kind: "rewrite" })],
  ["a row with a day that is no date", (step) => ({ ...step, line: { ...step.line, day: "2026-02-30" } })],
  ["a row with a month that is none", (step) => ({ ...step, line: { ...step.line, day: "2026-13-01" } })],
  ["a row with a due date in another form", (step) => ({ ...step, line: { ...step.line, due: "Oct 28" } })],
  ["a row whose item is a sentence", (step) => ({ ...step, line: { ...step.line, item: "i".repeat(61) } })],
  ["a done step for nobody", (step) => ({ id: step.id, at: step.at, author: step.author, kind: "done", line: step.line.id })],
  // It would sort after every correction made here, and its topic first in every turn.
  ["a step from more than five minutes ahead of this gateway's clock", (step) => ({ ...step, at: NOW + 5 * 60_000 + 1 })],
]) {
  test(`the other gateway's ${why} is refused`, () => {
    const { corey, denise } = gateways();
    denise.add({ topic: "Kitten weights", text: "Pepper 395 g", forWho: "gia" });
    const [step] = denise.outbox().notes;
    assert.deepEqual(corey.acceptPeer({ notes: [change(step)] }), { accepted: 0, refused: 1 });
    assert.deepEqual(corey.view(), { topics: [] });
  });
}

test("a step from a clock a little ahead of this one is kept", () => {
  const { corey, denise } = gateways();
  denise.add({ topic: "Kitten weights", text: "Pepper 395 g", forWho: "gia" });
  const [step] = denise.outbox().notes;
  assert.deepEqual(corey.acceptPeer({ notes: [{ ...step, at: NOW + 5 * 60_000 }] }), { accepted: 1, refused: 0 });
});

test("a delivery without notes, or with more steps than any honest one, is not read", () => {
  const { corey } = gateways();
  assert.deepEqual(corey.acceptPeer({}), { accepted: 0, refused: 0 });
  assert.deepEqual(corey.acceptPeer({ notes: new Array(50_001).fill({}) }), { accepted: 0, refused: 50_001 });
});

// MARK: - Bounds

for (const [why, line, code] of [
  ["no words", { topic: "Dates", text: "   " }, "invalid_line"],
  ["more than one fact's words", { topic: "Dates", text: "x".repeat(MAX_TEXT + 1) }, "invalid_line"],
  ["no topic", { topic: "", text: "Friday" }, "invalid_line"],
  ["a topic that is a sentence", { topic: "t".repeat(61), text: "Friday" }, "invalid_line"],
]) {
  test(`a line with ${why} is refused`, () => {
    const { corey } = gateways();
    assert.throws(() => corey.add({ ...line, forWho: "franco" }), (error) => error.code === code);
  });
}

test("a line is kept as one line of plain words", () => {
  const { corey } = gateways();
  const view = corey.add({ topic: " Kitten\tweights ", text: "Mochi\n410 g\u0000", forWho: "franco" });
  assert.equal(view.topic, "Kitten weights");
  assert.deepEqual(textsOf(view), ["Mochi 410 g"]);
});

test("a full note refuses a new line rather than dropping an old one", () => {
  const { corey } = gateways();
  for (let index = 0; index < MAX_OPEN_LINES; index += 1) corey.add({ topic: "Many", text: `Line ${index}`, forWho: "franco" });
  assert.throws(() => corey.add({ topic: "Many", text: "One more", forWho: "franco" }), (error) => error.code === "note_full");
  const many = corey.view("Many");
  assert.equal(many.lines.length + many.earlier, MAX_OPEN_LINES);
});

test("a line that is not there cannot be corrected or removed", () => {
  const { corey } = gateways();
  assert.throws(() => corey.correct("hn-00000000", { text: "Friday", forWho: "franco" }), (error) => error.code === "unknown_line");
  assert.throws(() => corey.remove("hn-00000000"), (error) => error.code === "unknown_line");
});

// MARK: - What a turn starts with

test("a long note shows the topics the message asks about first and names the rest", () => {
  // Arrange: more than a turn's share of other topics, all newer than the kitten weights.
  const { corey, tick } = gateways();
  corey.add({ topic: "Kitten weights", text: "Mochi 410 g", forWho: "franco" });
  for (let index = 0; index < 40; index += 1) {
    tick();
    corey.add({ topic: `Topic ${index}`, text: "w".repeat(200), forWho: "franco" });
  }

  // Act
  const prompt = corey.prompt("What did the kittens weigh?");

  // Assert
  assert.ok(prompt.indexOf("Kitten weights") < prompt.indexOf("Topic 39"), "the asked-about topic comes first");
  assert.match(prompt, /\nNot shown here: "Topic \d+"(, "Topic \d+"){9} and \d+ more\. household_note with view and the topic shows them\./);
  assert.ok(prompt.length < 4800, "a turn reads a bounded note");
});

test("a topic longer than a turn's share shows its newest lines and says how many came before", () => {
  const { corey, tick } = gateways();
  for (let index = 0; index < 60; index += 1) {
    tick();
    corey.add({ topic: "Kitten weights", text: `Weighing ${index}: Mochi ${400 + index} g, Pepper ${390 + index} g`, forWho: "gia" });
  }
  const prompt = corey.prompt("kitten weights");
  assert.match(prompt, /\nKitten weights\n- \(\d+ earlier lines not shown here\)\n/);
  assert.match(prompt, /Weighing 59: Mochi 459 g/);
  assert.doesNotMatch(prompt, /Weighing 0:/);
  assert.ok(prompt.length < 4800);
});

test("a view of the whole note answers with at most a hundred lines, newest topics first, and names the rest", () => {
  const { corey, tick } = gateways();
  for (let index = 0; index < 120; index += 1) {
    tick();
    corey.add({ topic: `Topic ${index}`, text: `Line ${index}`, forWho: "franco" });
  }
  const view = corey.view();
  assert.equal(view.topics.length, 100);
  assert.equal(view.topics[0].topic, "Topic 119");
  assert.match(view.notShown, /^"Topic 19", "Topic 18",.* and 10 more, each shown by its own view$/);
});

// MARK: - The owner's own turns, which hold every tool

test("the owner's own turns show in full only what this assistant kept for its owner, and name the rest", () => {
  // Arrange: Corey keeps a line for Franco, another for Gia in the family room's shared
  // session, and Denise's line arrives from her gateway.
  const { corey, denise, tick, relay } = gateways();
  corey.add({ topic: "Kitten weights", text: "Mochi 410 g", forWho: "franco" });
  tick();
  corey.add({ topic: "Kitten weights", text: "Pepper 395 g", forWho: "gia" });
  tick();
  denise.add({ topic: "Vet", text: "Shots Thursday at 4", forWho: "gia" });
  relay(denise, corey);

  // Act
  const owners = corey.prompt("kitten weights", { fullFor: "franco" });
  const room = corey.prompt("kitten weights");

  // Assert
  assert.match(owners, /"Mochi 410 g"/);
  assert.doesNotMatch(owners, /Pepper 395 g|Shots Thursday|Vet/, "words from a turn with fewer tools never start one with every tool, not even a topic");
  assert.match(owners, /\nIt also holds 2 lines written in other chats, which this chat does not show: household_note with view shows them when they matter\./);
  for (const words of ["Mochi 410 g", "Pepper 395 g", "Shots Thursday at 4"]) assert.ok(room.includes(words), `the family room shows ${words}`);
  assert.doesNotMatch(room, /others wrote/);
});

test("an owner's turn with only others' lines in the note still hears that they are there", () => {
  const { corey, denise, relay } = gateways();
  denise.add({ topic: "Kitten weights", text: "Pepper 395 g", forWho: "gia" });
  relay(denise, corey);
  const owners = corey.prompt("", { fullFor: "franco" });
  assert.match(owners, /^The household note, which Franco, Gia, Corey and Denise all read/);
  assert.match(owners, /It also holds 1 line written in other chats, which this chat does not show: household_note with view shows them when they matter\./);
  assert.doesNotMatch(owners, /Pepper|Kitten/);
});

// The review of 19 October: a correction changes a line's words, so what decides whether a
// full-tool turn shows them is whose step wrote them as they read now.
for (const [why, correct, isShown] of [
  ["the other assistant's correction of this assistant's line", ({ denise, id, relay, corey }) => {
    denise.correct(id, { text: "Mochi 900 g", forWho: "gia" });
    relay(denise, corey);
  }, false],
  ["this assistant's correction in the other person's turn", ({ corey, id }) => corey.correct(id, { text: "Mochi 900 g", forWho: "gia" }), false],
  ["this assistant's correction for its owner", ({ corey, id }) => corey.correct(id, { text: "Mochi 900 g", forWho: "franco" }), true],
]) {
  test(`after ${why}, the owner's own turns ${isShown ? "show" : "do not show"} the line's new words`, () => {
    // Arrange
    const { corey, denise, tick, relay } = gateways();
    const id = corey.add({ topic: "Kitten weights", text: "Mochi 410 g", forWho: "franco" }).lines[0].id;
    relay(corey, denise);
    tick();

    // Act
    correct({ corey, denise, id, relay });

    // Assert
    const owners = corey.prompt("kitten", { fullFor: "franco" });
    assert.equal(owners.includes("Mochi 900 g"), isShown);
    assert.equal(/It also holds 1 line written in other chats/.test(owners), !isShown);
    assert.ok(corey.prompt("kitten").includes("Mochi 900 g"), "the family room shows it either way");
  });
}

// A correction that leaves the words as they were leaves their writer as it was: tidying the
// topic of the other assistant's line in the owner's turn does not make its words the owner's.
test("correcting only the topic of the other assistant's line keeps its words out of the owner's own turns", () => {
  const { corey, denise, tick, relay } = gateways();
  const id = denise.add({ topic: "kittens", text: "Pepper 395 g", forWho: "gia" }).lines[0].id;
  relay(denise, corey);
  tick();
  corey.correct(id, { topic: "Kitten weights", forWho: "franco" });
  const owners = corey.prompt("kitten", { fullFor: "franco" });
  assert.doesNotMatch(owners, /Pepper 395 g|Kitten weights/);
  assert.match(owners, /It also holds 1 line written in other chats/);
  corey.correct(id, { text: "Pepper 395 g", forWho: "franco" });
  assert.doesNotMatch(corey.prompt("kitten", { fullFor: "franco" }), /Pepper 395 g/, "restating the same words changes nothing");
  corey.correct(id, { text: "Pepper 396 g on Sunday", forWho: "franco" });
  assert.match(corey.prompt("kitten", { fullFor: "franco" }), /"Pepper 396 g on Sunday"/, "words this assistant wrote for its owner show");
});

test("without a message to go by, the most recently changed topic comes first", () => {
  const { corey, tick } = gateways();
  corey.add({ topic: "Dates", text: "Friday dinner", forWho: "franco" });
  tick();
  corey.add({ topic: "Kitten weights", text: "Mochi 410 g", forWho: "franco" });
  const prompt = corey.prompt("");
  assert.ok(prompt.indexOf("Kitten weights") < prompt.indexOf("Dates"));
});

// MARK: - Rows, due dates and done: the note as the family's tracker

// The 22 October root cause: a weigh-in of a litter was a table in each assistant's own
// file, and the note had only sentences. Today on the test clock is Sunday 18 October in
// the gateway's zone.
test("a whole weigh-in is one add of rows that both gateways read as rows, each with its kitten and day", () => {
  // Arrange
  const { corey, denise, relay } = gateways();

  // Act: Gia gives Denise the evening's weights in her own thread.
  denise.add({
    topic: "Kitten weights",
    rows: [
      { item: "Mochi", text: "212 g", day: "2026-10-17" },
      { item: "Pepper", text: "198 g", day: "2026-10-17" },
      { item: "Biscuit", text: "205 g", day: "2026-10-17" },
    ],
    forWho: "gia",
  });
  const { accepted } = relay(denise, corey);

  // Assert
  assert.equal(accepted, 3, "one step per row");
  const [mochi] = corey.view("Kitten weights").lines;
  assert.deepEqual({ item: mochi.item, text: mochi.text, day: mochi.day, by: mochi.by }, { item: "Mochi", text: "212 g", day: "Sat, Oct 17", by: "Denise" });
  const room = corey.prompt("What do the kittens weigh?");
  assert.match(room, /\nKitten weights\n- hn-[0-9a-f]{8}, Sat, Oct 17: "Mochi": "212 g" \(Gia asked Denise\)\n- hn-[0-9a-f]{8}, Sat, Oct 17: "Pepper": "198 g"/);
  assert.match(room, /never in a file of your own/);
});

test("rows are kept all together or not at all", () => {
  const { corey } = gateways();
  assert.throws(
    () => corey.add({ topic: "Kitten weights", rows: [{ item: "Mochi", text: "212 g" }, { item: "Pepper", text: "198 g", day: "yesterday" }], forWho: "franco" }),
    (error) => error.code === "invalid_line",
  );
  assert.throws(() => corey.add({ topic: "Kitten weights", rows: [], forWho: "franco" }), (error) => error.code === "invalid_line");
  assert.throws(
    () => corey.add({ topic: "Kitten weights", rows: Array.from({ length: 21 }, (_, index) => ({ text: `${index} g` })), forWho: "franco" }),
    (error) => error.code === "invalid_line",
  );
  assert.deepEqual(corey.view(), { topics: [] });
});

test("every turn starts with what is overdue and what is due within a week, soonest first, and nothing later or done", () => {
  // Arrange: the litter's milestones, one each side.
  const { corey, denise, relay } = gateways();
  corey.add({
    topic: "Kitten milestones",
    rows: [
      { text: "Second deworming dose", due: "2026-10-16" },
      { text: "First shots", due: "2026-10-22" },
      { text: "Spay and neuter window opens", due: "2026-12-01" },
    ],
    forWho: "franco",
  });
  const visit = denise.add({ topic: "Kitten milestones", text: "Vet visit for the litter", due: "2026-10-20", forWho: "gia" }).lines[0].id;
  relay(corey, denise);
  relay(denise, corey);

  // Act
  const prompt = corey.prompt("anything for the vet?");

  // Assert
  assert.equal(prompt.split("\n")[1], "Due now or within a week:", "the due list comes before every topic");
  const dueBlock = prompt.slice(prompt.indexOf("Due now or within a week:"), prompt.indexOf("\nKitten milestones\n"));
  assert.match(dueBlock, /"Kitten milestones", Sun, Oct 18: "Second deworming dose", overdue since Fri, Oct 16/);
  assert.ok(dueBlock.indexOf("Second deworming") < dueBlock.indexOf("Vet visit") && dueBlock.indexOf("Vet visit") < dueBlock.indexOf("First shots"), "overdue, then soonest first");
  assert.doesNotMatch(dueBlock, /Spay/, "a date further out is only in its topic");
  assert.deepEqual(corey.due().soon.map((line) => line.text), ["Vet visit for the litter", "First shots"]);
  assert.equal(corey.due().later, 1);

  // Act: Gia says the visit happened, on Denise's side.
  denise.done(visit, { forWho: "gia" });
  relay(denise, corey);

  // Assert
  assert.deepEqual(corey.due().soon.map((line) => line.text), ["First shots"]);
  const done = corey.view("Kitten milestones").lines.find((line) => line.id === visit);
  assert.deepEqual({ done: done.done, doneBy: done.doneBy, standing: done.standing }, { done: "Sun, Oct 18", doneBy: "Denise", standing: "done" });
  assert.match(corey.prompt("vet"), /"Vet visit for the litter", due Tue, Oct 20, done Sun, Oct 18 by Denise/);
});

test("a line is marked done once, and a correction can move its due date", () => {
  const { corey, denise, tick, relay } = gateways();
  const id = corey.add({ topic: "Kitten milestones", text: "First shots", due: "2026-10-22", forWho: "franco" }).lines[0].id;
  relay(corey, denise);
  tick();
  denise.correct(id, { due: "2026-10-29", forWho: "gia" });
  relay(denise, corey);
  assert.equal(corey.view("Kitten milestones").lines[0].due, "Thu, Oct 29");
  assert.equal(corey.due().later, 1);
  corey.done(id, { forWho: "franco" });
  assert.throws(() => corey.done(id, { forWho: "franco" }), (error) => error.code === "already_done");
});

test("the owner's own turns list as due only what they show", () => {
  const { corey, denise, relay } = gateways();
  denise.add({ topic: "Kitten milestones", text: "Vet visit for the litter", due: "2026-10-20", forWho: "gia" });
  relay(denise, corey);
  corey.add({ topic: "Dates", text: "Franco's passport renewal", due: "2026-10-21", forWho: "franco" });
  const owners = corey.prompt("", { fullFor: "franco" });
  assert.match(owners, /Due now or within a week:\n- hn-[0-9a-f]{8}, "Dates", Sun, Oct 18: "Franco's passport renewal", due Wed, Oct 21/);
  assert.doesNotMatch(owners, /Vet visit/, "the other assistant's words stay out of a turn with every tool");
  assert.match(owners, /It also holds 1 line written in other chats/);
});

// MARK: - The ledger of promises

test("a promise made on one gateway starts every turn on both until it is done, its owner's first", () => {
  // Arrange: Franco asks Corey in passing to find a dentist by Friday, and Gia asks Denise
  // to order the kitten food.
  const { corey, denise, tick, relay } = gateways();
  const dentist = corey.add({ topic: "Promises", text: "Find a dentist who sees kittens' owners on Saturdays", owner: "corey", due: "2026-10-23", forWho: "franco" }).lines[0].id;
  tick();
  denise.add({ topic: "Promises", text: "Order the salmon kitten food", owner: "denise", forWho: "gia" });
  relay(corey, denise);
  relay(denise, corey);

  // Act
  const coreys = corey.prompt("");
  const denises = denise.prompt("");

  // Assert
  assert.match(coreys, /\nPromises still open:\n- hn-[0-9a-f]{8}, "Promises", Sun, Oct 18: "Find a dentist[^"]*", due Fri, Oct 23, Corey to do \(Franco asked Corey\)\n- hn-[0-9a-f]{8}, "Promises", Sun, Oct 18: "Order the salmon kitten food", Denise to do/);
  assert.match(denises, /\nPromises still open:\n- hn-[0-9a-f]{8}, "Promises", Sun, Oct 18: "Order the salmon kitten food", Denise to do/, "each assistant's own first");
  assert.doesNotMatch(coreys, /Due now or within a week:/, "a promise is listed once, with the promises");
  assert.deepEqual(corey.due().promises.map((line) => line.owner), ["Corey", "Denise"]);

  // Act: the dentist is found, on Corey's side.
  corey.done(dentist, { forWho: "franco" });
  relay(corey, denise);

  // Assert
  assert.deepEqual(denise.due().promises.map((line) => line.text), ["Order the salmon kitten food"]);
});

test("a promise is owned by someone in the household", () => {
  const { corey } = gateways();
  assert.throws(() => corey.add({ topic: "Promises", text: "Call the vet", owner: "mallory", forWho: "franco" }), (error) => error.code === "invalid_line");
});

test("a correction can hand a promise to someone else", () => {
  const { corey } = gateways();
  const id = corey.add({ topic: "Promises", text: "Call the vet", owner: "corey", forWho: "franco" }).lines[0].id;
  corey.correct(id, { owner: "franco", forWho: "franco" });
  assert.equal(corey.view("Promises").lines[0].owner, "Franco");
});

test("the tool keeps a promise as the assistant's own unless another owner is named, by name", async () => {
  const { found } = tool(DIRECT);
  const mine = await run(found, { action: "promise", text: "Book the kittens' second shots", due: "2026-10-25" });
  assert.deepEqual(mine.lines.map(({ text, owner, due }) => ({ text, owner, due })), [{ text: "Book the kittens' second shots", owner: "Corey", due: "Sun, Oct 25" }]);
  assert.equal(mine.topic, "Promises");
  const theirs = await run(found, { action: "promise", topic: "Kitten homes", text: "Ask the neighbors about the tortie", owner: "Gia" });
  assert.equal(theirs.lines[0].owner, "Gia");
  assert.equal((await run(found, { action: "promise", text: "Something", owner: "Mallory" })).code, "invalid_line");
});

// MARK: - Handoffs: the two assistants' direct line

test("a handoff is seen and answered on the other side, and the sender's turns say where it stands", () => {
  // Arrange: Corey hands Denise a question in Franco's thread.
  const { corey, denise, tick, relay } = gateways();
  const id = corey.add({ topic: "Handoffs", text: "Anything on Gia's side for the vet visit?", owner: "denise", forWho: "franco" }).lines[0].id;

  // Act
  const arrived = relay(corey, denise);

  // Assert
  assert.deepEqual(arrived.handed, [{ id, at: NOW }], "the receiving gateway hears of a new handoff to it");
  assert.match(corey.prompt(""), /Denise to do, not seen yet/);

  // Act: Denise's gateway marks it seen, and her turn answers.
  assert.equal(denise.seen(id), true);
  assert.equal(denise.seen(id), false, "seen once");
  tick();
  denise.reply(id, "Nothing the vet needs.\nThe due dates are in the note.");
  relay(denise, corey);

  // Assert
  assert.match(corey.prompt(""), /Denise to do, seen Sun, Oct 18 \d+:\d\d [AP]M, Denise replied Sun, Oct 18 \d+:\d\d [AP]M: "Nothing the vet needs\. The due dates are in the note\."/);
  const owners = corey.prompt("", { fullFor: "franco" });
  assert.match(owners, /Denise replied Sun, Oct 18 \d+:\d\d [AP]M \(household_note with view shows it\)/, "a turn with every tool hears only that there is an answer");
  assert.doesNotMatch(owners, /Nothing the vet needs/);
  assert.equal(corey.view("Handoffs").lines[0].reply, "Nothing the vet needs. The due dates are in the note.");
  // In Gia's own thread the handoff is counted as Denise's to do, never shown.
  const gias = denise.prompt("", { fullFor: "gia" });
  assert.match(gias, /It also holds 1 line written in other chats, 1 of them handed to you and not done, which this chat does not show: household_note with due shows them/);
  assert.doesNotMatch(gias, /vet visit/);
});

test("only the assistant a handoff is for marks it seen or answers it", () => {
  const { corey, denise, relay } = gateways();
  const toDenise = corey.add({ topic: "Handoffs", text: "Can you check?", owner: "denise", forWho: "franco" }).lines[0].id;
  const coreysOwn = corey.add({ topic: "Promises", text: "Call the vet", owner: "corey", forWho: "franco" }).lines[0].id;
  relay(corey, denise);
  assert.equal(corey.seen(toDenise), false, "the sender cannot mark its own handoff seen");
  assert.throws(() => corey.reply(toDenise, "Done"), (error) => error.code === "not_a_handoff");
  assert.throws(() => denise.reply(coreysOwn, "Done"), (error) => error.code === "not_a_handoff");
});

test("a handoff's answer is kept on one line and cut at its bound", () => {
  const { corey, denise, relay } = gateways();
  const id = corey.add({ topic: "Handoffs", text: "What's on your side?", owner: "denise", forWho: "franco" }).lines[0].id;
  relay(corey, denise);
  denise.reply(id, "word ".repeat(1000));
  const [reply] = denise.outbox().notes.filter((step) => step.kind === "reply");
  assert.equal(reply.text.length, 2000);
  assert.ok(reply.text.endsWith("…"));
  assert.deepEqual(corey.acceptPeer({ notes: [{ ...reply, text: "x".repeat(2001) }] }), { accepted: 0, refused: 1 });
  assert.deepEqual(corey.acceptPeer({ notes: [reply] }), { accepted: 1, refused: 0 });
});

test("an answer from the assistant a handoff was not for changes nothing", () => {
  const { corey, denise, relay } = gateways();
  const id = denise.add({ topic: "Handoffs", text: "Corey, the litter's food?", owner: "corey", forWho: "gia" }).lines[0].id;
  relay(denise, corey);
  // Denise answering her own handoff, as a malformed or replayed step would.
  const forged = { id: "ns-00000000-0000-4000-8000-0000000000ff", at: NOW, author: "denise", kind: "reply", line: id, text: "Done already" };
  assert.deepEqual(corey.acceptPeer({ notes: [forged] }), { accepted: 1, refused: 0 });
  assert.equal(corey.view("Handoffs").lines[0].reply, undefined);
});

test("the timeline names every step either assistant took, oldest first, a page at a time", () => {
  const { corey, denise, tick, relay } = gateways();
  const weight = corey.add({ topic: "Kitten weights", item: "Mochi", text: "212 g", forWho: "franco" }).lines[0].id;
  tick();
  corey.correct(weight, { text: "214 g", forWho: "franco" });
  tick();
  const id = corey.add({ topic: "Handoffs", text: "Can you check the litter box supplies?", owner: "denise", forWho: "franco" }).lines[0].id;
  relay(corey, denise);
  tick();
  denise.seen(id);
  tick();
  denise.reply(id, "Two bags left.");
  tick();
  denise.done(id, { forWho: "gia" });
  relay(denise, corey);

  for (const notes of [corey, denise]) {
    const { events, more } = notes.timeline();
    assert.deepEqual(events.map(({ by, kind }) => [by, kind]), [
      ["corey", "added"], ["corey", "corrected"], ["corey", "handed"], ["denise", "seen"], ["denise", "replied"], ["denise", "done"],
    ]);
    assert.equal(more, false);
    assert.deepEqual(events[1].line, { id: weight, topic: "Kitten weights", text: "214 g", item: "Mochi" });
    assert.equal(events[4].reply, "Two bags left.");
  }
  const older = corey.timeline({ before: corey.timeline().events[3].at, limit: 2 });
  assert.deepEqual(older.events.map(({ kind }) => kind), ["corrected", "handed"]);
  assert.equal(older.more, true);
  assert.equal(corey.lastAt(), corey.timeline().events.at(-1).at);
});

// MARK: - Who is on it

test("a claim of a family-room question crosses to the other gateway once, and so does a takeover", () => {
  const { corey, denise, tick, relay } = gateways();
  assert.equal(corey.claim("m-00000001", { forWho: "franco" }), true);
  assert.equal(corey.claim("m-00000001", { forWho: "franco" }), false, "once per message");
  relay(corey, denise);
  assert.deepEqual(denise.claimOf("m-00000001"), { claimedBy: "corey", tookBy: null });
  tick();
  assert.equal(denise.took("m-00000002"), true);
  relay(denise, corey);
  assert.deepEqual(corey.claimOf("m-00000002"), { claimedBy: null, tookBy: "denise" });
  assert.deepEqual(corey.timeline().events.map(({ by, kind, message, for: forWho }) => [by, kind, message, forWho]), [
    ["corey", "claimed", "m-00000001", "franco"],
    ["denise", "tookOver", "m-00000002", undefined],
  ]);
  assert.deepEqual(corey.view(), { topics: [] }, "a claim is no line of the note");
  assert.equal(corey.prompt(""), "", "and adds nothing to a turn");
});

test("a question stood down from is kept in the note's file until settled, and never crosses to the other gateway", () => {
  // Arrange
  const file = path.join(mkdtempSync(path.join(ROOT, "gateway-")), "notes.sqlite");
  const open = () => {
    const notes = createNotes({ file, assistant: COREY, peerAssistant: DENISE, people: [FRANCO, GIA], now: () => NOW, newId });
    opened.push(notes);
    return notes;
  };
  const before = open();

  // Act
  before.standDown("m-00000020", { since: NOW - 5000, deadline: NOW + 20_000 });
  before.standDown("m-00000020", { since: NOW, deadline: NOW + 60_000 });
  before.standDown("not a message id", { since: NOW, deadline: NOW });
  const after = open();
  const kept = after.standingDown();
  after.settled("m-00000020");

  // Assert
  assert.deepEqual(kept, [{ message: "m-00000020", since: NOW - 5000, deadline: NOW + 20_000 }], "the first bound holds");
  assert.deepEqual(after.standingDown(), []);
  assert.deepEqual(before.outbox(), { notes: [] });
});

for (const [why, step] of [
  ["a claim of no message", { kind: "claim", message: "x", for: "gia" }],
  ["a claim for nobody", { kind: "claim", message: "m-00000001", for: "mallory" }],
  ["a takeover of no message", { kind: "took", message: "" }],
]) {
  test(`the other gateway's ${why} is refused`, () => {
    const { corey } = gateways();
    assert.deepEqual(corey.acceptPeer({ notes: [{ id: "ns-00000000-0000-4000-8000-0000000000aa", at: NOW, author: "denise", ...step }] }), { accepted: 0, refused: 1 });
  });
}

// MARK: - Family reminders, fired by whichever assistant took them

// The test clock starts on Sunday 18 October, 8:37 pm in the gateway's zone.
function reminderGateways() {
  const pair = gateways();
  const at = (iso) => {
    pair.tick(Date.parse(iso) - (NOW + pair.elapsed));
    pair.elapsed = Date.parse(iso) - NOW;
  };
  pair.elapsed = 0;
  return { ...pair, at };
}

test("a weekly family reminder goes off on its owner's gateway alone, moves to its next week, and both turns see it", () => {
  // Arrange: Gia asks Corey in the family room to remind everyone Saturdays at 4:40.
  const { corey, denise, relay, at } = reminderGateways();
  const id = corey.add({ topic: "Reminders", text: "Pack the bags for Sunday", due: "2026-10-24", owner: "corey", remind: { at: "16:40", every: "week" }, forWho: "gia" }).lines[0].id;
  relay(corey, denise);

  // Assert: nothing due yet, and Denise knows it exists.
  assert.deepEqual(corey.dueReminders(), []);
  assert.match(denise.prompt(""), /\nFamily reminders set:\n- hn-[0-9a-f]{8}, "Reminders", Sun, Oct 18: "Pack the bags for Sunday", goes off Sat, Oct 24 at 4:40 PM, every week, posted by Corey \(Gia asked Corey\)/);
  assert.doesNotMatch(denise.prompt(""), /Promises still open/, "a reminder is no promise");

  // Act: Saturday 4:40 pm in Chicago is 21:40 UTC.
  at("2026-10-24T21:39:59Z");
  const early = corey.dueReminders();
  at("2026-10-24T21:40:00Z");
  const due = corey.dueReminders();
  assert.deepEqual(denise.dueReminders(), [], "only the gateway of the assistant that took it posts it");
  corey.fired(id);
  relay(corey, denise);

  // Assert
  assert.deepEqual(early, []);
  assert.deepEqual(due, [{ id, text: "Pack the bags for Sunday", isLate: false }]);
  assert.deepEqual(corey.dueReminders(), []);
  assert.equal(denise.view("Reminders").lines[0].due, "Sat, Oct 31");
  assert.deepEqual(denise.view("Reminders").lines[0].remind, { at: "4:40 PM", every: "week" });
});

test("a one-time reminder is done once it goes off", () => {
  const { corey, at } = reminderGateways();
  const id = corey.add({ topic: "Reminders", text: "Leave for the vet", due: "2026-10-19", owner: "corey", remind: { at: "09:15" }, forWho: "franco" }).lines[0].id;
  at("2026-10-19T14:15:00Z");
  assert.equal(corey.dueReminders().length, 1);
  corey.fired(id);
  assert.deepEqual(corey.dueReminders(), []);
  assert.equal(corey.view("Reminders").lines[0].standing, "done");
});

test("a reminder missed while the gateway was down is moved on unposted, to its next time still to come", () => {
  const { corey, at } = reminderGateways();
  const id = corey.add({ topic: "Reminders", text: "Bins out", due: "2026-10-19", owner: "corey", remind: { at: "07:00", every: "week" }, forWho: "franco" }).lines[0].id;
  at("2026-11-03T12:00:00Z");
  assert.deepEqual(corey.dueReminders(), [{ id, text: "Bins out", isLate: true }]);
  corey.fired(id);
  assert.equal(corey.view("Reminders").lines[0].due, "Mon, Nov 9", "two missed weeks skipped");
});

test("a monthly reminder on the 31st goes off on a shorter month's last day", () => {
  const { corey, at } = reminderGateways();
  const id = corey.add({ topic: "Reminders", text: "Pay the vet plan", due: "2026-10-31", owner: "corey", remind: { at: "08:00", every: "month" }, forWho: "franco" }).lines[0].id;
  at("2026-10-31T13:00:00Z");
  corey.fired(id);
  assert.equal(corey.view("Reminders").lines[0].due, "Mon, Nov 30");
});

test("a reminder after the clocks change goes off at its wall-clock time", () => {
  // Chicago leaves daylight time on 1 November, so 4:40 pm is 22:40 UTC from then on.
  const { corey, at } = reminderGateways();
  corey.add({ topic: "Reminders", text: "Pack the bags", due: "2026-11-07", owner: "corey", remind: { at: "16:40", every: "week" }, forWho: "gia" });
  at("2026-11-07T21:40:00Z");
  assert.deepEqual(corey.dueReminders(), []);
  at("2026-11-07T22:40:00Z");
  assert.equal(corey.dueReminders().length, 1);
});

for (const [why, remind, due] of [
  ["a time that is no time", { at: "25:00" }, "2026-10-24"],
  ["a repeat it does not know", { at: "16:40", every: "fortnight" }, "2026-10-24"],
  ["no day to go off", { at: "16:40" }, undefined],
]) {
  test(`a reminder with ${why} is refused`, () => {
    const { corey } = gateways();
    assert.throws(() => corey.add({ topic: "Reminders", text: "Bins out", due, owner: "corey", remind, forWho: "franco" }), (error) => error.code === "invalid_line");
  });
}

test("the other gateway's malformed reminder is refused, and a reminder goes off only for its own assistant", () => {
  const { corey, denise, relay } = gateways();
  const id = denise.add({ topic: "Reminders", text: "Bins out", due: "2026-10-18", owner: "denise", remind: { at: "07:00" }, forWho: "gia" }).lines[0].id;
  const [step] = denise.outbox().notes;
  assert.deepEqual(corey.acceptPeer({ notes: [{ ...step, line: { ...step.line, remind: { at: "7am" } } }] }), { accepted: 0, refused: 1 });
  relay(denise, corey);
  assert.deepEqual(corey.dueReminders(), []);
  assert.throws(() => corey.fired(id), (error) => error.code === "not_a_reminder");
});

// MARK: - Family automations, mirrored read-only

const WEEKLY = { job: "job-weekly-0001", name: "Saturday supplies reminder", schedule: "on the schedule 40 16 * * 6 (America/Chicago)" };
const SUNDAY = { job: "job-weekly-0002", name: "Sunday plan for the week", schedule: "on the schedule 0 18 * * 0 (America/Chicago)" };

test("Corey's family automations reach Denise's turns as lines with their name and schedule, and a restart takes no step", () => {
  // Arrange
  const { corey, denise, relay } = gateways();

  // Act
  const first = corey.mirror([WEEKLY, SUNDAY], { forWho: "franco" });
  const again = corey.mirror([WEEKLY, SUNDAY], { forWho: "franco" });
  relay(corey, denise);

  // Assert
  assert.deepEqual(first, { added: 2, corrected: 0, removed: 0 });
  assert.deepEqual(again, { added: 0, corrected: 0, removed: 0 });
  assert.equal(corey.outbox().notes.length, 2, "an unchanged automation takes no step");
  assert.match(denise.prompt(""), /\nFamily automations, which post on their own:\n- hn-[0-9a-f]{8}, "Family automations", "Saturday supplies reminder", runs on the schedule 40 16 \* \* 6 \(America\/Chicago\), an automation of Corey's that posts in the family room\n/);
  assert.deepEqual(denise.view("Family automations").lines.map((line) => line.automation), [
    { runs: WEEKLY.schedule, of: "Corey" },
    { runs: SUNDAY.schedule, of: "Corey" },
  ]);
  assert.doesNotMatch(denise.prompt(""), /Promises still open|Due now/, "an automation is neither a promise nor due");
});

test("a renamed or rescheduled automation is corrected, and a deleted one is removed, on both gateways", () => {
  // Arrange
  const { corey, denise, relay } = gateways();
  corey.mirror([WEEKLY, SUNDAY], { forWho: "franco" });
  relay(corey, denise);

  // Act
  const counts = corey.mirror([{ ...WEEKLY, schedule: "on the schedule 30 16 * * 6 (America/Chicago)" }], { forWho: "franco" });
  relay(corey, denise);

  // Assert
  assert.deepEqual(counts, { added: 0, corrected: 1, removed: 1 });
  assert.deepEqual(denise.view("Family automations").lines.map((line) => [line.text, line.automation.runs]), [
    ["Saturday supplies reminder", "on the schedule 30 16 * * 6 (America/Chicago)"],
  ]);
});

test("neither assistant's tool changes a mirrored automation, and each says why", () => {
  // Arrange
  const { corey, denise, relay } = gateways();
  corey.mirror([WEEKLY], { forWho: "franco" });
  relay(corey, denise);
  const id = denise.view("Family automations").lines[0].id;

  // Act and Assert
  for (const notes of [corey, denise]) {
    for (const change of [
      () => notes.correct(id, { text: "Something else", forWho: "gia" }),
      () => notes.done(id, { forWho: "gia" }),
      () => notes.remove(id),
    ]) {
      assert.throws(change, (error) => error.code === "automation_line" && /an automation of Corey's/.test(error.message));
    }
  }
});

test("Denise's gateway mirrors none of Corey's automations away, and refuses a malformed one", () => {
  // Arrange
  const { corey, denise, relay } = gateways();
  corey.mirror([WEEKLY], { forWho: "franco" });
  relay(corey, denise);
  const [step] = corey.outbox().notes;

  // Act
  const counts = denise.mirror([], { forWho: "gia" });
  const refused = denise.acceptPeer({ notes: [{ ...step, id: "ns-00000000-0000-4000-8000-0000000000ff", line: { ...step.line, id: "hn-0f0f0f0f", automation: { ...step.line.automation, prompt: "anything" } } }] });

  // Assert
  assert.deepEqual(counts, { added: 0, corrected: 0, removed: 0 });
  assert.equal(denise.view("Family automations").lines.length, 1);
  assert.deepEqual(refused, { accepted: 0, refused: 1 });
});

// MARK: - The tool, and the turns it answers in

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
const OWNERS_FAMILY = { ...FAMILY, requesterSenderId: "franco", sessionKey: "agent:main:household:group:family:sender:franco" };

function tool(context) {
  const { corey } = gateways();
  return { notes: corey, found: createNoteTool({ context, owner: "franco", people: ["franco", "gia"], notes: corey, peerAssistantName: "Denise" }) };
}

async function run(found, args) {
  const result = await found.execute("call-1", args);
  return { ...JSON.parse(result.content[0].text), isError: result.isError === true };
}

test("the tool is offered in the owner's own thread and in the family room, for anyone there", () => {
  for (const context of [DIRECT, FAMILY, OWNERS_FAMILY]) {
    const { found } = tool(context);
    assert.equal(found.name, NOTE_TOOL);
    assert.equal(found.parameters.additionalProperties, false);
    assert.match(found.description, /Franco, Gia, Corey and Denise all read/);
    assert.match(found.description, /asked to tell Denise goes here/);
    assert.match(found.description, /never keep family data in a file or tracker of your own/);
  }
});

for (const [why, context] of [
  ["Telegram", { ...DIRECT, messageChannel: "telegram", deliveryContext: { ...DIRECT.deliveryContext, channel: "telegram" } }],
  ["an automation with no sender", { ...DIRECT, requesterSenderId: undefined }],
  ["a gateway client speaking as itself", { ...DIRECT, requesterSenderId: "openclaw-ios", deliveryContext: { ...DIRECT.deliveryContext, to: "household:openclaw-ios" } }],
  ["the other person in the owner's thread", { ...DIRECT, requesterSenderId: "gia" }],
  ["a stranger in the family room", { ...FAMILY, requesterSenderId: "mallory" }],
  ["a turn the other assistant's @mention started, which reads the note but writes none", { ...FAMILY, requesterSenderId: "denise" }],
  ["another agent", { ...DIRECT, agentId: "helper" }],
]) {
  test(`the tool is not offered to ${why}`, () => {
    assert.equal(tool(context).found, null);
  });
}

test("adding in the family room puts the line down for whoever asked, and answers with its topic", async () => {
  const { found } = tool(FAMILY);
  const answer = await run(found, { action: "add", topic: "Kitten weights", text: "Pepper 395 g" });
  assert.equal(answer.isError, false);
  assert.equal(answer.topic, "Kitten weights");
  assert.deepEqual(answer.lines.map(({ text, for: forName, by }) => ({ text, for: forName, by })), [{ text: "Pepper 395 g", for: "Gia", by: "Corey" }]);
});

test("view, correct and remove answer with what the note says after", async () => {
  const { found } = tool(DIRECT);
  const id = (await run(found, { action: "add", topic: "Dates", text: "Dentist Monday" })).lines[0].id;
  assert.deepEqual(textsOf(await run(found, { action: "correct", line: id, text: "Dentist Tuesday 9 am" })), ["Dentist Tuesday 9 am"]);
  assert.deepEqual((await run(found, { action: "view" })).topics.map(textsOf), [["Dentist Tuesday 9 am"]]);
  assert.deepEqual(textsOf(await run(found, { action: "view", topic: "dates" })), ["Dentist Tuesday 9 am"]);
  assert.deepEqual(textsOf(await run(found, { action: "remove", line: id })), []);
});

test("the tool adds a weigh-in as rows, lists what is due, and marks a line done", async () => {
  const { found } = tool(FAMILY);
  const added = await run(found, { action: "add", topic: "Kitten weights", rows: [{ item: "Mochi", text: "212 g" }, { item: "Pepper", text: "198 g" }] });
  assert.deepEqual(added.lines.map(({ item, text, for: forName }) => ({ item, text, for: forName })), [
    { item: "Mochi", text: "212 g", for: "Gia" },
    { item: "Pepper", text: "198 g", for: "Gia" },
  ]);
  const shots = (await run(found, { action: "add", topic: "Kitten milestones", text: "First shots", due: "2026-10-22" })).lines[0].id;
  assert.deepEqual((await run(found, { action: "due" })).soon.map((line) => line.text), ["First shots"]);
  assert.equal((await run(found, { action: "done", line: shots })).lines[0].doneBy, "Corey");
  assert.deepEqual((await run(found, { action: "due" })).soon, []);
});

for (const [why, args, code] of [
  ["an unknown action", { action: "erase" }, "invalid_arguments"],
  ["one line's fields beside rows", { action: "add", topic: "Kitten weights", text: "212 g", rows: [{ text: "198 g" }] }, "invalid_arguments"],
  ["a due date that is no date", { action: "add", topic: "Kitten milestones", text: "First shots", due: "next week" }, "invalid_line"],
  ["another action's field", { action: "remove", line: "hn-00000000", text: "Friday" }, "invalid_arguments"],
  ["a person named as who asked", { action: "add", topic: "Dates", text: "Friday", for: "gia" }, "invalid_arguments"],
  ["a correction that changes nothing", { action: "correct", line: "hn-00000000" }, "invalid_arguments"],
  ["a line that is not there", { action: "remove", line: "hn-00000000" }, "unknown_line"],
  ["no words", { action: "add", topic: "Dates", text: " " }, "invalid_line"],
]) {
  test(`the tool refuses ${why} and says why`, async () => {
    const { found } = tool(DIRECT);
    const answer = await run(found, args);
    assert.equal(answer.isError, true);
    assert.equal(answer.code, code);
  });
}

test("an add whose every row was unclear logs nothing and says what to ask", async () => {
  // Arrange
  const { notes, found } = tool(DIRECT);

  // Act
  const answer = await run(found, { action: "add", topic: "Kitten weights", rows: [{ item: "Mochi", text: "2 g", unsure: "two-something grams" }] });

  // Assert
  assert.equal(answer.isError, false);
  assert.equal(answer.logged, "nothing yet");
  assert.deepEqual(answer.ask, [{ item: "Mochi", heard: "two-something grams" }]);
  assert.deepEqual(notes.view(), { topics: [] });
});
