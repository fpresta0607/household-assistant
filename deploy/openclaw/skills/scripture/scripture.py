#!/usr/bin/env python3
"""Read-only client for SIQsermon, behind the `scripture` skill.

Every call here is a read. SIQsermon's data, containers, compose file and
runtime env are never touched: writing study notes and plans back is a later
phase, not this one.

The account comes from the environment, which the gateway loads from its
root-only env file (`/etc/household-assistant/openclaw.env` for Corey,
`openclaw-denise.env` for Denise). No credential is read from the workspace,
written to disk, or printed. The session cookie lives in memory for the one
invocation; SIQsermon signs it rather than storing it, so re-logging in each
time costs one request and leaves no token at rest.

Only the standard library: the gateway image has no package manager and is
never rebuilt on the box.
"""

import argparse
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any

BACKEND = os.environ.get("SIQSERMON_URL", "http://deploy-backend-1:8000")
COOKIE_NAME = "siqsermon_session"

# Looking a reference up is the one thing SIQsermon's HTTP API cannot do:
# POST /search is semantic, so asking it for "John 3:16" returns verses about
# John the Baptist. The verse points carry the reference in their payload, so
# a reference is resolved by computing the point id and reading that one point.
#
# THIS COUPLES US TO TWO THINGS INSIDE SIQsermon:
#   - `ingestion/books.verse_id`, the BBCCCVVV id scheme (book * 1e6 +
#     chapter * 1e3 + verse) and the 1-66 book order mirrored below, and
#   - the Qdrant collection name `verses`.
# If either changes, this lookup breaks and the search path does not. The fix
# is not to patch this: SIQsermon should grow a verses-by-reference read, and
# this should call it instead. Read-only, and a GET is the only call made here.
QDRANT = os.environ.get("QDRANT_URL", "http://deploy-qdrant-1:6333")
VERSES_COLLECTION = "verses"

# The canonical 66, in SIQsermon's order, which is what makes the id arithmetic
# agree with the database. The short form is the OSIS code, which is also what
# makes "1 Sam 2:3" and "Rev 22:21" resolve.
BOOKS = [
    ("Gen", "Genesis"),
    ("Exod", "Exodus"),
    ("Lev", "Leviticus"),
    ("Num", "Numbers"),
    ("Deut", "Deuteronomy"),
    ("Josh", "Joshua"),
    ("Judg", "Judges"),
    ("Ruth", "Ruth"),
    ("1Sam", "1 Samuel"),
    ("2Sam", "2 Samuel"),
    ("1Kgs", "1 Kings"),
    ("2Kgs", "2 Kings"),
    ("1Chr", "1 Chronicles"),
    ("2Chr", "2 Chronicles"),
    ("Ezra", "Ezra"),
    ("Neh", "Nehemiah"),
    ("Esth", "Esther"),
    ("Job", "Job"),
    ("Ps", "Psalms"),
    ("Prov", "Proverbs"),
    ("Eccl", "Ecclesiastes"),
    ("Song", "Song of Solomon"),
    ("Isa", "Isaiah"),
    ("Jer", "Jeremiah"),
    ("Lam", "Lamentations"),
    ("Ezek", "Ezekiel"),
    ("Dan", "Daniel"),
    ("Hos", "Hosea"),
    ("Joel", "Joel"),
    ("Amos", "Amos"),
    ("Obad", "Obadiah"),
    ("Jonah", "Jonah"),
    ("Mic", "Micah"),
    ("Nah", "Nahum"),
    ("Hab", "Habakkuk"),
    ("Zeph", "Zephaniah"),
    ("Hag", "Haggai"),
    ("Zech", "Zechariah"),
    ("Mal", "Malachi"),
    ("Matt", "Matthew"),
    ("Mark", "Mark"),
    ("Luke", "Luke"),
    ("John", "John"),
    ("Acts", "Acts"),
    ("Rom", "Romans"),
    ("1Cor", "1 Corinthians"),
    ("2Cor", "2 Corinthians"),
    ("Gal", "Galatians"),
    ("Eph", "Ephesians"),
    ("Phil", "Philippians"),
    ("Col", "Colossians"),
    ("1Thess", "1 Thessalonians"),
    ("2Thess", "2 Thessalonians"),
    ("1Tim", "1 Timothy"),
    ("2Tim", "2 Timothy"),
    ("Titus", "Titus"),
    ("Phlm", "Philemon"),
    ("Heb", "Hebrews"),
    ("Jas", "James"),
    ("1Pet", "1 Peter"),
    ("2Pet", "2 Peter"),
    ("1John", "1 John"),
    ("2John", "2 John"),
    ("3John", "3 John"),
    ("Jude", "Jude"),
    ("Rev", "Revelation"),
]

