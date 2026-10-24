// The household-scripture plugin: the `scripture` tool against a small Bible built with the
// builder's own schema, a fake OpenRouter for meaning vectors, and a scratch state folder.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import entry, { createScripture, parseConfig } from "../../deploy/openclaw/plugins/household-scripture/index.js";
import { parseReference, verseId } from "../../deploy/openclaw/plugins/household-scripture/books.js";

const BUILDER = new URL("../../scripts/scripture-build.py", import.meta.url);
const SCHEMA = /SCHEMA = """([\s\S]*?)"""/.exec(readFileSync(BUILDER, "utf8"))[1];
const DIMS = 4;

// A Bible of a few verses: John 3:16, Romans 5:8, Luke 24:13-35 (with 20 missing unless
// `whole`), Psalm 23:1, and one KJV and one WEB rendering of John 3:16.
function bible({ vectors = true, whole = true, translations = ["BSB", "KJV", "WEB"] } = {}) {
  const directory = mkdtempSync(path.join(tmpdir(), "household-scripture-"));
  const file = path.join(directory, "bible.sqlite");
  const db = new DatabaseSync(file);
  db.exec(SCHEMA);
  const verses = new Map([
    [verseId(43, 3, 16), "For God so loved the world that He gave His one and only Son."],
    [verseId(45, 5, 8), "But God proves His love for us in this: While we were still sinners, Christ died for us."],
    [verseId(19, 23, 1), "The LORD is my shepherd; I shall not want."],
    [verseId(40, 18, 22), "Jesus answered, I tell you, not seven times, but seventy-seven times!"],
  ]);
  for (let verse = 13; verse <= 35; verse += 1) {
    if (verse === 20 && !whole) continue;
    verses.set(verseId(42, 24, verse), `Emmaus fixture ${verse}: ‘Stay with us.’`);
  }
  const insert = db.prepare("INSERT INTO verses (id, translation, text) VALUES (?, ?, ?)");
  for (const [id, text] of verses) {
    insert.run(id, "BSB", text);
    db.prepare("INSERT INTO verses_fts (rowid, text) VALUES (?, ?)").run(id, text);
  }
  insert.run(verseId(43, 3, 16), "KJV", "For God so loved the world, that he gave his only begotten Son.");
  insert.run(verseId(43, 3, 16), "WEB", "For God so loved the world, that he gave his one and only Son.");
  db.prepare("INSERT INTO xrefs VALUES (?, ?, ?, ?)").run(verseId(43, 3, 16), verseId(45, 5, 8), verseId(45, 5, 8), 120);
  db.prepare("INSERT INTO xrefs VALUES (?, ?, ?, ?)").run(verseId(43, 3, 16), verseId(20, 8, 22), verseId(20, 8, 30), 40);
  db.prepare("INSERT INTO xrefs VALUES (?, ?, ?, ?)").run(verseId(43, 3, 16), verseId(1, 1, 1), verseId(1, 1, 1), -3);
  const word = db.prepare("INSERT INTO words VALUES (?, ?, ?, ?, ?, ?)");
  word.run(verseId(43, 3, 16), 1, "G0025", "ἀγαπάω", "ēgapēsen", "to love");
  word.run(verseId(43, 3, 16), 2, "G2889", "κόσμος", "kosmon", "world");
  word.run(verseId(43, 3, 16), 3, "G0025", "ἀγαπάω", "agapē", "to love");
  const meta = db.prepare("INSERT INTO meta (key, value) VALUES (?, ?)");
  meta.run("schema_version", "1");
  meta.run("translations", JSON.stringify(translations));
  db.prepare("INSERT INTO sources VALUES (?, ?, ?, ?)").run("Berean Standard Bible", "fixture", "Public domain", "BSB");
  if (vectors) {
    meta.run("embedding_model", "openai/text-embedding-3-small");
    meta.run("embedding_dims", String(DIMS));
    const vector = db.prepare("INSERT INTO vectors (id, vector) VALUES (?, ?)");
    const axis = (index) => Buffer.from(new Float32Array([0, 1, 2, 3].map((i) => (i === index ? 1 : 0))).buffer);
    vector.run(verseId(43, 3, 16), axis(0));
    vector.run(verseId(45, 5, 8), axis(1));
    vector.run(verseId(19, 23, 1), axis(2));
    vector.run(verseId(40, 18, 22), axis(3));
  }
  db.close();
  return file;
}

