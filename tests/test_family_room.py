"""The relay half of the family room: each assistant's group posts, handed to the other.

Telegram shows no bot another bot's posts, so the relay reads what each gateway's
household-family-room plugin recorded in `household-family-room/outbox.json` and
hands it to the other gateway's plugin. These tests hold the parts that matter: a
post crosses once, a refusal is retried without hammering a stopped container, the
off switch holds, an assistant-owned file cannot stall or mislead the root reader,
and a tick stays inside the time its systemd unit gives it.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from household.family_room import (
    HANDOVER_WINDOW,
    MAX_ROOM_OUTBOX_BYTES,
    PEER_METHOD,
    POSTS_PER_CALL,
    RETRY_AFTER,
    DockerPeerDelivery,
    DockerPeerHandover,
    MirrorState,
    RoomPost,
    handover_due,
    mentions,
    mirror,
    read_room_outbox,
)
from household.openclaw import GatewayContainer, OutboxBoundaryError
from tests.capabilities import needs_nofollow_open, needs_symlinks

NOW = datetime(2026, 10, 6, 18, 0, tzinfo=UTC)
NOW_MS = int(NOW.timestamp() * 1000)


def gateways(tmp_path: Path) -> tuple[GatewayContainer, GatewayContainer]:
    return (
        GatewayContainer("corey", "openclaw-gateway", tmp_path / "openclaw"),
        GatewayContainer("denise", "openclaw-denise", tmp_path / "openclaw-denise"),
    )


def write_outbox(gateway: GatewayContainer, records: object) -> Path:
    directory = gateway.state_directory / "household-family-room"
    directory.mkdir(parents=True, exist_ok=True)
    outbox = directory / "outbox.json"
    outbox.write_text(json.dumps(records), encoding="utf-8")
    return outbox


def post(message_id: int, text: str, *, minutes_ago: int = 1) -> dict[str, object]:
    return {
        "key": f"telegram:-5100000001:{message_id}",
        "at": NOW_MS - minutes_ago * 60_000,
        "text": text,
    }


class Recorder:
    """A peer delivery that keeps what it was handed, or refuses on request."""

    def __init__(self, *, refuse: set[str] | None = None) -> None:
        self.refuse = refuse or set()
        self.handed: list[tuple[str, str, list[str]]] = []

    def deliver(self, listener: GatewayContainer, speaker: str, posts: Sequence[RoomPost]) -> int:
        if listener.persona_id in self.refuse:
            raise RuntimeError(f"unknown method: {PEER_METHOD}")
        self.handed.append((listener.persona_id, speaker, [p.text for p in posts]))
        return len(posts)


class Starts:
    """A handover that records which turns it would start, or fails to start one."""

    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.started: list[tuple[str, str, str]] = []

    def start(self, listener: GatewayContainer, speaker: str, post: RoomPost) -> None:
        if self.fail:
            raise OSError("docker: no such container")
        self.started.append((listener.persona_id, speaker, post.text))


@needs_nofollow_open
def test_each_assistant_s_posts_reach_the_other_once(tmp_path: Path) -> None:
    corey, denise = gateways(tmp_path)
    write_outbox(corey, [post(501, "I can grab the milk.", minutes_ago=3)])
    write_outbox(denise, [post(601, "Dinner is at seven.", minutes_ago=2)])
    state = tmp_path / "coordination/family-room.json"
    delivery = Recorder()

    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == 2
    )
    assert delivery.handed == [
        ("denise", "Corey", ["I can grab the milk."]),
        ("corey", "Denise", ["Dinner is at seven."]),
    ]

    delivery.handed.clear()
    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == 0
    )
    assert delivery.handed == []
    assert stat.S_IMODE(state.stat().st_mode) == 0o600

    write_outbox(
        corey,
        [post(501, "I can grab the milk.", minutes_ago=3), post(502, "Got it.", minutes_ago=0)],
    )
    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == 1
    )
    assert delivery.handed == [("denise", "Corey", ["Got it."])]


@needs_nofollow_open
def test_a_refused_handover_is_retried_later_and_not_every_tick(tmp_path: Path) -> None:
    corey, denise = gateways(tmp_path)
    write_outbox(corey, [post(501, "I can grab the milk.")])
    state = tmp_path / "family-room.json"

    refused = Recorder(refuse={"denise"})
    assert (
        mirror((corey, denise), refused, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == 0
    )

    # Inside the rest, the stopped gateway is not asked again.
    asked = Recorder()
    soon = NOW + RETRY_AFTER - timedelta(seconds=1)
    assert (
        mirror((corey, denise), asked, state, handover=Starts(), now=soon, still_on=lambda: True)
        == 0
    )
    assert asked.handed == []

    later = NOW + RETRY_AFTER
    assert (
        mirror((corey, denise), asked, state, handover=Starts(), now=later, still_on=lambda: True)
        == 1
    )
    assert asked.handed == [("denise", "Corey", ["I can grab the milk."])]
    assert MirrorState.load(state).resting_until == {}


@needs_nofollow_open
def test_nothing_crosses_while_coordination_is_off_or_after_it(tmp_path: Path) -> None:
    corey, denise = gateways(tmp_path)
    write_outbox(corey, [post(501, "Said while the pair was switched off.")])
    state = tmp_path / "family-room.json"
    delivery = Recorder()

    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: False)
        == 0
    )
    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == 0
    )
    assert delivery.handed == []


@needs_nofollow_open
def test_a_backlog_said_while_off_is_skipped_whole_not_one_call_at_a_time(tmp_path: Path) -> None:
    """More posts than one call carries, all said while off, must not trickle out later."""
    corey, denise = gateways(tmp_path)
    while_off = [
        post(500 + n, f"post {n}", minutes_ago=200 - n) for n in range(POSTS_PER_CALL + 10)
    ]
    write_outbox(corey, while_off)
    state = tmp_path / "family-room.json"
    delivery = Recorder()

    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: False)
        == 0
    )
    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == 0
    )
    assert delivery.handed == []


@needs_nofollow_open
def test_a_switch_pulled_during_one_handover_stops_the_next(tmp_path: Path) -> None:
    """The group is read again before each assistant's posts go over, not once per pass."""
    corey, denise = gateways(tmp_path)
    write_outbox(corey, [post(501, "Corey, before the switch.")])
    write_outbox(denise, [post(601, "Denise, after the switch.")])
    state = tmp_path / "family-room.json"
    delivery = Recorder()
    answers = iter([True, False])

    assert (
        mirror(
            (corey, denise),
            delivery,
            state,
            handover=Starts(),
            now=NOW,
            still_on=lambda: next(answers),
        )
        == 1
    )
    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == 0
    )
    assert delivery.handed == [("denise", "Corey", ["Corey, before the switch."])]


