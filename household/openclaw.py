"""The two OpenClaw gateways, as the relay sees them.

Everything here runs on the host, outside both containers, because that is what makes
the relay's state something neither assistant can edit. Reading is read-only against
each gateway's own SQLite; writing is the documented CLI and nothing else.
"""

from __future__ import annotations

import json
import os
import sqlite3
import stat
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .coordination import GroupMessage, GroupPostFailed, MessageOrigin, PeerRequest

# Where an assistant leaves something it wants said to the other assistant. It sits
# inside the gateway's own state mount, so no compose change is needed to reach it,
# and the daemon is the only reader.
OUTBOX_DIRECTORY = "workspace/coordination-outbox"

# The relay's answers live in that same directory, and both the relay and the skill
# write them. A request is anything that is not one of those. Told apart by name
# rather than by shape, because "a result happens to have no text field" is a thin
# thing to stand between a stale file and the family group.
ANSWER_SUFFIX = ".result.json"

# A request carries one short group message and no other payload.
# This ceiling keeps parsing work bounded even when the assistant owns the file.
MAX_OUTBOX_REQUEST_BYTES = 64 * 1024

# The symlink, directory, FIFO and parser guards close four individual doors.
# This bound makes containment true for the class by preventing one assistant's
# outbox from consuming the whole tick and starving the peer.
MAX_OUTBOX_ENTRIES_PER_PASS = 256

# How long a delivery is watched for an immediate failure before it is left to run.
# The peer's turn can take minutes and nothing waits on its answer: the peer replies
# by asking the relay in its own right, on a later tick. Waiting for the turn instead
# would deadlock, because the peer's own `coordinate ask` waits for this same relay.
DELIVERY_ACK_SECONDS = 10

# How long any one gateway command may run. Named rather than inlined because the
# systemd unit that drives the relay has to allow at least the sum of this and the
# daemon's own two waits: a unit that gives up sooner than its own work takes is a
# relay that stops mid-crossing. That unit, and the test holding its TimeoutStartSec
# against the sum, arrive with the deployment change. Nothing in this one reads this
# constant except the transport below.
TRANSPORT_TIMEOUT_SECONDS = 600

# What OpenClaw stamps on a message a person actually typed. Anything else in the
# transcript - a restart notice, a cron prompt, the assistant's own turns - is not a
# person speaking and cannot open an exchange.
HUMAN_SENDER_KIND = "human"


@dataclass(frozen=True, slots=True)
class GatewayContainer:
    """One assistant: its persona, its container, and its state directory on the host."""

    persona_id: str
    container: str
    state_directory: Path

    @property
    def agent_database(self) -> Path:
        return self.state_directory / "agents/main/agent/openclaw-agent.sqlite"

    @property
    def outbox(self) -> Path:
        return self.state_directory / OUTBOX_DIRECTORY


class OutboxBoundaryError(RuntimeError):
    """The host cannot safely open this gateway's outbox."""


@dataclass(frozen=True, slots=True)
class OutboxRequest:
    name: str
    request: PeerRequest
    created_at: datetime


@dataclass(slots=True)
class OutboxDirectory:
    descriptor: int
    owner_uid: int
    owner_gid: int

    def __enter__(self) -> OutboxDirectory:
        return self

    def __exit__(self, *_: object) -> None:
        os.close(self.descriptor)

    def names(self, persona_id: str) -> list[str]:
        names: list[str] = []
        with os.scandir(self.descriptor) as entries:
            for index, entry in enumerate(entries):
                if index == MAX_OUTBOX_ENTRIES_PER_PASS:
                    print(f"{persona_id}: outbox entry limit reached", file=sys.stderr)
                    break
                if isinstance(entry.name, str):
                    names.append(entry.name)
        return sorted(names)

    def metadata(self, name: str) -> os.stat_result | None:
        try:
            return os.stat(name, dir_fd=self.descriptor, follow_symlinks=False)
        except FileNotFoundError:
            return None

    def unlink(self, name: str) -> None:
        os.unlink(name, dir_fd=self.descriptor)

    def replace(self, source: str, destination: str) -> None:
        os.rename(
            source,
            destination,
            src_dir_fd=self.descriptor,
            dst_dir_fd=self.descriptor,
        )


