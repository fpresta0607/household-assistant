"""openclaw-family-group.py: who reaches Corey and Denise in The Fam, and the fix.

Every config in the first test was run through the gateway the compose file pins,
OpenClaw 2026.9.4 (3a9d69d), on 2026-10-05, with a fake Bot API standing in for
Telegram and a fake model standing in for the provider. The outcomes listed are what
that gateway did with a group message that mentions the bot: it answered, or it
dropped the message before any model saw it. The evaluator has to agree with the
gateway on every one, because its whole job is to say what the gateway will do.

A DM pairing approval does not appear in any of these configs, and that is the
point. The token-only and setup-default runs had Gia paired by DM first, and her DMs
were answered while her group messages were dropped. OpenClaw keeps pairings in its
own database and never consults them for a group.

The apply tests replace `docker exec` with a runner that applies the patch to the file
the way `openclaw config patch` does. The real CLI was driven the same way once, by
hand, and wrote the same result.
"""

from __future__ import annotations

import importlib.util
import json
import stat
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from tests.capabilities import needs_nofollow_open, needs_symlinks

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-family-group.py"

FRANCO = "7100000001"
GIA = "7100000002"
THE_FAM = "-5100000001"


def load(path: Path, name: str) -> ModuleType:
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
def family() -> ModuleType:
    return load(SCRIPT, "openclaw_family_group")


ROOM_PLUGIN = "household-family-room"
ROOM_PLUGIN_PATH = f"/opt/household-plugins/{ROOM_PLUGIN}"


def room_plugin() -> dict[str, Any]:
    """The plugins section `apply` writes, as a gateway that already has it carries it."""
    return {
        "load": {"paths": [ROOM_PLUGIN_PATH]},
        "entries": {
            ROOM_PLUGIN: {
                "enabled": True,
                "hooks": {"allowConversationAccess": True},
                "config": {"groupChatId": THE_FAM},
            }
        },
    }


def with_telegram(**telegram: object) -> dict[str, Any]:
    token = {"source": "env", "provider": "default", "id": "TELEGRAM_BOT_TOKEN_DENISE"}
    return {
        "agents": {"entries": {"main": {"identity": {"name": "Denise"}}}},
        "channels": {"telegram": {"enabled": True, "botToken": token, **telegram}},
        "plugins": room_plugin(),
        **family_history(),
    }


def family_history() -> dict[str, Any]:
    """The tool and session settings `apply` writes so family_history reaches the assistant."""
    return {
        "tools": {"profile": "coding", "alsoAllow": ["speak", "family_history"]},
        "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
    }


POLICY_ENTRY = {
    THE_FAM: {
        "requireMention": True,
        "allowFrom": [FRANCO, GIA],
        "disableAudioPreflight": False,
        "ingest": True,
    }
}