@needs_nofollow_open
def test_a_backlog_drains_one_call_per_direction_per_tick(tmp_path: Path) -> None:
    corey, denise = gateways(tmp_path)
    backlog = [post(500 + n, f"post {n}", minutes_ago=200 - n) for n in range(POSTS_PER_CALL + 5)]
    write_outbox(corey, backlog)
    state = tmp_path / "family-room.json"
    delivery = Recorder()

    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == POSTS_PER_CALL
    )
    assert len(delivery.handed) == 1
    assert (
        mirror((corey, denise), delivery, state, handover=Starts(), now=NOW, still_on=lambda: True)
        == 5
    )
    assert [len(texts) for _, _, texts in delivery.handed] == [POSTS_PER_CALL, 5]


@needs_symlinks
@needs_nofollow_open
def test_one_assistant_s_unreadable_outbox_does_not_stop_the_other(tmp_path: Path) -> None:
    corey, denise = gateways(tmp_path)
    (corey.state_directory / "household-family-room").mkdir(parents=True)
    os.symlink("/etc/shadow", corey.state_directory / "household-family-room/outbox.json")
    write_outbox(denise, [post(601, "Dinner is at seven.")])
    delivery = Recorder()

    assert (
        mirror(
            (corey, denise),
            delivery,
            tmp_path / "s.json",
            handover=Starts(),
            now=NOW,
            still_on=lambda: True,
        )
        == 1
    )
    assert delivery.handed == [("corey", "Denise", ["Dinner is at seven."])]


@needs_nofollow_open
def test_the_outbox_reader_is_safe_against_the_assistant_who_owns_it(tmp_path: Path) -> None:
    corey, _ = gateways(tmp_path)
    assert read_room_outbox(corey) == []

    room = corey.state_directory / "household-family-room"
    room.mkdir(parents=True)
    os.mkfifo(room / "outbox.json")
    with pytest.raises(OutboxBoundaryError, match="not a regular file"):
        read_room_outbox(corey)
    (room / "outbox.json").unlink()

    (room / "outbox.json").write_bytes(b"[" + b" " * MAX_ROOM_OUTBOX_BYTES + b"]")
    with pytest.raises(OutboxBoundaryError, match="size bound"):
        read_room_outbox(corey)

    (room / "outbox.json").write_text("{not json", encoding="utf-8")
    assert read_room_outbox(corey) == []

    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "outbox.json").write_text(json.dumps([post(1, "planted")]), encoding="utf-8")
    (room / "outbox.json").unlink()
    room.rmdir()
    os.symlink(elsewhere, room)
    with pytest.raises(OutboxBoundaryError):
        read_room_outbox(corey)