def _require_descriptor_outbox() -> None:
    required_dir_fd = (os.open, os.rename, os.stat, os.unlink)
    supported = (
        hasattr(os, "O_DIRECTORY")
        and hasattr(os, "O_NOFOLLOW")
        and hasattr(os, "fchown")
        and all(operation in os.supports_dir_fd for operation in required_dir_fd)
        and os.scandir in os.supports_fd
        and os.stat in os.supports_follow_symlinks
    )
    if not supported:
        raise OutboxBoundaryError("secure descriptor-relative outbox operations are unavailable")


def open_outbox(gateway: GatewayContainer) -> OutboxDirectory | None:
    _require_descriptor_outbox()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptors: list[int] = []
    try:
        descriptors.append(os.open(gateway.state_directory, flags))
        descriptors.append(os.open("workspace", flags, dir_fd=descriptors[-1]))
        descriptors.append(os.open("coordination-outbox", flags, dir_fd=descriptors[-1]))
    except FileNotFoundError:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
        return None
    except OSError as error:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
        raise OutboxBoundaryError(f"refusing {gateway.persona_id}'s outbox: {error}") from error
    outbox_descriptor = descriptors.pop()
    for descriptor in reversed(descriptors):
        os.close(descriptor)
    metadata = os.fstat(outbox_descriptor)
    return OutboxDirectory(
        descriptor=outbox_descriptor,
        owner_uid=metadata.st_uid,
        owner_gid=metadata.st_gid,
    )


def group_messages(
    agent_database: Path, *, group_chat_id: str, after_seq: int = 0
) -> list[GroupMessage]:
    """Every message a person typed in the household group, as this gateway recorded it.

    Only rows the channel marked as human are returned. A gateway's own turns, its
    restart notices and its cron prompts all live in the same table, and none of them
    is a person addressing an assistant.
    """
    if not agent_database.exists():
        return []
    connection = sqlite3.connect(f"file:{agent_database}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA busy_timeout = 5000")
        rows = connection.execute(
            "SELECT event.seq AS seq, event.event_json AS event_json "
            "FROM transcript_events AS event "
            "JOIN session_conversations AS link ON link.session_id = event.session_id "
            "JOIN conversations AS conversation "
            "  ON conversation.conversation_id = link.conversation_id "
            "WHERE conversation.kind = 'group' AND conversation.peer_id = ? AND event.seq > ? "
            # A transcript event carries a session and no conversation, so the group is
            # reached through the session's links. That table is many-to-many, and a session
            # linked to both the group and a direct chat would put the private half of it in
            # this feed as though it had been typed in front of everyone. No session on either
            # live gateway has more than one link today, which is an observation and not a
            # guarantee, so a session with more than one is skipped entirely rather than
            # trusted. It fails towards reading nothing, which for this query is the only
            # tolerable direction.
            "AND (SELECT COUNT(*) FROM session_conversations AS other "
            "     WHERE other.session_id = event.session_id) = 1 "
            "ORDER BY event.seq",
            (group_chat_id, after_seq),
        ).fetchall()
    finally:
        connection.close()

    messages: list[GroupMessage] = []
    for row in rows:
        message = _as_group_message(int(row["seq"]), str(row["event_json"]))
        if message is not None:
            messages.append(message)
    return messages


def _as_group_message(seq: int, event_json: str) -> GroupMessage | None:
    try:
        event = json.loads(event_json)
    except json.JSONDecodeError:
        return None
    if not isinstance(event, dict) or event.get("type") != "message":
        return None
    message = event.get("message")
    if not isinstance(message, dict) or message.get("role") != "user":
        return None
    envelope = message.get("__openclaw")
    if not isinstance(envelope, dict):
        return None
    identity = envelope.get("senderIdentity")
    if not isinstance(identity, dict) or identity.get("senderKind") != HUMAN_SENDER_KIND:
        return None
    sender_channel_id = identity.get("id")
    stamped = message.get("timestamp")
    if not isinstance(sender_channel_id, str) or not isinstance(stamped, int):
        return None
    return GroupMessage(
        seq=seq,
        at=datetime.fromtimestamp(stamped / 1000, tz=UTC),
        sender_channel_id=sender_channel_id,
        text=_text_of(message.get("content")),
        origin=MessageOrigin.GROUP_TRANSCRIPT,
    )


