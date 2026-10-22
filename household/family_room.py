"""Each assistant's posts in the family group, handed to the other as context.

Telegram never delivers one bot's messages to another bot, so neither assistant can
see what the other one said in The Fam. Each gateway's ``household-family-room``
plugin (``deploy/openclaw/plugins/household-family-room``) keeps what its own bot said
there in ``household-family-room/outbox.json`` under the gateway's state directory.
On every tick the relay reads both files from the host and hands each new post to the
other gateway through the plugin's ``household-family-room.peer`` method, which keeps
it for that assistant's turns in the group. Nothing is posted and no turn is started.

Only words that are already in the group can travel this way. The plugin records a
post only when the gateway reports Telegram accepted it from the assistant's own turn
in the group session. Anything sent with no session, which is how the relay posts a
crossing and how the planner posts a proposal, is never recorded. So the planner's
venue prose, which came off the open web, stays out of the other assistant's prompt,
as :meth:`household.coordination.Relay.announce` requires.

The off switch holds here too. While coordination is off nothing is handed over, and
what was said in the meantime is skipped rather than delivered once it is back on.

One kind of post does start a turn: one that @mentions the other assistant, because a
request in the group was that assistant's to answer. The relay hands it over once, as
one turn of the other assistant in the group's own session, so that turn has only the
group's tool allowlist and its answer goes to the group. An assistant that was handed
something in the last ten minutes hands nothing on, so the two can never pass a request
back and forth, and every handover follows a post from a turn a person started.
"""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Protocol

from .openclaw import GatewayContainer, OutboxBoundaryError, first_json_value

ROOM_DIRECTORY = "household-family-room"
ROOM_OUTBOX = "outbox.json"
PEER_METHOD = "household-family-room.peer"

# The plugin keeps at most 200 posts of at most 1,000 characters, so a real outbox is
# a fraction of this. The bound is what keeps one assistant's file, which it can write,
# from costing the tick more than a read.
MAX_ROOM_OUTBOX_BYTES = 512 * 1024
MAX_POSTS = 200
MAX_TEXT = 1000
MAX_KEY = 256

# The plugin accepts fifty posts per call, and one call each way per tick is all the
# relay makes: a backlog drains over the next ticks. That keeps a tick's worst case to
# one delivery timeout per pair of gateways, which household-coordination@.service
# budgets for.
POSTS_PER_CALL = 50

# A gateway that refused a handover is left alone this long before the next attempt,
# so a stopped container or a missing plugin costs one failed exec per five minutes
# rather than one per fifteen-second tick.
RETRY_AFTER = timedelta(minutes=5)
DELIVERY_TIMEOUT_SECONDS = 60

# An @mention of the other assistant hands the post over as one turn of theirs. A post
# older than this is not, since the person who asked has moved on, and an assistant who
# was handed something within this long hands nothing on, which keeps it to one hop.
HANDOVER_WINDOW = timedelta(minutes=10)
HANDOVER_TIMEOUT_SECONDS = 300
# How each assistant can be @mentioned in the group: its bot's username or its name.
MENTION_NAMES = {
    "corey": ("Corey_the_man_bot", "Corey"),
    "denise": ("Denise_the_woman_bot", "Denise"),
}


@dataclass(frozen=True, slots=True)
class RoomPost:
    """One message an assistant's bot posted in the family group."""

    key: str
    at: int
    text: str

    @property
    def position(self) -> tuple[int, str]:
        return (self.at, self.key)