function scripture({ file = bible(), edition = null, fetchFn, env = { OPENROUTER_API_KEY: "sk-test" }, stateDir } = {}) {
  const state = stateDir ?? mkdtempSync(path.join(tmpdir(), "household-scripture-state-"));
  const logs = [];
  const api = {
    runtime: { state: { resolveStateDir: () => state } },
    logger: { info: (line) => logs.push(line), warn: (line) => logs.push(line), error: (line) => logs.push(line) },
  };
  const plugin = createScripture(api, { bibleFile: file, edition }, { env, fetchFn: fetchFn ?? (async () => { throw new Error("no network in tests"); }) });
  const tool = plugin.tool();
  const run = async (params) => {
    const result = await tool.execute("call", params);
    return { text: result.content.map((part) => part.text).join(""), isError: result.isError === true };
  };
  return { run, tool, state, logs, plugin };
}

// OpenRouter answering every question with one vector.
const openRouter = (vector, seen = []) => async (url, init) => {
  seen.push({ url, body: JSON.parse(init.body), authorization: init.headers.authorization });
  return { ok: true, status: 200, json: async () => ({ data: [{ embedding: vector }] }) };
};

function readCard(text) {
  const lines = text.split("\n");
  assert.equal(lines.length, 3);
  assert.equal(lines[0], "```steward-card");
  assert.equal(lines[2], "```");
  return JSON.parse(lines[1]);
}

test("a reference reads the verse as the database holds it", async () => {
  const { run } = scripture();
  const answer = await run({ action: "ref", reference: "John 3:16" });
  assert.equal(answer.isError, false);
  assert.equal(answer.text, "John 3:16 (BSB)\n  For God so loved the world that He gave His one and only Son.");
});

test("the daily Emmaus reading is one whole card with its Bible link", async () => {
  const { run } = scripture();
  const card = readCard((await run({ action: "ref", reference: "Luke 24:13-35", card: true })).text);
  assert.deepEqual(card, {
    type: "scripture",
    reference: "Luke 24:13-35",
    translation: "BSB",
    verses: Array.from({ length: 23 }, (_, index) => ({ n: index + 13, text: `Emmaus fixture ${index + 13}: ‘Stay with us.’` })),
    skill: "scripture",
    link: "https://www.bible.com/bible/3034/LUK.24.13-35.BSB",
  });
});

test("a card's link keeps the text's own translation when the household names no edition", async () => {
  const { run } = scripture();
  const card = readCard((await run({ action: "ref", reference: "John 3:16", card: true, translation: "KJV" })).text);
  assert.equal(card.translation, "KJV");
  assert.equal(card.link, "https://www.bible.com/bible/1/JHN.3.16.KJV");
});

test("a card's link opens the household's edition whatever the text is", async () => {
  for (const translation of ["BSB", "KJV", "WEB"]) {
    const { run } = scripture({ edition: "NIV" });
    const card = readCard((await run({ action: "ref", reference: "John 3:16", card: true, translation })).text);
    assert.equal(card.link, "https://www.bible.com/bible/111/JHN.3.16.NIV");
    assert.equal(card.translation, translation);
  }
});

test("a card does not invent a link for a translation no edition matches", async () => {
  const { run } = scripture();
  const card = readCard((await run({ action: "ref", reference: "John 3:16", card: true, translation: "WEB" })).text);
  assert.equal(card.translation, "WEB");
  assert.equal("link" in card, false);
});

test("a card refuses a partial passage and prints no block", async () => {
  const { run } = scripture({ file: bible({ whole: false }) });
  const answer = await run({ action: "ref", reference: "Luke 24:13-35", card: true });
  assert.equal(answer.isError, true);
  assert.doesNotMatch(answer.text, /steward-card/);
  assert.match(answer.text, /incomplete/);
});

test("a plain read names the verses this Bible does not hold", async () => {
  const { run } = scripture({ file: bible({ whole: false }) });
  const answer = await run({ action: "ref", reference: "Luke 24:19-21" });
  assert.equal(answer.isError, false);
  assert.match(answer.text, /Luke 24:19 \(BSB\)/);
  assert.match(answer.text, /Not in this Bible: verse\(s\) 20 of Luke 24\./);
});

