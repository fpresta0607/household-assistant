#!/usr/bin/env python3
"""Builds the Bible database the household-scripture plugin reads, from public sources.

    python3 scripts/scripture-build.py                       # verses, cross references, words
    python3 scripts/scripture-build.py --embed               # and one meaning vector per verse
    python3 scripts/scripture-build.py --embed-only          # add vectors to a built database

It replaces what SIQsermon held for the assistants, with nothing to run: one SQLite file,
written atomically and mounted read-only into the gateway (/opt/household-scripture).

- The verses are the Berean Standard Bible, which is in the public domain, from
  bereanbible.com. Another public-domain translation in the same "Book 1:1<TAB>text" form
  can be added with --extra NAME=URL; the first translation is the one searched and shown.
- Cross references are OpenBible.info's, under CC BY.
- Each verse's Hebrew or Greek words, with Strong's numbers, transliterations and glosses,
  are STEPBible's TAHOT and TAGNT (Tyndale House, Cambridge), under CC BY 4.0, read at a
  pinned commit so a rebuild gives the same words.
- --embed adds a meaning vector per verse from OpenRouter, with the same embedding model the
  gateways' memory search uses, cut to 512 numbers. The key comes from OPENROUTER_API_KEY or
  the env file named by --env-file, and is never printed. Embedding every verse costs a few
  cents once.

Only the standard library, so it runs on any host with Python 3.
"""

from __future__ import annotations

import argparse
import io
import json
import math
import os
import re
import sqlite3
import struct
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
DEFAULT_OUT = Path("/var/lib/household-assistant/scripture/bible.sqlite")
BSB_URL = "https://bereanbible.com/bsb.txt"
XREFS_URL = "https://a.openbible.info/data/cross-references.zip"
STEP_COMMIT = "be4191f0082aeedddb0eff0c02c966292b2bd641"
STEP_BASE = (
    "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/"
    f"{STEP_COMMIT}/Translators%20Amalgamated%20OT%2BNT/"
)
STEP_FILES = (
    "TAHOT Gen-Deu - Translators Amalgamated Hebrew OT - STEPBible.org CC BY.txt",
    "TAHOT Jos-Est - Translators Amalgamated Hebrew OT - STEPBible.org CC BY.txt",
    "TAHOT Job-Sng - Translators Amalgamated Hebrew OT - STEPBible.org CC BY.txt",
    "TAHOT Isa-Mal - Translators Amalgamated Hebrew OT - STEPBible.org CC BY.txt",
    "TAGNT Mat-Jhn - Translators Amalgamated Greek NT - STEPBible.org CC-BY.txt",
    "TAGNT Act-Rev - Translators Amalgamated Greek NT - STEPBible.org CC-BY.txt",
)
EMBEDDINGS_URL = "https://openrouter.ai/api/v1/embeddings"
EMBEDDING_MODEL = "openai/text-embedding-3-small"
EMBEDDING_DIMS = 512
EMBED_BATCH = 256
# An English Bible has about 31,100 verses; far fewer means the source was not what it
# claimed to be, and the database is not written.
MIN_VERSES = 30_000
TIMEOUT = 120