def _text_of(content: object) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return " ".join(
        part["text"]
        for part in content
        if isinstance(part, dict)
        and part.get("type") == "text"
        and isinstance(part.get("text"), str)
    ).strip()


def _text_in(descriptor: int) -> str | None:
    try:
        with os.fdopen(descriptor, "rb") as stream:
            raw = stream.read(MAX_OUTBOX_REQUEST_BYTES + 1)
        if len(raw) > MAX_OUTBOX_REQUEST_BYTES:
            return None
        payload = json.loads(raw)
    # The byte bound is the resource guard; parser limit exceptions are its backstop.
    # An invalid file is left for prune to age out rather than treated as a request.
    except (OSError, RecursionError, UnicodeDecodeError, ValueError):
        return None
    text = payload.get("text") if isinstance(payload, dict) else None
    if not isinstance(text, str) or not text.strip():
        return None
    return text.strip()


def read_outbox(outbox: OutboxDirectory, persona_id: str) -> list[OutboxRequest]:
    """What this assistant asked to say to the other one.

    The file carries text and nothing else. Who is speaking comes from which gateway's
    outbox it was found in, and the origin is set here, so a file cannot name a
    different speaker or claim to have come from somewhere the relay would trust.
    """
    requests: list[OutboxRequest] = []
    for name in outbox.names(persona_id):
        if not name.endswith(".json") or name.endswith(ANSWER_SUFFIX):
            continue
        try:
            # O_NONBLOCK so the type check below is reachable at all. Opening a FIFO
            # for reading blocks until a writer appears, so an assistant naming one
            # `000.json` stopped the tick here for good, before the peer's outbox was
            # ever looked at. On a regular file the flag changes nothing.
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=outbox.descriptor,
            )
        except OSError:
            continue
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            os.close(descriptor)
            continue
        text = _text_in(descriptor)
        if text is None:
            continue
        requests.append(
            OutboxRequest(
                name=name,
                request=PeerRequest(
                    speaker_persona_id=persona_id,
                    text=text,
                    origin=MessageOrigin.GROUP_TRANSCRIPT,
                ),
                created_at=datetime.fromtimestamp(metadata.st_mtime, UTC),
            )
        )
    return requests


# The shape argument is a seam rather than generality for its own sake. _message_id
# below wants an object, and the relay daemon's research reader wants the list form.
def first_json_value[ValueT](
    output: str,
    wanted: type[ValueT],
    *,
    where: Callable[[ValueT], bool] | None = None,
) -> ValueT | None:
    """The first JSON value of the wanted shape in a CLI's stdout, or nothing.

    Every command here is `docker exec <container> node dist/index.js ...`, and that
    binary prints a bracketed config banner before its own output and can print more
    after it. So neither end of the output is a safe place to anchor: the first "["
    is the banner, and the JSON is not reliably the last thing on stdout either.

    This tries to decode at each opening bracket and keeps the first that parses, is
    the shape asked for, and satisfies ``where``. A value that decodes and is refused
    is skipped whole, so nothing nested inside it is offered as a separate answer: it
    is part of something the caller has already said no to. It exists as one function
    because it was two, one tolerant and one not, reading the same binary and
    disagreeing about its shape.

    ``where`` matters when the output is a model's, because "reply with JSON and
    nothing else" is an instruction rather than a guarantee: a citation marker like
    "[1]" decodes perfectly well as a list, and the caller is the only thing that
    knows a list of integers is not the answer it asked for.
    """
    decoder = json.JSONDecoder()
    start = 0
    while start < len(output):
        if output[start] not in "[{":
            start += 1
            continue
        try:
            found, end = decoder.raw_decode(output, start)
        except json.JSONDecodeError:
            start += 1
            continue
        if isinstance(found, wanted) and (where is None or where(found)):
            return found
        start = end
    return None


def _message_id(output: str) -> str | None:
    """The id Telegram gave the post, out of `message send --json`.

    The send result is the first object carrying a messageId, not simply the first
    object. Without saying so, a structured warning or a progress line printed ahead
    of it would be taken as the answer, _message_id would return None for a send that
    reached Telegram, and the crossing would be reported as unconfirmed. That is the
    same asymmetry that had a tolerant reader and an intolerant one reading the same
    binary: first_json_value grew the hook for exactly this, and this caller was not
    using it.
    """
    payload = first_json_value(output, dict, where=lambda found: "messageId" in found)
    if payload is None:
        return None
    message_id = payload.get("messageId")
    return str(message_id) if isinstance(message_id, str | int) else None


