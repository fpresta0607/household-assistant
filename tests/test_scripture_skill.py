"""The scripture skill's client, asserted by running it against a stub SIQsermon.

The skill is what the agent actually invokes, so these run the real file as a
subprocess the way the gateway does, against a stand-in backend that enforces
the two things the live one enforces: the login has to match, and every other
route needs the session cookie back.

That second point is the one worth a test. SIQsermon marks its cookie `Secure`,
and the gateway reaches it over plain `http://` inside the docker network, so a
cookie jar would silently drop it and every call would come back 401. The client
replays the cookie as a bare header instead, and the stub below fails the test
if it ever stops doing so.

What is not exercised here: the real backend, Qdrant, and whether the verses are
the right ones. Those were run against the box and are quoted in the pull request.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from collections.abc import Iterator, Mapping
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTURE = ROOT / "deploy" / "openclaw" / "skills" / "scripture" / "scripture.py"

USERNAME = "franco"
PASSWORD = "not-the-real-password"
TOKEN = "ZnJhbmNv.9999999999.a-signature"

# Shaped like a real /search anchor: BSB and KJV both present so the preference
# order is visible, and a Greek lemma, whose `translit` the graph leaves null.
ANCHORS = {
    "anchors": [
        {
            "ref": "John 10:11",
            "score": 0.7012,
            "renderings": {
                "KJV": "I am the good shepherd: the good shepherd giveth his life.",
                "BSB": "I am the good shepherd. The good shepherd lays down His life.",
            },
            "cross_refs": [
                {
                    "book": "Psalms",
                    "chapter": 23,
                    "verse": 1,
                    "votes": 9,
                    "text": "The LORD is my shepherd",
                },
            ],
            "lemmas": [
                {
                    "strongs": "G4166",
                    "lemma": "ποιμήν",
                    "translit": None,
                    "gloss": "shepherd, pastor",
                },
            ],
        }
    ]
}


# Keyed by the BBCCCVVV point id ingestion/books.verse_id builds. John is the
# 43rd book, so John 3:16 is 43 * 1e6 + 3 * 1e3 + 16.
VERSE_POINTS = {
    43003016: {
        "vid": 43003016,
        "osis": "John.3.16",
        "ref": "John 3:16",
        "book": "John",
        "chapter": 3,
        "verse": 16,
        "translation": "BSB",
        "text": "For God so loved the world that He gave His one and only Son.",
    },
    # The verse "John 3:1016" used to carry into: 43 * 1e6 + 4 * 1e3 + 16.
    43004016: {
        "vid": 43004016,
        "osis": "John.4.16",
        "ref": "John 4:16",
        "book": "John",
        "chapter": 4,
        "verse": 16,
        "translation": "BSB",
        "text": "Jesus told her, “Go, call your husband and come back.”",
    },
}


class _StubSIQsermon(BaseHTTPRequestHandler):
    """Closed by default, exactly like the real AuthMiddleware."""

    def log_message(self, format: str, *args: object) -> None:
        """Quiet: pytest captures enough already."""

    def _send(self, code: int, body: Mapping[str, object], cookie: str | None = None) -> None:
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if cookie is not None:
            self.send_header(
                "Set-Cookie",
                f"siqsermon_session={cookie}; HttpOnly; Max-Age=2592000; "
                f"Path=/; SameSite=lax; Secure",
            )
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        """The one Qdrant call the skill is allowed to make: a point by id."""
        prefix = "/collections/verses/points/"
        if not self.path.startswith(prefix):
            self._send(404, {"status": {"error": "no such route"}})
            return
        point_id = int(self.path[len(prefix) :].split("?")[0])
        point = VERSE_POINTS.get(point_id)
        if point is None:
            self._send(404, {"status": {"error": f"Point with id {point_id} does not exists!"}})
            return
        self._send(200, {"result": {"id": point_id, "payload": point}})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        sent = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/login":
            if sent.get("username") == USERNAME and sent.get("password") == PASSWORD:
                self._send(200, {"username": USERNAME}, cookie=TOKEN)
            else:
                self._send(401, {"detail": "That username and password do not match."})
            return
        if self.headers.get("Cookie") != f"siqsermon_session={TOKEN}":
            self._send(401, {"detail": "Sign in to continue."})
            return
        self._send(200, ANCHORS)


class _QdrantWithoutVerses(_StubSIQsermon):
    """Qdrant after an ingestion run drops or renames the `verses` collection.

    Its 404 for a missing collection is the same status code as its 404 for a
    missing point, which is why the client has to read the body.
    """

    def do_GET(self) -> None:
        self._send(404, {"status": {"error": "Collection `verses` doesn't exist!"}})


def _serve(handler: type[BaseHTTPRequestHandler]) -> Iterator[str]:
    """A stand-in backend on loopback, gone when the test ends."""
    server = HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


@pytest.fixture
def siqsermon() -> Iterator[str]:
    yield from _serve(_StubSIQsermon)


@pytest.fixture
def siqsermon_without_verses() -> Iterator[str]:
    yield from _serve(_QdrantWithoutVerses)


def run_scripture(
    url: str,
    *args: str,
    username: str | None = USERNAME,
    password: str | None = PASSWORD,
    bible_version: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run the skill's script the way the gateway does: env in, stdout out."""
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("SIQSERMON_", "QDRANT_", "HOUSEHOLD_BIBLE_VERSION"))
    }
    if bible_version is not None:
        env["HOUSEHOLD_BIBLE_VERSION"] = bible_version
    env["SIQSERMON_URL"] = url
    env["QDRANT_URL"] = url
    if username is not None:
        env["SIQSERMON_USERNAME"] = username
    if password is not None:
        env["SIQSERMON_PASSWORD"] = password
    return subprocess.run(
        [sys.executable, SCRIPTURE.as_posix(), *args],
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )


def test_a_search_cites_the_reference_and_replays_the_secure_cookie(siqsermon: str) -> None:
    """The whole point of the skill: a reference the agent can quote, from the database.

    The stub refuses /search without the cookie, so reaching the verse at all
    proves the Secure cookie survived the plain-http hop.
    """
    result = run_scripture(siqsermon, "search", "who is the good shepherd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Sign in to continue" not in result.stdout
    assert "John 10:11 (BSB)" in result.stdout
    assert "lays down His life" in result.stdout
    # The older rendering is in the payload and must not be the one quoted.
    assert "giveth his life" not in result.stdout
    assert "cross-refs: Psalms 23:1" in result.stdout
    # A Greek lemma has no transliteration; the word study must not print "None".
    assert "ποιμήν (G4166)" in result.stdout
    assert "None (G4166)" not in result.stdout


def test_a_reference_resolves_to_the_verse_semantic_search_cannot_find(siqsermon: str) -> None:
    """The gap this closes: POST /search answers "John 3:16" with John the Baptist.

    The id is computed here, so this also pins the book numbering: if the table
    ever drifts from SIQsermon's, John stops being the 43rd book and the stub
    404s rather than quietly returning a different verse.
    """
    result = run_scripture(siqsermon, "ref", "John 3:16")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "John 3:16 (BSB)" in result.stdout
    assert "For God so loved the world" in result.stdout


@pytest.mark.parametrize(
    ("reference", "expected"),
    [
        ("John 3:99", "holds nothing at John 3:99"),
        ("Hezekiah 3:1", "not one of the 66 books"),
        ("the bit about the shepherd", "not a reference this can look up"),
        # Four digits used to carry into the next id field: "John 3:1016" read
        # back John 4:16, and "1 Sam 1002:5" read back 2 Samuel 2:5.
        ("John 3:1016", "out of range"),
        ("1 Sam 1002:5", "out of range"),
    ],
)
def test_a_passage_it_cannot_fetch_is_refused_not_invented(
    siqsermon: str, reference: str, expected: str
) -> None:
    """The whole point of sourcing from a database: no reference is ever made up."""
    result = run_scripture(siqsermon, "ref", reference)
    assert result.returncode == 1
    assert expected in result.stderr
    assert result.stdout == ""


def test_a_missing_collection_is_reported_as_breakage_not_as_a_wrong_reference(
    siqsermon_without_verses: str,
) -> None:
    """A collection that is gone says nothing about the reference that was asked for.

    Both failures are a 404, so the earlier client read the collection being
    gone as "there is no such verse" and SKILL.md's relay table turned that into
    a confident "John 3:16 is not in the database" - the invented answer this
    skill exists to prevent.
    """
    result = run_scripture(siqsermon_without_verses, "ref", "John 3:16")
    assert result.returncode == 1
    assert "holds nothing at" not in result.stderr
    assert "verse collection `verses`" in result.stderr
    assert result.stdout == ""


def test_a_missing_account_is_named_not_guessed_at(siqsermon: str) -> None:
    """An unconfigured gateway has to say so; a scripture answer must never be invented."""
    result = run_scripture(siqsermon, "search", "anything", username=None, password=None)
    assert result.returncode == 1
    assert "SIQSERMON_USERNAME" in result.stderr
    assert result.stdout == ""


def test_a_rejected_login_is_reported(siqsermon: str) -> None:
    """A wrong password surfaces as SIQsermon's own refusal, not as an empty result."""
    result = run_scripture(siqsermon, "search", "anything", password="wrong")
    assert result.returncode == 1
    assert "401" in result.stderr
    assert "do not match" in result.stderr


def read_card(result: subprocess.CompletedProcess[str]) -> dict[str, object]:
    """The exact block an assistant can copy into Steward, with no surrounding output."""
    assert result.returncode == 0, result.stdout + result.stderr
    lines = result.stdout.splitlines()
    assert len(lines) == 3
    assert lines[0] == "```steward-card"
    assert lines[-1] == "```"
    card = json.loads(lines[1])
    assert isinstance(card, dict)
    return card


def test_daily_emmaus_reading_returns_the_whole_card_and_bible_link(
    siqsermon: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Synthetic wording makes it clear that the output must come from the DB,
    # not a model's remembered passage. Exercise the reported 23-verse range.
    for verse in range(13, 36):
        monkeypatch.setitem(
            VERSE_POINTS,
            42024000 + verse,
            {
                "ref": f"Luke 24:{verse}",
                "translation": "BSB",
                "text": f"Emmaus fixture {verse}: \u2018Stay with us.\u2019",
            },
        )
    card = read_card(run_scripture(siqsermon, "ref", "Luke 24:13-35", "--card"))
    assert card == {
        "type": "scripture",
        "reference": "Luke 24:13-35",
        "translation": "BSB",
        "verses": [
            {"n": n, "text": f"Emmaus fixture {n}: \u2018Stay with us.\u2019"}
            for n in range(13, 36)
        ],
        "skill": "scripture",
        "link": "https://www.bible.com/bible/3034/LUK.24.13-35.BSB",
    }


@pytest.mark.parametrize("translation,edition", [("BSB", 3034), ("KJV", 1), ("ASV", 12)])
def test_card_link_keeps_the_database_translation(
    siqsermon: str, monkeypatch: pytest.MonkeyPatch, translation: str, edition: int
) -> None:
    monkeypatch.setitem(VERSE_POINTS[43003016], "translation", translation)
    card = read_card(run_scripture(siqsermon, "ref", "John 3:16", "--card"))
    assert card["link"] == f"https://www.bible.com/bible/{edition}/JHN.3.16.{translation}"
    assert card["translation"] == translation
    assert card["verses"] == [{"n": 16, "text": VERSE_POINTS[43003016]["text"]}]


@pytest.mark.parametrize("translation", ["BSB", "KJV", "WEB"])
def test_card_link_opens_the_household_edition_whatever_the_text_is(
    siqsermon: str, monkeypatch: pytest.MonkeyPatch, translation: str
) -> None:
    monkeypatch.setitem(VERSE_POINTS[43003016], "translation", translation)
    card = read_card(run_scripture(siqsermon, "ref", "John 3:16", "--card", bible_version="NIV"))
    assert card["link"] == "https://www.bible.com/bible/111/JHN.3.16.NIV"
    assert card["translation"] == translation
    assert card["verses"] == [{"n": 16, "text": VERSE_POINTS[43003016]["text"]}]


def test_card_refuses_a_household_edition_it_cannot_link(siqsermon: str) -> None:
    result = run_scripture(siqsermon, "ref", "John 3:16", "--card", bible_version="MSG")
    assert result.returncode != 0
    assert "steward-card" not in result.stdout
    assert "HOUSEHOLD_BIBLE_VERSION is MSG" in result.stderr + result.stdout


def test_card_does_not_invent_an_edition_for_an_unmapped_translation(
    siqsermon: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setitem(VERSE_POINTS[43003016], "translation", "WEB")
    card = read_card(run_scripture(siqsermon, "ref", "John 3:16", "--card"))
    assert card["translation"] == "WEB"
    assert "link" not in card


def test_card_refuses_a_partial_passage_before_printing_any_block(siqsermon: str) -> None:
    result = run_scripture(siqsermon, "ref", "John 3:16-17", "--card")
    assert result.returncode == 1
    assert "incomplete" in result.stderr
    assert result.stdout == ""


@pytest.mark.parametrize(
    "change,error",
    [
        ({"ref": "John 4:16"}, "reference mismatches"),
        ({"text": "  "}, "no text"),
        ({"translation": ""}, "translation is missing"),
    ],
)
def test_card_refuses_inconsistent_database_records(
    siqsermon: str, monkeypatch: pytest.MonkeyPatch, change: dict[str, str], error: str
) -> None:
    for key, value in change.items():
        monkeypatch.setitem(VERSE_POINTS[43003016], key, value)
    result = run_scripture(siqsermon, "ref", "John 3:16", "--card")
    assert result.returncode == 1
    assert error in result.stderr
    assert result.stdout == ""


def test_card_refuses_mixed_translations(siqsermon: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(
        VERSE_POINTS,
        43003017,
        {
            "ref": "John 3:17",
            "translation": "KJV",
            "text": "A different edition.",
        },
    )
    result = run_scripture(siqsermon, "ref", "John 3:16-17", "--card")
    assert result.returncode == 1
    assert "mixes translations" in result.stderr
    assert result.stdout == ""