# YouVersion uses USFM rather than the OSIS spellings above. Keep the canonical
# book order; these are the same codes the iOS Bible links use.
USFM = [
    "GEN",
    "EXO",
    "LEV",
    "NUM",
    "DEU",
    "JOS",
    "JDG",
    "RUT",
    "1SA",
    "2SA",
    "1KI",
    "2KI",
    "1CH",
    "2CH",
    "EZR",
    "NEH",
    "EST",
    "JOB",
    "PSA",
    "PRO",
    "ECC",
    "SNG",
    "ISA",
    "JER",
    "LAM",
    "EZK",
    "DAN",
    "HOS",
    "JOL",
    "AMO",
    "OBA",
    "JON",
    "MIC",
    "NAM",
    "HAB",
    "ZEP",
    "HAG",
    "ZEC",
    "MAL",
    "MAT",
    "MRK",
    "LUK",
    "JHN",
    "ACT",
    "ROM",
    "1CO",
    "2CO",
    "GAL",
    "EPH",
    "PHP",
    "COL",
    "1TH",
    "2TH",
    "1TI",
    "2TI",
    "TIT",
    "PHM",
    "HEB",
    "JAS",
    "1PE",
    "2PE",
    "1JN",
    "2JN",
    "3JN",
    "JUD",
    "REV",
]
# YouVersion's ids for the editions an Open in Bible link can open.
BIBLE_VERSIONS = {"BSB": 3034, "KJV": 1, "ASV": 12, "NIV": 111}
# The edition the household reads, which every card's link opens whatever rendering its
# text is: the household file's bibleVersion, handed to this skill by
# scripts/openclaw-scripture.py through skills.entries.scripture.env. Without it a link
# opens the edition of the text itself.
HOUSEHOLD_BIBLE_VERSION = "HOUSEHOLD_BIBLE_VERSION"

# The same spellings SIQsermon's own table tolerates.
ALIASES = {"psalm": 19, "songofsongs": 22, "canticles": 22, "revelationofjohn": 66}

# A whole chapter would mean walking verses until one 404s. Bounded instead:
# ponytail: explicit ranges only, revisit if "read me Psalm 23" comes up often.
MAX_RANGE = 40

# Public-domain renderings, most modern first; the same order the verse
# embeddings were built with. Licensed translations are never stored.
PREFERENCE = ["BSB", "WEB", "KJV", "ASV", "YLT"]

TIMEOUT = 60  # the first search of the day warms the embedder


class ScriptureError(Exception):
    """Something the agent must report rather than work around."""


def _norm(name: str) -> str:
    """Fold a book name the way SIQsermon does, so "I Samuel" reaches 1 Samuel."""
    folded = name.strip().lower()
    folded = re.sub(r"^(i{1,3})\s", lambda m: str(len(m.group(1))) + " ", folded)
    return re.sub(r"[^a-z0-9]", "", folded)


_LOOKUP = {_norm(key): number for number, names in enumerate(BOOKS, 1) for key in names}
_LOOKUP.update({_norm(alias): number for alias, number in ALIASES.items()})


