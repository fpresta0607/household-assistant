"""openclaw-memory.py: what a family member asks to keep lasts, and older chats are found.

On 13 October the family group change kept private chats one session per person. In
OpenClaw 2026.9.4 that also turns off a default, "remember across conversations", which
took chat transcripts out of the memory index, so the index no longer matched its
settings and every memory search after it answered "paused". This script names
transcripts as a memory source outright, hands each gateway the household-memory
plugin, and checks both, without touching what the PocketPiggies guard holds.

The config below is Corey's shape on 14 October, read from the box, cut to the keys
that matter here. The apply tests replace `docker exec` with a runner that applies the
patch to the file the way `openclaw config patch` does.

Since the family stopped using Telegram the plugin knows them by their household person
ids alone, and a gateway still on the Telegram settings it was first given is moved off
them.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from tests.capabilities import needs_nofollow_open

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-memory.py"
INSTALLER = ROOT / "scripts" / "pocket-piggies-install.py"

GROUP = "-5100000001"
FRANCO = "7100000001"
GIA = "7100000002"
FINANCE = ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]
GROUP_TOOLS = [
    "web_search",
    "web_fetch",
    "family_history",
    "picture",
    "video",
    "household_location",
    "household_cart",
    "household_home",
    "household_react",
    "household_note",
    "scripture",
]
MEMORY = "/opt/household-plugins/household-memory"
PEOPLE = {"franco": "Franco", "gia": "Gia"}
# The plugin's config as openclaw-memory.py wrote it while the family used Telegram.
TELEGRAM_SETTINGS = {
    "groupChatId": GROUP,
    "ownerTelegramId": FRANCO,
    "people": {FRANCO: "Franco", GIA: "Gia"},
    "appPeople": {FRANCO: "franco", GIA: "gia"},
}


def load(name: str, path: Path) -> ModuleType:
    # On the box the scripts run from their own directory, which puts gateway_config
    # on the import path; here the test has to.
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # Dataclasses resolve their annotations through sys.modules.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def memory() -> ModuleType:
    return load("openclaw_memory", SCRIPT)


@pytest.fixture(scope="module")
def installer() -> ModuleType:
    return load("pocket_piggies_install", INSTALLER)


def as_on_the_box(owner: str = FRANCO, persona: str = "corey") -> dict[str, Any]:
    return {
        "agents": {
            "entries": {
                "main": {
                    "name": "main",
                    "memory": {
                        "search": {
                            "provider": "openai",
                            "model": "openai/text-embedding-3-small",
                            "remote": {"baseUrl": "https://openrouter.ai/api/v1"},
                        }
                    },
                }
            }
        },
        "memory": {"search": {"provider": "none"}},
        "plugins": {
            "entries": {
                "household-family-room": {
                    "enabled": True,
                    "hooks": {"allowConversationAccess": True},
                    "config": {"groupChatId": GROUP},
                },
                "pocket-piggies": {
                    "enabled": True,
                    "config": {
                        "ownerHouseholdPersonId": "franco" if persona == "corey" else "gia",
                        "accountLabel": persona,
                    },
                },
            },
            "load": {
                "paths": [
                    "/opt/household-plugins/household-family-room",
                    f"/opt/household-plugins/pocket-piggies-{persona}",
                ]
            },
        },
        "tools": {
            "profile": "coding",
            "alsoAllow": ["speak", "family_history", *FINANCE],
            "deny": ["codex", "memory-wiki", "onepassword"],
        },
        "channels": {
            "telegram": {
                "enabled": True,
                "groupPolicy": "allowlist",
                "groups": {
                    GROUP: {
                        "requireMention": True,
                        "allowFrom": [FRANCO, GIA],
                        "tools": {"allow": list(GROUP_TOOLS)},
                    }
                },
                "dmPolicy": "allowlist",
                "allowFrom": [owner],
            }
        },
        "commands": {"ownerAllowFrom": [f"telegram:{owner}"]},
        "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
    }


def test_todays_gateway_is_named_on_every_count(memory: ModuleType) -> None:
    assert memory.problems(as_on_the_box(), "corey") == [
        f"the household-memory plugin is not loaded from {MEMORY}",
        "the household-memory plugin is not enabled",
        "the household-memory plugin may not read the turn, so it keeps and shows nothing",
        "the household-memory plugin is not set up for franco and the family by their "
        "household person ids",
        "the assistant is not handed recall and forget in its private chat",
        "chat transcripts are not a memory source, so memory search leaves out older chats "
        "and pauses whenever the session setting changes",
    ]


@pytest.mark.parametrize("dm_scope", ["main", "per-channel-peer"])
def test_transcripts_stay_indexed_whatever_the_dm_scope(memory: ModuleType, dm_scope: str) -> None:
    config = as_on_the_box()
    config["session"]["dmScope"] = dm_scope
    before = memory.indexed_sources(config)
    after = memory.indexed_sources(memory.patched(config, memory.memory_patch(config, "corey")))
    # The flip that paused search on 13 October, and the setting that ends it.
    assert before == (["memory", "sessions"] if dm_scope == "main" else ["memory"])
    assert after == ["memory", "sessions"]


@pytest.mark.parametrize(
    ("persona", "owner", "person"), [("corey", FRANCO, "franco"), ("denise", GIA, "gia")]
)
def test_the_patch_leaves_nothing_and_keeps_what_was_there(
    memory: ModuleType, persona: str, owner: str, person: str
) -> None:
    config = as_on_the_box(owner, persona)
    result = memory.patched(config, memory.memory_patch(config, persona))

    assert memory.problems(result, persona) == []
    search = result["agents"]["entries"]["main"]["memory"]["search"]
    assert search["provider"] == "openai"
    assert search["model"] == "openai/text-embedding-3-small"
    assert search["remote"] == {"baseUrl": "https://openrouter.ai/api/v1"}
    assert result["memory"] == {"search": {"provider": "none"}}
    entry = result["plugins"]["entries"]["household-memory"]
    assert entry["config"] == {"ownerPersonId": person, "people": PEOPLE}
    assert result["tools"]["alsoAllow"] == ["speak", "family_history", "recall", "forget", *FINANCE]


@pytest.mark.parametrize(
    ("persona", "owner", "person"), [("corey", FRANCO, "franco"), ("denise", GIA, "gia")]
)
def test_the_pocketpiggies_guard_finds_nothing_to_put_back(
    memory: ModuleType, installer: ModuleType, persona: str, owner: str, person: str
) -> None:
    before = as_on_the_box(owner, persona)
    before["commands"]["ownerAllowFrom"].append(f"household:{person}")
    before["channels"]["household"] = {"owner": {"id": person}}
    config = installer.configured(before, persona, person)
    result = memory.patched(config, memory.memory_patch(config, persona))

    assert installer.configured(result, persona, person) == result
    assert result["channels"] == config["channels"]
    assert result["session"] == config["session"]


def on_telegram_settings(memory: ModuleType, owner: str, persona: str) -> dict[str, Any]:
    """A gateway that had the plugin while the family used Telegram."""
    before = as_on_the_box(owner, persona)
    config: dict[str, Any] = memory.patched(before, memory.memory_patch(before, persona))
    config["plugins"]["entries"]["household-memory"]["config"] = {
        **TELEGRAM_SETTINGS,
        "ownerTelegramId": owner,
    }
    return config


@pytest.mark.parametrize(
    ("persona", "owner", "person"), [("corey", FRANCO, "franco"), ("denise", GIA, "gia")]
)
def test_a_gateway_on_the_telegram_settings_is_moved_to_household_person_ids(
    memory: ModuleType, persona: str, owner: str, person: str
) -> None:
    config = on_telegram_settings(memory, owner, persona)
    assert memory.problems(config, persona) == [
        "the household-memory plugin still has its Telegram settings "
        "(groupChatId, ownerTelegramId, appPeople), which it refuses, so it keeps and shows nothing"
    ]
    assert memory.keeps_for(config).startswith("nobody")

    patch = memory.memory_patch(config, persona)
    # Each Telegram key and id goes, by a null, since a patch merges objects.
    assert patch["plugins"]["entries"]["household-memory"]["config"] == {
        "groupChatId": None,
        "ownerTelegramId": None,
        "appPeople": None,
        "ownerPersonId": person,
        "people": {FRANCO: None, GIA: None, **PEOPLE},
    }
    result = memory.patched(config, patch)
    entry = result["plugins"]["entries"]["household-memory"]
    assert entry["config"] == memory.expected_settings(persona)
    for telegram_id in (GROUP, FRANCO, GIA):
        assert telegram_id not in json.dumps(entry)
    assert memory.problems(result, persona) == []
    assert memory.patched(result, memory.memory_patch(result, persona)) == result


def test_telegram_ids_left_beside_the_person_ids_are_taken_out(memory: ModuleType) -> None:
    config = as_on_the_box()
    config = memory.patched(config, memory.memory_patch(config, "corey"))
    settings = config["plugins"]["entries"]["household-memory"]["config"]
    settings["people"] = {**settings["people"], FRANCO: "Franco"}

    assert memory.problems(config, "corey") == [
        "the household-memory plugin is not set up for franco and the family by their "
        "household person ids"
    ]
    result = memory.patched(config, memory.memory_patch(config, "corey"))
    assert result["plugins"]["entries"]["household-memory"]["config"] == {
        "ownerPersonId": "franco",
        "people": PEOPLE,
    }


def test_a_gateway_that_already_has_it_gets_an_empty_patch(memory: ModuleType) -> None:
    config = as_on_the_box()
    done = memory.patched(config, memory.memory_patch(config, "corey"))
    assert memory.patched(done, memory.memory_patch(done, "corey")) == done


def test_a_plugin_policy_that_blocks_it_is_reported(memory: ModuleType) -> None:
    config = as_on_the_box()
    config = memory.patched(config, memory.memory_patch(config, "corey"))
    config["plugins"]["deny"] = ["household-memory"]
    assert "plugins.deny blocks the household-memory plugin" in memory.problems(config, "corey")


def write_state(path: Path, config: dict[str, Any]) -> Path:
    path.mkdir(parents=True)
    (path / "openclaw.json").write_text(json.dumps(config))
    return path


class FakeGateways:
    """`docker exec ... config patch`, against config files on disk."""

    def __init__(self, memory: ModuleType, states: dict[str, Path]) -> None:
        self.memory = memory
        self.states = states
        self.writes: list[str] = []

    def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        assert argv[:3] == ["docker", "exec", "-i"], argv
        container, command = argv[3], argv[6:]
        assert command[:3] == ["config", "patch", "--stdin"], command
        if "--dry-run" in command:
            return subprocess.CompletedProcess(argv, 0, json.dumps({"ok": True}), "")
        path = self.states[container] / "openclaw.json"
        merged = self.memory.patched(json.loads(path.read_text()), json.loads(str(kwargs["input"])))
        path.write_text(json.dumps(merged))
        self.writes.append(container)
        return subprocess.CompletedProcess(argv, 0, "Applied.", "")


@pytest.fixture(autouse=True)
def installed_plugin(memory: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    manifest: Path = tmp_path / "plugins" / str(memory.PLUGIN) / "openclaw.plugin.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(json.dumps({"id": memory.PLUGIN}))
    monkeypatch.setattr(memory, "PLUGIN_ON_HOST", manifest)
    return manifest


@pytest.fixture
def gateways(memory: ModuleType, tmp_path: Path) -> tuple[Any, ...]:
    corey = write_state(tmp_path / "openclaw", as_on_the_box())
    denise = write_state(tmp_path / "openclaw-denise", as_on_the_box(GIA, "denise"))
    return (
        memory.Gateway("corey", "openclaw-gateway", corey, "franco"),
        memory.Gateway("denise", "openclaw-denise", denise, "gia"),
    )


@needs_nofollow_open
def test_apply_backs_up_and_writes_one_gateway_and_leaves_the_other(
    memory: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    corey, denise = gateways
    fake = FakeGateways(memory, {g.container: g.state for g in gateways})
    before = corey.config_path.read_bytes()
    untouched = denise.config_path.read_bytes()

    assert memory.apply([corey], run=fake, dry_run=False) == 0

    assert fake.writes == ["openclaw-gateway"]
    assert memory.problems(json.loads(corey.config_path.read_text()), "corey") == []
    (saved,) = corey.state.glob("openclaw.json.pre-memory-*")
    assert saved.read_bytes() == before
    assert str(saved) in capsys.readouterr().out
    assert denise.config_path.read_bytes() == untouched
    assert list(denise.state.glob("openclaw.json.pre-memory-*")) == []
    assert memory.apply([corey], run=fake, dry_run=False) == 0
    assert fake.writes == ["openclaw-gateway"]


@needs_nofollow_open
def test_apply_moves_a_gateway_off_the_telegram_settings_and_check_says_whose_it_keeps(
    memory: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    state = write_state(tmp_path / "openclaw", on_telegram_settings(memory, FRANCO, "corey"))
    corey = memory.Gateway("corey", "openclaw-gateway", state, "franco")
    fake = FakeGateways(memory, {corey.container: corey.state})

    assert memory.check([corey]) == 1
    before = capsys.readouterr().out
    assert "  keeps for    nobody: it still has the Telegram settings" in before
    assert "still has its Telegram settings (groupChatId, ownerTelegramId, appPeople)" in before

    assert memory.apply([corey], run=fake, dry_run=False) == 0

    after = capsys.readouterr().out
    assert "  keeps for    franco (Franco), with gia (Gia)\n" in after
    assert "  verdict      kept requests and older chats are covered\n" in after
    written = json.loads(corey.config_path.read_text())
    assert written["plugins"]["entries"]["household-memory"]["config"] == {
        "ownerPersonId": "franco",
        "people": PEOPLE,
    }


@needs_nofollow_open
def test_a_dry_run_validates_and_writes_nothing(
    memory: ModuleType, gateways: tuple[Any, ...]
) -> None:
    fake = FakeGateways(memory, {g.container: g.state for g in gateways})
    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert memory.apply(gateways, run=fake, dry_run=True) == 0

    assert fake.writes == []
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]
        assert list(gateway.state.glob("openclaw.json.pre-memory-*")) == []


def test_apply_refuses_until_the_plugin_is_installed(
    memory: ModuleType,
    gateways: tuple[Any, ...],
    installed_plugin: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    installed_plugin.unlink()
    fake = FakeGateways(memory, {g.container: g.state for g in gateways})

    assert memory.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == []
    assert "not installed" in capsys.readouterr().err