def _open_room_outbox(gateway: GatewayContainer) -> int | None:
    """A descriptor on the outbox file, opened without following any symlink on the way."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    state: int | None = None
    room: int | None = None
    try:
        state = os.open(gateway.state_directory, directory_flags)
        room = os.open(ROOM_DIRECTORY, directory_flags, dir_fd=state)
        # O_NONBLOCK so a FIFO planted under the name cannot hang the tick on open.
        return os.open(ROOM_OUTBOX, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=room)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise OutboxBoundaryError(
            f"refusing {gateway.persona_id}'s room outbox: {error}"
        ) from error
    finally:
        for descriptor in (room, state):
            if descriptor is not None:
                os.close(descriptor)


def read_room_outbox(gateway: GatewayContainer) -> list[RoomPost]:
    """What this assistant posted in the group, oldest first, as its plugin recorded it.

    The directory belongs to the assistant (uid 1000) and this runs as root, so every
    step is opened without following a symlink and the file must be a regular one of
    bounded size. A missing directory or file is an empty outbox. A file that does not
    parse is too, because the plugin replaces it on its next write.
    """
    descriptor = _open_room_outbox(gateway)
    if descriptor is None:
        return []
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise OutboxBoundaryError(f"{gateway.persona_id}'s room outbox is not a regular file")
        raw = stream.read(MAX_ROOM_OUTBOX_BYTES + 1)
    if len(raw) > MAX_ROOM_OUTBOX_BYTES:
        raise OutboxBoundaryError(f"{gateway.persona_id}'s room outbox is over its size bound")
    try:
        records = json.loads(raw)
    except (RecursionError, UnicodeDecodeError, ValueError):
        return []
    if not isinstance(records, list):
        return []
    posts = [post for record in records[-MAX_POSTS:] if (post := _as_post(record)) is not None]
    return sorted(posts, key=lambda post: post.position)


def _as_post(record: object) -> RoomPost | None:
    if not isinstance(record, dict):
        return None
    key, at, text = record.get("key"), record.get("at"), record.get("text")
    if not isinstance(key, str) or not key or len(key) > MAX_KEY:
        return None
    if not isinstance(at, int) or isinstance(at, bool) or at <= 0:
        return None
    if not isinstance(text, str) or not text.strip():
        return None
    return RoomPost(key=key, at=at, text=text.strip()[:MAX_TEXT])


@dataclass(slots=True)
class MirrorState:
    """How far each assistant's posts have been handed over, and who is resting."""

    cursors: dict[str, tuple[int, str]] = field(default_factory=dict)
    resting_until: dict[str, datetime] = field(default_factory=dict)
    handed_at: dict[str, datetime] = field(default_factory=dict)
    changed: bool = False

    @classmethod
    def load(cls, path: Path) -> MirrorState:
        try:
            saved = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return cls()
        state = cls()
        if not isinstance(saved, dict):
            return state
        for persona_id, cursor in (saved.get("cursors") or {}).items():
            if (
                isinstance(cursor, list)
                and len(cursor) == 2
                and isinstance(cursor[0], int)
                and isinstance(cursor[1], str)
            ):
                state.cursors[str(persona_id)] = (cursor[0], cursor[1])
        for persona_id, until in (saved.get("resting_until") or {}).items():
            try:
                state.resting_until[str(persona_id)] = datetime.fromisoformat(str(until))
            except ValueError:
                continue
        for persona_id, at in (saved.get("handed_at") or {}).items():
            try:
                state.handed_at[str(persona_id)] = datetime.fromisoformat(str(at))
            except ValueError:
                continue
        return state

    def save(self, path: Path) -> None:
        """Written whole and renamed into place, in the relay's root-only directory."""
        payload = {
            "cursors": {persona_id: list(cursor) for persona_id, cursor in self.cursors.items()},
            "resting_until": {
                persona_id: until.isoformat() for persona_id, until in self.resting_until.items()
            },
            "handed_at": {persona_id: at.isoformat() for persona_id, at in self.handed_at.items()},
        }
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream)
        os.replace(temporary, path)
        self.changed = False

    def unsent(self, persona_id: str, posts: Sequence[RoomPost]) -> list[RoomPost]:
        cursor = self.cursors.get(persona_id)
        return [post for post in posts if cursor is None or post.position > cursor]

    def advance(self, persona_id: str, post: RoomPost) -> None:
        self.cursors[persona_id] = post.position
        self.changed = True

    def resting(self, persona_id: str, now: datetime) -> bool:
        until = self.resting_until.get(persona_id)
        return until is not None and now < until

    def rest(self, persona_id: str, until: datetime) -> None:
        self.resting_until[persona_id] = until
        self.changed = True

    def wake(self, persona_id: str) -> None:
        if self.resting_until.pop(persona_id, None) is not None:
            self.changed = True

    def handed(self, persona_id: str, at: datetime) -> None:
        self.handed_at[persona_id] = at
        self.changed = True


