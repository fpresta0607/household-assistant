"""openclaw-speech.py: a spoken reply is made by the household-speech plugin, under a ceiling.

On 2026-10-10 a spoken reply reached Telegram as three unlabelled voice notes with its
summary sent twice, because OpenClaw's own `tts` tool leaves a long text to the model
and nothing bounds what it spends. The plugin in deploy/openclaw/plugins/household-speech
replaces that tool. This script is what hands it to both gateways and says, from each
gateway's config, whether any way of speaking is left that goes around it.

The first config below is the shape both gateways had that day, read from the box.
The apply tests replace `docker exec` with a runner that applies the patch to the file
the way `openclaw config patch` does.
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

ROOM = "/opt/household-plugins/household-family-room"
VIDEO = "/opt/household-plugins/household-openrouter-video"
SPEECH = "/opt/household-plugins/household-speech"
CEILINGS = {"replyCharacters": 8000, "dayCharacters": 25000}


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
    """Speech on request through OpenClaw's own tool, as both gateways ran on 10 October."""
    return {
        "tools": {"profile": "coding", "alsoAllow": ["tts"]},
        "tts": {
            "auto": "off",
            "provider": "openrouter",
            "providers": {
                "openrouter": {"model": "elevenlabs/eleven-v4-turbo", "speakerVoice": "will"},
                "microsoft": {"enabled": False},
            },
        },
        "plugins": {
            "load": {"paths": [ROOM, VIDEO]},
            "entries": {
                "household-family-room": {"enabled": True, "config": {"groupChatId": "-1"}},
                "household-openrouter-video": {"enabled": True},
            },
        },
    }


def test_a_gateway_still_on_the_built_in_tool_is_named_on_every_count(speech: ModuleType) -> None:
    assert speech.problems(as_on_the_box()) == [
        f"the household-speech plugin is not loaded from {SPEECH}",
        "the household-speech plugin is not enabled",
        "the household-speech plugin may not read the turn, so a request to hear a reply "
        "is not reminded to call speak",
        "no replyCharacters ceiling is set",
        "no dayCharacters ceiling is set",
        "the assistant is not handed the speak tool",
        "the assistant is still handed OpenClaw's own tts tool, which no ceiling covers",
        "DMs are not kept per sender and groups per group, so speak refuses every chat",
        "tools.deny leaves out codex, memory-wiki, onepassword, whose tools are asked for but "
        "not loaded at start, so speak finds no voice adapter",
        "the telegram plugin is not enabled by name, so a turn whose plugins load from the "
        "config has no voice adapter",
    ]


def test_the_patch_hands_over_speak_and_keeps_what_every_list_already_held(
    speech: ModuleType,
) -> None:
    config = as_on_the_box()
    config["tools"]["alsoAllow"] = ["tts", "image"]
    config["plugins"]["allow"] = ["household-family-room", "household-openrouter-video"]

    after = speech.patched(config, speech.speech_patch(config))

    assert speech.problems(after) == []
    # A patch replaces a list whole, so each is written back with what it held.
    assert after["tools"] == {
        "profile": "coding",
        "alsoAllow": ["image", "speak"],
        "deny": ["codex", "memory-wiki", "onepassword"],
    }
    assert after["session"] == {"dmScope": "per-channel-peer", "groupScope": "per-group"}
    assert after["plugins"]["load"]["paths"] == [ROOM, VIDEO, SPEECH]
    assert after["plugins"]["allow"] == [
        "household-family-room",
        "household-openrouter-video",
        "household-speech",
    ]
    assert after["plugins"]["entries"] == {
        **config["plugins"]["entries"],
        "household-speech": {
            "enabled": True,
            "hooks": {"allowConversationAccess": True},
            "config": CEILINGS,
        },
        "telegram": {"enabled": True},
    }
    # The voice, the model and speech on request are not this script's to change.
    assert after["tts"] == config["tts"]


def test_a_gateway_that_already_follows_it_is_left_as_it_is(speech: ModuleType) -> None:
    config = as_on_the_box()
    followed = speech.patched(config, speech.speech_patch(config))

    assert speech.patched(followed, speech.speech_patch(followed)) == followed
    # No allow list was there, and writing one would switch every other plugin off.
    assert "allow" not in followed["plugins"]


