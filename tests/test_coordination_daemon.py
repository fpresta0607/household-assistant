"""The host daemon's tick: what it carries, what it says about it, and what it does not.

A crossing that ends in an exception is reported once and never carried again, whichever
side of the post it broke on. Leaving the request in place had the tick timer re-posting
the same sentence into the family group every fifteen seconds.

Which word it is reported under is the part the assistant acts on. `unsent` means the
relay established that the group never saw the words, so the assistant may say them
itself; `unconfirmed` means it could not establish that, so it must not. Getting that
backwards is a post the family reads twice, or a follow-up about a message nobody saw.

The request file is the claim. The tick unlinks it before it posts anything, so an
assistant that gave up waiting can take its own words back and know it did.
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
import time
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

from household.app import Household
from household.coordination import TURN_CAP, GroupMessage, GroupPostFailed
from household.family_room import MirrorState, RoomPost
from household.openclaw import (
    MAX_OUTBOX_ENTRIES_PER_PASS,
    GatewayContainer,
    OutboxBoundaryError,
    open_outbox,
    read_outbox,
)
from household.planner import Candidate, ResearchBudget, TasteMemory, Window
from tests.capabilities import needs_nofollow_open

from .conftest import FakeClock
from .test_coordination import (
    RecordingTransport,
    build_relay,
    crossing,
    human,
    open_a_turn,
    relay_without_group_changes,
)
from .test_family_room import Recorder, gateways, post, write_outbox

DAEMON = Path(__file__).resolve().parents[1] / "scripts" / "coordination-daemon.py"


@pytest.fixture
def daemon() -> ModuleType:
    # On the box the daemon runs from its own directory, which puts gateway_config beside it.
    if str(DAEMON.parent) not in sys.path:
        sys.path.insert(0, str(DAEMON.parent))
    spec = importlib.util.spec_from_file_location("coordination_daemon", DAEMON)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def outbox_with_a_request(
    daemon: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[GatewayContainer, Path]:
    gateway = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    gateway.outbox.mkdir(parents=True)
    request = gateway.outbox / "001.json"
    request.write_text(json.dumps({"text": "Denise, is Gia free Friday?"}), encoding="utf-8")
    monkeypatch.setattr(daemon, "GATEWAYS", (gateway,))
    try:
        opened = open_outbox(gateway)
    except OutboxBoundaryError as error:
        pytest.skip(str(error))
    assert opened is not None
    with opened:
        pass
    return gateway, request


def test_a_post_that_never_landed_is_unsent_rather_than_failed(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Nothing reached the group, so the assistant is free to say it itself.

    Told this was `failed`, it would instead post a follow-up in the family group
    about a sentence nobody there ever saw.
    """
    gateway, request = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    relay, transport = build_relay(household, clock, transport=RecordingTransport(fail_post=True))
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0

    result = json.loads((gateway.outbox / "001.result.json").read_text(encoding="utf-8"))
    assert result["status"] == "unsent"
    assert "telegram said no" in result["detail"]
    assert transport.posted == []
    assert not request.exists()

    transport.fail_post = False

    assert daemon.tick(relay, taste) == 0
    assert transport.posted == []


def test_a_crossing_that_broke_after_the_post_is_failed_and_never_reposted(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The group has the words already, so the next tick must not send them again."""
    gateway, request = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    relay, transport = build_relay(
        household, clock, transport=RecordingTransport(fail_delivery=True)
    )
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0

    result = json.loads((gateway.outbox / "001.result.json").read_text(encoding="utf-8"))
    assert result["status"] == "unconfirmed"
    assert result["reason"] == "RuntimeError"
    assert transport.posted == ["Denise, is Gia free Friday?"]
    assert transport.delivered == []
    assert not request.exists()

    transport.fail_delivery = False

    assert daemon.tick(relay, taste) == 0
    assert transport.posted == ["Denise, is Gia free Friday?"]


def test_an_unacknowledged_handoff_is_unconfirmed(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    gateway, _ = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    relay, transport = build_relay(
        household, clock, transport=RecordingTransport(unacknowledged_delivery=True)
    )
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0

    result = json.loads((gateway.outbox / "001.result.json").read_text(encoding="utf-8"))
    assert result["status"] == "unconfirmed"
    assert "unacknowledged" in result["reason"]
    assert transport.posted == ["Denise, is Gia free Friday?"]
    assert transport.delivered == ["Denise, is Gia free Friday?"]


def test_a_stop_after_the_group_post_prevents_the_peer_handoff(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    gateway, _ = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    relay, transport = build_relay(household, clock)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)
    reads = 0

    def stop_during_crossing(*_: object) -> None:
        nonlocal reads
        reads += 1
        if reads == 3:
            relay.ingest("corey", [human("stop", seq=2)])

    monkeypatch.setattr(daemon, "read_the_group", stop_during_crossing)

    assert daemon.tick(relay, taste) == 0

    result = json.loads((gateway.outbox / "001.result.json").read_text(encoding="utf-8"))
    assert result["status"] == "unconfirmed"
    assert "stop" in result["reason"].lower()
    assert transport.events == [("group", "corey", "Denise, is Gia free Friday?")]


def test_off_then_on_during_the_group_post_still_prevents_the_peer_handoff(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    gateway, _ = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    relay, transport = build_relay(household, clock)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)
    reads = 0

    def switch_off_then_on_during_crossing(*_: object, **__: object) -> list[GroupMessage]:
        nonlocal reads
        reads += 1
        if reads == 3:
            return [human("!coordination off", seq=2), human("!coordination on", seq=3)]
        return []

    monkeypatch.setattr(daemon, "group_messages", switch_off_then_on_during_crossing)

    assert daemon.tick(relay, taste) == 0

    result = json.loads((gateway.outbox / "001.result.json").read_text(encoding="utf-8"))
    assert result["status"] == "unconfirmed"
    assert "off" in result["reason"].lower()
    assert transport.events == [("group", "corey", "Denise, is Gia free Friday?")]
    assert relay.enabled() is True

    relay_without_group_changes(relay, crossing("Denise, is Gia still free Friday?"))

    assert transport.delivered == ["Denise, is Gia still free Friday?"]


def test_a_request_withdrawn_before_it_is_claimed_is_never_posted(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The assistant gave up waiting and took its own words back. They stay unsaid.

    The withdrawal lands between reading the outbox and claiming the request, which
    is exactly the window the skill's timeout falls into. Posting anyway would put a
    sentence in the family group after its author was told it never got there.
    """
    gateway, request = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    relay, transport = build_relay(household, clock)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)
    reads = 0

    def withdraw_on_the_second_read(*_: object) -> None:
        nonlocal reads
        reads += 1
        if reads == 2:
            request.unlink()

    monkeypatch.setattr(daemon, "read_the_group", withdraw_on_the_second_read)

    assert daemon.tick(relay, taste) == 0

    assert transport.posted == []
    assert not (gateway.outbox / "001.result.json").exists()


