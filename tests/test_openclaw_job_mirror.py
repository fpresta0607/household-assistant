"""openclaw-job-mirror.py: each scheduled message on Telegram reaches the app too.

Every briefing and reminder on both gateways delivers to a Telegram chat, so the app
never hears of them and they would go silent the day Telegram is turned off. This
script hands each gateway the household-job-mirror plugin, set up for its owner's chat
and The Fam, and checks both, without touching what the PocketPiggies guard holds.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from tests.capabilities import needs_nofollow_open

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-job-mirror.py"
INSTALLER = ROOT / "scripts" / "pocket-piggies-install.py"

GROUP = "-5100000001"
FRANCO = "7100000001"
GIA = "7100000002"
GROUP_TOOLS = ["web_search", "web_fetch", "speak", "family_history", "picture"]
FINANCE = ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]
MIRROR = "/opt/household-plugins/household-job-mirror"


def load(name: str, path: Path) -> ModuleType:
    # On the box the scripts run from their own directory, which puts gateway_config
    # on the import path; here the test has to.
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def mirror() -> ModuleType:
    return load("openclaw_job_mirror", SCRIPT)


@pytest.fixture(scope="module")
def installer() -> ModuleType:
    return load("pocket_piggies_install", INSTALLER)


def as_on_the_box(owner: str = FRANCO, persona: str = "corey") -> dict[str, Any]:
    person = "franco" if persona == "corey" else "gia"
    return {
        "plugins": {
            "entries": {
                "household-family-room": {"enabled": True, "config": {"groupChatId": GROUP}},
                "pocket-piggies": {
                    "enabled": True,
                    "config": {"ownerTelegramId": owner, "accountLabel": persona},
                },
            },
            "load": {
                "paths": [
                    "/opt/household-plugins/household-family-room",
                    f"/opt/household-plugins/pocket-piggies-{persona}",
                ]
            },
        },
        "tools": {"profile": "coding", "alsoAllow": ["speak", "family_history", *FINANCE]},
        "channels": {
            "telegram": {
                "enabled": True,
                "groupPolicy": "allowlist",
                "groups": {
                    GROUP: {"allowFrom": [FRANCO, GIA], "tools": {"allow": list(GROUP_TOOLS)}}
                },
                "dmPolicy": "allowlist",
                "allowFrom": [owner],
            },
            "household": {
                "enabled": True,
                "owner": {"id": person, "name": person.title()},
                "familyTools": list(GROUP_TOOLS),
            },
        },
        "commands": {"ownerAllowFrom": [f"telegram:{owner}", f"household:{person}"]},
        "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
    }


@pytest.mark.parametrize(
    ("persona", "owner", "person"), [("corey", FRANCO, "franco"), ("denise", GIA, "gia")]
)
def test_the_patch_copies_the_owners_chat_and_the_fam_and_leaves_nothing(
    mirror: ModuleType, persona: str, owner: str, person: str
) -> None:
    config = as_on_the_box(owner, persona)
    assert mirror.problems(config, persona) != []

    result = mirror.patched(config, mirror.mirror_patch(config, persona))

    assert mirror.problems(result, persona) == []
    entry = result["plugins"]["entries"]["household-job-mirror"]
    assert entry == {
        "enabled": True,
        "config": {"targets": {owner: person, GROUP: "family"}},
        "hooks": {"allowConversationAccess": True},
    }
    assert result["plugins"]["load"]["paths"][-1] == MIRROR
    assert result["plugins"]["load"]["paths"][:-1] == config["plugins"]["load"]["paths"]
    assert (
        result["plugins"]["entries"]["pocket-piggies"]
        == config["plugins"]["entries"]["pocket-piggies"]
    )


@pytest.mark.parametrize(("persona", "owner"), [("corey", FRANCO), ("denise", GIA)])
def test_the_pocketpiggies_guard_finds_nothing_to_put_back(
    mirror: ModuleType, installer: ModuleType, persona: str, owner: str
) -> None:
    config = as_on_the_box(owner, persona)
    patch = mirror.mirror_patch(config, persona)
    result = mirror.patched(config, patch)

    # The guard does the same with the plugin as without it, and keeps the plugin.
    guarded = installer.configured(config, persona, owner)
    assert installer.configured(result, persona, owner) == mirror.patched(guarded, patch)
    assert result["channels"] == config["channels"]
    assert result["session"] == config["session"]
    assert result["tools"] == config["tools"]


def test_a_gateway_that_already_has_it_gets_an_empty_patch(mirror: ModuleType) -> None:
    config = as_on_the_box()
    done = mirror.patched(config, mirror.mirror_patch(config, "corey"))

    assert mirror.patched(done, mirror.mirror_patch(done, "corey")) == done


@pytest.mark.parametrize("permission", [None, False, True])
def test_complete_output_permission_preserves_existing_plugin_policies(
    mirror: ModuleType, permission: bool | None
) -> None:
    config = as_on_the_box()
    config["plugins"]["entries"]["household-job-mirror"] = {
        "enabled": True,
        "config": mirror.expected_settings("corey"),
        "hooks": {"allowPromptInjection": False},
    }
    hooks = config["plugins"]["entries"]["household-job-mirror"]["hooks"]
    if permission is not None:
        hooks["allowConversationAccess"] = permission
    config["plugins"]["allow"] = ["pocket-piggies"]
    config["plugins"]["deny"] = ["untrusted-plugin"]

    result = mirror.patched(config, mirror.mirror_patch(config, "corey"))

    assert result["plugins"]["entries"]["household-job-mirror"]["hooks"] == {
        "allowPromptInjection": False,
        "allowConversationAccess": True,
    }
    assert result["plugins"]["allow"] == ["pocket-piggies", "household-job-mirror"]
    assert result["plugins"]["deny"] == ["untrusted-plugin"]
    assert (
        result["plugins"]["entries"]["pocket-piggies"]
        == config["plugins"]["entries"]["pocket-piggies"]
    )
    assert result["channels"] == config["channels"]
    assert result["tools"] == config["tools"]
    assert mirror.problems(result, "corey") == []


@pytest.mark.parametrize("hooks", [{}, {"allowConversationAccess": False}])
def test_missing_complete_output_permission_is_reported(
    mirror: ModuleType, hooks: dict[str, bool]
) -> None:
    config = as_on_the_box()
    config = mirror.patched(config, mirror.mirror_patch(config, "corey"))
    config["plugins"]["entries"]["household-job-mirror"]["hooks"] = hooks

    assert any("allowConversationAccess" in problem for problem in mirror.problems(config, "corey"))


@pytest.mark.parametrize(
    ("change", "problem"),
    [
        (lambda c: c["plugins"].update(enabled=False), "plugins are switched off"),
        (lambda c: c["plugins"].update(deny=["household-job-mirror"]), "plugins.deny blocks"),
        (lambda c: c["plugins"].update(allow=["telegram"]), "plugins.allow leaves"),
        (lambda c: c["channels"].pop("household"), "nowhere to go"),
        (
            lambda c: c["plugins"]["entries"]["household-job-mirror"].update(
                config={"targets": {FRANCO: "franco"}}
            ),
            "not set up for The Fam and franco",
        ),
    ],
)
def test_each_way_a_copy_could_still_be_lost_is_reported(
    mirror: ModuleType, change: Callable[[dict[str, Any]], object], problem: str
) -> None:
    config = as_on_the_box()
    config = mirror.patched(config, mirror.mirror_patch(config, "corey"))
    change(config)

    assert any(problem in line for line in mirror.problems(config, "corey"))


def write_state(path: Path, config: dict[str, Any]) -> Path:
    path.mkdir(parents=True)
    (path / "openclaw.json").write_text(json.dumps(config))
    return path


class FakeGateways:
    """`docker exec ... config patch`, against config files on disk."""

    def __init__(self, mirror: ModuleType, states: dict[str, Path]) -> None:
        self.mirror = mirror
        self.states = states
        self.writes: list[str] = []

    def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        assert argv[:3] == ["docker", "exec", "-i"], argv
        container, command = argv[3], argv[6:]
        assert command[:3] == ["config", "patch", "--stdin"], command
        if "--dry-run" in command:
            return subprocess.CompletedProcess(argv, 0, json.dumps({"ok": True}), "")
        path = self.states[container] / "openclaw.json"
        merged = self.mirror.patched(json.loads(path.read_text()), json.loads(str(kwargs["input"])))
        path.write_text(json.dumps(merged))
        self.writes.append(container)
        return subprocess.CompletedProcess(argv, 0, "Applied.", "")


@pytest.fixture(autouse=True)
def installed_plugin(mirror: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    manifest: Path = tmp_path / "plugins" / str(mirror.PLUGIN) / "openclaw.plugin.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(json.dumps({"id": mirror.PLUGIN}))
    monkeypatch.setattr(mirror, "PLUGIN_ON_HOST", manifest)
    return manifest


@pytest.fixture
def gateways(mirror: ModuleType, tmp_path: Path) -> tuple[Any, ...]:
    corey = write_state(tmp_path / "openclaw", as_on_the_box())
    denise = write_state(tmp_path / "openclaw-denise", as_on_the_box(GIA, "denise"))
    return (
        mirror.Gateway("corey", "openclaw-gateway", corey, "franco"),
        mirror.Gateway("denise", "openclaw-denise", denise, "gia"),
    )


@needs_nofollow_open
def test_apply_backs_up_and_writes_one_gateway_and_leaves_the_other(
    mirror: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    corey, denise = gateways
    fake = FakeGateways(mirror, {g.container: g.state for g in gateways})
    before = corey.config_path.read_bytes()
    untouched = denise.config_path.read_bytes()

    assert mirror.apply([corey], run=fake, dry_run=False) == 0

    assert fake.writes == ["openclaw-gateway"]
    assert mirror.problems(json.loads(corey.config_path.read_text()), "corey") == []
    (saved,) = corey.state.glob("openclaw.json.pre-job-mirror-*")
    assert saved.read_bytes() == before
    assert str(saved) in capsys.readouterr().out
    assert denise.config_path.read_bytes() == untouched
    assert mirror.apply([corey], run=fake, dry_run=False) == 0
    assert fake.writes == ["openclaw-gateway"]


@needs_nofollow_open
def test_a_dry_run_validates_and_writes_nothing(
    mirror: ModuleType, gateways: tuple[Any, ...]
) -> None:
    fake = FakeGateways(mirror, {g.container: g.state for g in gateways})
    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert mirror.apply(gateways, run=fake, dry_run=True) == 0

    assert fake.writes == []
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]


def test_apply_refuses_until_the_plugin_is_installed(
    mirror: ModuleType,
    gateways: tuple[Any, ...],
    installed_plugin: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    installed_plugin.unlink()
    fake = FakeGateways(mirror, {g.container: g.state for g in gateways})

    assert mirror.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == []
    assert "not installed" in capsys.readouterr().err
