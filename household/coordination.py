"""The group surface: the only way one assistant's words reach the other.

Telegram never delivers one bot's messages to another bot, so something outside
Telegram has to carry them. This module is that something, and it is written so the
CFO's ruling holds by construction rather than by instruction:

* Nothing crosses that was not posted in the group first. :meth:`Relay.relay` posts
  the verbatim text to the group and only then hands the same string to the peer. A
  failed post raises before the peer is reached, and there is no other entry point.
* One thing opens an exchange: a human message in the group. The planner posts a
  proposal through :meth:`Relay.announce` and opens nothing, because its research
  step reads the open web and crossing that text would put it in a peer's prompt.
  :class:`MessageOrigin` has one member and no default, so a caller holding an email
  body has to write the assertion that a person typed this in the group rather than
  inherit it, which is a lie it must type instead of a blank it can leave.
* Two messages per assistant per human turn, counted in the database, checked
  before the post.
* "stop" from either person closes the exchange in progress, and nothing crosses
  again until a human addresses an assistant.
* One flag disables the whole surface and lives in the database, which sits on the
  host outside both containers and survives a force-recreate.
"""

from __future__ import annotations

import dataclasses
import hashlib
import re
import uuid
from collections.abc import Callable, Collection, Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum
from typing import Protocol

from .db import Database
from .errors import HouseholdError
from .identity import Clock, system_clock

# Two messages per assistant per human turn. The number lives here, the enforcement
# lives in Relay.relay, and no caller can pass a different one.
TURN_CAP = 2

# How long a human turn stays open. "Per human turn" has to mean the exchange the
# person is present for, so a turn that nobody spoke into goes stale rather than
# waiting to be spent hours later. It is also what stops a first run over a backlog
# of old group messages from opening an exchange about something already settled.
TURN_TTL = timedelta(minutes=15)

# The reference a crossing carries until Telegram confirms one, and keeps if it never
# does. The row exists from before the post, so that a send nobody can rule out still
# spends the speaker's slot.
UNCONFIRMED_POST = ""

# The one channel this household speaks on. A constant rather than a field on
# RelayConfig, because there it had one value, one reader and no caller that ever
# passed it.
HOUSEHOLD_CHANNEL = "telegram"

# Deliberately unguarded against negation, unlike the matchers that read what the
# household likes out of what it types, which arrive with the planner and are allowed
# to be wrong quietly. "Don't stop" closing the exchange costs one turn; a "stop" that
# does not stop is the failure this clause exists to prevent, so the cautious reading
# is the broad one.
_STOP = re.compile(r"\bstop\b", re.IGNORECASE)
# The two directions are not the same control and they do not get the same pattern.
#
# Off tolerates anything after it. "!coordination off please" and "!coordination off -
# too noisy" are what somebody types when they are annoyed, and an emergency control
# that answers a near miss with silence is one the person believes they have pulled.
#
# On does not, because a near miss in this direction is the unsafe one. Somebody who
# fails to silence the pair types it again; somebody who accidentally un-silences them
# is not told, and neither is the person who asked for the silence. So on has to be the
# whole message, and "!coordination on second thoughts" leaves the pair off.
#
# Both have to open the message, unlike the stop word, because a command buried in a
# sentence is as likely to be somebody talking about the switch as pulling it. Neither
# matches "!coordination offline": the boundary is after the setting rather than after
# the exclamation mark.
_SWITCH_OFF = re.compile(r"^\s*!coordination\s+off\b", re.IGNORECASE)
_SWITCH_ON = re.compile(r"^\s*!coordination\s+on\s*$", re.IGNORECASE)


class CoordinationRefused(HouseholdError):
    """The relay will not carry this. Every subclass is a fail-closed refusal."""


class OriginRefused(CoordinationRefused):
    """Something that is not a message a person typed in the group tried to speak."""


class CoordinationDisabled(CoordinationRefused):
    """The off switch is off."""


class NoOpenTurn(CoordinationRefused):
    """No human has addressed an assistant, or the exchange was stopped."""


class TurnCapReached(CoordinationRefused):
    """This assistant has already said its two things in this turn."""