test("references that cannot be looked up are refused, never guessed", async () => {
  const { run } = scripture();
  const cases = [
    [{ action: "ref", reference: "Hezekiah 1:1" }, /not one of the 66 books/],
    [{ action: "ref", reference: "John three sixteen" }, /not a reference this can look up/],
    [{ action: "ref", reference: "John 3:1000" }, /out of range/],
    [{ action: "ref", reference: "Luke 24:1-50" }, /more than 40 verses/],
    [{ action: "ref", reference: "John 3:17" }, /holds nothing at John 3:17/],
    [{ action: "ref", reference: "John 3:16", translation: "NIV" }, /holds BSB, KJV, WEB, not NIV/],
  ];
  for (const [params, message] of cases) {
    const answer = await run(params);
    assert.equal(answer.isError, true, JSON.stringify(params));
    assert.match(answer.text, message);
  }
});

test("a household edition no link can open is refused", async () => {
  assert.match(parseConfig({ edition: "MSG" }).error, /edition must be one of BSB, KJV, ASV, NIV/);
  assert.match(parseConfig({ bibleFile: "bible.sqlite" }).error, /absolute path/);
  assert.match(parseConfig({ siqsermon: true }).error, /unknown config keys: siqsermon/);
  assert.deepEqual(parseConfig(undefined).value, { bibleFile: "/opt/household-scripture/bible.sqlite", edition: null });
});

test("written references resolve the way SIQsermon's did", () => {
  const cases = [
    ["1 Sam 2:3-5", { book: 9, chapter: 2, first: 3, last: 5 }],
    ["I Samuel 2:3", { book: 9, chapter: 2, first: 3, last: 3 }],
    ["Psalm 23:1", { book: 19, chapter: 23, first: 1, last: 1 }],
    ["Song of Songs 1.2", { book: 22, chapter: 1, first: 2, last: 2 }],
    ["Rev 22:21", { book: 66, chapter: 22, first: 21, last: 21 }],
    ["Jhn 3:16", { book: 43, chapter: 3, first: 16, last: 16 }],
  ];
  for (const [written, expected] of cases) {
    const { book, chapter, first, last } = parseReference(written);
    assert.deepEqual({ book, chapter, first, last }, expected, written);
  }
});

test("a search by meaning lists the closest verses with their cross references and words", async () => {
  const seen = [];
  const { run } = scripture({ fetchFn: openRouter([0.9, 0.1, 0, 0], seen) });
  const answer = await run({ action: "search", query: "how much God loves people", limit: 2 });
  assert.equal(answer.isError, false);
  const blocks = answer.text.split("\n\n");
  assert.equal(blocks.length, 2);
  assert.match(blocks[0], /^John 3:16 \(BSB\) score 0\.99/);
  assert.match(blocks[0], /cross-refs: Romans 5:8; Proverbs 8:22-30\n/);
  assert.doesNotMatch(blocks[0], /Genesis 1:1/, "a cross reference voted down is left out");
  assert.match(blocks[0], /word study: ēgapēsen \(G0025\) "to love"; kosmon \(G2889\) "world"$/);
  assert.match(blocks[1], /^Romans 5:8 \(BSB\) score 0\.11/);
  assert.deepEqual(seen[0].body, { model: "openai/text-embedding-3-small", input: "how much God loves people" });
  assert.equal(seen[0].authorization, "Bearer sk-test");
});

test("a search where nothing is close says so", async () => {
  const { run } = scripture({ fetchFn: openRouter([-1, -1, -1, -1]) });
  const answer = await run({ action: "search", query: "parking garages" });
  assert.match(answer.text, /Every score is low: nothing here is close/);
});

test("a search falls back to words when meaning cannot be read, and says so", async () => {
  const { run, logs } = scripture();
  const answer = await run({ action: "search", query: "forgiving seven times" });
  assert.equal(answer.isError, false);
  assert.match(answer.text, /^Searched by words, not meaning: the meaning of the question could not be read just now\./);
  assert.match(answer.text, /Matthew 18:22 \(BSB\)\n/);
  assert.ok(logs.some((line) => line.includes("fell back to words")));
});