def test_an_answer_nobody_came_back_for_is_dropped_after_an_hour(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The skill never deletes an answer, so the tick is the only thing that can.

    An answer that a read destroys is not an answer, and an outbox that keeps every
    answer forever is not one either. An hour outlasts any assistant's waiting.
    """
    gateway = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    gateway.outbox.mkdir(parents=True)
    try:
        opened = open_outbox(gateway)
    except OutboxBoundaryError as error:
        pytest.skip(str(error))
    assert opened is not None
    with opened:
        pass
    monkeypatch.setattr(daemon, "GATEWAYS", (gateway,))
    stale = gateway.outbox / "old.result.json"
    recent = gateway.outbox / "new.result.json"
    for path in (stale, recent):
        path.write_text(json.dumps({"status": "unconfirmed"}), encoding="utf-8")
    two_hours_ago = time.time() - 2 * 3600
    os.utime(stale, (two_hours_ago, two_hours_ago))
    relay, _ = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0

    assert not stale.exists()
    assert recent.exists()


def test_an_answer_appears_whole_or_not_at_all(daemon: ModuleType, tmp_path: Path) -> None:
    """The skill polls this path every couple of seconds while the daemon writes it.

    Writing in place truncates first, so a read landing inside the write would hand the
    assistant a traceback where it expected a status. Renaming into place means the
    reader sees the previous answer or the new one, never a torn file, and never a
    moment where the path exists but holds nothing.
    """
    gateway = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    gateway.outbox.mkdir(parents=True)
    try:
        opened = open_outbox(gateway)
    except OutboxBoundaryError as error:
        pytest.skip(str(error))
    assert opened is not None
    with opened as outbox:
        daemon.write_answer(outbox, "abc.result.json", {"status": "relayed", "turn_id": "one"})
        daemon.write_answer(
            outbox,
            "abc.result.json",
            {"status": "unconfirmed", "reason": "two"},
        )
    answer = gateway.outbox / "abc.result.json"

    assert json.loads(answer.read_text(encoding="utf-8"))["status"] == "unconfirmed"
    # Nothing is left behind that a later read or a prune could trip over.
    assert sorted(path.name for path in gateway.outbox.iterdir()) == ["abc.result.json"]


def test_an_answer_belongs_to_the_outbox_owner(daemon: ModuleType, tmp_path: Path) -> None:
    if not hasattr(os, "fchown"):
        pytest.skip("descriptor ownership is unavailable")
    gateway = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    outbox = gateway.outbox
    outbox.mkdir(parents=True)
    if os.geteuid() == 0:
        os.chown(outbox, 1, 1)
    elif outbox.stat().st_uid == os.geteuid():
        pytest.skip("this process cannot create an outbox owned by another uid")
    opened = open_outbox(gateway)
    assert opened is not None
    with opened as secured:
        daemon.write_answer(
            secured,
            "abc.result.json",
            {"status": "relayed", "turn_id": "one"},
        )
    answer = outbox / "abc.result.json"

    assert answer.stat().st_uid == outbox.stat().st_uid
    assert stat.S_IMODE(answer.stat().st_mode) == 0o600


def test_a_precreated_answer_symlink_cannot_overwrite_its_target(
    daemon: ModuleType, tmp_path: Path
) -> None:
    gateway = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    gateway.outbox.mkdir(parents=True)
    answer = gateway.outbox / "abc.result.json"
    staging = gateway.outbox / "abc.result.json.partial"
    victim = tmp_path / "victim"
    victim.write_text("keep me", encoding="utf-8")
    try:
        staging.symlink_to(victim)
    except OSError as error:
        pytest.skip(f"symlinks are unavailable: {error}")

    try:
        opened = open_outbox(gateway)
    except OutboxBoundaryError as error:
        pytest.skip(str(error))
    assert opened is not None
    with opened as outbox:
        daemon.write_answer(outbox, answer.name, {"status": "relayed", "turn_id": "one"})

    assert victim.read_text(encoding="utf-8") == "keep me"
    assert json.loads(answer.read_text(encoding="utf-8"))["status"] == "relayed"
    assert not staging.exists()


def test_a_symlinked_request_is_not_read_from_the_assistant_outbox(tmp_path: Path) -> None:
    gateway = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    gateway.outbox.mkdir(parents=True)
    target = tmp_path / "outside.json"
    target.write_text(json.dumps({"text": "follow this link"}), encoding="utf-8")
    try:
        (gateway.outbox / "001.json").symlink_to(target)
    except OSError as error:
        pytest.skip(f"symlinks are unavailable: {error}")

    try:
        opened = open_outbox(gateway)
    except OutboxBoundaryError as error:
        pytest.skip(str(error))
    assert opened is not None
    with opened as outbox:
        assert read_outbox(outbox, gateway.persona_id) == []


def test_an_unsafe_outbox_does_not_starve_the_peer(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    corey = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    denise = GatewayContainer("denise", "openclaw-denise", tmp_path / "denise")
    denise.outbox.mkdir(parents=True)
    (denise.outbox / "001.json").write_text(
        json.dumps({"text": "Corey, is Franco free Friday?"}), encoding="utf-8"
    )
    try:
        opened = open_outbox(denise)
    except OutboxBoundaryError as error:
        pytest.skip(str(error))
    assert opened is not None
    with opened:
        pass
    corey.outbox.parent.mkdir(parents=True)
    try:
        corey.outbox.symlink_to(denise.outbox, target_is_directory=True)
    except OSError as error:
        pytest.skip(f"symlinks are unavailable: {error}")
    monkeypatch.setattr(daemon, "GATEWAYS", (corey, denise))
    relay, transport = build_relay(household, clock)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 1

    assert transport.posted == ["Corey, is Franco free Friday?"]
    refusal = capsys.readouterr().err
    assert "corey" in refusal
    assert "outbox" in refusal


def test_deeply_nested_json_does_not_starve_the_peer(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    corey = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    denise = GatewayContainer("denise", "openclaw-denise", tmp_path / "denise")
    corey.outbox.mkdir(parents=True)
    denise.outbox.mkdir(parents=True)
    nesting = sys.getrecursionlimit() + 100
    (corey.outbox / "000.json").write_text("[" * nesting + "0" + "]" * nesting, encoding="utf-8")
    (denise.outbox / "001.json").write_text(
        json.dumps({"text": "Corey, is Franco free Friday?"}), encoding="utf-8"
    )
    for gateway in (corey, denise):
        try:
            opened = open_outbox(gateway)
        except OutboxBoundaryError as error:
            pytest.skip(str(error))
        assert opened is not None
        with opened:
            pass
    monkeypatch.setattr(daemon, "GATEWAYS", (corey, denise))
    relay, transport = build_relay(household, clock)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 1

    assert transport.posted == ["Corey, is Franco free Friday?"]


def test_an_outbox_flood_does_not_starve_the_peer(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    corey = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    denise = GatewayContainer("denise", "openclaw-denise", tmp_path / "denise")
    corey.outbox.mkdir(parents=True)
    denise.outbox.mkdir(parents=True)
    for index in range(MAX_OUTBOX_ENTRIES_PER_PASS + 1):
        (corey.outbox / f"{index:04}.result.json").write_text("{}", encoding="utf-8")
    (denise.outbox / "001.json").write_text(
        json.dumps({"text": "Corey, is Franco free Friday?"}), encoding="utf-8"
    )
    for gateway in (corey, denise):
        try:
            opened = open_outbox(gateway)
        except OutboxBoundaryError as error:
            pytest.skip(str(error))
        assert opened is not None
        with opened:
            pass
    monkeypatch.setattr(daemon, "GATEWAYS", (corey, denise))
    relay, transport = build_relay(household, clock)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 1

    assert transport.posted == ["Corey, is Franco free Friday?"]
    notice = capsys.readouterr().err
    assert "corey" in notice
    assert "entry limit" in notice


def test_failed_posts_stop_at_the_attempt_cap_without_starving_the_peer(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    corey = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    denise = GatewayContainer("denise", "openclaw-denise", tmp_path / "denise")
    corey.outbox.mkdir(parents=True)
    denise.outbox.mkdir(parents=True)
    for index in range(TURN_CAP + 1):
        (corey.outbox / f"{index:03}.json").write_text(
            json.dumps({"text": f"failed post {index}"}), encoding="utf-8"
        )
    (denise.outbox / "001.json").write_text(
        json.dumps({"text": "Corey, is Franco free Friday?"}), encoding="utf-8"
    )
    for gateway in (corey, denise):
        try:
            opened = open_outbox(gateway)
        except OutboxBoundaryError as error:
            pytest.skip(str(error))
        assert opened is not None
        with opened:
            pass
    monkeypatch.setattr(daemon, "GATEWAYS", (corey, denise))

    class PersonaTransport(RecordingTransport):
        def __init__(self) -> None:
            super().__init__()
            self.attempted: list[str] = []

        def post_to_group(self, persona_id: str, text: str) -> str:
            self.attempted.append(persona_id)
            if persona_id == "corey":
                raise GroupPostFailed("telegram said no")
            return super().post_to_group(persona_id, text)

    transport = PersonaTransport()
    relay, _ = build_relay(household, clock, transport=transport)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 1

    assert transport.attempted.count("corey") == TURN_CAP
    assert (corey.outbox / f"{TURN_CAP:03}.json").exists()
    assert transport.posted == ["Corey, is Franco free Friday?"]
    assert transport.delivered == ["Corey, is Franco free Friday?"]


def test_a_nonregular_prune_entry_does_not_block_a_request(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    gateway, _ = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    directory = gateway.outbox / "old.json"
    directory.mkdir()
    hours_ago = time.time() - 6 * 3600
    os.utime(directory, (hours_ago, hours_ago))
    relay, transport = build_relay(household, clock)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 1

    assert directory.is_dir()
    assert transport.posted == ["Denise, is Gia free Friday?"]


def test_a_non_regular_outbox_entry_is_removed_and_said_out_loud(
    daemon: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Removed, not skipped, and the persona is named.

    An earlier round skipped non-regular entries during pruning, which left a FIFO
    named like a request sitting in the outbox permanently: the tick blocked on it,
    systemd killed the unit, and the next tick found it still there and blocked again.
    Nothing legitimate puts one of these here, so it is an attack or a corruption
    either way, and the journal is where whoever is wondering why the pair went quiet
    will look.
    """
    if not hasattr(os, "mkfifo") or os.open not in os.supports_dir_fd:
        pytest.skip("this platform has no FIFOs or no descriptor-relative open")
    gateway = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    gateway.outbox.mkdir(parents=True)
    os.mkfifo(gateway.outbox / "000.json")

    opened = open_outbox(gateway)
    assert opened is not None
    with opened as outbox:
        daemon.prune_outbox(outbox, gateway.persona_id)

    assert not (gateway.outbox / "000.json").exists()
    printed = capsys.readouterr().err
    assert "corey" in printed
    assert "000.json" in printed


@pytest.mark.parametrize(
    "metadata",
    [
        SimpleNamespace(st_mode=stat.S_IFLNK | 0o755, st_uid=0),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o755, st_uid=1000),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o775, st_uid=0),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o757, st_uid=0),
    ],
)
def test_an_untrusted_calendar_reader_fails_the_unit_rather_than_going_quiet(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    metadata: SimpleNamespace,
) -> None:
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    monkeypatch.setattr(daemon.os, "lstat", lambda _: metadata)

    def must_not_run(*_: object, **__: object) -> None:
        raise AssertionError("the untrusted calendar reader was executed")

    monkeypatch.setattr(daemon.subprocess, "run", must_not_run)

    # Non-zero, and deliberately not NOTHING_TO_PROPOSE. Type=oneshot reads any
    # non-zero as a failed unit, which is what makes the fault visible; returning 0
    # here left the weekly timer green while the reader root executes was missing,
    # replaced or writable by someone it should not be.
    assert daemon.plan(relay, taste, budget, dry_run=True) == daemon.TRUST_BOUNDARY_FAULT
    assert daemon.TRUST_BOUNDARY_FAULT != daemon.NOTHING_TO_PROPOSE
    assert "calendar reader" in capsys.readouterr().err
    assert transport.events == []