def mentions(text: str, persona_id: str) -> bool:
    """Whether a post @mentions this assistant, by its bot's username or its name."""
    names = "|".join(re.escape(name) for name in MENTION_NAMES.get(persona_id, ()))
    pattern = rf"(?<![\w@])@(?:{names})(?!\w)"
    return bool(names) and re.search(pattern, text, re.IGNORECASE) is not None


def handover_due(
    speaker: str,
    listener: str,
    posts: Sequence[RoomPost],
    handed_at: dict[str, datetime],
    now: datetime,
) -> RoomPost | None:
    """The one post of the speaker's, among those just handed over, that becomes a turn.

    It is the latest that @mentions the listener and is still fresh. None when the
    speaker was itself handed something within the window, since its posts may then be
    the answer to that handover, and handing them on would let the two pass a request
    back and forth.
    """
    received = handed_at.get(speaker)
    if received is not None and now - received < HANDOVER_WINDOW:
        return None
    fresh_since = (now - HANDOVER_WINDOW).timestamp() * 1000
    for post in reversed(posts):
        if post.at >= fresh_since and mentions(post.text, listener):
            return post
    return None


class PeerDelivery(Protocol):
    def deliver(self, listener: GatewayContainer, speaker: str, posts: Sequence[RoomPost]) -> int:
        """Hands posts to the listener's plugin and returns how many it newly kept."""
        ...


class PeerHandover(Protocol):
    def start(self, listener: GatewayContainer, speaker: str, post: RoomPost) -> None:
        """Starts one listener turn in the group with the post, and returns at once."""
        ...