class GroupPostFailed(HouseholdError):
    """The post to the group did not happen: it failed, or it never started.

    Not a refusal: no guard said no, the channel did, or the crossing broke before it
    reached the channel at all. It is separate from every other failure because it is
    the one that tells the caller the group never saw the words, which is the only
    thing that decides what the caller should do next. Raising it is a claim that the
    words cannot have been posted, so only a path that establishes that may raise it.
    """


class CrossingStopped(HouseholdError):
    """The posted words cannot cross because the turn closed during the post."""


class OffSwitchStopped(HouseholdError):
    """The posted words cannot cross because the off switch changed during the post."""


class MessageOrigin(StrEnum):
    """Where a piece of text came from. One member, and that is the point.

    There is deliberately nothing here for mail, a calendar description, a web page
    or the planner, so a caller holding any of those has nothing to put in this
    field. It is a type whose whole job is the members it does not have, which is why
    it survives as an enum of one rather than collapsing into a boolean.
    """

    GROUP_TRANSCRIPT = "group_transcript"


@dataclass(frozen=True, slots=True)
class GroupMessage:
    """A message a gateway recorded in the household group.

    ``sender_channel_id`` and ``at`` come from the channel, so the same human message
    read out of Corey's gateway and out of Denise's gateway produces one identity.
    """

    seq: int
    at: datetime
    sender_channel_id: str
    text: str
    # No default. A field defaulting to the one value the guard accepts is a
    # decoration rather than a guard: a caller holding an email body inherits the
    # accepting answer without typing anything, which is the opposite of the claim.
    origin: MessageOrigin

    @property
    def key(self) -> str:
        """One id for one human message, whichever gateway recorded it.

        The two gateways stamp their own idempotency keys on the same Telegram
        message, so the relay derives its own from what the channel authenticated.
        """
        digest = hashlib.sha256(
            "\x00".join(
                (self.sender_channel_id, str(int(self.at.timestamp() * 1000)), self.text)
            ).encode("utf-8")
        )
        return digest.hexdigest()


@dataclass(frozen=True, slots=True)
class PeerRequest:
    """An assistant asking to say something to the other assistant.

    ``origin`` is what the relay checks first, and there is one value it accepts.
    """

    speaker_persona_id: str
    text: str
    origin: MessageOrigin


@dataclass(frozen=True, slots=True)
class Turn:
    """An exchange in progress.

    Only ever an open one, which is why it carries no closed_at or closed_reason:
    ``open_turn`` returns ``None`` rather than a closed Turn. Both columns exist on
    ``coordination_turn`` and are written there, because why an exchange ended is an
    audit fact; they are just not part of this shape. Same for which person opened it.
    """

    id: str
    opened_at: str


@dataclass(frozen=True, slots=True)
class RelayedMessage:
    id: str
    turn_id: str
    speaker_persona_id: str
    peer_persona_id: str
    text: str
    group_message_ref: str
    posted_at: str
    delivered_at: str | None = None


class RelayTransport(Protocol):
    """The two sinks, in the order the ruling requires.

    ``post_to_group`` returns the channel's own reference for the posted message.
    Raising from it stops the exchange before anything crosses, and which exception it
    raises is what says whether the group saw the words: :class:`GroupPostFailed` means
    it did not, and anything else means it may have.

    ``deliver_to_peer`` says whether the peer took the words, which is not the same as
    the handover not failing. A transport may stop watching a delivery that is still
    running, and a stopped watch is not an acknowledgement.
    """

    def post_to_group(self, persona_id: str, text: str) -> str: ...

    def deliver_to_peer(self, persona_id: str, turn_id: str, text: str) -> bool: ...


@dataclass(frozen=True, slots=True)
class RelayConfig:
    """The two assistant personas on this surface, and nothing else about them.

    Exactly two, because the peer of one is the other and a third would make "the
    peer" ambiguous in a surface whose whole safety argument is that both people can
    read every word of it.

    Deliberately not carrying the group's chat id, and not carrying the channel
    either. The relay never addresses the group itself; the transport does, and it is
    told the chat id directly. A second copy of either would give two places to change
    it and nothing to notice when only one of them was.
    """

    # Typed as what it is used as: the two persona ids.
    assistants: Collection[str]

    def __post_init__(self) -> None:
        if len(self.assistants) != 2:
            raise ValueError(f"the group surface pairs two assistants, not {len(self.assistants)}")

    def peer_of(self, persona_id: str) -> str:
        others = [persona for persona in self.assistants if persona != persona_id]
        if len(others) != 1:
            raise OriginRefused(f"{persona_id!r} is not a coordinating assistant")
        return others[0]