def _parse_reference(text: str) -> tuple[str, int, int, int, int]:
    """ "John 3:16" or "1 Sam 2:3-5" -> (book name, number, chapter, first, last).

    Raises rather than guessing: a reference the database cannot be asked for
    must be reported, never quietly turned into a different verse.
    """
    match = re.fullmatch(r"\s*(.+?)\s+(\d+)\s*[:.]\s*(\d+)(?:\s*-\s*(\d+))?\s*", text)
    if match is None:
        raise ScriptureError(
            f"'{text}' is not a reference this can look up. Use 'Book chapter:verse', "
            f"for example 'John 3:16' or 'Psalms 23:1-6'."
        )
    book, chapter, first, last = match.groups()
    number = _LOOKUP.get(_norm(book))
    if number is None:
        raise ScriptureError(f"'{book}' is not one of the 66 books SIQsermon holds.")
    chapter, first, last = int(chapter), int(first), int(last or first)
    if not all(1 <= part <= 999 for part in (chapter, first, last)):
        raise ScriptureError(
            f"'{text.strip()}' is out of range: SIQsermon's verse ids hold only "
            f"chapters and verses 1-999."
        )
    return book, number, chapter, first, last


def _verse_point(book_number: int, chapter: int, verse: int) -> dict[str, Any] | None:
    """One verse from the Qdrant collection, or None when there is no such verse."""
    # ingestion/books.verse_id: the BBCCCVVV integer that is the point's id.
    point_id = book_number * 1_000_000 + chapter * 1_000 + verse
    url = f"{QDRANT}/collections/{VERSES_COLLECTION}/points/{point_id}?with_vector=false"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = json.load(response).get("result", {}).get("payload")
            return payload if isinstance(payload, dict) else None
    except urllib.error.HTTPError as exc:
        # Qdrant answers 404 both for a point it does not hold and for a
        # collection it does not have. Only the first is a verdict about the
        # reference; the second is SIQsermon's collection gone or renamed, and
        # reporting that as "no such verse" is the invented answer this skill
        # exists to prevent. Anything but the point's own 404 is breakage.
        detail = exc.read().decode(errors="replace")[:300]
        if exc.code == 404 and "Point with id" in detail:
            return None
        if exc.code == 404:
            raise ScriptureError(
                f"Cannot read SIQsermon's verse collection `{VERSES_COLLECTION}` at "
                f"{QDRANT}: {detail}. This says nothing about the reference."
            ) from exc
        raise ScriptureError(f"Qdrant returned {exc.code} for {url}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise ScriptureError(
            f"Cannot reach the verse collection at {QDRANT} ({exc.reason}). The "
            f"gateway must be on the deploy_default network."
        ) from exc


def _call(
    url: str,
    payload: dict[str, str] | None = None,
    cookie: str | None = None,
) -> tuple[Any, list[str]]:
    """The parsed JSON body and the response's Set-Cookie headers."""
    headers = {"Accept": "application/json"}
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode()
    if cookie:
        headers["Cookie"] = f"{COOKIE_NAME}={cookie}"
    # No Origin header: SIQsermon refuses a cross-site write from an unknown
    # origin, and a server-to-server call has no origin to claim.
    request = urllib.request.Request(url, data=body, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response), response.headers.get_all("Set-Cookie") or []
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:300]
        raise ScriptureError(f"SIQsermon returned {exc.code} for {url}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise ScriptureError(
            f"Cannot reach SIQsermon at {url} ({exc.reason}). The gateway must be "
            f"on the deploy_default network."
        ) from exc


def _session() -> str:
    """A signed session cookie, or a plain explanation of why there is none."""
    username = os.environ.get("SIQSERMON_USERNAME")
    password = os.environ.get("SIQSERMON_PASSWORD")
    if not username or not password:
        raise ScriptureError(
            "No SIQsermon account configured: SIQSERMON_USERNAME and "
            "SIQSERMON_PASSWORD are not set in this gateway's env file."
        )
    _, cookies = _call(f"{BACKEND}/login", {"username": username, "password": password})
    for value in cookies:
        if value.startswith(f"{COOKIE_NAME}="):
            # Sent back as a bare header: the cookie is marked Secure, and a
            # cookie jar would refuse to replay it over the in-network http call.
            return value.split("=", 1)[1].split(";", 1)[0]
    raise ScriptureError("SIQsermon accepted the login but issued no session cookie.")