def test_a_gateway_whose_turn_hook_is_blocked_is_reported_and_then_allowed(
    speech: ModuleType,
) -> None:
    # Both gateways on 15 October: OpenClaw logged the plugin's before_prompt_build hook
    # as blocked, because nothing allowed it to read the turn.
    config = as_on_the_box()
    config = speech.patched(config, speech.speech_patch(config))
    del config["plugins"]["entries"]["household-speech"]["hooks"]

    assert speech.problems(config) == [
        "the household-speech plugin may not read the turn, so a request to hear a reply "
        "is not reminded to call speak",
    ]
    after = speech.patched(config, speech.speech_patch(config))
    assert speech.problems(after) == []
    assert after["plugins"]["entries"]["household-speech"]["hooks"] == {
        "allowConversationAccess": True
    }


@pytest.mark.parametrize(
    ("session", "expected"),
    [
        (None, {"dmScope": "per-channel-peer", "groupScope": "per-group"}),
        (
            {"dmScope": "per-account-channel-peer", "idleMinutes": 30},
            {"dmScope": "per-account-channel-peer", "idleMinutes": 30, "groupScope": "per-group"},
        ),
        (
            {"dmScope": "per-channel-peer", "groupScope": "per-group"},
            {"dmScope": "per-channel-peer", "groupScope": "per-group"},
        ),
    ],
    ids=["no-session", "per-account", "already-isolated"],
)
def test_speak_gets_dms_kept_per_sender_and_an_isolating_scope_a_person_chose_stays(
    speech: ModuleType, session: dict[str, Any] | None, expected: dict[str, Any]
) -> None:
    config = as_on_the_box()
    if session is not None:
        config["session"] = session

    after = speech.patched(config, speech.speech_patch(config))

    assert after["session"] == expected
    assert speech.problems(after) == []


def test_a_shared_dm_scope_a_person_set_is_reported_and_left_for_them(speech: ModuleType) -> None:
    config = as_on_the_box()
    config["session"] = {"dmScope": "main"}

    after = speech.patched(config, speech.speech_patch(config))

    assert after["session"] == {"dmScope": "main", "groupScope": "per-group"}
    assert speech.problems(after) == [
        "DMs are not kept per sender and groups per group, so speak refuses every chat"
    ]


def test_a_telegram_plugin_switched_off_on_purpose_is_reported_and_left(
    speech: ModuleType,
) -> None:
    config = as_on_the_box()
    config["plugins"]["entries"]["telegram"] = {"enabled": False, "config": {"kept": True}}

    after = speech.patched(config, speech.speech_patch(config))

    assert after["plugins"]["entries"]["telegram"] == {"enabled": False, "config": {"kept": True}}
    assert speech.problems(after) == [
        "the telegram plugin is not enabled by name, so a turn whose plugins load from the "
        "config has no voice adapter"
    ]


def test_the_unloaded_tool_owners_are_denied_beside_what_a_person_denied(
    speech: ModuleType,
) -> None:
    config = as_on_the_box()
    config["tools"]["deny"] = ["browser", "memory-wiki"]

    after = speech.patched(config, speech.speech_patch(config))

    assert after["tools"]["deny"] == ["browser", "memory-wiki", "codex", "onepassword"]
    # The coding profile and everything it hands over stay.
    assert after["tools"]["profile"] == "coding"
    assert speech.problems(after) == []
    assert "deny" not in speech.speech_patch(after).get("tools", {})


@pytest.mark.parametrize(
    ("held", "expected"),
    [
        (None, CEILINGS),
        ({}, CEILINGS),
        ({"replyCharacters": 3000}, {"replyCharacters": 3000, "dayCharacters": 25000}),
        (
            {"replyCharacters": 3000, "dayCharacters": 9000},
            {"replyCharacters": 3000, "dayCharacters": 9000},
        ),
        # The plugin refuses these and does not start, so each gets the default.
        (
            {"replyCharacters": 0, "dayCharacters": "9000"},
            CEILINGS,
        ),
        ({"replyCharacters": True, "dayCharacters": 2.5}, CEILINGS),
    ],
)
def test_a_ceiling_a_person_set_stays_and_one_that_is_missing_gets_the_default(
    speech: ModuleType, held: dict[str, object] | None, expected: dict[str, int]
) -> None:
    config = as_on_the_box()
    if held is not None:
        config["plugins"]["entries"]["household-speech"] = {"enabled": False, "config": held}

    after = speech.patched(config, speech.speech_patch(config))

    assert after["plugins"]["entries"]["household-speech"] == {
        "enabled": True,
        "hooks": {"allowConversationAccess": True},
        "config": expected,
    }
    assert speech.problems(after) == []