@needs_nofollow_open
def test_only_well_formed_posts_are_read_and_in_order(tmp_path: Path) -> None:
    corey, _ = gateways(tmp_path)
    write_outbox(
        corey,
        [
            post(502, "second", minutes_ago=1),
            {"key": "", "at": NOW_MS, "text": "no key"},
            {"key": "k", "at": True, "text": "a boolean is not a time"},
            {"key": "k2", "at": NOW_MS, "text": "   "},
            "not a record",
            post(501, "first", minutes_ago=2),
        ],
    )
    assert [p.text for p in read_room_outbox(corey)] == ["first", "second"]


def test_docker_delivery_calls_the_peer_method_and_reads_its_answer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _, denise = gateways(tmp_path)
    seen: list[list[str]] = []

    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        seen.append(argv)
        return subprocess.CompletedProcess(argv, 0, '[config] banner\n{"accepted": 1}\n', "")

    monkeypatch.setattr(subprocess, "run", run)
    posts = [RoomPost(key="telegram:-5100000001:501", at=NOW_MS, text="I can grab the milk.")]
    assert DockerPeerDelivery().deliver(denise, "Corey", posts) == 1

    argv = seen[0]
    assert argv[:9] == [
        "docker",
        "exec",
        "openclaw-denise",
        "node",
        "dist/index.js",
        "gateway",
        "call",
        PEER_METHOD,
        "--params",
    ]
    assert json.loads(argv[9]) == {
        "speaker": "Corey",
        "posts": [{"id": "telegram:-5100000001:501", "at": NOW_MS, "text": "I can grab the milk."}],
    }

    def refuse(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(argv, 1, "", f"unknown method: {PEER_METHOD}")

    monkeypatch.setattr(subprocess, "run", refuse)
    with pytest.raises(RuntimeError, match="did not take the posts"):
        DockerPeerDelivery().deliver(denise, "Corey", posts)


# -- an @mention hands the request over, once --------------------------------


@pytest.mark.parametrize(
    ("text", "listener", "expected"),
    [
        ("@Denise_the_woman_bot can you check Gia's Saturday?", "denise", True),
        ("That one is Gia's, @denise can answer it.", "denise", True),
        ("@Denise, over to you.", "denise", True),
        ("Denise would know.", "denise", False),
        ("email me at someone@Denise.example", "denise", False),
        ("@Denisette is not her", "denise", False),
        ("@Corey_the_man_bot is this yours?", "corey", True),
        ("@Corey_the_man_bot is this yours?", "denise", False),
    ],
)
def test_a_mention_is_the_assistant_s_bot_or_name_after_an_at_sign(
    text: str, listener: str, expected: bool
) -> None:
    assert mentions(text, listener) is expected


def room_post(message_id: int, text: str, *, minutes_ago: float) -> RoomPost:
    return RoomPost(
        key=f"telegram:-5100000001:{message_id}",
        at=int(NOW_MS - minutes_ago * 60_000),
        text=text,
    )


def test_the_latest_fresh_mention_of_the_listener_is_the_one_handed_over() -> None:
    posts = [
        room_post(1, "@Denise what about Friday?", minutes_ago=4),
        room_post(2, "I'll grab the milk.", minutes_ago=3),
        room_post(3, "@Denise_the_woman_bot is Gia free Saturday?", minutes_ago=2),
    ]

    due = handover_due("corey", "denise", posts, {}, NOW)

    assert due is not None
    assert due.text == "@Denise_the_woman_bot is Gia free Saturday?"


def test_a_stale_mention_or_one_of_someone_else_is_not_handed_over() -> None:
    stale = HANDOVER_WINDOW.total_seconds() / 60 + 1
    assert (
        handover_due("corey", "denise", [room_post(1, "@Denise?", minutes_ago=stale)], {}, NOW)
        is None
    )
    assert (
        handover_due("corey", "denise", [room_post(2, "@Corey?", minutes_ago=1)], {}, NOW) is None
    )


def test_an_assistant_that_was_just_handed_something_hands_nothing_back() -> None:
    answer = [room_post(1, "Gia is free. @Corey_the_man_bot over to you.", minutes_ago=1)]
    received = {"denise": NOW - timedelta(minutes=2)}

    assert handover_due("denise", "corey", answer, received, NOW) is None
    window_over = {"denise": NOW - HANDOVER_WINDOW}
    assert handover_due("denise", "corey", answer, window_over, NOW) is not None


@needs_nofollow_open
def test_a_mention_starts_one_turn_of_the_other_assistant_after_the_post_is_handed_over(
    tmp_path: Path,
) -> None:
    corey, denise = gateways(tmp_path)
    write_outbox(
        corey, [post(501, "That one is Gia's. @Denise_the_woman_bot is she free?", minutes_ago=1)]
    )
    state = tmp_path / "family-room.json"
    delivery, starts = Recorder(), Starts()

    assert (
        mirror((corey, denise), delivery, state, handover=starts, now=NOW, still_on=lambda: True)
        == 1
    )

    assert delivery.handed == [
        ("denise", "Corey", ["That one is Gia's. @Denise_the_woman_bot is she free?"])
    ]
    assert starts.started == [
        ("denise", "Corey", "That one is Gia's. @Denise_the_woman_bot is she free?")
    ]
    assert (
        mirror((corey, denise), delivery, state, handover=starts, now=NOW, still_on=lambda: True)
        == 0
    )
    assert len(starts.started) == 1


@needs_nofollow_open
def test_the_handed_assistant_s_answer_never_hands_back(tmp_path: Path) -> None:
    corey, denise = gateways(tmp_path)
    state = tmp_path / "family-room.json"
    starts = Starts()
    write_outbox(corey, [post(501, "@Denise is Gia free Saturday?", minutes_ago=1)])
    mirror((corey, denise), Recorder(), state, handover=starts, now=NOW, still_on=lambda: True)

    write_outbox(denise, [post(601, "She is. @Corey back to you.", minutes_ago=0)])
    soon = NOW + timedelta(minutes=1)
    delivery = Recorder()
    assert (
        mirror((corey, denise), delivery, state, handover=starts, now=soon, still_on=lambda: True)
        == 1
    )

    assert delivery.handed == [("corey", "Denise", ["She is. @Corey back to you."])]
    assert starts.started == [("denise", "Corey", "@Denise is Gia free Saturday?")]


@needs_nofollow_open
def test_nothing_is_handed_over_while_coordination_is_off(tmp_path: Path) -> None:
    corey, denise = gateways(tmp_path)
    write_outbox(corey, [post(501, "@Denise is Gia free?", minutes_ago=1)])
    starts = Starts()

    mirror(
        (corey, denise),
        Recorder(),
        tmp_path / "s.json",
        handover=starts,
        now=NOW,
        still_on=lambda: False,
    )

    assert starts.started == []


@needs_nofollow_open
def test_a_handover_that_fails_to_start_is_reported_and_not_tried_again(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    corey, denise = gateways(tmp_path)
    write_outbox(corey, [post(501, "@Denise is Gia free?", minutes_ago=1)])
    state = tmp_path / "s.json"

    assert (
        mirror(
            (corey, denise),
            Recorder(),
            state,
            handover=Starts(fail=True),
            now=NOW,
            still_on=lambda: True,
        )
        == 1
    )
    assert "handover not started" in capsys.readouterr().err
    retried = Starts()
    mirror((corey, denise), Recorder(), state, handover=retried, now=NOW, still_on=lambda: True)
    assert retried.started == []


def test_the_handover_is_one_turn_in_the_group_session_answering_in_the_group(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    started: list[list[str]] = []

    class Process:
        def __init__(self, argv: list[str], **kwargs: object) -> None:
            assert kwargs.get("shell") is not True
            assert kwargs.get("start_new_session") is True
            started.append(argv)

    monkeypatch.setattr(subprocess, "Popen", Process)
    listener = GatewayContainer("denise", "openclaw-denise", Path("/unused"))

    DockerPeerHandover("-5100000001").start(
        listener, "Corey", RoomPost("k", NOW_MS, "@Denise is Gia free?")
    )

    (argv,) = started
    assert argv[:6] == ["docker", "exec", "openclaw-denise", "node", "dist/index.js", "agent"]
    flags = dict(zip(argv[6::2], argv[7::2], strict=False))
    assert argv[argv.index("--session-key") + 1] == "agent:main:telegram:group:-5100000001"
    assert "--deliver" in argv
    assert argv[argv.index("--reply-channel") + 1] == "telegram"
    assert argv[argv.index("--reply-to") + 1] == "-5100000001"
    message = argv[argv.index("--message") + 1]
    assert '"@Denise is Gia free?"' in message
    assert "never hand it back to Corey" in message
    assert flags
