"""openclaw-pictures.py: the household-pictures plugin makes pictures and videos, under a ceiling.

OpenClaw's own image_generate and video_generate drop the cost OpenRouter reports for each
request, so nothing could hold a day's spend. The plugin in
deploy/openclaw/plugins/household-pictures replaces them. This script is what hands it to
both gateways and says, from each gateway's config, whether a picture or a video could
still go around it.

The first config below is the shape both gateways had on 17 October 2026, read from the
box. The apply tests replace `docker exec` with a runner that applies the patch to the
file the way `openclaw config patch` does.
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
SCRIPT = ROOT / "scripts" / "openclaw-pictures.py"

SPEECH = "/opt/household-plugins/household-speech"
PICTURES = "/opt/household-plugins/household-pictures"
CEILINGS = {"pictureDayDollars": 2.0, "videoDayDollars": 3.0}


@pytest.fixture(scope="module")
def pictures() -> ModuleType:
    # On the box the scripts run from their own directory, which puts gateway_config on the
    # import path; here the test has to.
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("openclaw_pictures", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # Dataclasses resolve their annotations through sys.modules.
    sys.modules["openclaw_pictures"] = module
    spec.loader.exec_module(module)
    return module


def as_on_the_box() -> dict[str, Any]:
    """OpenClaw's own media tools, as both gateways ran them on 17 October."""
    return {
        "agents": {
            "defaults": {
                "mediaModels": {
                    "image": {"primary": "openrouter/openai/gpt-5.4-image-2"},
                    "video": {"primary": "openrouter/google/veo-3.1-fast"},
                }
            }
        },
        "tools": {
            "profile": "coding",
            "alsoAllow": ["speak", "household_home"],
            "deny": ["codex", "memory-wiki", "onepassword"],
        },
        "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
        "plugins": {
            "load": {"paths": [SPEECH]},
            "entries": {"household-speech": {"enabled": True}},
        },
    }


def test_a_gateway_still_on_the_built_in_tools_is_named_on_every_count(
    pictures: ModuleType,
) -> None:
    assert pictures.problems(as_on_the_box()) == [
        f"the household-pictures plugin is not loaded from {PICTURES}",
        "the household-pictures plugin is not enabled",
        "no pictureDayDollars ceiling is set",
        "no videoDayDollars ceiling is set",
        "the assistant is not handed picture, video",
        "the assistant is still handed OpenClaw's own image_generate, video_generate, "
        "which no ceiling covers",
    ]


def test_the_patch_hands_over_both_tools_and_keeps_what_every_list_already_held(
    pictures: ModuleType,
) -> None:
    config = as_on_the_box()
    config["plugins"]["allow"] = ["household-speech"]

    after = pictures.patched(config, pictures.pictures_patch(config))

    assert pictures.problems(after) == []
    # A patch replaces a list whole, so each is written back with what it held.
    assert after["tools"] == {
        "profile": "coding",
        "alsoAllow": ["speak", "household_home", "picture", "video"],
        "deny": ["codex", "memory-wiki", "onepassword", "image_generate", "video_generate"],
    }
    assert after["plugins"]["load"]["paths"] == [SPEECH, PICTURES]
    assert after["plugins"]["allow"] == ["household-speech", "household-pictures"]
    assert after["plugins"]["entries"]["household-pictures"] == {
        "enabled": True,
        "config": CEILINGS,
    }
    # The models are the phone's and openclaw-openrouter.py's.
    assert after["agents"] == config["agents"]


def test_a_gateway_that_already_follows_it_is_left_as_it_is(pictures: ModuleType) -> None:
    config = as_on_the_box()
    followed = pictures.patched(config, pictures.pictures_patch(config))

    assert pictures.patched(followed, pictures.pictures_patch(followed)) == followed
    # No allow list was there, and writing one would switch every other plugin off.
    assert "allow" not in followed["plugins"]


