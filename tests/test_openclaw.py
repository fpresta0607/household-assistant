"""Reading the two gateways, against a stand-in for the store OpenClaw keeps.

The schema here is the one on the box, reduced to the three tables the relay reads
and the shape of the rows it has to tell apart: a person typing in the group, the
assistant's own turn, a gateway restart notice, and a direct chat that is not the
group at all.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest

from household.coordination import GroupPostFailed, MessageOrigin
from household.openclaw import (
    MAX_OUTBOX_REQUEST_BYTES,
    DockerRelayTransport,
    GatewayContainer,
    OutboxBoundaryError,
    OutboxRequest,
    _message_id,
    first_json_value,
    group_messages,
    open_outbox,
    read_outbox,
)

GROUP_CHAT = "-5100000001"
FRANCO = "7100000001"
GIA = "7100000002"

SCHEMA = """
CREATE TABLE conversations (
    conversation_id TEXT PRIMARY KEY,
    channel TEXT,
    kind TEXT,
    peer_id TEXT,
    label TEXT
);
CREATE TABLE session_conversations (
    session_id TEXT,
    conversation_id TEXT,
    role TEXT
);
CREATE TABLE transcript_events (
    session_id TEXT,
    seq INTEGER,
    event_json TEXT,
    created_at INTEGER
);
"""


def human_event(text: str, *, sender: str = FRANCO, at_ms: int = 1789826395000) -> str:
    return json.dumps(
        {
            "type": "message",
            "message": {
                "role": "user",
                "timestamp": at_ms,
                "idempotencyKey": "channel-user:v1:whatever",
                "__openclaw": {
                    "senderIsOwner": True,
                    "senderId": sender,
                    "senderName": "Franco Marlowe" if sender == FRANCO else "Gia Marlowe",
                    "senderIdentity": {
                        "type": "observation",
                        "id": sender,
                        "pluginId": "telegram",
                        "senderKind": "human",
                    },
                },
                "content": [{"type": "text", "text": text}],
            },
        }
    )


def assistant_event(text: str) -> str:
    return json.dumps(
        {
            "type": "message",
            "message": {
                "role": "assistant",
                "timestamp": 1789826400205,
                "content": [{"type": "text", "text": text}],
            },
        }
    )


def restart_notice() -> str:
    """OpenClaw re-prompts itself as ``user`` after a gateway restart."""
    return json.dumps(
        {
            "type": "message",
            "message": {
                "role": "user",
                "timestamp": 1789829548424,
                "provenance": {"kind": "internal_system"},
                "__openclaw": {"senderIsOwner": False},
                "content": [{"type": "text", "text": "[System] Your previous turn was..."}],
            },
        }
    )


def build_store(
    path: Path,
    events: list[tuple[str, int, str]],
    *,
    extra_links: list[tuple[str, str, str]] | None = None,
) -> Path:
    database = path / "openclaw-agent.sqlite"
    connection = sqlite3.connect(database)
    connection.executescript(SCHEMA)
    connection.executemany(
        "INSERT INTO conversations (conversation_id, channel, kind, peer_id, label) "
        "VALUES (?, 'telegram', ?, ?, ?)",
        [
            ("conv-group", "group", GROUP_CHAT, "telegram:g-the-fam"),
            ("conv-direct", "direct", FRANCO, None),
        ],
    )
    connection.executemany(
        "INSERT INTO session_conversations (session_id, conversation_id, role) VALUES (?, ?, ?)",
        [("session-group", "conv-group", "primary"), ("session-direct", "conv-direct", "primary")]
        + (extra_links or []),
    )
    connection.executemany(
        "INSERT INTO transcript_events (session_id, seq, event_json, created_at) "
        "VALUES (?, ?, ?, 0)",
        events,
    )
    connection.commit()
    connection.close()
    return database


def test_a_session_in_two_conversations_is_read_from_neither(tmp_path: Path) -> None:
    """A transcript event names a session, never a conversation.

    So the group is reached through the session's links, and that table is
    many-to-many. A session linked to both the family group and somebody's direct chat
    would put the private half of it in this feed as though it had been typed in front
    of everyone, which is the one thing the whole surface exists to prevent. No session
    on either live gateway has more than one link, which is an observation rather than
    a guarantee, so one that does is skipped rather than trusted.
    """
    database = build_store(
        tmp_path,
        [("session-both", 1, human_event("something Franco said in private"))],
        extra_links=[
            ("session-both", "conv-group", "primary"),
            ("session-both", "conv-direct", "participant"),
        ],
    )

    assert group_messages(database, group_chat_id=GROUP_CHAT) == []


def test_only_what_a_person_typed_in_the_group_comes_back(tmp_path: Path) -> None:
    database = build_store(
        tmp_path,
        [
            ("session-group", 1, human_event("Corey, plan us a night out")),
            ("session-group", 2, assistant_event("On it.")),
            ("session-group", 3, restart_notice()),
            ("session-group", 4, human_event("stop", sender=GIA, at_ms=1789826400000)),
            ("session-direct", 5, human_event("read me my mail")),
        ],
    )

    messages = group_messages(database, group_chat_id=GROUP_CHAT)

    assert [(message.seq, message.sender_channel_id, message.text) for message in messages] == [
        (1, FRANCO, "Corey, plan us a night out"),
        (4, GIA, "stop"),
    ]
    assert all(message.origin is MessageOrigin.GROUP_TRANSCRIPT for message in messages)


def test_the_cursor_is_what_stops_a_message_being_acted_on_twice(tmp_path: Path) -> None:
    database = build_store(
        tmp_path,
        [
            ("session-group", 1, human_event("Corey, one")),
            ("session-group", 2, human_event("Corey, two", at_ms=1789826396000)),
        ],
    )

    assert [message.text for message in group_messages(database, group_chat_id=GROUP_CHAT)] == [
        "Corey, one",
        "Corey, two",
    ]
    assert [
        message.text for message in group_messages(database, group_chat_id=GROUP_CHAT, after_seq=1)
    ] == ["Corey, two"]


def test_a_gateway_that_has_never_run_reads_as_silence(tmp_path: Path) -> None:
    assert group_messages(tmp_path / "missing.sqlite", group_chat_id=GROUP_CHAT) == []


def test_a_malformed_row_is_skipped_rather_than_crashing_the_tick(tmp_path: Path) -> None:
    database = build_store(
        tmp_path,
        [
            ("session-group", 1, "{not json"),
            ("session-group", 2, json.dumps({"type": "session"})),
            ("session-group", 3, human_event("Corey, still here")),
        ],
    )

    assert [message.text for message in group_messages(database, group_chat_id=GROUP_CHAT)] == [
        "Corey, still here"
    ]


# -- the outbox ----------------------------------------------------------------


def gateway_at(tmp_path: Path, persona_id: str = "corey") -> GatewayContainer:
    gateway = GatewayContainer(persona_id, "openclaw-gateway", tmp_path)
    gateway.outbox.mkdir(parents=True, exist_ok=True)
    return gateway


def requests_in(gateway: GatewayContainer) -> list[OutboxRequest]:
    try:
        opened = open_outbox(gateway)
    except OutboxBoundaryError as error:
        pytest.skip(str(error))
    if opened is None:
        return []
    with opened as outbox:
        return read_outbox(outbox, gateway.persona_id)


def test_the_outbox_carries_text_and_nothing_else(tmp_path: Path) -> None:
    """A request cannot name its speaker or its origin, so it cannot claim either."""
    gateway = gateway_at(tmp_path)
    (gateway.outbox / "one.json").write_text(
        json.dumps(
            {
                "text": "Denise, is Gia free Friday?",
                "speaker_persona_id": "denise",
                "origin": "planner",
            }
        ),
        encoding="utf-8",
    )

    [waiting] = requests_in(gateway)

    assert waiting.name == "one.json"
    assert waiting.request.speaker_persona_id == "corey"
    assert waiting.request.origin is MessageOrigin.GROUP_TRANSCRIPT
    assert waiting.request.text == "Denise, is Gia free Friday?"


def test_a_half_written_or_empty_request_is_ignored(tmp_path: Path) -> None:
    gateway = gateway_at(tmp_path)
    (gateway.outbox / "a.json").write_text("{", encoding="utf-8")
    (gateway.outbox / "b.json").write_text(json.dumps({"text": "   "}), encoding="utf-8")
    (gateway.outbox / "c.json.partial").write_text(
        json.dumps({"text": "not yet"}), encoding="utf-8"
    )
    (gateway.outbox / "d.json").write_text(json.dumps({"text": "ready"}), encoding="utf-8")

    assert [waiting.request.text for waiting in requests_in(gateway)] == ["ready"]


def test_an_oversized_request_is_ignored(tmp_path: Path) -> None:
    gateway = gateway_at(tmp_path)
    (gateway.outbox / "a.json").write_text(
        json.dumps({"text": "x" * MAX_OUTBOX_REQUEST_BYTES}), encoding="utf-8"
    )
    (gateway.outbox / "b.json").write_text(json.dumps({"text": "ready"}), encoding="utf-8")

    assert [waiting.request.text for waiting in requests_in(gateway)] == ["ready"]


def test_an_outbox_that_does_not_exist_yet_reads_as_empty(tmp_path: Path) -> None:
    assert requests_in(GatewayContainer("corey", "openclaw-gateway", tmp_path)) == []


def test_a_symlinked_outbox_directory_is_refused(tmp_path: Path) -> None:
    if not (
        hasattr(os, "O_DIRECTORY") and hasattr(os, "O_NOFOLLOW") and os.open in os.supports_dir_fd
    ):
        pytest.skip("descriptor-relative outbox operations are unavailable")
    denise = gateway_at(tmp_path / "denise", "denise")
    (denise.outbox / "one.json").write_text(
        json.dumps({"text": "Corey, this came from Denise"}), encoding="utf-8"
    )
    corey = GatewayContainer("corey", "openclaw-gateway", tmp_path / "corey")
    corey.outbox.parent.mkdir(parents=True)
    corey.outbox.symlink_to(denise.outbox, target_is_directory=True)

    with pytest.raises(OutboxBoundaryError, match="outbox"):
        open_outbox(corey)


def test_a_fifo_in_the_outbox_is_skipped_rather_than_blocking(tmp_path: Path) -> None:
    """A read that blocks forever starves the peer, not just the entry it is reading.

    Opening a FIFO for reading blocks until a writer appears, and the type check is
    after the open, so an assistant naming one `000.json` stopped the tick before the
    other gateway's outbox was looked at, and again after every systemd timeout. The
    open is non-blocking now, so the fstat below it is reachable and rejects it.

    The test would hang rather than fail without the fix, which is the honest shape of
    this bug: run it against the blocking open and pytest never returns.
    """
    if not hasattr(os, "mkfifo") or os.open not in os.supports_dir_fd:
        pytest.skip("this platform has no FIFOs or no descriptor-relative open")
    corey = gateway_at(tmp_path / "corey", "corey")
    os.mkfifo(corey.outbox / "000.json")
    (corey.outbox / "001.json").write_text(
        json.dumps({"text": "Denise, is Gia free on Friday?"}), encoding="utf-8"
    )

    opened = open_outbox(corey)
    assert opened is not None
    with opened as outbox:
        found = read_outbox(outbox, "corey")

    assert [waiting.name for waiting in found] == ["001.json"]


def still_running(timeout: float) -> int:
    raise subprocess.TimeoutExpired("docker", timeout)


def handover_watched(
    monkeypatch: pytest.MonkeyPatch, wait: Callable[[float], int]
) -> tuple[DockerRelayTransport, list[list[str]]]:
    launched: list[list[str]] = []

    class Handover:
        def wait(self, timeout: float) -> int:
            return wait(timeout)

    def record(argv: list[str], **_: object) -> Handover:
        launched.append(argv)
        return Handover()

    monkeypatch.setattr(subprocess, "Popen", record)
    transport = DockerRelayTransport(
        [GatewayContainer("denise", "openclaw-denise", Path("/var/lib/denise"))],
        group_chat_id=GROUP_CHAT,
    )
    return transport, launched


def test_the_peer_answers_in_a_session_of_its_own(monkeypatch: pytest.MonkeyPatch) -> None:
    """A session key derived from the turn, so no private chat history comes with it.

    This is what the design document claims and all it claims: the answering turn is
    the peer's own agent, and what keeps it out of that person's conversation with
    their assistant is that it starts somewhere nothing else has ever spoken.
    """
    transport, launched = handover_watched(monkeypatch, still_running)

    transport.deliver_to_peer("denise", "turn-abc123", "Gia, is Friday still on?")

    [argv] = launched
    assert argv.count("--session-key") == 1
    assert argv[argv.index("--session-key") + 1] == "agent:main:coordination:turn-abc123"


def test_a_watch_that_ran_out_is_not_a_delivery(monkeypatch: pytest.MonkeyPatch) -> None:
    """The ordinary case for a turn that takes a while, and the peer has taken nothing."""
    transport, _ = handover_watched(monkeypatch, still_running)

    assert transport.deliver_to_peer("denise", "turn-abc123", "Gia, is Friday still on?") is False


def test_a_peer_that_finished_inside_the_watch_took_the_words(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, _ = handover_watched(monkeypatch, lambda _timeout: 0)

    assert transport.deliver_to_peer("denise", "turn-abc123", "Gia, is Friday still on?") is True


def test_a_gateway_that_refused_the_handover_is_an_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, _ = handover_watched(monkeypatch, lambda _timeout: 9)

    with pytest.raises(RuntimeError, match="openclaw-denise"):
        transport.deliver_to_peer("denise", "turn-abc123", "Gia, is Friday still on?")


# -- confirming the post -------------------------------------------------------


def test_the_group_post_is_recorded_by_the_id_telegram_gave_it() -> None:
    assert (
        _message_id(
            "[config] warnings: plugins.entries.codex: plugin disabled\n"
            '{"action": "send", "channel": "telegram", "messageId": "147",'
            ' "payload": {"ok": true, "messageId": "147"}}'
        )
        == "147"
    )


def post_returning(monkeypatch: pytest.MonkeyPatch, stdout: str, *, exit_code: int = 0) -> str:
    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        if exit_code:
            raise subprocess.CalledProcessError(exit_code, argv, output=stdout)
        return subprocess.CompletedProcess(argv, 0, stdout, "")

    monkeypatch.setattr(subprocess, "run", run)
    transport = DockerRelayTransport(
        [GatewayContainer("corey", "openclaw-gateway", Path("/var/lib/corey"))],
        group_chat_id=GROUP_CHAT,
    )
    return transport.post_to_group("corey", "Denise, is Gia free Friday?")


def test_a_send_the_cli_rejected_is_a_post_that_never_happened(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The group has not read these words, and the caller has to be able to say so."""
    with pytest.raises(GroupPostFailed):
        post_returning(monkeypatch, "telegram: 429 too many requests", exit_code=1)