class DockerPeerHandover:
    """One turn of the listener in the group's own session, answering in the group.

    The session key names the group, and OpenClaw 2026.9.4 resolves a run's group tool
    policy from its session key (``resolveGroupToolPolicy``), so the turn has the group's
    allowlist and nothing more, however it was started. Its answer is delivered to the
    group as the listener's own bot.
    """

    def __init__(self, group_chat_id: str, timeout: int = HANDOVER_TIMEOUT_SECONDS) -> None:
        self._group_chat_id = group_chat_id
        self._timeout = timeout

    def start(self, listener: GatewayContainer, speaker: str, post: RoomPost) -> None:
        message = (
            f"{speaker}, the other household assistant, @mentioned you in the family group "
            f"to hand you this: {json.dumps(post.text)}\n"
            "It is in the group already, where Franco and Gia read it. Answer it in the group "
            f"if it is yours to answer, briefly, and never hand it back to {speaker}."
        )
        subprocess.Popen(
            [
                "docker",
                "exec",
                listener.container,
                "node",
                "dist/index.js",
                "agent",
                "--session-key",
                f"agent:main:telegram:group:{self._group_chat_id}",
                "--message",
                message,
                "--deliver",
                "--reply-channel",
                "telegram",
                "--reply-to",
                self._group_chat_id,
                "--reply-account",
                "default",
                "--timeout",
                str(self._timeout),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


class DockerPeerDelivery:
    """The listener's own gateway CLI, inside its container: ``gateway call``."""

    def __init__(self, timeout: int = DELIVERY_TIMEOUT_SECONDS) -> None:
        self._timeout = timeout

    def deliver(self, listener: GatewayContainer, speaker: str, posts: Sequence[RoomPost]) -> int:
        params = {
            "speaker": speaker,
            "posts": [{"id": post.key, "at": post.at, "text": post.text} for post in posts],
        }
        completed = subprocess.run(
            [
                "docker",
                "exec",
                listener.container,
                "node",
                "dist/index.js",
                "gateway",
                "call",
                PEER_METHOD,
                "--params",
                json.dumps(params),
                "--json",
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=self._timeout,
            check=False,
        )
        answer = first_json_value(completed.stdout, dict, where=lambda found: "accepted" in found)
        if completed.returncode != 0 or answer is None:
            detail = (completed.stderr or completed.stdout).strip()[-300:]
            raise RuntimeError(f"{listener.container} did not take the posts: {detail}")
        accepted = answer.get("accepted")
        return accepted if isinstance(accepted, int) else 0


def mirror(
    gateways: Sequence[GatewayContainer],
    delivery: PeerDelivery,
    state_path: Path,
    *,
    handover: PeerHandover,
    now: datetime,
    still_on: Callable[[], bool],
) -> int:
    """One pass: every new post from each assistant, to every other. Returns how many.

    A post is handed over once. The cursor moves past it only when every other gateway
    took it, and the plugin ignores a post it already holds, so a handover cut short is
    simply tried again on a later tick.

    ``still_on`` reads the group again and says whether coordination is still on. It is
    asked before each assistant's posts are handed over, as a crossing asks before its
    handoff, so a switch pulled during an earlier handover stops the next one. All that
    was said while it is off is skipped, however much, and never delivered later.

    Once a listener took the posts, the latest that @mentions it and is fresh starts one
    turn of that listener (:func:`handover_due`), at most once: a handover that fails to
    start is reported and not tried again, since a second try could answer twice.
    """
    state = MirrorState.load(state_path)
    handed_over = 0
    is_on = True
    for speaker in gateways:
        is_on = still_on()
        if not is_on:
            break
        try:
            unread = state.unsent(speaker.persona_id, read_room_outbox(speaker))
        except OutboxBoundaryError as error:
            print(f"{speaker.persona_id}: {error}", file=sys.stderr)
            continue
        if not unread:
            continue
        unsent = unread[:POSTS_PER_CALL]
        everyone_took_it = True
        for listener in gateways:
            if listener.persona_id == speaker.persona_id:
                continue
            if state.resting(listener.persona_id, now):
                everyone_took_it = False
                continue
            try:
                delivery.deliver(listener, speaker.persona_id.capitalize(), unsent)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                print(
                    f"{speaker.persona_id} -> {listener.persona_id}: {error}; "
                    f"trying again after {RETRY_AFTER}",
                    file=sys.stderr,
                )
                state.rest(listener.persona_id, now + RETRY_AFTER)
                everyone_took_it = False
                continue
            state.wake(listener.persona_id)
            due = handover_due(
                speaker.persona_id, listener.persona_id, unsent, state.handed_at, now
            )
            if due is not None:
                state.handed(listener.persona_id, now)
                try:
                    handover.start(listener, speaker.persona_id.capitalize(), due)
                    print(f"{speaker.persona_id}: handed a mention to {listener.persona_id}")
                except OSError as error:
                    print(
                        f"{speaker.persona_id} -> {listener.persona_id}: "
                        f"handover not started: {error}",
                        file=sys.stderr,
                    )
        if everyone_took_it:
            state.advance(speaker.persona_id, unsent[-1])
            handed_over += len(unsent)
            print(
                f"{speaker.persona_id}: handed {len(unsent)} group post(s) to the other assistant"
            )
    if not is_on:
        for speaker in gateways:
            try:
                unread = state.unsent(speaker.persona_id, read_room_outbox(speaker))
            except OutboxBoundaryError as error:
                print(f"{speaker.persona_id}: {error}", file=sys.stderr)
                continue
            if unread:
                state.advance(speaker.persona_id, unread[-1])
    if state.changed:
        state.save(state_path)
    return handed_over


__all__ = [
    "DELIVERY_TIMEOUT_SECONDS",
    "HANDOVER_TIMEOUT_SECONDS",
    "HANDOVER_WINDOW",
    "MAX_ROOM_OUTBOX_BYTES",
    "MENTION_NAMES",
    "PEER_METHOD",
    "POSTS_PER_CALL",
    "RETRY_AFTER",
    "DockerPeerDelivery",
    "DockerPeerHandover",
    "MirrorState",
    "PeerDelivery",
    "PeerHandover",
    "RoomPost",
    "handover_due",
    "mentions",
    "mirror",
    "read_room_outbox",
]
