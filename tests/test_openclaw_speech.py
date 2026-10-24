"""openclaw-speech.py: speech is asked for, and the retired speech plugin is taken out.

Until Telegram was retired the household-speech plugin spoke replies there as numbered voice
notes, under its own ceilings, and the app refused them. Speak and Talk in the app are now
all the speech a gateway makes, and household-app refuses every other way. This script says,
from each gateway's config, whether anything still speaks a reply nobody asked for, and takes
out what household-speech left behind.

The first config below is the shape both gateways had before the retirement. The apply tests
replace `docker exec` with a runner that applies the patch to the file the way `openclaw
config patch` does.
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

from tests.capabilities import needs_nofollow_open, needs_symlinks

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-speech.py"

APP = "/opt/household-plugins/household-app"
VIDEO = "/opt/household-plugins/household-openrouter-video"
SPEECH = "/opt/household-plugins/household-speech"


@pytest.fixture(scope="module")
def speech() -> ModuleType:
    # On the box the scripts run from their own directory, which puts gateway_config
    # on the import path; here the test has to.
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("openclaw_speech", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # Dataclasses resolve their annotations through sys.modules.
    sys.modules["openclaw_speech"] = module
    spec.loader.exec_module(module)
    return module


def as_on_the_box() -> dict[str, Any]:
    """Both gateways with household-speech handed over, as before Telegram was retired."""
    return {
        "tools": {
            "profile": "coding",
            "alsoAllow": ["image", "speak"],
            "deny": ["codex", "memory-wiki", "onepassword"],
        },
        "tts": {
            "auto": "off",
            "provider": "openrouter",
            "providers": {"openrouter": {"model": "elevenlabs/eleven-v4-turbo"}},
        },
        "channels": {"household": {"talkDailyCharacters": 20000}},
        "plugins": {
            "load": {"paths": [APP, SPEECH, VIDEO]},
            "entries": {
                "household-app": {"enabled": True},
                "household-speech": {
                    "enabled": True,
                    "hooks": {"allowConversationAccess": True},
                    "config": {"replyCharacters": 8000, "dayCharacters": 25000},
                },
                "household-openrouter-video": {"enabled": True},
                "telegram": {"enabled": True},
            },
        },
    }


def test_the_retired_plugin_and_its_tool_are_named(speech: ModuleType) -> None:
    assert speech.problems(as_on_the_box()) == [
        "the assistant is still handed speak, which nothing provides any more",
        "the retired household-speech plugin is still in plugins.entries.household-speech, "
        "plugins.load.paths",
    ]


def test_the_patch_takes_out_the_plugin_and_both_tools_and_keeps_everything_else(
    speech: ModuleType,
) -> None:
    config = as_on_the_box()
    config["tools"]["alsoAllow"] = ["tts", "image", "speak"]
    config["plugins"]["allow"] = ["household-app", "household-speech", "telegram"]

    after = speech.patched(config, speech.speech_patch(config))

    assert speech.problems(after) == []
    # A patch replaces a list whole, so each is written back with what else it held.
    assert after["tools"] == {
        "profile": "coding",
        "alsoAllow": ["image"],
        "deny": ["codex", "memory-wiki", "onepassword"],
    }
    assert after["plugins"]["load"]["paths"] == [APP, VIDEO]
    assert after["plugins"]["allow"] == ["household-app", "telegram"]
    assert "household-speech" not in after["plugins"]["entries"]
    # Telegram, the voice, the model and speech on request are not this script's to change.
    assert after["plugins"]["entries"]["telegram"] == {"enabled": True}
    assert after["tts"] == config["tts"]


def test_a_gateway_that_already_follows_it_is_left_as_it_is(speech: ModuleType) -> None:
    config = as_on_the_box()
    followed = speech.patched(config, speech.speech_patch(config))

    assert speech.speech_patch(followed) == {}
    # No allow list was there, and writing one would switch every other plugin off.
    assert "allow" not in followed["plugins"]


@pytest.mark.parametrize(
    ("path", "mode"),
    [
        (("tts",), "always"),
        (("agents", "entries", "main", "tts"), "inbound"),
        (("channels", "household", "tts"), "tagged"),
        (("channels", "household", "accounts", "default", "tts"), "always"),
    ],
)
def test_speech_nobody_asked_for_is_reported_wherever_it_is_set_and_never_changed(
    speech: ModuleType, path: tuple[str, ...], mode: str
) -> None:
    """Automatic speech calls the provider from the reply itself, around the app."""
    config = as_on_the_box()
    node = config
    for key in path:
        node = node.setdefault(key, {})
    node["auto"] = mode

    after = speech.patched(config, speech.speech_patch(config))

    line = (
        f"{'.'.join(path)}.auto is {mode}, so replies are spoken unasked and no ceiling covers them"
    )
    assert line in speech.problems(config)
    assert speech.problems(after) == [line]


@pytest.mark.parametrize(
    ("settings", "expected"),
    [
        # With no `auto`, OpenClaw 2026.9.4 reads the older toggle as `always`.
        (
            {"enabled": True},
            ["tts.enabled is true, so replies are spoken unasked and no ceiling covers them"],
        ),
        ({"enabled": True, "auto": "off"}, []),
        ({"enabled": False}, []),
        ({}, []),
    ],
)
def test_the_older_speech_toggle_is_read_the_way_openclaw_reads_it(
    speech: ModuleType, settings: dict[str, object], expected: list[str]
) -> None:
    config = as_on_the_box()
    config["tts"] = {"provider": "openrouter", **settings}

    assert speech.problems(speech.patched(config, speech.speech_patch(config))) == expected


def write_state(path: Path, config: dict[str, Any]) -> Path:
    path.mkdir(parents=True)
    (path / "openclaw.json").write_text(json.dumps(config))
    (path / "openclaw.json").chmod(0o600)
    return path


class FakeGateways:
    """`docker exec ... config patch`, against config files on disk."""

    def __init__(self, speech: ModuleType, states: dict[str, Path]) -> None:
        self.speech = speech
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
        merged = self.speech.patched(json.loads(path.read_text()), json.loads(str(kwargs["input"])))
        path.write_text(json.dumps(merged))
        self.writes.append(container)
        return subprocess.CompletedProcess(argv, 0, "Applied.", "")


@pytest.fixture(autouse=True)
def installed_guard(speech: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """household-app's speech guard as scripts/openclaw-install.sh leaves it on the host."""
    guard: Path = tmp_path / "plugins" / "household-app" / "speech-guard.js"
    guard.parent.mkdir(parents=True)
    guard.write_text("export const SPEECH_TOOLS = [];\n")
    monkeypatch.setattr(speech, "GUARD_ON_HOST", guard)
    return guard