def test_the_research_array_survives_the_cli_banner(daemon: ModuleType) -> None:
    """The gateway prints a bracketed config line before its own output.

    This repository already knew that: `_message_id` exists for exactly that reason
    and tests/test_openclaw.py asserts the shape. A pattern spanning the first "[" to
    the last "]" swallows the banner and fails to decode, so the array is found by
    trying to decode at each bracket instead.
    """
    output = (
        "[config] warnings: plugins.entries.codex: plugin disabled (bundled)\n"
        '[{"name": "Cantigny Fall Fest", "area": "Wheaton", "what": "live music",'
        ' "tags": ["autumn"]}]\n'
        "done\n"
    )

    [candidate] = daemon._parse_candidates(output)

    assert candidate.name == "Cantigny Fall Fest"
    assert candidate.tags == ("autumn",)


def test_output_with_no_array_at_all_is_an_error(daemon: ModuleType) -> None:
    with pytest.raises(RuntimeError, match="no JSON array"):
        daemon._parse_candidates("[config] warnings: something\nI could not find anything.\n")


def test_an_empty_research_result_opens_no_proposal(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Nothing to pick means nothing to say, not a message that lists no options."""
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    monkeypatch.setattr(daemon, "shared_calendar", lambda start, end: [])
    monkeypatch.setattr(daemon, "research", lambda window, interests: [])

    # Zero, because having nothing to propose is the design working. A non-zero exit
    # would leave systemd marking the weekly planner failed for behaving correctly.
    assert daemon.plan(relay, taste, budget, dry_run=False) == 0
    assert transport.events == []


def test_a_research_turn_that_found_nothing_is_parsed_rather_than_raised(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The same outcome as above, reached through the parser instead of around it.

    The test above stubs `research`, so it never touches `_parse_candidates` and
    cannot see what this one is for: the parser rejected an empty array, so a research
    turn that honestly found nothing raised and the weekly unit failed for behaving
    exactly as designed. The comment above it named that failure while being unable to
    observe it, which is worse than no test, because it reads as coverage.

    So this one stubs the subprocess, which is the real external boundary, and leaves
    `research` and `_parse_candidates` to run.
    """
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    monkeypatch.setattr(daemon, "shared_calendar", lambda start, end: [])
    monkeypatch.setattr(
        daemon.subprocess,
        "run",
        lambda *_, **__: SimpleNamespace(stdout="[]", stderr="", returncode=0),
    )

    assert daemon.plan(relay, taste, budget, dry_run=False) == daemon.NOTHING_TO_PROPOSE
    assert transport.events == []


def test_a_malformed_research_answer_is_not_read_as_found_nothing(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An almost-right answer fails the unit rather than hiding behind an empty tags list.

    The second item has a null area, so the whole array is refused. The scanner used to
    resume one character past the refused array's opening bracket and reach the first
    item's empty `tags`, which an empty array is accepted as, so a malformed reply
    became found nothing, spent the day's research, and left the unit green.
    """
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    monkeypatch.setattr(daemon, "shared_calendar", lambda start, end: [])
    stdout = (
        '[{"name":"A","area":"Itasca","what":"x","tags":[]},'
        '{"name":"B","area":null,"what":"y","tags":["food"]}]'
    )
    monkeypatch.setattr(
        daemon.subprocess,
        "run",
        lambda *_, **__: SimpleNamespace(stdout=stdout, stderr="", returncode=0),
    )

    with pytest.raises(RuntimeError, match="no JSON array of candidates"):
        daemon.plan(relay, taste, budget, dry_run=False)
    assert transport.events == []


def test_a_citation_marker_is_not_the_research_answer(daemon: ModuleType) -> None:
    """The research turn is a model's, so JSON-and-nothing-else is a wish.

    "[1]" decodes as a list perfectly well, and indexing it by name is a TypeError
    rather than an honest failure, so the shape the caller wanted is part of the
    question rather than something checked afterwards.
    """
    output = (
        "[config] warnings: plugin disabled\n"
        "Four options for that Friday [1]:\n\n"
        '[{"name": "Cantigny Fall Fest", "area": "Wheaton", "what": "a fall festival",'
        ' "tags": ["autumn"]}]\n'
    )

    [candidate] = daemon._parse_candidates(output)

    assert candidate.name == "Cantigny Fall Fest"


def test_an_array_of_the_wrong_shape_is_an_honest_failure(daemon: ModuleType) -> None:
    with pytest.raises(RuntimeError, match="no JSON array of candidates"):
        daemon._parse_candidates("[config] warnings\nI found [1] and [2] but nothing open.\n")


def test_a_spent_research_budget_is_reported_rather_than_raised(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A designed outcome, so it reads like the other two nothing-to-propose paths.

    Escaping plan() made the weekly unit fail on a day the planner had simply
    already researched a different window.
    """
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    # The day's one turn, spent on some other evening.
    budget.candidates(
        Window(start=clock.now + timedelta(days=30), end=clock.now + timedelta(days=30, hours=3)),
        lambda: [_a_candidate()],
    )
    monkeypatch.setattr(daemon, "shared_calendar", lambda start, end: [])
    monkeypatch.setattr(daemon, "research", lambda window, interests: [_a_candidate()])

    assert daemon.plan(relay, taste, budget, dry_run=True) == 0
    assert transport.events == []


def _a_candidate() -> Candidate:
    return Candidate("Cantigny Fall Fest", "Wheaton", "a fall festival", ("autumn",))


def test_the_season_comes_from_the_evening_not_from_the_day_it_was_written(
    daemon: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """This job fires every Wednesday indefinitely, so a fixed season goes stale.

    A prompt asserting that it is autumn would have been asking a model for pumpkin
    patches and haunted houses in February, getting nothing useful, and failing
    nowhere anyone would see. It is the window's own month that decides.
    """
    asked: list[str] = []

    def fake_run(argv: list[str], **_: object) -> SimpleNamespace:
        asked.append(argv[argv.index("--message") + 1])
        return SimpleNamespace(stdout='[{"name": "n", "area": "a", "what": "w", "tags": []}]')

    # On the daemon's own reference, and undone afterwards: subprocess is shared, and
    # replacing run() on it outright took four unrelated tests down with it.
    monkeypatch.setattr(daemon.subprocess, "run", fake_run)

    for month, expected in ((10, "autumn"), (2, "winter"), (7, "summer"), (4, "spring")):
        asked.clear()
        window = Window(
            start=datetime(2027, month, 10, 23, 0, tzinfo=UTC),
            end=datetime(2027, month, 11, 4, 0, tzinfo=UTC),
        )
        daemon.research(window, ["live music"])
        assert f"It is {expected}:" in asked[0], (month, asked[0])

    # Every month resolves, including the December wrap, which is the one the
    # (month % 12) // 3 arithmetic could get wrong.
    assert {daemon.season_of(month)[0] for month in range(1, 13)} == {
        "winter",
        "spring",
        "summer",
        "autumn",
    }
    assert daemon.season_of(12)[0] == "winter"
    assert daemon.season_of(1)[0] == "winter"


def test_a_tags_field_that_is_not_a_list_is_no_tags(daemon: ModuleType) -> None:
    """A string is iterable, so taking it at its word made "autumn" six letters.

    None of them match a real tag, so the candidate silently stopped being rankable
    and its six wrong tags went on to be shown as why it was suggested. A list of
    strings is the one spelling the prompt asks for, so it is the one read here, and
    the candidate is still offered, just without a tag to rank it by.
    """
    output = (
        '[{"name": "Cantigny Fall Fest", "area": "Wheaton", "what": "a fall festival",'
        ' "tags": "autumn"}]'
    )

    [candidate] = daemon._parse_candidates(output)

    assert candidate.tags == ()
    assert candidate.name == "Cantigny Fall Fest"


def test_a_candidate_missing_the_fields_that_name_it_is_not_the_answer(
    daemon: ModuleType,
) -> None:
    """name, area and what have to be strings, because they are printed as strings."""
    with pytest.raises(RuntimeError, match="no JSON array of candidates"):
        daemon._parse_candidates('[{"name": 1, "area": "Wheaton", "what": "a festival"}]')
    with pytest.raises(RuntimeError, match="no JSON array of candidates"):
        daemon._parse_candidates('[{"name": "Cantigny", "area": "Wheaton"}]')


def test_tags_that_are_neither_a_list_nor_a_string_are_dropped(daemon: ModuleType) -> None:
    output = (
        '[{"name": "Cantigny", "area": "Wheaton", "what": "a festival",'
        ' "tags": ["autumn", 7, null]}]'
    )

    [candidate] = daemon._parse_candidates(output)

    assert candidate.tags == ("autumn",)


def test_a_request_nobody_came_back_for_is_not_posted_hours_later(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An ask whose process died leaves its request behind, and nothing aged it out.

    The harm is not the file. It is that the next time a person opens a turn, those
    stale words go into it as though they were part of it, spending a slot of a
    conversation they were never in.
    """
    gateway, request = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    hours_ago = time.time() - 6 * 3600
    os.utime(request, (hours_ago, hours_ago))
    relay, transport = build_relay(household, clock)
    # A person has just spoken, so there is a live turn for it to gatecrash.
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0

    assert not request.exists()
    assert transport.events == []
    answer = json.loads((gateway.outbox / "001.result.json").read_text(encoding="utf-8"))
    assert answer["status"] == "unsent"


def test_a_request_from_a_closed_turn_is_refused_in_the_next_turn(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clock.now = datetime.now(UTC)
    gateway, request = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    relay, transport = build_relay(household, clock)
    relay.ingest(
        "corey",
        [human("Corey, ask Denise about Friday", seq=1, at=clock.now)],
    )
    written_at = clock.now + timedelta(seconds=1)
    os.utime(request, (written_at.timestamp(), written_at.timestamp()))
    relay.ingest("corey", [human("stop", seq=2, at=clock.now + timedelta(seconds=2))])
    clock.advance(timedelta(minutes=2))
    relay.ingest(
        "corey",
        [human("Corey, start something else", seq=3, at=clock.now)],
    )
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0

    result = json.loads((gateway.outbox / "001.result.json").read_text(encoding="utf-8"))
    assert result["status"] == "refused"
    assert "stale request" in result["reason"]
    assert transport.events == []


def test_a_request_written_moments_ago_is_still_carried(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The other direction, so the pruning cannot quietly eat live traffic."""
    gateway, _ = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    relay, transport = build_relay(household, clock)
    open_a_turn(relay)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 1

    assert transport.posted == ["Denise, is Gia free Friday?"]
    result = json.loads((gateway.outbox / "001.result.json").read_text(encoding="utf-8"))
    assert result["status"] == "relayed"


def test_a_request_too_corrupt_to_read_is_still_aged_out(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Found by name, not by parsing it.

    read_outbox skips a file it cannot parse, so pruning through it would have left
    exactly the files nothing else touches sitting there forever, which is the thing
    the pruning exists to stop.
    """
    gateway, _ = outbox_with_a_request(daemon, tmp_path, monkeypatch)
    corrupt = gateway.outbox / "002.json"
    corrupt.write_text("{ this was never json", encoding="utf-8")
    hours_ago = time.time() - 6 * 3600
    os.utime(corrupt, (hours_ago, hours_ago))
    relay, _ = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)

    daemon.tick(relay, taste)

    assert not corrupt.exists()


def test_a_dry_run_is_switched_off_like_any_other(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The runbook promises no research turn is spent while the switch is off.

    The dry run was exempt, and the install script hands an operator the dry run as
    the first thing to try, so the promise was false on exactly the path they are
    told to take. A dry run reserves the day's only research turn like any other.
    """
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    relay.set_enabled(enabled=False, person_id="franco")
    read_the_calendar: list[int] = []

    def calendar(start: datetime, end: datetime) -> list[object]:
        read_the_calendar.append(1)
        return []

    monkeypatch.setattr(daemon, "shared_calendar", calendar)
    monkeypatch.setattr(daemon, "research", lambda window, interests: [_a_candidate()])

    assert daemon.plan(relay, taste, budget, dry_run=True) == 0

    assert read_the_calendar == []
    assert transport.events == []
    with household.database.read() as cx:
        assert cx.execute("SELECT COUNT(*) FROM research_budget").fetchone()[0] == 0


def test_a_pending_off_command_stops_dry_run_before_calendar_or_research(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    calendar_reads: list[int] = []
    research_turns: list[int] = []

    def group_messages(database: Path, **_: object) -> list[GroupMessage]:
        if database == daemon.GATEWAYS[0].agent_database:
            return [human("!coordination off")]
        return []

    def calendar(start: datetime, end: datetime) -> list[object]:
        calendar_reads.append(1)
        return []

    def research(window: Window, interests: list[str]) -> list[Candidate]:
        research_turns.append(1)
        return [_a_candidate()]

    monkeypatch.setattr(daemon, "group_messages", group_messages)
    monkeypatch.setattr(daemon, "shared_calendar", calendar)
    monkeypatch.setattr(daemon, "research", research)

    assert daemon.plan(relay, taste, budget, dry_run=True) == 0

    assert calendar_reads == []
    assert research_turns == []
    assert transport.events == []
    assert "switched off" in capsys.readouterr().err


def _state_of(household: Household) -> tuple[list[object], int, int]:
    """The three tables a planner run must leave alone: cursors, seen keys, turns."""
    with household.database.read() as cx:
        cursors = cx.execute(
            "SELECT persona_id, last_seq FROM coordination_cursor ORDER BY persona_id"
        ).fetchall()
        seen = cx.execute("SELECT COUNT(*) FROM coordination_seen").fetchone()[0]
        turns = cx.execute("SELECT COUNT(*) FROM coordination_turn").fetchone()[0]
    return [tuple(row) for row in cursors], int(seen), int(turns)


def _planner_reading(
    daemon: ModuleType, monkeypatch: pytest.MonkeyPatch, pending: list[object]
) -> list[int]:
    """Point the daemon at one gateway whose transcript holds these pending messages."""
    gateway = GatewayContainer("corey", "openclaw-gateway", Path("/nonexistent"))
    monkeypatch.setattr(daemon, "GATEWAYS", (gateway,))
    monkeypatch.setattr(daemon, "group_messages", lambda *_, **__: pending)
    read_the_calendar: list[int] = []

    def calendar(start: datetime, end: datetime) -> list[object]:
        read_the_calendar.append(1)
        return []

    monkeypatch.setattr(daemon, "shared_calendar", calendar)
    monkeypatch.setattr(daemon, "research", lambda window, interests: [_a_candidate()])
    return read_the_calendar


def test_an_unapplied_off_stops_the_planner_before_it_spends_anything(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The switch is honoured the moment it is typed, not at the next tick.

    The planner runs on its own timer and its own process. Reading only the persisted
    flag meant an off typed after the last tick was invisible to it, and the operator
    is told to run the dry run as the very first thing after installing.
    """
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    read_the_calendar = _planner_reading(daemon, monkeypatch, [human("!coordination off")])

    assert daemon.plan(relay, taste, budget, dry_run=True) == 0

    assert relay.enabled() is True
    assert read_the_calendar == []
    assert transport.events == []


def test_a_planner_run_proceeds_when_nothing_is_pending(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The mirror of the case above, so the refusal is not passing for its own sake."""
    relay, _ = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    read_the_calendar = _planner_reading(daemon, monkeypatch, [human("what a week")])

    daemon.plan(relay, taste, budget, dry_run=True)

    assert read_the_calendar == [1]


def test_seen_off_and_on_duplicates_do_not_stop_the_planner(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    relay, _ = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    switched_off = human("!coordination off", seq=1)
    switched_on = human(
        "!coordination on",
        seq=2,
        at=switched_off.at + timedelta(seconds=1),
    )
    relay.ingest("corey", [switched_off, switched_on])
    read_the_calendar = _planner_reading(
        daemon,
        monkeypatch,
        [switched_off, switched_on],
    )

    daemon.plan(relay, taste, budget, dry_run=True)

    assert relay.enabled() is True
    assert read_the_calendar == [1]


def test_an_off_applied_with_on_during_research_still_stops_the_proposal(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    transcript: list[GroupMessage] = []

    def group_messages(database: Path, *, after_seq: int = 0, **_: object) -> list[GroupMessage]:
        if database == daemon.GATEWAYS[0].agent_database:
            return [message for message in transcript if message.seq > after_seq]
        return []

    def research(window: Window, interests: list[str]) -> list[Candidate]:
        switched_off = human("!coordination off", seq=1, at=clock.now)
        switched_on = human(
            "!coordination on",
            seq=2,
            at=clock.now + timedelta(seconds=1),
        )
        transcript.extend((switched_off, switched_on))
        assert relay.ingest("corey", transcript) == ["switch:off", "switch:on"]
        return [_a_candidate()]

    monkeypatch.setattr(daemon, "group_messages", group_messages)
    monkeypatch.setattr(daemon, "shared_calendar", lambda start, end: [])
    monkeypatch.setattr(daemon, "research", research)
    before = _state_of(household)

    assert daemon.plan(relay, taste, budget, dry_run=False) == 0

    assert transport.events == []
    assert relay.enabled() is True
    assert _state_of(household)[1] == before[1] + 2
    assert "switched off during planning" in capsys.readouterr().err


def test_off_and_on_ingested_between_starting_snapshots_still_stop_the_proposal(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    transcript: list[GroupMessage] = []

    def group_messages(database: Path, *, after_seq: int = 0, **_: object) -> list[GroupMessage]:
        if database == daemon.GATEWAYS[0].agent_database:
            return [message for message in transcript if message.seq > after_seq]
        return []

    def now_after_tick_ingests_switches() -> datetime:
        run_start = clock.now
        switched_off = human("!coordination off", seq=1, at=run_start)
        switched_on = human(
            "!coordination on",
            seq=2,
            at=run_start + timedelta(seconds=1),
        )
        transcript.extend((switched_off, switched_on))
        assert relay.ingest("corey", transcript) == ["switch:off", "switch:on"]
        return run_start

    monkeypatch.setattr(relay, "now", now_after_tick_ingests_switches)
    monkeypatch.setattr(daemon, "group_messages", group_messages)
    monkeypatch.setattr(daemon, "shared_calendar", lambda start, end: [])
    monkeypatch.setattr(daemon, "research", lambda window, interests: [_a_candidate()])

    result = daemon.plan(relay, taste, budget, dry_run=False)

    assert result == 0
    assert transport.events == []
    assert relay.enabled() is True
    assert "switched off during planning" in capsys.readouterr().err


def test_old_applied_off_and_on_duplicates_behind_a_lagging_cursor_still_post(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    relay, transport = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    switched_off = human(
        "!coordination off",
        seq=1,
        at=clock.now - timedelta(seconds=2),
    )
    switched_on = human(
        "!coordination on",
        seq=2,
        at=clock.now - timedelta(seconds=1),
    )
    relay.ingest("corey", [switched_off, switched_on])

    def group_messages(database: Path, *, after_seq: int = 0, **_: object) -> list[GroupMessage]:
        if database == daemon.GATEWAYS[1].agent_database:
            return [message for message in (switched_off, switched_on) if message.seq > after_seq]
        return []

    monkeypatch.setattr(daemon, "group_messages", group_messages)
    monkeypatch.setattr(daemon, "shared_calendar", lambda start, end: [])
    monkeypatch.setattr(daemon, "research", lambda window, interests: [_a_candidate()])

    assert daemon.plan(relay, taste, budget, dry_run=False) == 0

    assert len(transport.posted) == 1
    assert transport.delivered == []


def test_a_planner_run_applies_nothing_it_reads(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The tick is the only ingestor, and this is what holds that.

    An earlier version had the planner call read_the_group, which made it a second
    process applying the same messages: two ingestors could each claim one human
    message and each open a turn, doubling the two-message cap. Reading without
    applying is what removes that, so the evidence is that these three tables come
    back untouched even though the planner read a message that would have opened a
    turn had it applied it.
    """
    relay, _ = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)
    budget = ResearchBudget(household.database, clock=clock)
    _planner_reading(daemon, monkeypatch, [human("Corey, ask Denise if Gia is free Friday")])
    before = _state_of(household)

    daemon.plan(relay, taste, budget, dry_run=True)

    assert _state_of(household) == before


def test_the_tick_hands_over_group_posts_and_honours_the_off_switch(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Each assistant's group posts reach the other on every tick, unless the pair is off."""
    seen: list[dict[str, object]] = []

    def mirror(gateways: object, delivery: object, state: Path, **flags: object) -> int:
        still_on = flags["still_on"]
        assert callable(still_on)
        seen.append({"state": state, "on": bool(still_on())})
        return 0

    monkeypatch.setattr(daemon, "GATEWAYS", ())
    monkeypatch.setattr(daemon, "mirror", mirror)
    relay, _ = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0
    relay.set_enabled(enabled=False, person_id="franco")
    assert daemon.tick(relay, taste) == 0

    assert seen[0]["on"] is True
    assert seen[1:]
    assert all(entry["on"] is False for entry in seen[1:])
    assert seen[0]["state"] == daemon.FAMILY_ROOM_STATE


def test_the_handover_reads_the_group_again_before_handing_anything_over(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A switch pulled after the tick's own read of the group still stops the handover."""
    answers: list[bool] = []

    def mirror(*_: object, **flags: object) -> int:
        still_on = flags["still_on"]
        assert callable(still_on)
        answers.append(bool(still_on()))
        return 0

    def group_messages(database: Path, **_: object) -> list[GroupMessage]:
        if database == daemon.GATEWAYS[0].agent_database:
            return [human("!coordination off")]
        return []

    monkeypatch.setattr(daemon, "mirror", mirror)
    monkeypatch.setattr(daemon, "group_messages", group_messages)
    relay, _ = build_relay(household, clock)

    daemon.hand_over_group_posts(relay, TasteMemory(household.database, clock=clock))

    assert answers and not any(answers)
    assert relay.enabled() is False


@pytest.mark.parametrize("commands_available_on_read", [1, 2])
@pytest.mark.parametrize("is_initially_off", [False, True])
@needs_nofollow_open
def test_off_and_on_consumed_together_skip_both_mirror_backlogs(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    commands_available_on_read: int,
    is_initially_off: bool,
) -> None:
    corey, denise = gateways(tmp_path)
    state_path = tmp_path / "coordination/family-room.json"
    pending = [post(number, f"post {number}") for number in range(60)]
    for gateway in (corey, denise):
        write_outbox(gateway, pending)
    delivery = Recorder()
    monkeypatch.setattr(daemon, "GATEWAYS", (corey, denise))
    monkeypatch.setattr(daemon, "FAMILY_ROOM_STATE", state_path)
    monkeypatch.setattr(daemon, "DockerPeerDelivery", lambda: delivery)
    monkeypatch.setattr(daemon, "open_outbox", lambda _: None)
    reads = 0
    commands = [human("!coordination off", seq=1), human("!coordination on", seq=2)]
    if is_initially_off:
        commands = [human("!coordination on", seq=1)]

    def group_messages(database: Path, *, after_seq: int, **_: object) -> list[GroupMessage]:
        nonlocal reads
        if database != corey.agent_database:
            return []
        reads += 1
        if reads < commands_available_on_read:
            return []
        return [message for message in commands if message.seq > after_seq]

    monkeypatch.setattr(daemon, "group_messages", group_messages)
    relay, _ = build_relay(household, clock)
    if is_initially_off:
        relay.set_enabled(enabled=False, person_id="franco")
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0

    assert relay.enabled() is True
    assert delivery.handed == []
    assert set(MirrorState.load(state_path).cursors) == {"corey", "denise"}
    for gateway in (corey, denise):
        write_outbox(gateway, [*pending, post(60, "After re-enabling", minutes_ago=0)])

    assert daemon.tick(relay, taste) == 0
    assert delivery.handed == [
        ("denise", "Corey", ["After re-enabling"]),
        ("corey", "Denise", ["After re-enabling"]),
    ]


@needs_nofollow_open
def test_switches_during_a_handover_skip_new_posts_from_an_already_delivered_speaker(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    corey, denise = gateways(tmp_path)
    state_path = tmp_path / "coordination/family-room.json"
    first = post(501, "Before switching off", minutes_ago=2)
    missed = post(502, "While switched off", minutes_ago=1)
    write_outbox(corey, [first])
    write_outbox(denise, [post(601, "Denise's pending post")])
    transcript: list[GroupMessage] = []
    delivery = Recorder()
    record_delivery = delivery.deliver

    def deliver(listener: GatewayContainer, speaker: str, posts: Sequence[RoomPost]) -> int:
        accepted = record_delivery(listener, speaker, posts)
        transcript.extend([human("!coordination off", seq=1), human("!coordination on", seq=2)])
        write_outbox(corey, [first, missed])
        return accepted

    def group_messages(database: Path, *, after_seq: int, **_: object) -> list[GroupMessage]:
        return (
            [message for message in transcript if message.seq > after_seq]
            if database == corey.agent_database
            else []
        )

    monkeypatch.setattr(delivery, "deliver", deliver)
    monkeypatch.setattr(daemon, "GATEWAYS", (corey, denise))
    monkeypatch.setattr(daemon, "FAMILY_ROOM_STATE", state_path)
    monkeypatch.setattr(daemon, "DockerPeerDelivery", lambda: delivery)
    monkeypatch.setattr(daemon, "open_outbox", lambda _: None)
    monkeypatch.setattr(daemon, "group_messages", group_messages)
    relay, _ = build_relay(household, clock)
    taste = TasteMemory(household.database, clock=clock)

    assert daemon.tick(relay, taste) == 0
    assert relay.enabled() is True
    assert MirrorState.load(state_path).cursors["corey"] == (missed["at"], missed["key"])
    assert daemon.tick(relay, taste) == 0
    assert delivery.handed == [("denise", "Corey", ["Before switching off"])]


def test_a_failed_handover_does_not_fail_the_tick(
    daemon: ModuleType,
    household: Household,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    def broken(*_: object, **__: object) -> int:
        raise PermissionError(13, "Permission denied", "/var/lib/household-assistant/coordination")

    monkeypatch.setattr(daemon, "GATEWAYS", ())
    monkeypatch.setattr(daemon, "mirror", broken)
    relay, _ = build_relay(household, clock)

    assert daemon.tick(relay, TasteMemory(household.database, clock=clock)) == 0
    assert "family room: handover refused" in capsys.readouterr().err