# The 66 books: OSIS code (OpenBible's), the name a card shows, and the USFM code
# (YouVersion's, and STEPBible's in title case). The same table as the plugin's books.js.
BOOKS: tuple[tuple[str, str, str], ...] = (
    ("Gen", "Genesis", "GEN"),
    ("Exod", "Exodus", "EXO"),
    ("Lev", "Leviticus", "LEV"),
    ("Num", "Numbers", "NUM"),
    ("Deut", "Deuteronomy", "DEU"),
    ("Josh", "Joshua", "JOS"),
    ("Judg", "Judges", "JDG"),
    ("Ruth", "Ruth", "RUT"),
    ("1Sam", "1 Samuel", "1SA"),
    ("2Sam", "2 Samuel", "2SA"),
    ("1Kgs", "1 Kings", "1KI"),
    ("2Kgs", "2 Kings", "2KI"),
    ("1Chr", "1 Chronicles", "1CH"),
    ("2Chr", "2 Chronicles", "2CH"),
    ("Ezra", "Ezra", "EZR"),
    ("Neh", "Nehemiah", "NEH"),
    ("Esth", "Esther", "EST"),
    ("Job", "Job", "JOB"),
    ("Ps", "Psalms", "PSA"),
    ("Prov", "Proverbs", "PRO"),
    ("Eccl", "Ecclesiastes", "ECC"),
    ("Song", "Song of Solomon", "SNG"),
    ("Isa", "Isaiah", "ISA"),
    ("Jer", "Jeremiah", "JER"),
    ("Lam", "Lamentations", "LAM"),
    ("Ezek", "Ezekiel", "EZK"),
    ("Dan", "Daniel", "DAN"),
    ("Hos", "Hosea", "HOS"),
    ("Joel", "Joel", "JOL"),
    ("Amos", "Amos", "AMO"),
    ("Obad", "Obadiah", "OBA"),
    ("Jonah", "Jonah", "JON"),
    ("Mic", "Micah", "MIC"),
    ("Nah", "Nahum", "NAM"),
    ("Hab", "Habakkuk", "HAB"),
    ("Zeph", "Zephaniah", "ZEP"),
    ("Hag", "Haggai", "HAG"),
    ("Zech", "Zechariah", "ZEC"),
    ("Mal", "Malachi", "MAL"),
    ("Matt", "Matthew", "MAT"),
    ("Mark", "Mark", "MRK"),
    ("Luke", "Luke", "LUK"),
    ("John", "John", "JHN"),
    ("Acts", "Acts", "ACT"),
    ("Rom", "Romans", "ROM"),
    ("1Cor", "1 Corinthians", "1CO"),
    ("2Cor", "2 Corinthians", "2CO"),
    ("Gal", "Galatians", "GAL"),
    ("Eph", "Ephesians", "EPH"),
    ("Phil", "Philippians", "PHP"),
    ("Col", "Colossians", "COL"),
    ("1Thess", "1 Thessalonians", "1TH"),
    ("2Thess", "2 Thessalonians", "2TH"),
    ("1Tim", "1 Timothy", "1TI"),
    ("2Tim", "2 Timothy", "2TI"),
    ("Titus", "Titus", "TIT"),
    ("Phlm", "Philemon", "PHM"),
    ("Heb", "Hebrews", "HEB"),
    ("Jas", "James", "JAS"),
    ("1Pet", "1 Peter", "1PE"),
    ("2Pet", "2 Peter", "2PE"),
    ("1John", "1 John", "1JN"),
    ("2John", "2 John", "2JN"),
    ("3John", "3 John", "3JN"),
    ("Jude", "Jude", "JUD"),
    ("Rev", "Revelation", "REV"),
)
ALIASES = {"psalm": 19, "songofsongs": 22, "canticles": 22, "revelationofjohn": 66}
# Words too common to be worth studying: the Greek article and "and", Hebrew's object
# marker, and STEPBible's codes for prefixes and suffixes (H9000 and up).
SKIPPED_STRONGS = frozenset({"G3588", "G2532", "H0853"})


class BuildError(Exception):
    """A source that is not what it claimed to be; nothing is written."""


def fold(name: str) -> str:
    folded = name.strip().lower()
    folded = re.sub(r"^(i{1,3})\s", lambda m: f"{len(m.group(1))} ", folded)
    return re.sub(r"[^a-z0-9]", "", folded)


def _lookup() -> dict[str, int]:
    table: dict[str, int] = {}
    for number, (osis, name, usfm) in enumerate(BOOKS, 1):
        for key in (osis, name, usfm):
            table.setdefault(fold(key), number)
    table.update(ALIASES)
    return table


LOOKUP = _lookup()
OSIS = {osis: number for number, (osis, _, _) in enumerate(BOOKS, 1)}
FIRST_NEW_TESTAMENT_BOOK = 40


def verse_id(book: int, chapter: int, verse: int) -> int:
    return book * 1_000_000 + chapter * 1_000 + verse


# --- reading sources --------------------------------------------------------------------


