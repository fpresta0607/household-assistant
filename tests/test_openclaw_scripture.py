"""Both gateways read the Bible through the household-scripture plugin, in the family's edition."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-scripture.py"
MANIFEST = ROOT / "deploy" / "openclaw" / "plugins" / "household-scripture" / "openclaw.plugin.json"
PLUGIN_PATH = "/opt/household-plugins/household-scripture"

HANDED = {
    "plugins": {
        "load": {"paths": [PLUGIN_PATH]},
        "entries": {"household-scripture": {"enabled": True, "config": {"edition": "NIV"}}},
    },
    "tools": {"alsoAllow": ["scripture"]},
}


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


def test_the_installers_editions_are_the_plugins_own(scripture: ModuleType) -> None:
    manifest = json.loads(MANIFEST.read_text())
    schema = manifest["configSchema"]["properties"]
    editions: list[str] = schema["edition"]["enum"]
    assert editions == scripture.EDITIONS
    assert set(schema) == scripture.CONFIG_KEYS


def test_a_gateway_without_the_plugin_is_reported(scripture: ModuleType) -> None:
    assert scripture.problems({}) == [
        f"the household-scripture plugin is not loaded from {PLUGIN_PATH}",
        "the household-scripture plugin is not enabled",
        "scripture cards do not open NIV",
        "the assistant is not handed the scripture tool",
    ]


def test_a_gateway_with_the_plugin_has_no_problems(scripture: ModuleType) -> None:
    assert scripture.problems(HANDED) == []


@pytest.mark.parametrize(
    ("change", "expected"),
    [
        ({"plugins": {"enabled": False}}, "plugins are switched off"),
        ({"plugins": {"deny": ["household-scripture"]}}, "plugins.deny blocks"),
        (
            {"plugins": {"allow": ["household-app"]}},
            "plugins.allow leaves the household-scripture plugin out",
        ),
        (
            {"plugins": {"entries": {"household-scripture": {"config": {"edition": "BSB"}}}}},
            "scripture cards do not open NIV",
        ),
        (
            {"plugins": {"entries": {"household-scripture": {"config": {"siqsermonUrl": "x"}}}}},
            "refuses its config and does not start: it does not know siqsermonUrl",
        ),
        (
            {"skills": {"entries": {"scripture": {"env": {"HOUSEHOLD_BIBLE_VERSION": "NIV"}}}}},
            "the SIQsermon skill's HOUSEHOLD_BIBLE_VERSION is still set",
        ),
    ],
)
def test_each_way_around_the_plugin_is_reported(
    scripture: ModuleType, change: dict[str, Any], expected: str
) -> None:
    config = scripture.patched(HANDED, change)
    assert any(expected in problem for problem in scripture.problems(config)), scripture.problems(
        config
    )


def test_the_patch_hands_over_the_plugin_and_keeps_the_rest(scripture: ModuleType) -> None:
    before = {
        "plugins": {
            "load": {"paths": ["/opt/household-plugins/household-app"]},
            "allow": ["household-app"],
            "entries": {"household-app": {"enabled": True}},
        },
        "tools": {"alsoAllow": ["picture"]},
        "skills": {
            "entries": {
                "scripture": {
                    "enabled": True,
                    "env": {"HOUSEHOLD_BIBLE_VERSION": "NIV", "OTHER": "kept"},
                },
                "coordinate": {"enabled": True},
            }
        },
        "agents": {"defaults": {"model": "kept"}},
    }

    after = scripture.patched(before, scripture.scripture_patch(before))

    assert after["plugins"]["load"]["paths"] == [
        "/opt/household-plugins/household-app",
        PLUGIN_PATH,
    ]
    assert after["plugins"]["allow"] == ["household-app", "household-scripture"]
    assert after["plugins"]["entries"]["household-app"] == {"enabled": True}
    assert after["plugins"]["entries"]["household-scripture"] == {
        "enabled": True,
        "config": {"edition": "NIV"},
    }
    assert after["tools"]["alsoAllow"] == ["picture", "scripture"]
    assert after["skills"]["entries"]["scripture"] == {"enabled": True, "env": {"OTHER": "kept"}}
    assert after["skills"]["entries"]["coordinate"] == {"enabled": True}
    assert after["agents"] == before["agents"]
    assert scripture.problems(after) == []


def test_a_patched_gateway_needs_no_second_patch(scripture: ModuleType) -> None:
    once = scripture.patched({}, scripture.scripture_patch({}))
    assert scripture.patched(once, scripture.scripture_patch(once)) == once


@pytest.mark.parametrize("edition", ["ESV", "niv"])
def test_an_edition_no_card_can_link_is_reported(
    scripture: ModuleType, monkeypatch: pytest.MonkeyPatch, edition: str
) -> None:
    monkeypatch.setattr(scripture, "BIBLE_VERSION", edition)
    assert (
        f"the household's edition {edition} is not one a card can link (BSB, KJV, ASV, NIV)"
        in scripture.problems(HANDED)
    )


@pytest.mark.parametrize("edition", ["ESV", "niv"])
def test_an_edition_no_card_can_link_is_refused_with_nothing_written(
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
        f"refused, nothing written: the household's edition {edition} is not one a card can"
        " link (BSB, KJV, ASV, NIV)\n"
    )


def test_apply_refuses_before_the_plugin_is_installed(
    scripture: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(scripture, "PLUGIN_ON_HOST", tmp_path / "missing" / "openclaw.plugin.json")
    calls: list[list[str]] = []

    def run(argv: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "", "")

    assert scripture.apply(scripture.GATEWAYS, run=run, dry_run=True) == 1
    assert calls == []
    assert "run scripts/openclaw-install.sh first" in capsys.readouterr().err


def test_the_verdict_names_a_bible_not_built_yet(
    scripture: ModuleType, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    gateway = scripture.GATEWAYS[0]
    state = tmp_path / "openclaw"
    state.mkdir()
    (state / "openclaw.json").write_text(json.dumps(HANDED))
    monkeypatch.setattr(scripture, "BIBLE_ON_HOST", tmp_path / "scripture" / "bible.sqlite")
    monkeypatch.setattr(
        scripture,
        "gateway_for",
        lambda container, path: gateway.__class__(
            gateway.persona, gateway.container, state, gateway.person
        ),
    )
    assert (
        scripture.verdict(gateway.container, state)
        == f"{tmp_path / 'scripture' / 'bible.sqlite'} is not built"
    )
    (tmp_path / "scripture").mkdir()
    (tmp_path / "scripture" / "bible.sqlite").write_bytes(b"")
    assert scripture.verdict(gateway.container, state) == "ok"