@pytest.fixture
def gateways(speech: ModuleType, tmp_path: Path) -> tuple[Any, ...]:
    corey = write_state(tmp_path / "openclaw", as_on_the_box())
    denise = write_state(tmp_path / "openclaw-denise", as_on_the_box())
    return (
        speech.Gateway("corey", "openclaw-gateway", corey, "franco"),
        speech.Gateway("denise", "openclaw-denise", denise, "gia"),
    )


@pytest.fixture
def fake(speech: ModuleType, gateways: tuple[Any, ...]) -> FakeGateways:
    return FakeGateways(speech, {g.container: g.state for g in gateways})


@needs_nofollow_open
def test_apply_backs_up_and_writes_both_gateways_and_then_they_follow_it(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert speech.apply(gateways, run=fake, dry_run=False) == 0

    assert fake.writes == ["openclaw-gateway", "openclaw-denise"]
    out = capsys.readouterr().out
    for gateway in gateways:
        assert speech.problems(json.loads(gateway.config_path.read_text())) == []
        (saved,) = gateway.state.glob("openclaw.json.pre-speech-*")
        assert saved.read_bytes() == before[gateway.persona]
        assert str(saved) in out
    assert "speech only when someone asks for it" in out
    assert speech.check(gateways) == 0
    # A second run has nothing left to do and writes nothing.
    assert speech.apply(gateways, run=fake, dry_run=False) == 0
    assert fake.writes == ["openclaw-gateway", "openclaw-denise"]
    assert "corey: nothing to write" in capsys.readouterr().out


@needs_nofollow_open
def test_a_dry_run_validates_on_both_and_writes_nothing(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert speech.apply(gateways, run=fake, dry_run=True) == 0

    assert fake.writes == []
    out = capsys.readouterr().out
    assert "dry run: nothing written" in out
    assert '"household-speech": null' in out
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]
        assert list(gateway.state.glob("openclaw.json.pre-speech-*")) == []


@needs_nofollow_open
def test_apply_writes_neither_gateway_when_one_refuses_the_patch(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake.refuses.add("openclaw-denise")

    assert speech.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == []
    assert "refused, nothing written" in capsys.readouterr().err


@needs_nofollow_open
def test_apply_writes_neither_gateway_when_one_cannot_be_backed_up(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Both are backed up before either is written, so a backup that fails leaves both alone."""
    real_backup = speech.backup
    backed_up: list[Path] = []

    def backup(*arguments: object) -> Path:
        if backed_up:
            raise FileExistsError("openclaw.json.pre-speech already exists")
        saved: Path = real_backup(*arguments)
        backed_up.append(saved)
        return saved

    monkeypatch.setattr(speech, "backup", backup)

    assert speech.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == []
    assert "refused, nothing written" in capsys.readouterr().err


@needs_nofollow_open
def test_apply_says_which_gateway_it_wrote_when_the_other_write_fails(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake.fails_to_write.add("openclaw-denise")

    assert speech.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == ["openclaw-gateway"]
    err = capsys.readouterr().err
    assert "denise: write failed, previous config at " in err
    assert "corey is already written, so the two gateways are apart until apply is run again" in err


def test_apply_refuses_until_the_guard_is_installed_and_touches_nothing(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    installed_guard: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Without the guard, taking the old plugin out would leave `/tts on` to OpenClaw's own."""
    installed_guard.unlink()

    assert speech.apply(gateways, run=fake, dry_run=False) == 1

    assert "scripts/openclaw-install.sh" in capsys.readouterr().err
    assert fake.writes == []


@needs_nofollow_open
def test_apply_says_what_it_leaves_for_a_person(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    config = as_on_the_box()
    config["tts"]["auto"] = "always"
    gateways[1].config_path.write_text(json.dumps(config))

    assert speech.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == ["openclaw-gateway", "openclaw-denise"]
    out = capsys.readouterr().out
    assert "denise: still needs a hand: tts.auto is always" in out


@needs_nofollow_open
def test_apply_can_write_one_gateway_and_leave_the_other_untouched(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(speech, "GATEWAYS", gateways)
    monkeypatch.setattr(speech.os, "geteuid", lambda: 0, raising=False)
    denise_before = gateways[1].config_path.read_bytes()

    assert speech.main(["apply", "--gateway", "corey"], run=fake) == 0

    assert fake.writes == ["openclaw-gateway"]
    assert speech.problems(json.loads(gateways[0].config_path.read_text())) == []
    assert gateways[1].config_path.read_bytes() == denise_before
    assert list(gateways[1].state.glob("openclaw.json.pre-speech-*")) == []


@needs_nofollow_open
def test_check_and_verdict_read_one_gateway_from_its_state(
    speech: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    corey, denise = gateways
    config = as_on_the_box()
    denise.config_path.write_text(json.dumps(speech.patched(config, speech.speech_patch(config))))

    assert speech.check(gateways) == 1
    out = capsys.readouterr().out
    assert "the assistant is still handed speak" in out
    assert "20,000 characters" in out
    assert speech.verdict(denise.container, denise.state) == "ok"
    assert speech.verdict(corey.container, corey.state).startswith(
        "the assistant is still handed speak, which nothing provides any more; "
    )
    assert speech.verdict("someone-else", corey.state) == "no policy for container someone-else"
    assert speech.verdict(corey.container, corey.state / "missing").startswith("unreadable: ")


SWITCH_LINE = (
    "settings/tts.json under the state directory holds a stored switch ({mode}), "
    "so replies are spoken unasked and no ceiling covers them"
)


@pytest.mark.parametrize(
    ("stored", "expected"),
    [
        ({"tts": {"auto": "always"}}, SWITCH_LINE.format(mode="always")),
        ({"tts": {"auto": "inbound"}}, SWITCH_LINE.format(mode="inbound")),
        ({"tts": {"auto": "tagged"}}, SWITCH_LINE.format(mode="tagged")),
        # The older toggle, and what OpenClaw falls back to when `auto` is not a mode.
        ({"tts": {"enabled": True}}, SWITCH_LINE.format(mode="always")),
        ({"tts": {"auto": "sometimes", "enabled": True}}, SWITCH_LINE.format(mode="always")),
        ({"tts": {"auto": "off", "enabled": True}}, "ok"),
        ({"tts": {"enabled": False}}, "ok"),
        ({"tts": {"provider": "openrouter", "maxLength": 1500}}, "ok"),
        ({}, "ok"),
        # OpenClaw reads a file it cannot parse as no preference at all.
        ("not json", "ok"),
        ([], "ok"),
    ],
)
@needs_nofollow_open
def test_a_stored_switch_that_speaks_replies_unasked_is_reported(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    stored: object,
    expected: str,
) -> None:
    """`/tts on` and a client's speech switch are kept outside openclaw.json, and
    OpenClaw 2026.9.4 reads them ahead of `tts.auto`."""
    corey = gateways[0]
    config = as_on_the_box()
    corey.config_path.write_text(json.dumps(speech.patched(config, speech.speech_patch(config))))
    (corey.state / "settings").mkdir()
    content = stored if isinstance(stored, str) else json.dumps(stored)
    (corey.state / "settings" / "tts.json").write_text(content)

    assert speech.verdict(corey.container, corey.state) == expected
    assert speech.check((corey,)) == int(expected != "ok")


@needs_symlinks
@needs_nofollow_open
def test_a_stored_switch_that_cannot_be_read_is_not_taken_for_none(
    speech: ModuleType, gateways: tuple[Any, ...]
) -> None:
    """The state directory is the assistant's own, so the file is not followed anywhere."""
    corey = gateways[0]
    config = as_on_the_box()
    corey.config_path.write_text(json.dumps(speech.patched(config, speech.speech_patch(config))))
    elsewhere = corey.state / "elsewhere.json"
    elsewhere.write_text(json.dumps({"tts": {"auto": "always"}}))
    (corey.state / "settings").mkdir()
    (corey.state / "settings" / "tts.json").symlink_to(elsewhere)

    assert speech.verdict(corey.container, corey.state).startswith(
        "settings/tts.json under the state directory cannot be read"
    )


@needs_nofollow_open
def test_apply_leaves_a_stored_switch_for_a_person_and_says_so(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    denise = gateways[1]
    (denise.state / "settings").mkdir()
    (denise.state / "settings" / "tts.json").write_text(json.dumps({"tts": {"auto": "always"}}))

    assert speech.apply(gateways, run=fake, dry_run=False) == 1

    assert fake.writes == ["openclaw-gateway", "openclaw-denise"]
    assert (
        f"denise: still needs a hand: {SWITCH_LINE.format(mode='always')}"
        in capsys.readouterr().out
    )
    assert json.loads((denise.state / "settings" / "tts.json").read_text()) == {
        "tts": {"auto": "always"}
    }