@pytest.fixture(autouse=True)
def installed_plugin(family: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """The plugin's code where openclaw-install.sh puts it on the box."""
    index = tmp_path / "opt-plugins" / ROOM_PLUGIN / "index.js"
    index.parent.mkdir(parents=True)
    index.write_text("export default {};\n")
    monkeypatch.setattr(family, "ROOM_PLUGIN_ON_HOST", index)
    return index


@pytest.mark.parametrize(
    ("telegram", "franco", "gia"),
    [
        ({}, "not-allowed", "not-allowed"),
        (
            {"groups": {"*": {"requireMention": True}}},
            "groupPolicy: allowlist, no group allowlist entries",
            "groupPolicy: allowlist, no group allowlist entries",
        ),
        (
            {"groups": {"*": {"requireMention": True}}, "allowFrom": [GIA]},
            "groupPolicy: allowlist, sender not listed",
            None,
        ),
        ({"groups": POLICY_ENTRY}, None, None),
        (
            {"groups": {"*": {"requireMention": True}, **POLICY_ENTRY}, "allowFrom": [GIA]},
            None,
            None,
        ),
    ],
    ids=[
        "token-only",
        "setup-wizard-default",
        "dm-allowlist-for-gia",
        "the-policy-entry",
        "the-policy-entry-over-a-dm-allowlist",
    ],
)
def test_each_config_gets_the_answer_the_pinned_gateway_gave(
    family: ModuleType, telegram: dict[str, Any], franco: str | None, gia: str | None
) -> None:
    """None means the gateway answered; a string is the reason it dropped the message."""
    config = with_telegram(**telegram)
    for sender, expected in ((FRANCO, franco), (GIA, gia)):
        outcome = family.admission(config, THE_FAM, sender)
        assert outcome.admitted is (expected is None), (sender, outcome)
        if expected is not None:
            assert outcome.reason == expected


def test_a_mention_is_required_unless_the_group_or_its_default_says_otherwise(
    family: ModuleType,
) -> None:
    assert family.mention_required(with_telegram(), THE_FAM) is True
    everywhere = with_telegram(groups={"*": {"requireMention": False}})
    assert family.mention_required(everywhere, THE_FAM) is False
    entry_wins = with_telegram(
        groups={"*": {"requireMention": False}, THE_FAM: {"requireMention": True}}
    )
    assert family.mention_required(entry_wins, THE_FAM) is True

    always_on = with_telegram(
        groups={THE_FAM: {"requireMention": False, "allowFrom": [FRANCO, GIA], "ingest": True}}
    )
    assert family.problems(always_on, "corey") == ["answers unmentioned messages"]


def test_nobody_outside_the_household_is_answered_even_when_groups_are_open(
    family: ModuleType,
) -> None:
    """An open channel lets anyone in the group drive the bot, and the check says so."""
    wide_open = with_telegram(groupPolicy="open")
    assert family.admission(wide_open, THE_FAM, family.SOMEONE_ELSE).admitted
    assert "anyone else answered" in family.problems(wide_open, "denise")

    fixed = family.patched(wide_open, family.policy_patch("denise"))
    assert not family.admission(fixed, THE_FAM, family.SOMEONE_ELSE).admitted
    assert family.problems(fixed, "denise") == []


@pytest.mark.parametrize("persona", ["corey", "denise"])
@pytest.mark.parametrize("source", ["exact", "wildcard", "channel", "dm"])
@needs_nofollow_open
def test_check_and_verdict_reject_every_effective_outsider(
    family: ModuleType,
    gateways: tuple[Any, ...],
    persona: str,
    source: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    senders = [FRANCO, GIA, "tg:123456789"]
    telegram: dict[str, Any] = {"groups": {THE_FAM: {"requireMention": True, "ingest": True}}}
    if source == "exact":
        telegram["groups"][THE_FAM]["allowFrom"] = senders
    elif source == "wildcard":
        telegram["groups"] = {"*": {"requireMention": True, "allowFrom": senders, "ingest": True}}
    else:
        telegram["groupAllowFrom" if source == "channel" else "allowFrom"] = senders
    config = with_telegram(**telegram)
    gateway = next(gateway for gateway in gateways if gateway.persona == persona)
    write_state(gateway.state, config)

    wrong = family.problems(config, persona)
    status = family.check([gateway], run=lambda *_, **__: completed(), probe=False)
    verdict = family.verdict(gateway.container, gateway.state)

    assert family.admission(config, THE_FAM, "123456789").admitted
    assert not family.admission(config, THE_FAM, family.SOMEONE_ELSE).admitted
    assert wrong == ["unexpected senders answered: 123456789"]
    assert status == 1
    assert verdict == wrong[0]
    assert wrong[0] in capsys.readouterr().out


def test_only_the_effective_sender_list_is_checked(family: ModuleType) -> None:
    config = with_telegram(
        groups={THE_FAM: {"allowFrom": [f"TG:{FRANCO}", f"telegram:{GIA}"], "ingest": True}},
        groupAllowFrom=[FRANCO, GIA, "123456789"],
        allowFrom=["*"],
    )

    assert family.problems(config, "denise") == []
    assert not family.admission(config, THE_FAM, "123456789").admitted


@pytest.mark.parametrize(
    ("entry", "sender", "reason"),
    [
        ({"enabled": False}, FRANCO, "group disabled"),
        ({"groupPolicy": "disabled"}, FRANCO, "groupPolicy: disabled"),
        ({"allowFrom": [GIA]}, FRANCO, "group allowFrom override"),
    ],
)
def test_admission_uses_the_wildcard_when_there_is_no_exact_entry(
    family: ModuleType, entry: dict[str, Any], sender: str, reason: str
) -> None:
    config = with_telegram(groups={"*": entry}, groupAllowFrom=[FRANCO, GIA])

    outcome = family.admission(config, THE_FAM, sender)

    assert not outcome.admitted
    assert outcome.reason == reason
    assert family.problems(config, "denise")


def test_an_exact_entry_hides_the_wildcard_access_settings(family: ModuleType) -> None:
    config = with_telegram(groups={"*": {"enabled": False, "allowFrom": []}, **POLICY_ENTRY})

    assert family.problems(config, "denise") == []
    assert family.admission(config, THE_FAM, FRANCO).admitted
    assert family.admission(config, THE_FAM, GIA).admitted


def test_the_allowlist_is_read_the_way_the_gateway_reads_it(family: ModuleType) -> None:
    listed = family.allowlist([f"telegram:{FRANCO}", f"TG:{GIA}", "@gia", " "])
    assert listed.ids == frozenset({FRANCO, GIA})
    # "@gia" is ignored as a sender, and still makes the list non-empty, which is
    # what stops an empty-means-everyone reading of it.
    assert listed.has_entries
    assert not listed.allows(family.SOMEONE_ELSE)
    assert family.allowlist(["*"]).allows(family.SOMEONE_ELSE)
    with pytest.raises(family.UnsupportedConfig):
        family.allowlist(["accessGroup:household"])


def test_the_token_is_described_and_never_printed(family: ModuleType) -> None:
    literal = "8000000001:a-token-that-must-not-be-printed"
    assert family.token_source(with_telegram()) == "env reference (TELEGRAM_BOT_TOKEN_DENISE)"
    said = family.token_source(with_telegram(botToken=literal))
    assert said.startswith("a literal in openclaw.json")
    assert literal not in said


def test_named_accounts_are_refused_rather_than_guessed(family: ModuleType) -> None:
    config = with_telegram(accounts={"denise": {"botToken": "x"}})
    with pytest.raises(family.UnsupportedConfig):
        family.admission(config, THE_FAM, GIA)


def test_the_patch_changes_the_family_group_entry_and_nothing_else(family: ModuleType) -> None:
    before = with_telegram(
        dmPolicy="pairing",
        allowFrom=[GIA],
        groups={
            "*": {"requireMention": True},
            "-100200300": {"requireMention": False},
            THE_FAM: {"systemPrompt": "kept", "allowFrom": [GIA], "requireMention": False},
        },
    )
    before["agents"] = {"defaults": {"model": {"primary": "openrouter/z-ai/glm-5.3-flash"}}}

    after = family.patched(before, family.policy_patch("denise"))

    groups = after["channels"]["telegram"]["groups"]
    assert groups[THE_FAM] == {
        "systemPrompt": "kept",
        "allowFrom": [FRANCO, GIA],
        "requireMention": True,
        "disableAudioPreflight": False,
        "ingest": True,
    }
    del groups[THE_FAM]
    del before["channels"]["telegram"]["groups"][THE_FAM]
    assert after == before


def write_state(path: Path, config: dict[str, Any]) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    target = path / "openclaw.json"
    target.write_text(json.dumps(config, indent=2))
    target.chmod(0o600)
    return path


@needs_nofollow_open
def test_verdict_is_one_line_about_one_gateway(family: ModuleType, tmp_path: Path) -> None:
    fixed = write_state(tmp_path / "fixed", with_telegram(groups=POLICY_ENTRY))
    bare = write_state(tmp_path / "bare", with_telegram())

    assert family.verdict("openclaw-denise", fixed) == "ok"
    assert family.verdict("openclaw-denise", bare) == (
        "franco dropped (not-allowed); gia dropped (not-allowed); "
        "a voice note that does not name it is dropped unheard"
    )
    assert family.verdict("openclaw-denise", tmp_path / "missing").startswith("unreadable:")
    assert family.verdict("someone-else", fixed) == "no policy for container someone-else"


@needs_symlinks
@needs_nofollow_open
def test_a_config_that_is_a_symlink_is_not_followed(family: ModuleType, tmp_path: Path) -> None:
    """The state directory is the assistant's, and this runs as root."""
    elsewhere = write_state(tmp_path / "elsewhere", with_telegram(groups=POLICY_ENTRY))
    state = tmp_path / "state"
    state.mkdir()
    (state / "openclaw.json").symlink_to(elsewhere / "openclaw.json")

    assert family.verdict("openclaw-denise", state).startswith("unreadable:")


# What `channels status --probe --json` printed on 2026.9.4, trimmed to the fields read,
# with a banner line ahead of it the way the CLI can print one.
PROBE_OUTPUT = "[openclaw] config: /home/node/.openclaw/openclaw.json\n" + json.dumps(
    {
        "channels": {
            "telegram": {
                "configured": True,
                "running": True,
                "lastError": None,
                "probe": {
                    "ok": True,
                    "bot": {
                        "id": 8000000001,
                        "username": "Denise_the_woman_bot",
                        "canReadAllGroupMessages": False,
                    },
                },
            }
        }
    }
)


def completed(stdout: str = "", returncode: int = 0) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr="")


UNKNOWN_METHOD = json.dumps(
    {
        "ok": False,
        "error": {
            "type": "gateway_request_error",
            "code": "INVALID_REQUEST",
            "message": f"unknown method: {ROOM_PLUGIN}.peer",
        },
    }
)


def probing(
    bot: str = PROBE_OUTPUT, room: str = '{"accepted": 0}'
) -> Callable[..., subprocess.CompletedProcess[str]]:
    """Both of check's probes: Telegram's view of the bot, and the family-room plugin.

    The plugin's answer is what 2026.9.4 printed for `gateway call ... --json`, loaded
    and not loaded.
    """

    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        if "gateway" in argv and "call" in argv:
            return completed(room, 0 if "accepted" in room else 1)
        return completed(bot)

    return run


def test_the_probe_reads_privacy_mode_through_the_gateway(family: ModuleType) -> None:
    calls: list[list[str]] = []

    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        calls.append(argv)
        return completed(PROBE_OUTPUT)

    probe = family.probe_bot(family.GATEWAYS[1], run)

    assert probe.username == "Denise_the_woman_bot"
    assert probe.reads_all_group_messages is False
    assert "only @mentions" in family.privacy_line(probe)
    # Read-only, against Denise's own container, without attaching a terminal.
    assert calls == [
        [
            "docker",
            "exec",
            "openclaw-denise",
            "node",
            "dist/index.js",
            "channels",
            "status",
            "--probe",
            "--json",
            "--channel",
            "telegram",
        ]
    ]

    unanswered = family.probe_bot(family.GATEWAYS[1], lambda *_, **__: completed("", 1))
    assert unanswered.reads_all_group_messages is None
    assert family.privacy_line(unanswered).startswith("unknown")


class FakeGateways:
    """`docker exec ... config patch --stdin`, applied to the file as OpenClaw does."""

    def __init__(self, family: ModuleType, states: dict[str, Path]) -> None:
        self.family = family
        self.states = states
        self.calls: list[tuple[str, bool]] = []
        self.restores: list[str] = []
        self.refuse: set[str] = set()

    def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if argv[:2] == ["docker", "exec"] and argv[3] == "cp":
            container = argv[2]
            self.restores.append(container)
            assert argv[5] == "/home/node/.openclaw/openclaw.json"
            saved = self.states[container] / Path(argv[4]).name
            (self.states[container] / "openclaw.json").write_bytes(saved.read_bytes())
            return completed()
        assert argv[:3] == ["docker", "exec", "-i"], argv
        container = argv[3]
        dry_run = "--dry-run" in argv
        self.calls.append((container, dry_run))
        if container in self.refuse:
            return subprocess.CompletedProcess(argv, 1, "", "Config validation error: no")
        if dry_run:
            return completed(json.dumps({"ok": True, "operations": 2}))
        path = self.states[container] / "openclaw.json"
        merged = self.family.patched(json.loads(path.read_text()), json.loads(str(kwargs["input"])))
        path.write_text(json.dumps(merged, indent=2))
        return completed("Applied 2 config update(s).")


@pytest.fixture
def gateways(family: ModuleType, tmp_path: Path) -> tuple[Any, ...]:
    corey = write_state(tmp_path / "openclaw", with_telegram(allowFrom=[FRANCO], groups={"*": {}}))
    denise = write_state(tmp_path / "openclaw-denise", with_telegram())
    return (
        family.Gateway("corey", "openclaw-gateway", corey, "franco"),
        family.Gateway("denise", "openclaw-denise", denise, "gia"),
    )


@needs_nofollow_open
def test_apply_writes_both_gateways_and_backs_each_one_up(
    family: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.apply(gateways, run=run, dry_run=False) == 0

    # Both validated before either was written.
    assert run.calls == [
        ("openclaw-gateway", True),
        ("openclaw-denise", True),
        ("openclaw-gateway", False),
        ("openclaw-denise", False),
    ]
    for gateway in gateways:
        config = json.loads(gateway.config_path.read_text())
        assert family.problems(config, gateway.persona) == []
        (saved,) = gateway.state.glob("openclaw.json.pre-family-group-*")
        assert saved.read_bytes() == before[gateway.persona]
        assert stat.S_IMODE(saved.stat().st_mode) == 0o600
        assert saved.stat().st_uid == gateway.config_path.stat().st_uid
    assert "follows the policy" in capsys.readouterr().out

    # Run again: nothing left to write.
    run.calls.clear()
    assert family.apply(gateways, run=run, dry_run=False) == 0
    assert run.calls == []


@needs_nofollow_open
def test_a_dry_run_validates_and_writes_nothing(
    family: ModuleType, gateways: tuple[Any, ...]
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.apply(gateways, run=run, dry_run=True) == 0

    assert run.calls == [("openclaw-gateway", True), ("openclaw-denise", True)]
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]
        assert list(gateway.state.glob("openclaw.json.pre-family-group-*")) == []


@needs_nofollow_open
def test_one_gateway_refusing_the_patch_leaves_both_untouched(
    family: ModuleType, gateways: tuple[Any, ...]
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}
    run = FakeGateways(family, {g.container: g.state for g in gateways})
    run.refuse.add("openclaw-denise")

    assert family.apply(gateways, run=run, dry_run=False) == 1

    assert run.calls == [("openclaw-gateway", True), ("openclaw-denise", True)]
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]
        assert list(gateway.state.glob("openclaw.json.pre-family-group-*")) == []


@needs_nofollow_open
def test_a_backup_failure_leaves_both_live_configs_untouched(
    family: ModuleType,
    gateways: tuple[Any, ...],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {gateway.persona: gateway.config_path.read_bytes() for gateway in gateways}
    stamp = "20261005T000000Z"
    monkeypatch.setattr(family.time, "strftime", lambda *_: stamp)
    reserved = gateways[1].state / f"openclaw.json.pre-family-group-{stamp}"
    reserved.write_bytes(b"reserved")
    run = FakeGateways(family, {gateway.container: gateway.state for gateway in gateways})

    status = family.apply(gateways, run=run, dry_run=False)

    assert status == 1
    assert run.calls == [("openclaw-gateway", True), ("openclaw-denise", True)]
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]
    assert reserved.read_bytes() == b"reserved"
    error = capsys.readouterr().err
    assert "refused, nothing written:" in error
    assert str(reserved) in error


@pytest.mark.parametrize("failure", ["refusal", "timeout", "exec-unavailable"])
@pytest.mark.parametrize("container", ["openclaw-gateway", "openclaw-denise"])
@needs_nofollow_open
def test_a_write_failure_restores_every_attempted_gateway(
    family: ModuleType,
    gateways: tuple[Any, ...],
    failure: str,
    container: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {gateway.persona: gateway.config_path.read_bytes() for gateway in gateways}
    fake = FakeGateways(family, {gateway.container: gateway.state for gateway in gateways})

    def run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        is_write = argv[:3] == ["docker", "exec", "-i"] and "--dry-run" not in argv
        if is_write:
            for gateway in gateways:
                (saved,) = gateway.state.glob("openclaw.json.pre-family-group-*")
                assert saved.read_bytes() == before[gateway.persona]
        result = fake(argv, **kwargs)
        if is_write and argv[3] == container:
            if failure == "timeout":
                raise subprocess.TimeoutExpired(argv, 120)
            if failure == "exec-unavailable":
                raise OSError("docker exec unavailable")
            return completed(returncode=1)
        return result

    status = family.apply(gateways, run=run, dry_run=False)

    assert status == 1
    assert fake.restores == (
        ["openclaw-gateway"]
        if container == "openclaw-gateway"
        else ["openclaw-denise", "openclaw-gateway"]
    )
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]
        (saved,) = gateway.state.glob("openclaw.json.pre-family-group-*")
        assert saved.read_bytes() == before[gateway.persona]
    assert "restored previous config" in capsys.readouterr().err


@needs_nofollow_open
def test_a_failed_postwrite_check_restores_both_gateways(
    family: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    before = {gateway.persona: gateway.config_path.read_bytes() for gateway in gateways}
    fake = FakeGateways(family, {gateway.container: gateway.state for gateway in gateways})

    def run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if argv[:4] == ["docker", "exec", "-i", "openclaw-denise"] and "--dry-run" not in argv:
            return completed()
        return fake(argv, **kwargs)

    status = family.apply(gateways, run=run, dry_run=False)

    assert status == 1
    assert fake.restores == ["openclaw-denise", "openclaw-gateway"]
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]
    assert "written configs do not follow the policy" in capsys.readouterr().err


@needs_nofollow_open
def test_a_failed_rollback_is_reported_and_other_gateways_are_restored(
    family: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    before = {gateway.persona: gateway.config_path.read_bytes() for gateway in gateways}
    fake = FakeGateways(family, {gateway.container: gateway.state for gateway in gateways})

    def run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if argv[:4] == ["docker", "exec", "openclaw-denise", "cp"]:
            return completed(returncode=1)
        result = fake(argv, **kwargs)
        if argv[:4] == ["docker", "exec", "-i", "openclaw-denise"] and "--dry-run" not in argv:
            return completed(returncode=1)
        return result

    status = family.apply(gateways, run=run, dry_run=False)

    assert status == 1
    assert gateways[0].config_path.read_bytes() == before["corey"]
    assert gateways[1].config_path.read_bytes() != before["denise"]
    (saved,) = gateways[1].state.glob("openclaw.json.pre-family-group-*")
    assert saved.read_bytes() == before["denise"]
    error = capsys.readouterr().err
    assert f"denise: rollback failed; previous config at {saved}" in error
    assert "corey: restored previous config" in error


@pytest.mark.parametrize(
    "switched_off",
    [
        {"enabled": False},
        {"groupPolicy": "disabled"},
        {"groups": {THE_FAM: {"enabled": False}}},
        {"groups": {"*": {"enabled": False}}, "groupAllowFrom": [FRANCO, GIA]},
        {"groups": {"*": {"groupPolicy": "disabled"}}},
    ],
    ids=["telegram-off", "groups-off", "the-fam-off", "wildcard-off", "wildcard-policy-off"],
)
@needs_nofollow_open
def test_apply_does_not_override_something_switched_off_on_purpose(
    family: ModuleType,
    gateways: tuple[Any, ...],
    switched_off: dict[str, Any],
    capsys: pytest.CaptureFixture[str],
) -> None:
    denise = gateways[1]
    write_state(denise.state, with_telegram(**switched_off))
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.apply(gateways, run=run, dry_run=False) == 1

    assert run.calls == []
    assert "nothing written" in capsys.readouterr().err


@needs_nofollow_open
def test_check_reports_both_gateways_and_fails_while_one_drops_the_household(
    family: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    assert family.check(gateways, run=lambda *_, **__: completed(PROBE_OUTPUT), probe=True) == 1

    out = capsys.readouterr().out
    assert "corey (openclaw-gateway), franco's assistant" in out
    assert "denise (openclaw-denise), gia's assistant" in out
    assert "franco       dropped (not-allowed)   <- should be answered" in out
    assert "@Denise_the_woman_bot" in out


@needs_nofollow_open
def test_check_cli_always_probes_the_gateways(
    family: ModuleType,
    gateways: tuple[Any, ...],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    calls: list[list[str]] = []

    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        calls.append(argv)
        return completed(PROBE_OUTPUT)

    monkeypatch.setattr(family, "GATEWAYS", gateways)

    assert family.main(["check"], run=run) == 1
    telegram_probes = [call for call in calls if "channels" in call]
    assert len(telegram_probes) == 2
    assert all("--probe" in call for call in telegram_probes)
    probed = len(calls)
    with pytest.raises(SystemExit) as error:
        family.main(["check", "--no-probe"], run=run)
    assert error.value.code == 2
    assert "unrecognized arguments: --no-probe" in capsys.readouterr().err
    assert len(calls) == probed


def test_check_says_to_run_as_root_when_it_cannot_read(
    family: ModuleType,
    gateways: tuple[Any, ...],
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The state directories are mode 0700 and owned by the gateway's uid."""

    def denied(gateway: object) -> dict[str, Any]:
        raise PermissionError(13, "Permission denied", str(gateway))

    monkeypatch.setattr(family, "read_config", denied)

    assert family.check(gateways[:1], run=lambda *_, **__: completed(), probe=False) == 1
    assert "(run as root)" in capsys.readouterr().out


# Voice notes. Run through the pinned gateway on 2026-10-06 with The Fam's policy entry,
# OpenRouter transcription and a fake Bot API serving the voice files: Gia saying
# "Denise, what's for dinner tonight?" was transcribed, matched Denise's name and was
# answered; a voice reply to Denise's message was answered; a note naming nobody, and
# one naming Corey, were not. The transcript reached the model as
# `[Audio transcript (machine-generated, untrusted)]: "..."` with the sender's name.
# The checks below are the config those outcomes depend on.


def test_a_name_counts_as_a_mention_only_when_openclaw_json_carries_one(
    family: ModuleType,
) -> None:
    named = with_telegram()
    assert family.name_is_a_mention(named)

    unnamed = with_telegram()
    del unnamed["agents"]
    assert not family.name_is_a_mention(unnamed)
    assert "its name is not a mention, so only its @handle and replies reach it" in (
        family.problems(unnamed, "denise")
    )

    # An explicit empty list switches the derived name off, at either level.
    silenced = with_telegram()
    silenced["messages"] = {"groupChat": {"mentionPatterns": []}}
    assert not family.name_is_a_mention(silenced)
    patterned = with_telegram()
    del patterned["agents"]
    patterned["messages"] = {"groupChat": {"mentionPatterns": ["\\bdenise\\b"]}}
    assert family.name_is_a_mention(patterned)


def test_voice_notes_are_checked_for_the_name_unless_a_group_says_not_to(
    family: ModuleType,
) -> None:
    off_everywhere = with_telegram(groups={"*": {"disableAudioPreflight": True}})
    assert family.voice_preflight_disabled(off_everywhere, THE_FAM)

    fixed = family.patched(off_everywhere, family.policy_patch("denise"))
    assert not family.voice_preflight_disabled(fixed, THE_FAM)
    assert family.problems(fixed, "denise") == []


@needs_nofollow_open
def test_apply_names_an_assistant_whose_name_is_not_a_mention(
    family: ModuleType, gateways: tuple[Any, ...]
) -> None:
    unnamed = with_telegram()
    del unnamed["agents"]
    write_state(gateways[1].state, unnamed)

    planned = family.plan(gateways[1])

    assert planned.patch["agents"] == {"entries": {"main": {"identity": {"name": "Denise"}}}}
    assert family.problems(family.patched(unnamed, planned.patch), "denise") == []


@needs_nofollow_open
def test_check_fails_while_telegram_keeps_voice_notes_from_the_bot(
    family: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    for gateway in gateways:
        write_state(gateway.state, with_telegram(groups=POLICY_ENTRY))

    assert family.check(gateways, run=probing(), probe=True) == 1
    assert "Telegram privacy mode is on, so voice notes never reach it" in capsys.readouterr().out

    privacy_off = PROBE_OUTPUT.replace(
        '"canReadAllGroupMessages": false', '"canReadAllGroupMessages": true'
    )
    assert family.check(gateways, run=probing(privacy_off), probe=True) == 0
    assert "the family-room plugin is loaded" in capsys.readouterr().out


# The family room. Run through two pinned gateways on 2026-10-06 with the plugin loaded
# from a read-only mount: a voice note naming nobody was transcribed by the plugin and
# reached Denise's next turn as "Franco Marlowe, in a voice note (machine transcript)",
# and Corey's reply in the group, handed over by the relay, opened Denise's next turn as
# "Corey, the other household assistant, posted: ...". Without `ingest` the plugin never
# saw the skipped note at all. The checks below are the config that depends on.


def test_a_skipped_voice_note_reaches_the_plugin_only_with_ingest(family: ModuleType) -> None:
    assert not family.ingests_skipped_messages(with_telegram(), THE_FAM)
    everywhere = with_telegram(groups={"*": {"ingest": True}})
    assert family.ingests_skipped_messages(everywhere, THE_FAM)
    entry_wins = with_telegram(groups={"*": {"ingest": True}, THE_FAM: {"ingest": False}})
    assert not family.ingests_skipped_messages(entry_wins, THE_FAM)

    no_ingest = with_telegram(groups={THE_FAM: {**POLICY_ENTRY[THE_FAM], "ingest": False}})
    assert family.problems(no_ingest, "denise") == [
        "a voice note that does not name it is dropped unheard"
    ]


@pytest.mark.parametrize(
    ("plugins", "said"),
    [
        ({}, "the family-room plugin is not loaded from /opt/household-plugins"),
        ({"enabled": False}, "plugins are switched off"),
        ({**room_plugin(), "deny": [ROOM_PLUGIN]}, "plugins.deny blocks the family-room plugin"),
        (
            {**room_plugin(), "allow": ["telegram"]},
            "plugins.allow leaves the family-room plugin out",
        ),
        (
            {**room_plugin(), "entries": {ROOM_PLUGIN: {"enabled": False}}},
            "the family-room plugin is not enabled",
        ),
        (
            {
                **room_plugin(),
                "entries": {ROOM_PLUGIN: {"enabled": True, "config": {"groupChatId": THE_FAM}}},
            },
            "may not add context to a turn",
        ),
        (
            {
                **room_plugin(),
                "entries": {
                    ROOM_PLUGIN: {
                        "enabled": True,
                        "hooks": {"allowConversationAccess": True, "allowPromptInjection": False},
                        "config": {"groupChatId": THE_FAM},
                    }
                },
            },
            "may not add context to a turn",
        ),
        (
            {
                **room_plugin(),
                "entries": {
                    ROOM_PLUGIN: {
                        "enabled": True,
                        "hooks": {"allowConversationAccess": True},
                        "config": {"groupChatId": "-100200300"},
                    }
                },
            },
            "not watching The Fam",
        ),
    ],
    ids=[
        "absent",
        "plugins-off",
        "denied",
        "not-on-allow",
        "disabled",
        "no-conversation-access",
        "prompt-injection-off",
        "wrong-group",
    ],
)
def test_every_way_the_plugin_can_be_kept_from_running_is_named(
    family: ModuleType, plugins: dict[str, Any], said: str
) -> None:
    config = with_telegram(groups=POLICY_ENTRY)
    config["plugins"] = plugins
    assert any(said in problem for problem in family.problems(config, "denise")), said


def test_the_plugin_patch_keeps_what_the_lists_already_hold(family: ModuleType) -> None:
    config = with_telegram(groups=POLICY_ENTRY)
    config["plugins"] = {
        "allow": ["telegram", "memory-core"],
        "load": {"paths": ["/opt/other-plugin"]},
        "entries": {"memory-core": {"enabled": True}},
    }

    after = family.patched(config, family.room_plugin_patch(config))

    assert after["plugins"]["load"]["paths"] == ["/opt/other-plugin", ROOM_PLUGIN_PATH]
    assert after["plugins"]["allow"] == ["telegram", "memory-core", ROOM_PLUGIN]
    assert after["plugins"]["entries"]["memory-core"] == {"enabled": True}
    assert family.problems(after, "denise") == []
    # Nothing to add the second time.
    assert set(family.room_plugin_patch(after)["plugins"]) == {"entries"}


@pytest.mark.parametrize(
    ("missing", "said"),
    [
        (
            {"tools": {"profile": "coding", "alsoAllow": ["speak"]}},
            "the assistant is not handed family_history, so it cannot read the group's earlier "
            "messages",
        ),
        (
            {"session": {"dmScope": "main"}},
            "DMs are not kept per sender and groups per group, so family_history is never handed "
            "over",
        ),
        (
            {"session": {"dmScope": "per-channel-peer"}},
            "DMs are not kept per sender and groups per group, so family_history is never handed "
            "over",
        ),
    ],
    ids=["tool-not-handed-over", "shared-dm-session", "no-group-scope"],
)
def test_family_history_needs_the_tool_and_sessions_kept_apart(
    family: ModuleType, missing: dict[str, Any], said: str
) -> None:
    config = {**with_telegram(groups=POLICY_ENTRY), **missing}

    assert family.problems(config, "denise") == [said]


def test_the_history_patch_hands_over_the_tool_and_keeps_what_a_person_set(
    family: ModuleType,
) -> None:
    config = with_telegram(groups=POLICY_ENTRY)
    config["tools"] = {"profile": "coding", "alsoAllow": ["speak"], "deny": ["codex"]}
    config["session"] = {"dmScope": "per-account-channel-peer", "idleMinutes": 30}

    after = family.patched(config, family.history_patch(config))

    assert after["tools"] == {
        "profile": "coding",
        "alsoAllow": ["speak", "family_history"],
        "deny": ["codex"],
    }
    assert after["session"] == {
        "dmScope": "per-account-channel-peer",
        "idleMinutes": 30,
        "groupScope": "per-group",
    }
    assert family.problems(after, "denise") == []
    assert family.history_patch(after) == {}


@needs_nofollow_open
def test_apply_hands_family_history_to_a_gateway_without_it(
    family: ModuleType, gateways: tuple[Any, ...]
) -> None:
    for gateway in gateways:
        config = with_telegram(groups=POLICY_ENTRY)
        del config["tools"], config["session"]
        write_state(gateway.state, config)
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.apply(gateways, run=run, dry_run=False) == 0

    for gateway in gateways:
        config = json.loads(gateway.config_path.read_text())
        assert config["tools"] == {"alsoAllow": ["family_history"]}
        assert config["session"] == {"dmScope": "per-channel-peer", "groupScope": "per-group"}
        assert family.problems(config, gateway.persona) == []


@needs_nofollow_open
def test_apply_leaves_a_shared_dm_scope_a_person_set_to_them(
    family: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    config = with_telegram(groups=POLICY_ENTRY)
    config["session"] = {"dmScope": "main"}
    write_state(gateways[0].state, config)
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.apply(gateways, run=run, dry_run=False) == 1

    assert run.calls == []
    assert "DMs are not kept per sender" in capsys.readouterr().err


@needs_nofollow_open
def test_apply_can_write_one_gateway_and_leave_the_other_untouched(
    family: ModuleType, gateways: tuple[Any, ...], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(family, "GATEWAYS", gateways)
    monkeypatch.setattr(family.os, "geteuid", lambda: 0, raising=False)
    denise_before = gateways[1].config_path.read_bytes()
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.main(["apply", "--gateway", "corey"], run=run) == 0

    assert run.calls == [("openclaw-gateway", True), ("openclaw-gateway", False)]
    assert family.problems(json.loads(gateways[0].config_path.read_text()), "corey") == []
    assert gateways[1].config_path.read_bytes() == denise_before
    assert list(gateways[1].state.glob("openclaw.json.pre-family-group-*")) == []


@needs_nofollow_open
def test_apply_leaves_a_denied_or_switched_off_plugin_to_a_person(
    family: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    denied = with_telegram()
    denied["plugins"] = {**room_plugin(), "deny": [ROOM_PLUGIN]}
    write_state(gateways[1].state, denied)
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.apply(gateways, run=run, dry_run=False) == 1
    assert run.calls == []
    assert "plugins.deny blocks the family-room plugin" in capsys.readouterr().err


def test_apply_refuses_until_the_plugin_is_installed_on_the_box(
    family: ModuleType,
    gateways: tuple[Any, ...],
    installed_plugin: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    installed_plugin.unlink()
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.apply(gateways, run=run, dry_run=False) == 1
    assert run.calls == []
    assert "run scripts/openclaw-install.sh first" in capsys.readouterr().err


@needs_nofollow_open
def test_apply_turns_the_family_room_on_for_a_gateway_that_never_had_it(
    family: ModuleType, gateways: tuple[Any, ...]
) -> None:
    for gateway in gateways:
        bare = with_telegram()
        del bare["plugins"]
        write_state(gateway.state, bare)
    run = FakeGateways(family, {g.container: g.state for g in gateways})

    assert family.apply(gateways, run=run, dry_run=False) == 0

    for gateway in gateways:
        config = json.loads(gateway.config_path.read_text())
        assert config["plugins"] == room_plugin()
        assert config["channels"]["telegram"]["groups"][THE_FAM]["ingest"] is True
        assert family.problems(config, gateway.persona) == []


@needs_nofollow_open
def test_check_fails_while_the_plugin_is_not_loaded(
    family: ModuleType, gateways: tuple[Any, ...], capsys: pytest.CaptureFixture[str]
) -> None:
    for gateway in gateways:
        write_state(gateway.state, with_telegram(groups=POLICY_ENTRY))
    privacy_off = PROBE_OUTPUT.replace(
        '"canReadAllGroupMessages": false', '"canReadAllGroupMessages": true'
    )

    assert family.check(gateways, run=probing(privacy_off, room=UNKNOWN_METHOD), probe=True) == 1
    out = capsys.readouterr().out
    assert f"NOT loaded: unknown method: {ROOM_PLUGIN}.peer" in out
    assert "the family-room plugin is not running" in out


def test_the_plugin_probe_asks_the_plugin_to_keep_nothing(family: ModuleType) -> None:
    calls: list[list[str]] = []

    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        calls.append(argv)
        return completed('[openclaw] banner\n{\n  "accepted": 0\n}\n')

    assert family.probe_room_plugin(family.GATEWAYS[0], run) is None
    (argv,) = calls
    assert argv[:7] == [
        "docker",
        "exec",
        "openclaw-gateway",
        "node",
        "dist/index.js",
        "gateway",
        "call",
    ]
    assert argv[7] == f"{ROOM_PLUGIN}.peer"
    assert json.loads(argv[9]) == {"speaker": "Check", "posts": []}