def fetch(source: str) -> bytes:
    """A URL's body, or a local file's bytes."""
    if re.match(r"^https?://", source):
        request = urllib.request.Request(
            source, headers={"User-Agent": "household-scripture-build"}
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            body: bytes = response.read()
            return body
    return Path(source).read_bytes()


def decode(raw: bytes) -> str:
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("cp1252")


VERSE_LINE = re.compile(r"^(?P<book>.+?)\s+(?P<chapter>\d+):(?P<verse>\d+)\t(?P<text>.*)$")


def parse_verses(text: str) -> dict[int, str]:
    """`Book 1:1<TAB>text` lines, as bereanbible.com publishes them; anything else is skipped."""
    verses: dict[int, str] = {}
    for line in text.splitlines():
        match = VERSE_LINE.match(line.strip("﻿"))
        if match is None:
            continue
        book = LOOKUP.get(fold(match["book"]))
        words = re.sub(r"\s+", " ", match["text"]).strip()
        if book is None or not words:
            continue
        verses[verse_id(book, int(match["chapter"]), int(match["verse"]))] = words
    return verses


OSIS_REF = re.compile(r"^(?P<book>[1-3]?[A-Za-z]+)\.(?P<chapter>\d+)\.(?P<verse>\d+)$")


def _osis(ref: str) -> int | None:
    match = OSIS_REF.match(ref.strip())
    if match is None:
        return None
    book = OSIS.get(match["book"]) or LOOKUP.get(fold(match["book"]))
    if book is None:
        return None
    return verse_id(book, int(match["chapter"]), int(match["verse"]))


def parse_cross_references(text: str) -> Iterator[tuple[int, int, int, int]]:
    """OpenBible's `From<TAB>To<TAB>Votes` lines: (from, to first, to last, votes)."""
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) < 3 or not fields[2].strip().lstrip("-").isdigit():
            continue
        start, _, end = fields[1].partition("-")
        source, first = _osis(fields[0]), _osis(start)
        last = _osis(end) if end else first
        if source is None or first is None or last is None or last < first:
            continue
        yield source, first, last, int(fields[2])


def cross_reference_text(raw: bytes) -> str:
    """The text file inside OpenBible's zip, or the bytes as text when they are not a zip."""
    if raw[:2] == b"PK":
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            names = [name for name in archive.namelist() if name.endswith(".txt")]
            if not names:
                raise BuildError("the cross-reference zip holds no .txt file")
            return decode(archive.read(names[0]))
    return decode(raw)


@dataclass(frozen=True, slots=True)
class Word:
    verse: int
    strongs: str
    lemma: str
    translit: str
    gloss: str


STEP_REF = re.compile(
    r"^(?P<book>[1-3]?[A-Za-z]{2,3})\.(?P<chapter>\d+)\.(?P<verse>\d+)(?:\([^)]*\))?#\d+=(?P<type>[^\t]*)$"
)
STRONGS = re.compile(r"^[GH]\d{4}[A-Za-z]?$")
MAIN_WORD = re.compile(r"\{(?P<strongs>H\d{4}[A-Za-z]?)=(?P<lemma>[^=}]*)=(?P<gloss>[^}]*)\}")


def _clean_gloss(raw: str) -> str:
    gloss = raw.strip().lstrip(":").strip()
    gloss = re.split(r"[»@]", gloss, maxsplit=1)[0]
    return gloss.replace("_", " ").strip()


def _skipped(strongs: str) -> bool:
    base = strongs[:5]
    return base in SKIPPED_STRONGS or (base.startswith("H9") and base[1:].isdigit())