def addresses_an_assistant(text: str, persona_ids: Iterable[str]) -> bool:
    """Whether a human is talking to an assistant rather than to the other person.

    Matched on the persona name as a whole word, with or without the @ a Telegram
    mention carries, because the bot usernames differ from the persona ids.
    """
    lowered = text.lower()
    return any(re.search(rf"\b{re.escape(persona)}\b", lowered) for persona in persona_ids)


class Relay:
    """Carries one assistant's group message to the other, or refuses."""

    def __init__(
        self,
        database: Database,
        config: RelayConfig,
        transport: RelayTransport,
        clock: Clock = system_clock,
    ) -> None:
        self._database = database
        self._config = config
        self._transport = transport
        self._clock = clock

    # -- the off switch --------------------------------------------------------

    def enabled(self) -> bool:
        """Default on, so a fresh database behaves the way the deployed one does."""
        with self._database.read() as cx:
            row = cx.execute("SELECT enabled FROM coordination_flag WHERE id = 1").fetchone()
        return True if row is None else bool(row["enabled"])

    def now(self) -> datetime:
        return self._clock()

    def set_enabled(self, *, enabled: bool, person_id: str) -> None:
        with self._database.write() as cx:
            cx.execute(
                "INSERT INTO coordination_flag (id, enabled, changed_at, changed_by_person_id) "
                "VALUES (1, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
                "enabled = excluded.enabled, changed_at = excluded.changed_at, "
                "changed_by_person_id = excluded.changed_by_person_id",
                (int(enabled), self._clock().isoformat(), person_id),
            )

    # -- what a human said in the group ----------------------------------------

    def ingest(self, persona_id: str, messages: Iterable[GroupMessage]) -> list[str]:
        """Read one gateway's record of the group and act on what the people said.

        Returns the effects applied, oldest first, which is what the daemon logs and
        what the tests assert on. A message either gateway has already been shown is
        skipped, because both gateways record the same Telegram message.
        """
        effects: list[str] = []
        for message in sorted(messages, key=lambda item: item.seq):
            if message.origin is not MessageOrigin.GROUP_TRANSCRIPT:
                raise OriginRefused(
                    f"{message.origin} cannot be ingested as something a person said"
                )
            person_id = self.person_for(message.sender_channel_id)
            # Nothing someone outside the household types opens a turn, stops one, or
            # reaches the off switch, and a message the other gateway's copy already
            # applied needs nothing either. Either way this gateway has now read it,
            # and its cursor has to say so or it re-reads the group forever.
            if person_id is not None and not self._already_seen(message.key):
                effects.append(self._apply(person_id, message))
            self._advance_cursor(persona_id, message.seq, message.key)
        return effects

    def _apply(self, person_id: str, message: GroupMessage) -> str:
        effects: list[str] = []
        if _SWITCH_ON.match(message.text) is not None:
            self.set_enabled(enabled=True, person_id=person_id)
            effects.append("switch:on")
        elif _SWITCH_OFF.match(message.text) is not None:
            self.set_enabled(enabled=False, person_id=person_id)
            effects.append("switch:off")
        # Asked of open_turn rather than of the table, because "an exchange in
        # progress" is that method's definition and it is not the same as a row with
        # no closed_at: a turn past TURN_TTL is one of those and is not an exchange.
        # Such a row is only ever closed lazily from inside open_turn, whose one other
        # caller runs only when an assistant has something to say, so a stale one can
        # sit there for hours. Asking the table directly made every stop in that
        # window swallow the request beside it again.
        if _STOP.search(message.text) and self.open_turn() is not None:
            # Immediately: the turn is closed before this call returns, so a relay
            # racing with it finds no open turn and refuses.
            #
            # Checked even when the message flipped the switch, because the switch no
            # longer has to be the whole message: "!coordination off stop" asks for
            # both, and returning on the switch alone left the exchange it was trying
            # to end still open.
            #
            # And only counted when there was something to stop. The word is matched
            # anywhere on purpose, so "Corey, ask Denise if Gia can stop by the
            # pharmacy" says it without meaning it. With an exchange running, that
            # still ends it, which is the cautious direction and the cost the broad
            # match is chosen for. With nothing running it ended nothing and used to
            # swallow the request in the same breath, so the person was asking for a
            # turn and got silence.
            self._close_open_turn("stop")
            effects.append("stop")
        if effects:
            return " ".join(effects)
        if addresses_an_assistant(message.text, self._config.assistants):
            self._close_open_turn("superseded")
            # Timed by when the person spoke, not by when this tick read it. A backlog
            # the relay has not seen before is history, not an exchange in progress.
            self._open_turn(person_id=person_id, source_seq=message.seq, opened_at=message.at)
            return "turn:open"
        return "ignored"

    # -- speaking to the people, without crossing -------------------------------

    def announce(self, persona_id: str, text: str) -> str:
        """Say something to both people in the group, where it stops.

        The planner's proposal goes out this way. It is addressed to Franco and Gia
        and asks the other assistant for nothing, so crossing it would buy nothing,
        and it would carry text derived from the open web into a peer's prompt. That
        is the one path the design refuses to have, and closing it by not having the
        path beats filtering venue prose for instructions forever.

        The off switch is checked here rather than left to the caller, because a
        proposal signed by both of them is the coordination feature speaking.
        """
        if not self.enabled():
            raise CoordinationDisabled("assistant-to-assistant messaging is switched off")
        return self._transport.post_to_group(persona_id, text)

    # -- the crossing ----------------------------------------------------------

    def relay(self, request: PeerRequest, refresh_group: Callable[[], bool]) -> RelayedMessage:
        """Post to the group, then hand the same words to the peer. In that order.

        Nothing above the post can have said anything to anybody, so everything that
        goes wrong up there is either a refusal or a :class:`GroupPostFailed`, never
        the ambiguous kind. A disk that has gone read-only must not be reported as
        words the family may already have read.
        """
        try:
            if request.origin is not MessageOrigin.GROUP_TRANSCRIPT:
                raise OriginRefused(f"{request.origin} may not reach the other assistant")
            if not self.enabled():
                raise CoordinationDisabled("assistant-to-assistant messaging is switched off")

            peer_persona_id = self._config.peer_of(request.speaker_persona_id)
            turn = self.open_turn()
            if turn is None:
                raise NoOpenTurn(
                    "no human has addressed an assistant in the group since the last stop"
                )
            if self._spoken(turn.id, request.speaker_persona_id) >= TURN_CAP:
                self._close_if_both_capped(turn.id)
                raise TurnCapReached(
                    f"{request.speaker_persona_id} has already sent {TURN_CAP} messages this turn"
                )

            # The slot is taken before the post, not after it. The transport treats an
            # unconfirmed send as posted, on the grounds that there is no way to rule
            # out that Telegram has the words; counting only confirmed sends made the
            # cap read the same event the opposite way, so words that may already be
            # in the family group cost nothing against the two. The row is released
            # only when the relay establishes that nothing was sent, so the cap counts
            # what may have reached them rather than what is known to have.
            #
            # Inside this block, because it is still above the post: a write that
            # fails here said nothing to anybody, and reporting that as the ambiguous
            # status would tell the assistants the family may have read words that
            # were never sent.
            record = RelayedMessage(
                id=uuid.uuid4().hex,
                turn_id=turn.id,
                speaker_persona_id=request.speaker_persona_id,
                peer_persona_id=peer_persona_id,
                text=request.text,
                group_message_ref=UNCONFIRMED_POST,
                posted_at=self._clock().isoformat(),
            )
            self._reserve(record)
        except CoordinationRefused:
            raise
        except Exception as never_started:
            raise GroupPostFailed(f"nothing was sent: {never_started}") from never_started

        try:
            group_message_ref = self._transport.post_to_group(
                request.speaker_persona_id, request.text
            )
        except GroupPostFailed:
            # The one case the relay can rule out: the send did not happen, so the
            # group never saw it and the slot goes back.
            self._release(record.id)
            raise
        record = dataclasses.replace(record, group_message_ref=group_message_ref)
        with self._database.write() as cx:
            cx.execute(
                "UPDATE coordination_message SET group_message_ref = ? WHERE id = ?",
                (group_message_ref, record.id),
            )

        # Both checks detect events, but by intentionally different mechanisms. The
        # flag stores only current state, so refresh_group reports off even when the
        # same refresh later sees on. A closed turn cannot reopen, so comparing turn
        # ids detects stop followed by a new turn. Normalizing either loses a case.
        off_switch_seen = refresh_group()
        if off_switch_seen or not self.enabled():
            raise OffSwitchStopped("the off switch was pulled before the peer handoff")
        refreshed_turn = self.open_turn()
        if refreshed_turn is None or refreshed_turn.id != turn.id:
            raise CrossingStopped("stop closed the exchange before the peer handoff")

        # Stamped only when the peer actually took it. The transport watches a handover
        # for a few seconds and then leaves it running, and a watch that ran out is not
        # a delivery: the peer's gateway can be up while its agent is wedged. Recording
        # that as delivered would put a time in the column against a message nothing
        # ever received, and this row is what anyone asking what happened will read.
        if self._transport.deliver_to_peer(peer_persona_id, turn.id, request.text):
            delivered_at = self._clock().isoformat()
            with self._database.write() as cx:
                cx.execute(
                    "UPDATE coordination_message SET delivered_at = ? WHERE id = ?",
                    (delivered_at, record.id),
                )
            record = dataclasses.replace(record, delivered_at=delivered_at)
        self._close_if_both_capped(turn.id)
        return record

    def _reserve(self, record: RelayedMessage) -> None:
        """Take the speaker's slot, before anything can have reached the group."""
        with self._database.write() as cx:
            cx.execute(
                "INSERT INTO coordination_message (id, turn_id, speaker_persona_id, "
                "peer_persona_id, text, posted_at, group_message_ref) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    record.id,
                    record.turn_id,
                    record.speaker_persona_id,
                    record.peer_persona_id,
                    record.text,
                    record.posted_at,
                    record.group_message_ref,
                ),
            )

    def _release(self, message_id: str) -> None:
        """Give the slot back, only ever when the group demonstrably never saw it."""
        with self._database.write() as cx:
            cx.execute("DELETE FROM coordination_message WHERE id = ?", (message_id,))

    # -- state -----------------------------------------------------------------

    def open_turn(self) -> Turn | None:
        """The exchange in progress, if a person is still plausibly watching it."""
        with self._database.read() as cx:
            row = cx.execute(
                "SELECT id, opened_at FROM coordination_turn "
                "WHERE closed_at IS NULL ORDER BY opened_at DESC LIMIT 1"
            ).fetchone()
        if row is None:
            return None
        if self._clock() - datetime.fromisoformat(str(row["opened_at"])) >= TURN_TTL:
            self._close_open_turn("stale")
            return None
        return Turn(id=str(row["id"]), opened_at=str(row["opened_at"]))

    def _open_turn(
        self,
        *,
        person_id: str,
        source_seq: int,
        opened_at: datetime,
    ) -> Turn:
        """A person addressed an assistant in the group. That is the only way in.

        No ``opened_by``: the planner used to be the other opener and no longer opens
        anything, so a parameter with one caller and one value would be a way back to
        a hole that is closed.
        """
        turn = Turn(id=uuid.uuid4().hex, opened_at=opened_at.isoformat())
        with self._database.write() as cx:
            cx.execute(
                "INSERT INTO coordination_turn (id, opened_by_person_id, source_seq, "
                "opened_at) VALUES (?, ?, ?, ?)",
                (turn.id, person_id, source_seq, turn.opened_at),
            )
        return turn

    def _close_open_turn(self, reason: str) -> None:
        with self._database.write() as cx:
            cx.execute(
                "UPDATE coordination_turn SET closed_at = ?, closed_reason = ? "
                "WHERE closed_at IS NULL",
                (self._clock().isoformat(), reason),
            )

    def _close_if_both_capped(self, turn_id: str) -> None:
        if all(self._spoken(turn_id, persona) >= TURN_CAP for persona in self._config.assistants):
            with self._database.write() as cx:
                cx.execute(
                    "UPDATE coordination_turn SET closed_at = ?, closed_reason = 'cap' "
                    "WHERE id = ? AND closed_at IS NULL",
                    (self._clock().isoformat(), turn_id),
                )

    def _spoken(self, turn_id: str, persona_id: str) -> int:
        with self._database.read() as cx:
            row = cx.execute(
                "SELECT COUNT(*) AS spoken FROM coordination_message "
                "WHERE turn_id = ? AND speaker_persona_id = ?",
                (turn_id, persona_id),
            ).fetchone()
        return int(row["spoken"])

    def person_for(self, sender_channel_id: str) -> str | None:
        """The enrolled household member behind a channel account, or nobody."""
        with self._database.read() as cx:
            row = cx.execute(
                "SELECT person_id FROM channel_identity WHERE channel = ? AND channel_user_id = ?",
                (HOUSEHOLD_CHANNEL, sender_channel_id),
            ).fetchone()
        return None if row is None else str(row["person_id"])

    def off_is_pending(self, messages: Iterable[GroupMessage]) -> bool:
        """Whether any of these unapplied messages switches coordination off.

        Read-only, and that is the whole point of it. Nothing is applied, no cursor
        moves, no turn opens. The planner runs in its own process and asks this so it
        honours a switch that has been typed but not yet ingested, while the tick
        stays the only thing that writes. Two processes ingesting the same group is
        what :mod:`household.db` means when it says one controlled writer without a
        second process to run it, and a planner that applied what it read was that
        second process.

        Matched with the same pattern the switch itself uses, so there is one
        definition of what off looks like rather than a second one drifting here.

        An off followed by an on in the same pending batch still answers yes. That is
        the rule a crossing already follows: somebody pulled the switch while this run
        was being decided, and a later on enables the next run rather than reviving
        this one.

        A message already applied from either gateway is not pending. Its switch
        effect is already represented by :meth:`enabled`, even when the other
        gateway's cursor has not reached its duplicate yet.
        """
        for message in messages:
            if self._already_seen(message.key):
                continue
            if self.person_for(message.sender_channel_id) is None:
                continue
            if _SWITCH_OFF.match(message.text) is not None:
                return True
        return False

    def off_was_typed_since(self, messages: Iterable[GroupMessage], since: datetime) -> bool:
        """Whether a household member typed off at or after a moment.

        Unlike :meth:`off_is_pending`, this asks what happened since a time rather
        than what nobody has applied. Seen status is irrelevant here because the tick
        may apply off and then on while the planner is in flight.
        """
        for message in messages:
            if message.at < since:
                continue
            if self.person_for(message.sender_channel_id) is None:
                continue
            if _SWITCH_OFF.match(message.text) is not None:
                return True
        return False

    def _already_seen(self, key: str) -> bool:
        with self._database.read() as cx:
            row = cx.execute("SELECT 1 FROM coordination_seen WHERE key = ?", (key,)).fetchone()
        return row is not None

    def _advance_cursor(self, persona_id: str, seq: int, key: str) -> None:
        with self._database.write() as cx:
            cx.execute(
                "INSERT INTO coordination_cursor (persona_id, last_seq) VALUES (?, ?) "
                "ON CONFLICT(persona_id) DO UPDATE SET last_seq = MAX(last_seq, excluded.last_seq)",
                (persona_id, seq),
            )
            cx.execute("INSERT OR IGNORE INTO coordination_seen (key) VALUES (?)", (key,))

    def cursor(self, persona_id: str) -> int:
        with self._database.read() as cx:
            row = cx.execute(
                "SELECT last_seq FROM coordination_cursor WHERE persona_id = ?", (persona_id,)
            ).fetchone()
        return 0 if row is None else int(row["last_seq"])


__all__ = [
    "TURN_CAP",
    "TURN_TTL",
    "UNCONFIRMED_POST",
    "CoordinationDisabled",
    "CoordinationRefused",
    "CrossingStopped",
    "GroupMessage",
    "GroupPostFailed",
    "MessageOrigin",
    "NoOpenTurn",
    "OffSwitchStopped",
    "OriginRefused",
    "PeerRequest",
    "Relay",
    "RelayConfig",
    "RelayTransport",
    "RelayedMessage",
    "Turn",
    "TurnCapReached",
    "addresses_an_assistant",
]