@pytest.mark.parametrize(
    ("path", "mode"),
    [
        (("tts",), "always"),
        (("agents", "entries", "main", "tts"), "inbound"),
        (("channels", "telegram", "tts"), "tagged"),
        (("channels", "telegram", "accounts", "default", "tts"), "always"),
    ],
)
def test_speech_nobody_asked_for_is_reported_wherever_it_is_set_and_never_changed(
    speech: ModuleType, path: tuple[str, ...], mode: str
) -> None:
    """Automatic speech calls the provider from the reply itself, around the plugin."""
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


@pytest.mark.parametrize(
    ("policy", "expected"),
    [
        (
            {"enabled": False},
            ["plugins are switched off, so the household-speech plugin cannot run"],
        ),
        ({"deny": ["household-speech"]}, ["plugins.deny blocks the household-speech plugin"]),
        ({"deny": ["another-plugin"]}, []),
    ],
)
def test_a_plugin_policy_that_blocks_it_is_reported_and_left_for_a_person(
    speech: ModuleType, policy: dict[str, object], expected: list[str]
) -> None:
    config = as_on_the_box()
    config["plugins"].update(policy)

    after = speech.patched(config, speech.speech_patch(config))

    assert speech.problems(after) == expected
    for key, value in policy.items():
        assert after["plugins"][key] == value


def test_an_allow_list_that_leaves_it_out_is_reported_and_then_merged(speech: ModuleType) -> None:
    config = as_on_the_box()
    followed = speech.patched(config, speech.speech_patch(config))
    followed["plugins"]["allow"] = ["household-family-room"]

    assert speech.problems(followed) == ["plugins.allow leaves the household-speech plugin out"]
    after = speech.patched(followed, speech.speech_patch(followed))
    assert after["plugins"]["allow"] == ["household-family-room", "household-speech"]


def test_a_config_key_the_plugin_refuses_is_reported_and_taken_out(speech: ModuleType) -> None:
    """The plugin refuses a config with a key it does not know, and then registers nothing:
    no `speak` tool, and no claim on `/tts`."""
    config = as_on_the_box()
    followed = speech.patched(config, speech.speech_patch(config))
    held = followed["plugins"]["entries"]["household-speech"]["config"]
    held["voice"] = "will"
    held["dayCharacter"] = 9000

    after = speech.patched(followed, speech.speech_patch(followed))

    assert speech.problems(followed) == [
        "the household-speech plugin refuses its config and does not start: "
        "it does not know dayCharacter, voice"
    ]
    assert after["plugins"]["entries"]["household-speech"] == {
        "enabled": True,
        "hooks": {"allowConversationAccess": True},
        "config": CEILINGS,
    }
    assert speech.problems(after) == []


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
def installed_plugin(speech: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """The plugin as scripts/openclaw-install.sh leaves it on the host."""
    manifest: Path = tmp_path / "plugins" / str(speech.PLUGIN) / "openclaw.plugin.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(json.dumps({"id": speech.PLUGIN}))
    monkeypatch.setattr(speech, "PLUGIN_ON_HOST", manifest)
    return manifest


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
    assert "8,000 characters a reply, 25,000 a day" in out
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
    assert '"alsoAllow": ["speak"]' in out
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


def test_apply_refuses_until_the_plugin_is_installed_and_touches_nothing(
    speech: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    installed_plugin: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Naming a plugin the gateway cannot find takes `tts` away and hands over nothing."""
    installed_plugin.unlink()

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
    assert "the assistant is not handed the speak tool" in out
    assert speech.verdict(denise.container, denise.state) == "ok"
    assert speech.verdict(corey.container, corey.state).startswith(
        f"the household-speech plugin is not loaded from {SPEECH}; "
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
