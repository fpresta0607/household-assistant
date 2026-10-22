"""The scripture skill's links open the household's edition, handed over in the gateway's config."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-scripture.py"
SKILL_SCRIPT = ROOT / "deploy" / "openclaw" / "skills" / "scripture" / "scripture.py"


@pytest.fixture(scope="module")
def scripture() -> ModuleType:
    # On the box the scripts run from their own directory, which puts gateway_config beside them.
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("openclaw_scripture", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_edition_is_the_household_files(scripture: ModuleType) -> None:
    assert scripture.BIBLE_VERSION == "NIV"


def test_a_gateway_without_the_edition_is_reported(scripture: ModuleType) -> None:
    assert scripture.problems({}) == ["the scripture skill's links do not open NIV"]


@pytest.mark.parametrize(
    ("config", "expected"),
    [
        (
            {"skills": {"entries": {"scripture": {"env": {"HOUSEHOLD_BIBLE_VERSION": "BSB"}}}}},
            ["the scripture skill's links do not open NIV"],
        ),
        (
            {
                "skills": {
                    "entries": {
                        "scripture": {"enabled": False, "env": {"HOUSEHOLD_BIBLE_VERSION": "NIV"}}
                    }
                }
            },
            ["the scripture skill is switched off"],
        ),
    ],
)
def test_a_wrong_edition_or_a_switched_off_skill_is_reported(
    scripture: ModuleType, config: dict[str, Any], expected: list[str]
) -> None:
    assert scripture.problems(config) == expected


def test_the_installers_editions_are_the_skills_own(scripture: ModuleType) -> None:
    spec = importlib.util.spec_from_file_location("scripture_skill_under_test", SKILL_SCRIPT)
    assert spec is not None and spec.loader is not None
    skill = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(skill)

    assert scripture.BIBLE_VERSIONS == skill.BIBLE_VERSIONS


@pytest.mark.parametrize("edition", ["ESV", "niv"])
def test_an_edition_the_skill_cannot_link_is_reported(
    scripture: ModuleType, monkeypatch: pytest.MonkeyPatch, edition: str
) -> None:
    monkeypatch.setattr(scripture, "BIBLE_VERSION", edition)
    config = {"skills": {"entries": {"scripture": {"env": {"HOUSEHOLD_BIBLE_VERSION": edition}}}}}

    assert scripture.problems(config) == [
        f"the household's edition {edition} is not one the scripture skill can link"
        " (BSB, KJV, ASV, NIV)"
    ]


@pytest.mark.parametrize("edition", ["ESV", "niv"])
def test_an_edition_the_skill_cannot_link_is_refused_with_nothing_written(
    scripture: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    edition: str,
) -> None:
    monkeypatch.setattr(scripture, "BIBLE_VERSION", edition)
    calls: list[list[str]] = []

    def run(argv: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "", "")

    status = scripture.apply(scripture.GATEWAYS, run=run, dry_run=False)

    assert status == 1
    assert calls == []
    assert capsys.readouterr().err == (
        f"refused, nothing written: the household's edition {edition} is not one the"
        " scripture skill can link (BSB, KJV, ASV, NIV)\n"
    )


def test_the_patch_sets_only_the_edition_and_keeps_the_rest(scripture: ModuleType) -> None:
    before = {
        "skills": {
            "entries": {
                "scripture": {"enabled": True, "env": {"OTHER": "kept"}},
                "coordinate": {"enabled": True},
            }
        },
        "agents": {"defaults": {"model": "kept"}},
    }

    after = scripture.patched(before, scripture.scripture_patch())

    assert after["skills"]["entries"]["scripture"] == {
        "enabled": True,
        "env": {"OTHER": "kept", "HOUSEHOLD_BIBLE_VERSION": "NIV"},
    }
    assert after["skills"]["entries"]["coordinate"] == {"enabled": True}
    assert after["agents"] == before["agents"]
    assert scripture.problems(after) == []