def _rendering(renderings: dict[str, str]) -> tuple[str | None, str | None]:
    """The best available text for a verse, and which translation it is."""
    for name in PREFERENCE:
        if (renderings.get(name) or "").strip():
            return name, renderings[name].strip()
    for name, text in renderings.items():
        if (text or "").strip():
            return name, text.strip()
    return None, None


def _print_anchor(anchor: dict[str, Any]) -> None:
    translation, text = _rendering(anchor.get("renderings") or {})
    if text is None:
        return
    print(f"{anchor['ref']} ({translation}) score {anchor.get('score', 0):.3f}")
    print(f"  {text}")
    cross = anchor.get("cross_refs") or []
    if cross:
        print(
            "  cross-refs: " + "; ".join(f"{c['book']} {c['chapter']}:{c['verse']}" for c in cross)
        )
    lemmas = anchor.get("lemmas") or []
    if lemmas:
        # Greek entries carry no transliteration, so fall back to the lemma
        # itself and then to the Strong's number, which is always there.
        print(
            "  word study: "
            + "; ".join(
                f"{lemma.get('translit') or lemma.get('lemma') or lemma['strongs']} "
                f'({lemma["strongs"]}) "{(lemma.get("gloss") or "")[:60]}"'
                for lemma in lemmas
            )
        )
    print()


def search(args: argparse.Namespace) -> None:
    """Semantic search over all 31,105 verses, then the graph around each hit."""
    found, _ = _call(f"{BACKEND}/search", {"topic": args.topic}, cookie=_session())
    anchors = found.get("anchors") or []
    if not anchors:
        print(f"SIQsermon found no verses for: {args.topic}")
        return
    for anchor in anchors:
        _print_anchor(anchor)


def _passage_card(
    points: list[dict[str, Any]], number: int, chapter: int, first: int, last: int
) -> dict[str, Any]:
    """Render a complete, consistent database passage without a second model call."""
    if len(points) != last - first + 1:
        raise ScriptureError("Cannot make a scripture card: the passage is incomplete.")
    translation = points[0].get("translation")
    if not isinstance(translation, str) or not translation.strip():
        raise ScriptureError("Cannot make a scripture card: the translation is missing.")
    verses = []
    for verse, point in zip(range(first, last + 1), points, strict=True):
        _, actual_book, actual_chapter, actual_first, actual_last = _parse_reference(
            str(point.get("ref", ""))
        )
        if (actual_book, actual_chapter, actual_first, actual_last) != (
            number,
            chapter,
            verse,
            verse,
        ):
            raise ScriptureError("Cannot make a scripture card: a stored reference mismatches.")
        text = point.get("text")
        if not isinstance(text, str) or not text.strip():
            raise ScriptureError("Cannot make a scripture card: a verse has no text.")
        if point.get("translation") != translation:
            raise ScriptureError("Cannot make a scripture card: the passage mixes translations.")
        verses.append({"n": verse, "text": text})
    verse_range = str(first) if first == last else f"{first}-{last}"
    card: dict[str, Any] = {
        "type": "scripture",
        "reference": f"{BOOKS[number - 1][1]} {chapter}:{verse_range}",
        "translation": translation,
        "verses": verses,
        "skill": "scripture",
    }
    chosen = os.environ.get(HOUSEHOLD_BIBLE_VERSION)
    if chosen and chosen not in BIBLE_VERSIONS:
        raise ScriptureError(
            f"Cannot make a scripture card: {HOUSEHOLD_BIBLE_VERSION} is {chosen}, "
            f"and a link can open only {', '.join(BIBLE_VERSIONS)}."
        )
    edition = chosen or translation
    version = BIBLE_VERSIONS.get(edition)
    if version is not None:
        card["link"] = (
            f"https://www.bible.com/bible/{version}/"
            f"{USFM[number - 1]}.{chapter}.{verse_range}.{edition}"
        )
    return card