class DockerRelayTransport:
    """Posts through the speaker's own gateway, then wakes the peer's.

    ``post_to_group`` is the speaker's bot sending to the household chat, so the words
    arrive under the name the people already know. ``deliver_to_peer`` starts a fresh
    session keyed on the turn, which is what keeps a peer's answer out of its own
    person's conversation history.
    """

    def __init__(
        self,
        gateways: Sequence[GatewayContainer],
        *,
        group_chat_id: str,
        timeout: int = TRANSPORT_TIMEOUT_SECONDS,
    ) -> None:
        self._by_persona = {gateway.persona_id: gateway for gateway in gateways}
        self._group_chat_id = group_chat_id
        self._timeout = timeout

    def post_to_group(self, persona_id: str, text: str) -> str:
        """Returns the channel's own message id, so the audit row points at the post.

        Three outcomes, and the caller has to be able to tell them apart because the
        group either read these words or did not:

        * the send ran and failed, or could not be started at all, so Telegram was
          never reached - :class:`GroupPostFailed`;
        * it exits zero with a message id, so Telegram has it - the id comes back;
        * anything else, including a timeout and an exit-zero with no id, leaves no
          way to rule out that Telegram has it. That raises too, and not as
          ``GroupPostFailed``, because "may have" has to be read as "did".

        Either way nothing crosses: the peer is never handed words the group may not
        have seen.
        """
        try:
            output = self._run(
                persona_id,
                [
                    "message",
                    "send",
                    "--channel",
                    "telegram",
                    "--target",
                    self._group_chat_id,
                    "--message",
                    text,
                    "--json",
                ],
            )
        except (subprocess.CalledProcessError, OSError) as never_sent:
            raise GroupPostFailed(
                f"{self._by_persona[persona_id].container} sent nothing: {never_sent}"
            ) from never_sent
        message_id = _message_id(output)
        if message_id is None:
            raise RuntimeError(f"telegram did not confirm the group post: {output[-500:]}")
        return f"telegram:{self._group_chat_id}:{message_id}"

    def deliver_to_peer(self, persona_id: str, turn_id: str, text: str) -> bool:
        """Hand the words over and let the peer think in its own time.

        Watched for :data:`DELIVERY_ACK_SECONDS` so a gateway that is down is an error
        here rather than a silence, then left to run. Nothing needs its answer: the
        peer replies by asking the relay itself, which is what keeps the two of them
        from waiting on each other.

        True when the peer took it inside that window, False when the watch ran out
        and it is still going. The second is the ordinary case for a turn that takes
        a while, and it is not a delivery: the gateway can be up while its agent is
        wedged, so the caller must not record one.
        """
        gateway = self._by_persona[persona_id]
        process = subprocess.Popen(
            [
                "docker",
                "exec",
                gateway.container,
                "node",
                "dist/index.js",
                "agent",
                "--session-key",
                f"agent:main:coordination:{turn_id}",
                "--message",
                text,
                "--timeout",
                str(self._timeout),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            code = process.wait(timeout=DELIVERY_ACK_SECONDS)
        except subprocess.TimeoutExpired:
            # Still running, which is the ordinary case and not an acknowledgement.
            return False
        if code != 0:
            raise RuntimeError(f"{gateway.container} refused the delivery, exit {code}")
        return True

    def _run(self, persona_id: str, arguments: Sequence[str]) -> str:
        gateway = self._by_persona[persona_id]
        completed = subprocess.run(
            ["docker", "exec", gateway.container, "node", "dist/index.js", *arguments],
            capture_output=True,
            text=True,
            timeout=self._timeout,
            check=True,
        )
        return completed.stdout


__all__ = [
    "ANSWER_SUFFIX",
    "HUMAN_SENDER_KIND",
    "MAX_OUTBOX_ENTRIES_PER_PASS",
    "MAX_OUTBOX_REQUEST_BYTES",
    "OUTBOX_DIRECTORY",
    "DockerRelayTransport",
    "GatewayContainer",
    "OutboxBoundaryError",
    "OutboxDirectory",
    "OutboxRequest",
    "first_json_value",
    "group_messages",
    "open_outbox",
    "read_outbox",
]