@pytest.mark.parametrize(
    ("held", "kept"),
    [
        (
            {"pictureDayDollars": 5, "videoDayDollars": 0.5},
            {"pictureDayDollars": 5, "videoDayDollars": 0.5},
        ),
        ({"pictureDayDollars": 0}, CEILINGS),
        ({"pictureDayDollars": True, "videoDayDollars": "3"}, CEILINGS),
        (
            {"pictureDayDollars": 101, "videoDayDollars": 1},
            {"pictureDayDollars": 2.0, "videoDayDollars": 1},
        ),
    ],
)
def test_a_ceiling_a_person_set_stays_and_one_that_is_missing_or_wrong_gets_the_default(
    pictures: ModuleType, held: dict[str, Any], kept: dict[str, Any]
) -> None:
    config = as_on_the_box()
    config["plugins"]["entries"]["household-pictures"] = {"enabled": True, "config": held}

    after = pictures.patched(config, pictures.pictures_patch(config))

    assert after["plugins"]["entries"]["household-pictures"]["config"] == kept
    assert pictures.problems(after) == []


def test_a_config_key_the_plugin_refuses_is_reported_and_taken_out(pictures: ModuleType) -> None:
    config = as_on_the_box()
    config["plugins"]["entries"]["household-pictures"] = {
        "enabled": True,
        "config": {**CEILINGS, "model": "openai/gpt-image-2"},
    }

    assert (
        "the household-pictures plugin refuses its config and does not start: "
        "it does not know model" in pictures.problems(config)
    )
    after = pictures.patched(config, pictures.pictures_patch(config))
    assert after["plugins"]["entries"]["household-pictures"]["config"] == CEILINGS


def test_dms_kept_together_are_reported_and_kept_apart(pictures: ModuleType) -> None:
    config = as_on_the_box()
    del config["session"]

    assert (
        "DMs are not kept per sender and groups per group, so picture and video refuse every chat"
        in pictures.problems(config)
    )
    after = pictures.patched(config, pictures.pictures_patch(config))
    assert after["session"] == {"dmScope": "per-channel-peer", "groupScope": "per-group"}


def test_a_plugin_policy_that_blocks_it_is_reported(pictures: ModuleType) -> None:
    config = as_on_the_box()
    config["plugins"]["enabled"] = False
    config["plugins"]["deny"] = ["household-pictures"]

    wrong = pictures.problems(config)

    assert "plugins are switched off, so the household-pictures plugin cannot run" in wrong
    assert "plugins.deny blocks the household-pictures plugin" in wrong


def write_state(path: Path, config: dict[str, Any]) -> Path:
    path.mkdir(parents=True)
    (path / "openclaw.json").write_text(json.dumps(config))
    (path / "openclaw.json").chmod(0o600)
    return path


class FakeGateways:
    """`docker exec ... config patch`, against config files on disk."""

    def __init__(self, pictures: ModuleType, states: dict[str, Path]) -> None:
        self.pictures = pictures
        self.states = states
        self.refuses: set[str] = set()
        self.fails_to_write: set[str] = set()
        self.writes: list[str] = []

    def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        assert argv[:3] == ["docker", "exec", "-i"], argv
        container, command = argv[3], argv[6:]
        assert command[:3] == ["config", "patch", "--stdin"], command
        if container in self.refuses:
            return subprocess.CompletedProcess(argv, 1, "", "plugins.entries: unknown plugin")
        if "--dry-run" in command:
            return subprocess.CompletedProcess(argv, 0, json.dumps({"ok": True}), "")
        if container in self.fails_to_write:
            return subprocess.CompletedProcess(argv, 1, "", "the gateway went away")
        path = self.states[container] / "openclaw.json"
        merged = self.pictures.patched(
            json.loads(path.read_text()), json.loads(str(kwargs["input"]))
        )
        path.write_text(json.dumps(merged))
        self.writes.append(container)
        return subprocess.CompletedProcess(argv, 0, "Applied.", "")