def parse_step(text: str) -> Iterator[Word]:
    """STEPBible's TAGNT and TAHOT word lines: each verse's words, in English versification.

    A TAGNT line is `Mat.1.1#01=NKO<TAB>Greek (translit)<TAB>English<TAB>G0976=grammar<TAB>
    lemma=gloss`, and only words of the Nestle-Aland text (an N in the type) are kept. A
    TAHOT line is `Gen.31.55(32.1)#01=L<TAB>Hebrew<TAB>translit<TAB>English<TAB>dStrongs...`
    with the main word's Strong's number, lemma and gloss in braces in the expanded tags.
    """
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) < 5:
            continue
        ref = STEP_REF.match(fields[0])
        if ref is None:
            continue
        book = LOOKUP.get(fold(ref["book"]))
        if book is None:
            continue
        verse = verse_id(book, int(ref["chapter"]), int(ref["verse"]))
        if book >= FIRST_NEW_TESTAMENT_BOOK:
            # TAGNT: the word's Greek, with its transliteration in brackets.
            if "N" not in ref["type"]:
                continue
            strongs = fields[3].split("=", 1)[0].strip()
            lemma, _, gloss = fields[4].partition("=")
            bracketed = re.search(r"\(([^)]*)\)", fields[1])
            if not STRONGS.match(strongs) or _skipped(strongs):
                continue
            yield Word(
                verse,
                strongs,
                lemma.strip(),
                bracketed.group(1).strip() if bracketed else "",
                _clean_gloss(gloss),
            )
            continue
        # TAHOT: the main word sits in braces in the expanded tags, or in the dStrongs field.
        expanded = fields[11] if len(fields) > 11 else ""
        main = MAIN_WORD.search(expanded)
        if main is not None:
            strongs, lemma, gloss = (
                main["strongs"],
                main["lemma"].strip(),
                _clean_gloss(main["gloss"]),
            )
        else:
            braced = re.search(r"\{(H\d{4}[A-Za-z]?)\}", fields[4])
            if braced is None:
                continue
            strongs, lemma, gloss = braced.group(1), "", _clean_gloss(fields[3])
        if _skipped(strongs):
            continue
        translit = re.sub(r"[./]", "", fields[2]).strip().lower()
        yield Word(verse, strongs, lemma, translit, gloss)


# --- meaning vectors ---------------------------------------------------------------------

Post = Callable[[str, dict[str, Any], str], dict[str, Any]]


def openrouter_post(url: str, body: dict[str, Any], key: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "User-Agent": "household-scripture-build",
        },
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                answer: dict[str, Any] = json.load(response)
                return answer
        except urllib.error.HTTPError as error:
            if error.code in (429, 500, 502, 503) and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            raise BuildError(f"OpenRouter answered {error.code} to an embedding request") from error
    raise BuildError("OpenRouter did not answer the embedding requests")


def pack(vector: Sequence[float], dims: int) -> bytes:
    """The first `dims` numbers, scaled to length 1, as little-endian float32."""
    head = [float(value) for value in vector[:dims]]
    if len(head) < dims:
        raise BuildError(f"the embedding has {len(head)} numbers, fewer than {dims}")
    length = math.sqrt(sum(value * value for value in head)) or 1.0
    return struct.pack(f"<{dims}f", *(value / length for value in head))


def embed(
    db: sqlite3.Connection,
    translation: str,
    key: str,
    *,
    post: Post = openrouter_post,
    model: str = EMBEDDING_MODEL,
    dims: int = EMBEDDING_DIMS,
    log: Callable[[str], None] = print,
) -> int:
    rows = db.execute(
        "SELECT id, text FROM verses WHERE translation = ? ORDER BY id", (translation,)
    ).fetchall()
    db.execute("DELETE FROM vectors")
    done = 0
    for start in range(0, len(rows), EMBED_BATCH):
        batch = rows[start : start + EMBED_BATCH]
        answer = post(EMBEDDINGS_URL, {"model": model, "input": [text for _, text in batch]}, key)
        data = answer.get("data")
        if not isinstance(data, list) or len(data) != len(batch):
            raise BuildError("OpenRouter returned a different number of embeddings than asked for")
        ordered = sorted(data, key=lambda item: int(item.get("index", 0)))
        db.executemany(
            "INSERT INTO vectors (id, vector) VALUES (?, ?)",
            [
                (verse, pack(item["embedding"], dims))
                for (verse, _), item in zip(batch, ordered, strict=True)
            ],
        )
        done += len(batch)
        if done % (EMBED_BATCH * 20) == 0 or done == len(rows):
            log(f"embedded {done} of {len(rows)} verses")
    db.executemany(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
        [("embedding_model", model), ("embedding_dims", str(dims))],
    )
    return done