test("a Bible without meaning vectors searches by words and says why", async () => {
  const { run } = scripture({ file: bible({ vectors: false }), fetchFn: openRouter([1, 0, 0, 0]) });
  const answer = await run({ action: "search", query: "the LORD my shepherd" });
  assert.match(answer.text, /^Searched by words, not meaning: this Bible's meaning vectors are not built yet\./);
  assert.match(answer.text, /Psalms 23:1 \(BSB\)/);
});

test("a study lists one verse's cross references and words", async () => {
  const { run } = scripture();
  const answer = await run({ action: "study", reference: "John 3:16" });
  assert.equal(answer.text.split("\n")[0], "John 3:16 (BSB)");
  assert.match(answer.text, /word study: ēgapēsen \(G0025\)/);
  assert.equal((await run({ action: "study", reference: "John 3:16-17" })).isError, true);
});

test("the household keeps the sermons and plans it asks to keep", async () => {
  const { run } = scripture();
  assert.equal((await run({ action: "sermons" })).text, "The household has no kept sermons yet.");
  const kept = await run({ action: "save", kind: "sermon", title: "Seventy times seven", detail: "Matthew 18:21-35", text: "Forgiveness without counting." });
  assert.match(kept.text, /^Kept as sermon 1\./);
  assert.match((await run({ action: "sermons" })).text, /^ {3}1 {2}\d{4}-\d{2}-\d{2} {2}Seventy times seven {2}\(Matthew 18:21-35\)$/);
  const read = await run({ action: "sermons", id: 1 });
  assert.match(read.text, /Seventy times seven\n\(Matthew 18:21-35\)\n\nForgiveness without counting\.$/);
  assert.equal((await run({ action: "plans", id: 1 })).isError, true, "a sermon is not a plan");
  assert.equal((await run({ action: "save", kind: "song", title: "x", text: "y" })).isError, true);
});

test("sermons exported from SIQsermon are kept once, and a file that is not one is set aside", async () => {
  const state = mkdtempSync(path.join(tmpdir(), "household-scripture-state-"));
  const inbox = path.join(state, "household-scripture", "import");
  mkdirSync(inbox, { recursive: true });
  const items = [
    { kind: "sermon", title: "Patience", detail: "James 5", body: "## Outline\n\nWait.", createdAt: "2026-08-03T10:00:00Z", source: "siqsermon", originId: "12" },
    { kind: "plan", title: "Romans in a month", detail: "inductive", body: "Day 1", createdAt: "2026-07-01T10:00:00Z", source: "siqsermon", originId: "5" },
  ];
  writeFileSync(path.join(inbox, "siqsermon-sermons.json"), JSON.stringify(items));
  writeFileSync(path.join(inbox, "broken.json"), "{ not json");
  const { run, logs } = scripture({ stateDir: state });
  assert.match((await run({ action: "sermons" })).text, /^ {3}1 {2}2026-08-03 {2}Patience {2}\(James 5\)$/);
  assert.match((await run({ action: "plans" })).text, /Romans in a month {2}\(inductive\)/);
  assert.deepEqual(readdirSync(path.join(inbox, "done")), ["siqsermon-sermons.json"]);
  assert.deepEqual(readdirSync(path.join(inbox, "refused")), ["broken.json"]);
  assert.ok(logs.some((line) => line.includes("refused 1 import files")));
  // The same export dropped in again keeps nothing twice.
  writeFileSync(path.join(inbox, "again.json"), JSON.stringify(items));
  const listed = (await run({ action: "sermons" })).text.split("\n");
  assert.equal(listed.length, 1);
});

test("a gateway without the Bible says what an administrator has to do", async () => {
  const { run } = scripture({ file: "/nonexistent/bible.sqlite" });
  const answer = await run({ action: "ref", reference: "John 3:16" });
  assert.equal(answer.isError, true);
  assert.match(answer.text, /The Bible is not installed on this gateway \(no \/nonexistent\/bible\.sqlite\)\. An administrator builds it with scripts\/scripture-build\.py\./);
});

test("the plugin registers the scripture tool and refuses a config it does not know", () => {
  const registered = [];
  const errors = [];
  const api = {
    pluginConfig: { edition: "NIV" },
    runtime: { state: { resolveStateDir: () => tmpdir() } },
    logger: { error: (line) => errors.push(line), info() {}, warn() {} },
    registerTool: (factory, options) => registered.push({ factory, options }),
  };
  entry.register(api);
  assert.deepEqual(registered.map((r) => r.options.names), [["scripture"]]);
  const tool = registered[0].factory({});
  assert.equal(tool.name, "scripture");
  assert.ok(tool.description.length < 1500);
  entry.register({ ...api, pluginConfig: { siqsermonPassword: "x" } });
  assert.equal(registered.length, 1);
  assert.match(errors[0], /not started, unknown config keys: siqsermonPassword/);
});
