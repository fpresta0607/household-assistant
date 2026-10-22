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
    assert.match(found.description, /to tell Denise something/);
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

for (const [why, args, code] of [
  ["an unknown action", { action: "erase" }, "invalid_arguments"],
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