def key_from(env_file: Path | None) -> str:
    """OPENROUTER_API_KEY from the environment, or from a root-only env file's line."""
    key = os.environ.get("OPENROUTER_API_KEY", "")
    if not key and env_file is not None:
        for line in env_file.read_text().splitlines():
            name, _, value = line.partition("=")
            if name.strip() == "OPENROUTER_API_KEY":
                key = value.strip().strip("'\"")
    if not key:
        raise BuildError("no OPENROUTER_API_KEY in the environment or the env file")
    return key


# --- writing the database ----------------------------------------------------------------

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE sources (name TEXT PRIMARY KEY, url TEXT NOT NULL, license TEXT NOT NULL,
                      attribution TEXT NOT NULL);
CREATE TABLE verses (id INTEGER NOT NULL, translation TEXT NOT NULL, text TEXT NOT NULL,
                     PRIMARY KEY (translation, id)) WITHOUT ROWID;
CREATE VIRTUAL TABLE verses_fts USING fts5(text, tokenize = 'porter unicode61');
CREATE TABLE xrefs (from_id INTEGER NOT NULL, to_first INTEGER NOT NULL,
                    to_last INTEGER NOT NULL, votes INTEGER NOT NULL);
CREATE INDEX xrefs_from ON xrefs (from_id, votes DESC);
CREATE TABLE words (verse_id INTEGER NOT NULL, position INTEGER NOT NULL, strongs TEXT NOT NULL,
                    lemma TEXT NOT NULL, translit TEXT NOT NULL, gloss TEXT NOT NULL,
                    PRIMARY KEY (verse_id, position)) WITHOUT ROWID;