def passage(args: argparse.Namespace) -> None:
    """A verse, or a short range, fetched by its reference rather than by meaning."""
    book, number, chapter, first, last = _parse_reference(args.reference)
    if last < first:
        raise ScriptureError(f"{book} {chapter}:{first}-{last} runs backwards.")
    if last - first + 1 > MAX_RANGE:
        raise ScriptureError(
            f"{book} {chapter}:{first}-{last} is more than {MAX_RANGE} verses. "
            f"Ask for a shorter range."
        )

    found: list[dict[str, Any]] = []
    missing: list[int] = []
    for verse in range(first, last + 1):
        point = _verse_point(number, chapter, verse)
        if point is None:
            missing.append(verse)
        else:
            found.append(point)

    if not found:
        # Never answer from memory here: if the database does not hold it, say so.
        raise ScriptureError(
            f"SIQsermon's verse collection holds nothing at {book} {chapter}:{first}"
            f"{'-' + str(last) if last != first else ''}. Check the reference."
        )
    if args.card:
        card = _passage_card(found, number, chapter, first, last)
        print("```steward-card")
        print(json.dumps(card, ensure_ascii=False, separators=(",", ":")))
        print("```")
        return
    for point in found:
        print(f"{point['ref']} ({point['translation']})")
        print(f"  {point['text']}")
    if missing:
        print(
            f"\nNot in the collection: verse(s) "
            f"{', '.join(str(verse) for verse in missing)} of {book} {chapter}."
        )


def sermons(args: argparse.Namespace) -> None:
    """The preaching archive. SIQsermon does not scope these to an account."""
    if args.id is not None:
        sermon, _ = _call(f"{BACKEND}/sermons/{args.id}", cookie=_session())
        print(json.dumps(sermon, indent=2))
        return
    listing, _ = _call(f"{BACKEND}/sermons", cookie=_session())
    for sermon in listing.get("sermons") or []:
        created = (sermon.get("created_at") or "")[:10]
        print(f"{sermon['id']:>4}  {created}  {sermon.get('topic', '')}")


def plans(args: argparse.Namespace) -> None:
    """Study projects and their planning artifacts, likewise not account-scoped."""
    if args.id is not None:
        project, _ = _call(f"{BACKEND}/projects/{args.id}", cookie=_session())
        print(json.dumps(project, indent=2))
        return
    listing, _ = _call(f"{BACKEND}/projects", cookie=_session())
    for project in listing.get("projects") or []:
        method = project.get("study_method") or ""
        print(f"{project['id']:>4}  {method:<20}  {project.get('title', '')}")


def main(argv: list[str] | None = None) -> int:
    # Scripture is not ASCII: the word studies are Greek and Hebrew and the
    # verse text carries typographic quotes. Under a non-UTF-8 locale the
    # default encoder raises and the agent gets a traceback instead of a verse.
    for stream in (sys.stdout, sys.stderr):
        if isinstance(stream, io.TextIOWrapper):
            stream.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_search = sub.add_parser("search", help="find verses by meaning")
    p_search.add_argument("topic", help="a question, a theme, or remembered wording")
    p_search.set_defaults(func=search)

    p_ref = sub.add_parser("ref", help="look a reference up, e.g. 'John 3:16'")
    p_ref.add_argument("reference", help="Book chapter:verse, optionally -verse")
    p_ref.add_argument("--card", action="store_true", help="emit a Steward scripture card")
    p_ref.set_defaults(func=passage)

    p_sermons = sub.add_parser("sermons", help="list the sermon archive, or read one")
    p_sermons.add_argument("id", nargs="?", type=int)
    p_sermons.set_defaults(func=sermons)

    p_plans = sub.add_parser("plans", help="list study projects, or read one")
    p_plans.add_argument("id", nargs="?", type=int)
    p_plans.set_defaults(func=plans)

    args = parser.parse_args(argv)
    try:
        args.func(args)
    except ScriptureError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