@pytest.fixture(autouse=True)
def installed_plugin(pictures: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """The plugin as scripts/openclaw-install.sh leaves it on the host."""
    manifest: Path = tmp_path / "plugins" / str(pictures.PLUGIN) / "openclaw.plugin.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(json.dumps({"id": pictures.PLUGIN}))
    monkeypatch.setattr(pictures, "PLUGIN_ON_HOST", manifest)
    return manifest


@pytest.fixture
def gateways(pictures: ModuleType, tmp_path: Path) -> tuple[Any, ...]:
    corey = write_state(tmp_path / "openclaw", as_on_the_box())
    denise = write_state(tmp_path / "openclaw-denise", as_on_the_box())
    return (
        pictures.Gateway("corey", "openclaw-gateway", corey, "franco"),
        pictures.Gateway("denise", "openclaw-denise", denise, "gia"),
    )


@pytest.fixture
def fake(pictures: ModuleType, gateways: tuple[Any, ...]) -> FakeGateways:
    return FakeGateways(pictures, {g.container: g.state for g in gateways})


@needs_nofollow_open
def test_apply_backs_up_and_writes_both_gateways_and_then_they_follow_it(
    pictures: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert pictures.apply(gateways, run=fake, dry_run=False) == 0

    assert fake.writes == ["openclaw-gateway", "openclaw-denise"]
    out = capsys.readouterr().out
    for gateway in gateways:
        assert pictures.problems(json.loads(gateway.config_path.read_text())) == []
        (saved,) = gateway.state.glob("openclaw.json.pre-pictures-*")
        assert saved.read_bytes() == before[gateway.persona]
        assert str(saved) in out
    assert "$2.00 of pictures and $3.00 of videos a person a day" in out
    assert pictures.check(gateways) == 0
    # A second run has nothing left to do and writes nothing.
    assert pictures.apply(gateways, run=fake, dry_run=False) == 0
    assert fake.writes == ["openclaw-gateway", "openclaw-denise"]
    assert "corey: nothing to write" in capsys.readouterr().out


@needs_nofollow_open
def test_a_dry_run_validates_and_writes_nothing(
    pictures: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert pictures.apply(gateways, run=fake, dry_run=True) == 0

    assert fake.writes == []
    out = capsys.readouterr().out
    assert "dry run: nothing written" in out
    assert (
        '"deny": ["codex", "memory-wiki", "onepassword", "image_generate", "video_generate"]' in out
    )
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]


@needs_nofollow_open
def test_apply_writes_neither_gateway_when_one_refuses_the_patch(
    pictures: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake.refuses.add("openclaw-denise")

    assert pictures.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == []
    assert "refused, nothing written" in capsys.readouterr().err


@needs_nofollow_open
def test_apply_says_which_gateway_it_wrote_when_the_other_write_fails(
    pictures: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake.fails_to_write.add("openclaw-denise")

    assert pictures.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == ["openclaw-gateway"]
    err = capsys.readouterr().err
    assert "denise: write failed, previous config at " in err
    assert "corey is already written, so the two gateways are apart until apply is run again" in err


def test_apply_refuses_until_the_plugin_is_installed_and_touches_nothing(
    pictures: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    installed_plugin: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A plugin the gateway cannot find would take the built-ins away and hand over nothing."""
    installed_plugin.unlink()

    assert pictures.apply(gateways, run=fake, dry_run=False) == 1

    assert "scripts/openclaw-install.sh" in capsys.readouterr().err
    assert fake.writes == []


@needs_nofollow_open
def test_apply_can_write_one_gateway_and_leave_the_other_untouched(
    pictures: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(pictures, "GATEWAYS", gateways)
    monkeypatch.setattr(pictures.os, "geteuid", lambda: 0, raising=False)
    denise_before = gateways[1].config_path.read_bytes()

    assert pictures.main(["apply", "--gateway", "corey"], run=fake) == 0

    assert fake.writes == ["openclaw-gateway"]
    assert pictures.problems(json.loads(gateways[0].config_path.read_text())) == []
    assert gateways[1].config_path.read_bytes() == denise_before
    assert list(gateways[1].state.glob("openclaw.json.pre-pictures-*")) == []


@needs_nofollow_open
def test_check_and_verdict_read_one_gateway_from_its_state(
    pictures: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    corey, denise = gateways
    config = as_on_the_box()
    denise.config_path.write_text(
        json.dumps(pictures.patched(config, pictures.pictures_patch(config)))
    )

    assert pictures.check(gateways) == 1
    out = capsys.readouterr().out
    assert "the assistant is not handed picture, video" in out
    assert pictures.verdict(denise.container, denise.state) == "ok"
    assert pictures.verdict(corey.container, corey.state).startswith(
        f"the household-pictures plugin is not loaded from {PICTURES}; "
    )
    assert pictures.verdict("someone-else", corey.state) == "no policy for container someone-else"
    assert pictures.verdict(corey.container, corey.state / "missing").startswith("unreadable: ")