CREATE TABLE vectors (id INTEGER PRIMARY KEY, vector BLOB NOT NULL);
"""


@dataclass(frozen=True, slots=True)
class Sources:
    bsb: str = BSB_URL
    xrefs: str = XREFS_URL
    step_base: str = STEP_BASE
    extra: tuple[tuple[str, str], ...] = ()


def step_source(base: str, name: str) -> str:
    if re.match(r"^https?://", base):
        return base + urllib.parse.quote(name)
    return str(Path(base) / name)


def build(
    out: Path,
    sources: Sources,
    *,
    min_verses: int = MIN_VERSES,
    log: Callable[[str], None] = print,
) -> sqlite3.Connection:
    """Writes the database to a temporary file beside `out`, returning it open."""
    translations: list[tuple[str, dict[int, str]]] = [
        ("BSB", parse_verses(decode(fetch(sources.bsb))))
    ]
    for name, source in sources.extra:
        translations.append((name.upper(), parse_verses(decode(fetch(source)))))
    for name, verses in translations:
        if len(verses) < min_verses:
            raise BuildError(f"{name} gave {len(verses)} verses, fewer than {min_verses}")
        log(f"{name}: {len(verses)} verses")
    xrefs = list(parse_cross_references(cross_reference_text(fetch(sources.xrefs))))
    log(f"cross references: {len(xrefs)}")
    words: list[Word] = []
    for name in STEP_FILES:
        words.extend(parse_step(decode(fetch(step_source(sources.step_base, name)))))
    log(f"original-language words: {len(words)}")

    out.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=".bible-", suffix=".sqlite", dir=out.parent)
    os.close(handle)
    db = sqlite3.connect(temporary)
    db.executescript(SCHEMA)
    for name, verses in translations:
        db.executemany(
            "INSERT INTO verses (id, translation, text) VALUES (?, ?, ?)",
            ((verse, name, text) for verse, text in sorted(verses.items())),
        )
    primary = translations[0][1]
    db.executemany("INSERT INTO verses_fts (rowid, text) VALUES (?, ?)", sorted(primary.items()))
    db.executemany("INSERT INTO xrefs VALUES (?, ?, ?, ?)", xrefs)
    positions: dict[int, int] = {}
    rows = []
    for word in words:
        if word.verse not in primary:
            continue
        positions[word.verse] = positions.get(word.verse, 0) + 1
        rows.append(
            (word.verse, positions[word.verse], word.strongs, word.lemma, word.translit, word.gloss)
        )
    db.executemany("INSERT INTO words VALUES (?, ?, ?, ?, ?, ?)", rows)
    db.executemany(
        "INSERT INTO sources VALUES (?, ?, ?, ?)",
        [
            ("Berean Standard Bible", sources.bsb, "Public domain", "Berean Standard Bible (BSB)"),
            (
                "OpenBible.info cross references",
                sources.xrefs,
                "CC BY",
                "Cross references from OpenBible.info",
            ),
            (
                "STEPBible TAHOT and TAGNT",
                sources.step_base,
                "CC BY 4.0",
                "Hebrew and Greek words from STEPBible.org, Tyndale House, Cambridge",
            ),
            *[(name, source, "Public domain", name) for name, source in sources.extra],
        ],
    )
    db.executemany(
        "INSERT INTO meta (key, value) VALUES (?, ?)",
        [
            ("schema_version", str(SCHEMA_VERSION)),
            ("translations", json.dumps([name for name, _ in translations])),
            ("built_at", datetime.now(UTC).isoformat(timespec="seconds")),
            ("step_commit", STEP_COMMIT),
        ],
    )
    db.commit()
    return db


def finish(db: sqlite3.Connection, out: Path) -> None:
    """Checks the temporary database and moves it into place, readable by the gateway."""
    temporary = Path(db.execute("PRAGMA database_list").fetchone()[2])
    db.commit()
    if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise BuildError("the new database failed its integrity check")
    db.execute("PRAGMA journal_mode = DELETE")
    db.execute("VACUUM")
    db.close()
    os.chmod(temporary, 0o644)
    os.replace(temporary, out)


def primary_translation(db: sqlite3.Connection) -> str:
    row = db.execute("SELECT value FROM meta WHERE key = 'translations'").fetchone()
    if row is None:
        raise BuildError("the database has no translations recorded")
    names: list[str] = json.loads(row[0])
    return names[0]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--bsb", default=BSB_URL, help="URL or file of the BSB text")
    parser.add_argument("--xrefs", default=XREFS_URL, help="URL or file of OpenBible's zip")
    parser.add_argument("--step-base", default=STEP_BASE, help="URL or folder of STEPBible's files")
    parser.add_argument(
        "--extra", action="append", default=[], metavar="NAME=URL", help="another translation"
    )
    parser.add_argument("--embed", action="store_true", help="add meaning vectors from OpenRouter")
    parser.add_argument("--embed-only", action="store_true", help="only (re)embed --out")
    parser.add_argument("--env-file", type=Path, help="where to read OPENROUTER_API_KEY")
    parser.add_argument("--min-verses", type=int, default=MIN_VERSES, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        extra = tuple(_pair(value) for value in args.extra)
        if args.embed_only:
            key = key_from(args.env_file)
            fd, temporary = tempfile.mkstemp(
                prefix=".bible-", suffix=".sqlite", dir=args.out.parent
            )
            os.close(fd)
            with args.out.open("rb") as source, open(temporary, "wb") as copy:
                copy.write(source.read())
            db = sqlite3.connect(temporary)
            embed(db, primary_translation(db), key)
        else:
            key = key_from(args.env_file) if args.embed else ""
            db = build(
                args.out,
                Sources(args.bsb, args.xrefs, args.step_base, extra),
                min_verses=args.min_verses,
            )
            if args.embed:
                embed(db, primary_translation(db), key)
        finish(db, args.out)
    except (BuildError, OSError, urllib.error.URLError, sqlite3.Error) as error:
        print(f"scripture-build: {error}", file=sys.stderr)
        return 1
    print(f"wrote {args.out}")
    return 0


def _pair(value: str) -> tuple[str, str]:
    name, sep, source = value.partition("=")
    if not sep or not re.fullmatch(r"[A-Za-z]{2,8}", name) or not source:
        raise BuildError(f"--extra takes NAME=URL, not {value!r}")
    return name, source


if __name__ == "__main__":
    sys.exit(main())
