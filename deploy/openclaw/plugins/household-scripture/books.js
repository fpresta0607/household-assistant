// The 66 books, in canonical order, and how a reference written by a person or a model
// becomes the one book, chapter and verse range it names. Ported from the SIQsermon
// skill's own tables, so "1 Sam 2:3", "I Samuel 2:3", "Psalm 23:1" and "Rev 22:21" all
// still resolve, and anything else is refused rather than guessed.

// [OSIS code, the name a card shows]. The OSIS code is also what OpenBible's cross
// references are written in.
export const BOOKS = [
  ["Gen", "Genesis"], ["Exod", "Exodus"], ["Lev", "Leviticus"], ["Num", "Numbers"],
  ["Deut", "Deuteronomy"], ["Josh", "Joshua"], ["Judg", "Judges"], ["Ruth", "Ruth"],
  ["1Sam", "1 Samuel"], ["2Sam", "2 Samuel"], ["1Kgs", "1 Kings"], ["2Kgs", "2 Kings"],
  ["1Chr", "1 Chronicles"], ["2Chr", "2 Chronicles"], ["Ezra", "Ezra"], ["Neh", "Nehemiah"],
  ["Esth", "Esther"], ["Job", "Job"], ["Ps", "Psalms"], ["Prov", "Proverbs"],
  ["Eccl", "Ecclesiastes"], ["Song", "Song of Solomon"], ["Isa", "Isaiah"], ["Jer", "Jeremiah"],
  ["Lam", "Lamentations"], ["Ezek", "Ezekiel"], ["Dan", "Daniel"], ["Hos", "Hosea"],
  ["Joel", "Joel"], ["Amos", "Amos"], ["Obad", "Obadiah"], ["Jonah", "Jonah"],
  ["Mic", "Micah"], ["Nah", "Nahum"], ["Hab", "Habakkuk"], ["Zeph", "Zephaniah"],
  ["Hag", "Haggai"], ["Zech", "Zechariah"], ["Mal", "Malachi"], ["Matt", "Matthew"],
  ["Mark", "Mark"], ["Luke", "Luke"], ["John", "John"], ["Acts", "Acts"],
  ["Rom", "Romans"], ["1Cor", "1 Corinthians"], ["2Cor", "2 Corinthians"], ["Gal", "Galatians"],
  ["Eph", "Ephesians"], ["Phil", "Philippians"], ["Col", "Colossians"], ["1Thess", "1 Thessalonians"],
  ["2Thess", "2 Thessalonians"], ["1Tim", "1 Timothy"], ["2Tim", "2 Timothy"], ["Titus", "Titus"],
  ["Phlm", "Philemon"], ["Heb", "Hebrews"], ["Jas", "James"], ["1Pet", "1 Peter"],
  ["2Pet", "2 Peter"], ["1John", "1 John"], ["2John", "2 John"], ["3John", "3 John"],
  ["Jude", "Jude"], ["Rev", "Revelation"],
];

// YouVersion's USFM codes, in the same order: what an Open in Bible link names, the codes
// the iOS app's own Bible links use, and, in title case, STEPBible's book codes.
export const USFM = [
  "GEN", "EXO", "LEV", "NUM", "DEU", "JOS", "JDG", "RUT", "1SA", "2SA", "1KI", "2KI",
  "1CH", "2CH", "EZR", "NEH", "EST", "JOB", "PSA", "PRO", "ECC", "SNG", "ISA", "JER",
  "LAM", "EZK", "DAN", "HOS", "JOL", "AMO", "OBA", "JON", "MIC", "NAM", "HAB", "ZEP",
  "HAG", "ZEC", "MAL", "MAT", "MRK", "LUK", "JHN", "ACT", "ROM", "1CO", "2CO", "GAL",
  "EPH", "PHP", "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM", "HEB", "JAS", "1PE",
  "2PE", "1JN", "2JN", "3JN", "JUD", "REV",
];

// YouVersion's ids for the editions an Open in Bible link can open.
export const BIBLE_VERSIONS = { BSB: 3034, KJV: 1, ASV: 12, NIV: 111 };

// The same spellings SIQsermon's table tolerated.
const ALIASES = { psalm: 19, songofsongs: 22, canticles: 22, revelationofjohn: 66 };

// A whole chapter would mean walking verses until one is missing, so a range is bounded:
// a longer reading is fetched as consecutive ranges.
export const MAX_RANGE = 40;

export class ScriptureError extends Error {}

// Folds a book name the way SIQsermon did, so "I Samuel" reaches 1 Samuel.
export function fold(name) {
  const folded = String(name).trim().toLowerCase().replace(/^(i{1,3})\s/, (_, roman) => `${roman.length} `);
  return folded.replace(/[^a-z0-9]/g, "");
}

const LOOKUP = new Map();
BOOKS.forEach(([osis, name], index) => {
  LOOKUP.set(fold(osis), index + 1);
  LOOKUP.set(fold(name), index + 1);
});
USFM.forEach((code, index) => {
  if (!LOOKUP.has(fold(code))) LOOKUP.set(fold(code), index + 1);
});
for (const [alias, number] of Object.entries(ALIASES)) LOOKUP.set(alias, number);

// The book's number, 1 to 66, or undefined for a name that is not one of them.
export function bookNumber(name) {
  return LOOKUP.get(fold(name));
}

export const bookName = (number) => BOOKS[number - 1][1];

// The verse's id: book * 1,000,000 + chapter * 1,000 + verse, SIQsermon's own scheme, so
// an id reads as its reference and sorts in canonical order.
export const verseId = (book, chapter, verse) => book * 1_000_000 + chapter * 1_000 + verse;

export function referenceOf(id) {
  const book = Math.floor(id / 1_000_000);
  const chapter = Math.floor((id % 1_000_000) / 1_000);
  return { book, chapter, verse: id % 1_000, label: `${bookName(book)} ${chapter}:${id % 1_000}` };
}

// "John 3:16" or "1 Sam 2:3-5": the book's number, chapter, first and last verse, and the
// book as written. Throws rather than guessing: a reference that cannot be looked up is
// reported, never quietly turned into a different verse.
export function parseReference(text) {
  const match = /^\s*(.+?)\s+(\d+)\s*[:.]\s*(\d+)(?:\s*-\s*(\d+))?\s*$/.exec(String(text ?? ""));
  if (!match) {
    throw new ScriptureError(
      `'${text}' is not a reference this can look up. Use 'Book chapter:verse', for example 'John 3:16' or 'Psalms 23:1-6'.`,
    );
  }
  const [, written, chapterText, firstText, lastText] = match;
  const book = bookNumber(written);
  if (book === undefined) throw new ScriptureError(`'${written}' is not one of the 66 books.`);
  const chapter = Number(chapterText);
  const first = Number(firstText);
  const last = Number(lastText ?? firstText);
  if (![chapter, first, last].every((part) => part >= 1 && part <= 999)) {
    throw new ScriptureError(`'${String(text).trim()}' is out of range: chapters and verses run from 1 to 999.`);
  }
  return { written, book, chapter, first, last };
}
