"""The Bible database the household-scripture plugin reads, built from its public sources.

The fixtures in tests/fixtures/scripture are a few lines of each source in its real form:
bereanbible.com's text, OpenBible's cross references, and STEPBible's TAHOT and TAGNT word
lines (copied from the files at the pinned commit, CC BY 4.0, STEPBible.org).
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import sqlite3
import stat
import struct
import subprocess
import sys
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "scripture-build.py"
PLUGIN = ROOT / "deploy" / "openclaw" / "plugins" / "household-scripture"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "scripture"

Post = Callable[[str, dict[str, Any], str], dict[str, Any]]


@dataclass(frozen=True)
class Fixture:
    """Where one test's copies of the three sources are."""

    bsb: str
    xrefs: str
    step: str


@pytest.fixture(scope="module")
def build() -> ModuleType:
    spec = importlib.util.spec_from_file_location("scripture_build", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["scripture_build"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def fixture(tmp_path: Path, build: ModuleType) -> Fixture:
    xrefs = tmp_path / "cross-references.zip"
    with zipfile.ZipFile(xrefs, "w") as archive:
        archive.write(FIXTURES / "cross_references.txt", "cross_references.txt")
    step = tmp_path / "step"
    step.mkdir()
    for name in build.STEP_FILES:
        (step / name).write_text("", encoding="utf-8")
    for source, index in (
        ("tahot-gen-deu.txt", 0),
        ("tahot-isa-mal.txt", 3),
        ("tagnt-mat-jhn.txt", 4),
    ):
        shutil.copy(FIXTURES / source, step / build.STEP_FILES[index])
    return Fixture(str(FIXTURES / "bsb.txt"), str(xrefs), str(step))


def built(
    build: ModuleType, fixture: Fixture, out: Path, *, embed: bool = False
) -> sqlite3.Connection:
    sources = build.Sources(fixture.bsb, fixture.xrefs, fixture.step)
    db = build.build(out, sources, min_verses=3, log=lambda _line: None)
    if embed:
        build.embed(db, "BSB", "sk-test", post=fake_post(), dims=4, log=lambda _line: None)
    build.finish(db, out)
    return sqlite3.connect(out)


def fake_post(calls: list[dict[str, Any]] | None = None) -> Post:
    def post(url: str, body: dict[str, Any], key: str) -> dict[str, Any]:
        if calls is not None:
            calls.append({"url": url, "body": body, "key": key})
        inputs = body["input"]
        # Answered out of order, as an API may: the builder must use each item's index.
        data = [
            {"index": index, "embedding": [float(index + 1), 0.0, 0.0, 2.0, 9.0]}
            for index in range(len(inputs))
        ]
        return {"data": list(reversed(data))}

    return post


def test_the_verses_are_the_bsb_texts_own_lines(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    db = built(build, fixture, tmp_path / "bible.sqlite")
    rows = db.execute(
        "SELECT id, text FROM verses WHERE translation = 'BSB' ORDER BY id"
    ).fetchall()
    assert [row[0] for row in rows] == [1001001, 19023001, 39004001, 40001001, 43003016, 45005008]
    assert rows[0][1] == "In the beginning God created the heavens and the earth."
    assert rows[2][1].startswith("“For behold")
    meta = dict(db.execute("SELECT key, value FROM meta").fetchall())
    assert meta["schema_version"] == "1"
    assert json.loads(meta["translations"]) == ["BSB"]
    assert meta["step_commit"] == build.STEP_COMMIT
    assert "embedding_model" not in meta


def test_the_word_index_finds_a_verse_by_its_words(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    db = built(build, fixture, tmp_path / "bible.sqlite")
    found = db.execute(
        "SELECT rowid FROM verses_fts WHERE verses_fts MATCH ? ORDER BY bm25(verses_fts)",
        ('"shepherd"',),
    ).fetchall()
    assert found == [(19023001,)]


def test_cross_references_keep_ranges_and_votes(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    db = built(build, fixture, tmp_path / "bible.sqlite")
    rows = db.execute("SELECT * FROM xrefs ORDER BY from_id, votes DESC").fetchall()
    assert rows == [
        (1001001, 43001001, 43001003, 393),
        (43003016, 45005008, 45005008, 120),
        (43003016, 20008022, 20008030, 41),
        (43003016, 1001001, 1001001, -3),
    ]


def test_words_are_the_main_hebrew_and_greek_words_of_each_verse(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    db = built(build, fixture, tmp_path / "bible.sqlite")

    def strongs(verse: int) -> list[tuple[str, str, str]]:
        return db.execute(
            "SELECT strongs, translit, gloss FROM words WHERE verse_id = ? ORDER BY position",
            (verse,),
        ).fetchall()

    # The prefixes (H9003, H9009) and the object marker (H0853) are not words to study.
    assert strongs(1001001) == [
        ("H7225G", "bereshit", "beginning"),
        ("H1254A", "bara'", "to create"),
        ("H8064", "hashamayim", "heaven"),
    ]
    # English versification: Malachi 4:1 is Hebrew 3:19.
    assert strongs(39004001) == [("H2009", "hineh", "behold")]
    # Only the Nestle-Aland text, and never the article.
    assert strongs(43003016) == [
        ("G3779", "Houtōs", "thus(-ly)"),
        ("G0025", "ēgapēsen", "to love"),
        ("G2889", "kosmon", "world"),
    ]
    lemma = db.execute("SELECT lemma FROM words WHERE strongs = 'G2889'").fetchone()[0]
    assert lemma == "κόσμος"


def test_the_sources_and_their_licenses_are_recorded(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    db = built(build, fixture, tmp_path / "bible.sqlite")
    licenses = dict(db.execute("SELECT name, license FROM sources").fetchall())
    assert licenses == {
        "Berean Standard Bible": "Public domain",
        "OpenBible.info cross references": "CC BY",
        "STEPBible TAHOT and TAGNT": "CC BY 4.0",
    }


def test_the_file_is_readable_by_the_gateway_and_nothing_is_left_behind(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    out = tmp_path / "scripture" / "bible.sqlite"
    built(build, fixture, out)
    assert stat.S_IMODE(out.stat().st_mode) == 0o644
    assert [path.name for path in out.parent.iterdir()] == ["bible.sqlite"]


def test_meaning_vectors_are_cut_scaled_and_in_verse_order(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    sources = build.Sources(fixture.bsb, fixture.xrefs, fixture.step)
    db = build.build(tmp_path / "bible.sqlite", sources, min_verses=3, log=lambda _line: None)
    calls: list[dict[str, Any]] = []
    done = build.embed(db, "BSB", "sk-test", post=fake_post(calls), dims=4, log=lambda _line: None)
    build.finish(db, tmp_path / "bible.sqlite")
    assert done == 6
    assert calls[0]["key"] == "sk-test"
    assert calls[0]["body"]["model"] == "openai/text-embedding-3-small"
    assert calls[0]["body"]["input"][0] == "In the beginning God created the heavens and the earth."
    db = sqlite3.connect(tmp_path / "bible.sqlite")
    first = db.execute("SELECT vector FROM vectors WHERE id = 1001001").fetchone()[0]
    values = struct.unpack("<4f", first)
    # [1, 0, 0, 2] cut to four numbers and scaled to length 1; the fifth number is dropped.
    assert values == pytest.approx((1 / 5**0.5, 0.0, 0.0, 2 / 5**0.5))
    meta = dict(db.execute("SELECT key, value FROM meta").fetchall())
    assert (meta["embedding_model"], meta["embedding_dims"]) == (
        "openai/text-embedding-3-small",
        "4",
    )


def test_a_short_answer_from_openrouter_writes_no_vectors(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    sources = build.Sources(fixture.bsb, fixture.xrefs, fixture.step)
    db = build.build(tmp_path / "bible.sqlite", sources, min_verses=3, log=lambda _line: None)

    def short(url: str, body: dict[str, Any], key: str) -> dict[str, Any]:
        return {"data": [{"index": 0, "embedding": [1.0, 0.0, 0.0, 0.0]}]}

    with pytest.raises(build.BuildError, match="different number of embeddings"):
        build.embed(db, "BSB", "sk-test", post=short, dims=4, log=lambda _line: None)


def test_a_source_with_too_few_verses_writes_nothing(
    build: ModuleType, fixture: Fixture, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    out = tmp_path / "bible.sqlite"
    arguments = ["--out", str(out), "--bsb", fixture.bsb, "--xrefs", fixture.xrefs]
    status = build.main([*arguments, "--step-base", fixture.step])
    assert status == 1
    assert "BSB gave 6 verses, fewer than 30000" in capsys.readouterr().err
    assert not out.exists()


def test_the_key_comes_from_the_environment_or_the_env_file(
    build: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    env_file = tmp_path / "openclaw.env"
    env_file.write_text("OPENCLAW_GATEWAY_TOKEN=abc\nOPENROUTER_API_KEY='sk-from-file'\n")
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    assert build.key_from(env_file) == "sk-from-file"
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-from-env")
    assert build.key_from(env_file) == "sk-from-env"
    monkeypatch.delenv("OPENROUTER_API_KEY")
    with pytest.raises(build.BuildError, match="no OPENROUTER_API_KEY"):
        build.key_from(None)


def test_an_extra_translation_needs_a_name_and_a_source(build: ModuleType) -> None:
    assert build._pair("KJV=https://example.org/kjv.txt") == ("KJV", "https://example.org/kjv.txt")
    with pytest.raises(build.BuildError, match="NAME=URL"):
        build._pair("https://example.org/kjv.txt")


def test_the_plugin_reads_what_the_builder_writes(
    build: ModuleType, fixture: Fixture, tmp_path: Path
) -> None:
    """The two halves agree on the schema: node opens the file with the plugin's own code."""
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is not installed")
    out = tmp_path / "bible.sqlite"
    built(build, fixture, out, embed=True)
    script = f"""
      import {{ Bible }} from {json.dumps((PLUGIN / "bible.js").as_uri())};
      const bible = new Bible({json.dumps(str(out))});
      const hits = bible.byMeaning([0, 0, 0, 1], 2).map((hit) => hit.id);
      console.log(JSON.stringify({{
        text: bible.text(43003016),
        xrefs: bible.crossReferences(43003016).map((x) => x.label),
        words: bible.words(43003016).map((w) => w.strongs),
        byWords: bible.byWords("shepherd", 3).map((hit) => hit.id),
        hits,
        dims: bible.embeddingDims,
      }}));
    """
    result = subprocess.run(
        [node, "--input-type=module", "-e", script], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr
    read = json.loads(result.stdout)
    assert read["text"] == "For God so loved the world that He gave His one and only Son."
    assert read["xrefs"] == ["Romans 5:8", "Proverbs 8:22-30"]
    assert read["words"] == ["G3779", "G0025", "G2889"]
    assert read["byWords"] == [19023001]
    assert read["dims"] == 4
    assert len(read["hits"]) == 2
