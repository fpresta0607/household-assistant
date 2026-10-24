// The Bible database scripts/scripture-build.py writes, read here and nowhere else: every
// verse of the public-domain translations it holds, a word index over the first of them,
// OpenBible's cross references, STEPBible's original-language words for each verse, and,
// once built, one meaning vector per verse.
//
// The file is opened read-only and never written by the gateway. A verse the database does
// not hold is reported as missing, never filled in from anywhere else.

import { existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

import { BIBLE_VERSIONS, MAX_RANGE, ScriptureError, USFM, bookName, referenceOf, verseId } from "./books.js";

export const SCHEMA_VERSION = 1;
// How many cross references and words a verse lists at most.
const MAX_XREFS = 8;
const MAX_WORDS = 14;
// Words too common to search for: a question's other words carry its meaning.
const STOP_WORDS = new Set(
  ("a about after again all also am an and any are as at be because been before being but by can could did do does " +
    "for from had has have he her him his how i if in into is it its just me more most my no not now of on one or our " +
    "out say says said she should so some than that the their them then there these they this those to up us was we " +
    "were what when where which while who whom why will with would you your bible verse verses scripture passage").split(" "),
);

export class Bible {
  constructor(file) {
    if (!existsSync(file)) {
      throw new ScriptureError(
        `The Bible is not installed on this gateway (no ${file}). An administrator builds it with scripts/scripture-build.py.`,
      );
    }
    this.db = new DatabaseSync(file, { readOnly: true });
    const meta = Object.fromEntries(this.db.prepare("SELECT key, value FROM meta").all().map((row) => [row.key, row.value]));
    if (Number(meta.schema_version) !== SCHEMA_VERSION) {
      throw new ScriptureError(`The Bible at ${file} is schema ${meta.schema_version}, and this plugin reads schema ${SCHEMA_VERSION}. Rebuild it.`);
    }
    this.translations = JSON.parse(meta.translations);
    this.primary = this.translations[0];
    this.embeddingModel = meta.embedding_model || null;
    this.embeddingDims = Number(meta.embedding_dims) || 0;
    this.sources = this.db.prepare("SELECT name, license, attribution FROM sources ORDER BY name").all();
    this.verseStatement = this.db.prepare("SELECT text FROM verses WHERE translation = ? AND id = ?");
    this.xrefStatement = this.db.prepare(
      "SELECT to_first, to_last, votes FROM xrefs WHERE from_id = ? AND votes > 0 ORDER BY votes DESC, to_first LIMIT ?",
    );
    this.wordStatement = this.db.prepare(
      "SELECT strongs, lemma, translit, gloss FROM words WHERE verse_id = ? ORDER BY position",
    );
    this.vectors = null;
  }

  close() {
    this.db.close();
  }

  get hasMeaning() {
    return this.embeddingDims > 0 && this.embeddingModel !== null;
  }

  // The translation a passage is read in: the one asked for when the database holds it,
  // otherwise the first it holds.
  translationFor(asked) {
    if (asked === undefined || asked === null || asked === "") return this.primary;
    const wanted = String(asked).trim().toUpperCase();
    if (!this.translations.includes(wanted)) {
      throw new ScriptureError(`This Bible holds ${this.translations.join(", ")}, not ${wanted}.`);
    }
    return wanted;
  }

  text(id, translation = this.primary) {
    return this.verseStatement.get(translation, id)?.text ?? null;
  }

  // A verse or a short range by its reference: the verses found and the numbers missing.
  passage({ book, chapter, first, last }, translation = this.primary) {
    if (last < first) throw new ScriptureError(`${bookName(book)} ${chapter}:${first}-${last} runs backwards.`);
    if (last - first + 1 > MAX_RANGE) {
      throw new ScriptureError(
        `${bookName(book)} ${chapter}:${first}-${last} is more than ${MAX_RANGE} verses. Ask for consecutive ranges of at most ${MAX_RANGE}.`,
      );
    }
    const found = [];
    const missing = [];
    for (let verse = first; verse <= last; verse += 1) {
      const text = this.text(verseId(book, chapter, verse), translation);
      if (text === null) missing.push(verse);
      else found.push({ n: verse, text });
    }
    return { found, missing, translation };
  }

  crossReferences(id, limit = MAX_XREFS) {
    return this.xrefStatement.all(id, limit).map((row) => ({ label: rangeLabel(row.to_first, row.to_last), votes: row.votes }));
  }

  // The verse's original-language words, each Strong's number once.
  words(id, limit = MAX_WORDS) {
    const seen = new Set();
    const words = [];
    for (const row of this.wordStatement.all(id)) {
      if (seen.has(row.strongs)) continue;
      seen.add(row.strongs);
      words.push(row);
      if (words.length === limit) break;
    }
    return words;
  }

  // Verses by their words, best first, for a database without meaning vectors or a moment
  // the vectors cannot be asked.
  byWords(query, limit) {
    const terms = [...new Set(String(query).toLowerCase().match(/[a-z][a-z']+/g) ?? [])]
      .map((term) => term.replace(/'/g, ""))
      .filter((term) => term.length > 1 && !STOP_WORDS.has(term));
    if (terms.length === 0) return [];
    const match = terms.map((term) => `"${term}"`).join(" OR ");
    const rows = this.db
      .prepare("SELECT rowid AS id, bm25(verses_fts) AS rank FROM verses_fts WHERE verses_fts MATCH ? ORDER BY rank LIMIT ?")
      .all(match, limit);
    return rows.map((row) => ({ id: Number(row.id), score: null }));
  }

  // Verses by meaning, best first: the question's vector against every verse's.
  byMeaning(vector, limit) {
    const { ids, values, dims } = this.loadVectors();
    if (vector.length < dims) throw new ScriptureError(`The question's vector has ${vector.length} numbers, and the verses' have ${dims}.`);
    const query = normalized(vector.slice(0, dims));
    const best = [];
    for (let row = 0; row < ids.length; row += 1) {
      let score = 0;
      const base = row * dims;
      for (let i = 0; i < dims; i += 1) score += values[base + i] * query[i];
      if (best.length < limit || score > best[best.length - 1].score) {
        best.push({ id: ids[row], score });
        best.sort((a, b) => b.score - a.score);
        if (best.length > limit) best.pop();
      }
    }
    return best;
  }

  loadVectors() {
    if (this.vectors) return this.vectors;
    if (!this.hasMeaning) throw new ScriptureError("This Bible has no meaning vectors yet.");
    const rows = this.db.prepare("SELECT id, vector FROM vectors ORDER BY id").all();
    const dims = this.embeddingDims;
    const ids = new Int32Array(rows.length);
    const values = new Float32Array(rows.length * dims);
    rows.forEach((row, index) => {
      ids[index] = Number(row.id);
      const bytes = row.vector;
      values.set(new Float32Array(bytes.buffer, bytes.byteOffset, dims), index * dims);
    });
    this.vectors = { ids, values, dims };
    return this.vectors;
  }
}

export function normalized(vector) {
  let length = 0;
  for (const value of vector) length += value * value;
  length = Math.sqrt(length) || 1;
  return Float32Array.from(vector, (value) => value / length);
}

// "Romans 5:8", "Proverbs 8:22-30", or "Proverbs 8:22-9:2".
export function rangeLabel(firstId, lastId) {
  const first = referenceOf(firstId);
  if (lastId === firstId) return first.label;
  const last = referenceOf(lastId);
  if (last.book === first.book && last.chapter === first.chapter) return `${first.label}-${last.verse}`;
  if (last.book === first.book) return `${first.label}-${last.chapter}:${last.verse}`;
  return `${first.label}-${last.label}`;
}

// The card the Steward app draws for a passage, with an Open in Bible link to the edition
// the household reads, or to the text's own when none is set. Refuses an incomplete
// passage: a card must show exactly the verses it names.
export function passageCard({ book, chapter, first, last }, { found, missing, translation }, edition) {
  if (missing.length > 0 || found.length !== last - first + 1) {
    throw new ScriptureError("Cannot make a scripture card: the passage is incomplete.");
  }
  if (edition && !(edition in BIBLE_VERSIONS)) {
    throw new ScriptureError(`Cannot make a scripture card: a link can open only ${Object.keys(BIBLE_VERSIONS).join(", ")}, not ${edition}.`);
  }
  const range = first === last ? String(first) : `${first}-${last}`;
  const card = { type: "scripture", reference: `${bookName(book)} ${chapter}:${range}`, translation, verses: found, skill: "scripture" };
  const opens = edition || translation;
  const version = BIBLE_VERSIONS[opens];
  if (version !== undefined) card.link = `https://www.bible.com/bible/${version}/${USFM[book - 1]}.${chapter}.${range}.${opens}`;
  return card;
}