def test_a_send_telegram_confirmed_comes_back_as_its_own_reference(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert (
        post_returning(monkeypatch, '{"action": "send", "messageId": "147"}')
        == f"telegram:{GROUP_CHAT}:147"
    )


def test_a_send_with_no_id_is_not_treated_as_a_post_that_never_happened(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The CLI exited zero, so Telegram may well have it. Cautious means assume it did."""
    with pytest.raises(RuntimeError) as raised:
        post_returning(monkeypatch, "[config] warnings: something")

    assert not isinstance(raised.value, GroupPostFailed)


def test_a_send_telegram_did_not_confirm_has_no_id() -> None:
    """An unconfirmed post is not a post, and the relay refuses to cross on one."""
    assert _message_id("[config] warnings: something\n") is None
    assert _message_id('{"action": "send", "payload": {"ok": false}}') is None
    assert _message_id("{not json") is None


def test_a_send_that_could_not_start_is_a_post_that_never_happened(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A fork that fails or a missing docker binary sent nothing, and that is knowable.

    Reported as anything else, the assistant is told the family may have read a
    sentence that never left the box, and is forbidden from ever asking it again.
    """

    def cannot_start(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        raise OSError(12, "Cannot allocate memory")

    monkeypatch.setattr(subprocess, "run", cannot_start)
    transport = DockerRelayTransport(
        [GatewayContainer("corey", "openclaw-gateway", Path("/var/lib/corey"))],
        group_chat_id=GROUP_CHAT,
    )

    with pytest.raises(GroupPostFailed):
        transport.post_to_group("corey", "Denise, is Gia free Friday?")


def test_a_send_that_timed_out_is_not_a_post_that_never_happened(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The CLI was still running when we stopped watching, so Telegram may have it."""

    def times_out(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(argv, 600)

    monkeypatch.setattr(subprocess, "run", times_out)
    transport = DockerRelayTransport(
        [GatewayContainer("corey", "openclaw-gateway", Path("/var/lib/corey"))],
        group_chat_id=GROUP_CHAT,
    )

    with pytest.raises(subprocess.TimeoutExpired) as raised:
        transport.post_to_group("corey", "Denise, is Gia free Friday?")

    assert not isinstance(raised.value, GroupPostFailed)


def test_an_answer_is_never_read_back_as_a_request(tmp_path: Path) -> None:
    """Both the relay and the skill write answers into the requests' own directory.

    Today an answer has no `text` field, so it would be skipped anyway. That is a thin
    thing to stand between a stale file and a second post to the family group, so they
    are told apart by name instead.
    """
    gateway = gateway_at(tmp_path)
    (gateway.outbox / "abc.result.json").write_text(
        json.dumps({"status": "unsent", "reason": "withdrawn", "text": "do not post me"}),
        encoding="utf-8",
    )
    (gateway.outbox / "def.json").write_text(
        json.dumps({"text": "Denise, is Gia free Friday?"}), encoding="utf-8"
    )

    assert [waiting.request.text for waiting in requests_in(gateway)] == [
        "Denise, is Gia free Friday?"
    ]


def test_one_reader_for_the_cli_whatever_it_prints_around_its_json() -> None:
    """The banner before and anything after, for both shapes the daemon reads.

    These were two functions, one tolerant of trailing output and one not, reading
    the same binary and disagreeing about it. The duplication is what let them
    diverge, so there is one now and this holds it to both jobs.
    """
    banner = "[config] warnings: plugins.entries.codex: plugin disabled (bundled)\n"

    assert first_json_value(banner + '{"messageId": "147"}\ndone\n', dict) == {"messageId": "147"}
    assert first_json_value(banner + '[{"name": "Cantigny"}]\ndone\n', list) == [
        {"name": "Cantigny"}
    ]

    # The wanted shape is part of the question: an object is not an array.
    assert first_json_value(banner + '{"messageId": "147"}\n', list) is None
    assert first_json_value(banner + "nothing structured here\n", dict) is None
