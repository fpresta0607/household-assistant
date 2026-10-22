#!/usr/bin/env python3
"""The host side of the group surface.

Two subcommands:

``tick``
    Read what the people said in the group out of both gateways, apply it, then carry
    anything an assistant asked to say to the other one, and hand each assistant's own
    group posts to the other as context. Run it from a systemd timer.

``plan``
    One planner run: read the shared household calendar, find an evening both are
    free, and post a proposal to both people. It opens no exchange with the other
    assistant. ``--dry-run`` prints the message instead of posting it, which is how
    the first proposal reaches the CFO rather than the family group; the off switch
    is honoured either way.

Everything runs on the host as root, outside both containers, so the relay's state,
its turn counters and its off switch are not something either assistant can edit.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import stat
import subprocess
import sys
import uuid
from collections.abc import Callable, Sequence
from datetime import UTC, datetime, timedelta
from pathlib import Path

from gateway_config import load_household

from household.app import build_household
from household.coordination import (
    TURN_CAP,
    TURN_TTL,
    CoordinationRefused,
    GroupPostFailed,
    PeerRequest,
    Relay,
    RelayConfig,
)
from household.family_room import DockerPeerDelivery, DockerPeerHandover, mirror
from household.openclaw import (
    ANSWER_SUFFIX,
    DockerRelayTransport,
    GatewayContainer,
    OutboxBoundaryError,
    OutboxDirectory,
    OutboxRequest,
    first_json_value,
    group_messages,
    open_outbox,
    read_outbox,
)
from household.planner import (
    HOUSEHOLD_TZ,
    PLANNING_LEAD,
    CalendarEvent,
    Candidate,
    ResearchBudget,
    ResearchBudgetSpent,
    TasteMemory,
    Window,
    choose_window,
    compose_proposal,
    free_windows,
)

# The family group, the two people and the shared calendar, from the box's household
# file, which openclaw-family-group.py reads too.
IDENTIFIERS = load_household()
GROUP_CHAT_ID = IDENTIFIERS.family_group
STATE_ROOT = Path("/var/lib/household-assistant")
DATABASE_PATH = STATE_ROOT / "coordination/coordination.db"
# How far each assistant's own group posts have been handed to the other one. Beside
# the relay's database, root-only, so neither assistant can move it.
FAMILY_ROOM_STATE = STATE_ROOT / "coordination/family-room.json"

GATEWAYS = (
    GatewayContainer("corey", "openclaw-gateway", STATE_ROOT / "openclaw"),
    GatewayContainer("denise", "openclaw-denise", STATE_ROOT / "openclaw-denise"),
)
ASSISTANTS = tuple(gateway.persona_id for gateway in GATEWAYS)

# The two Telegram accounts that belong to this household. A sender the relay cannot
# find here opens no turn, stops nothing and cannot reach the off switch, which is
# what keeps anyone else in the group from driving the pair.
HOUSEHOLD_MEMBERS = {user_id: person for person, user_id in IDENTIFIERS.telegram_ids.items()}

# Whose iCloud reads the shared calendar, and its name in that account. One read, one
# source, no per-person split.
SHARED_CALENDAR = IDENTIFIERS.shared_calendar
SHARED_CALENDAR_APPLE_ID = IDENTIFIERS.shared_calendar_apple_id
APPLECAL = Path("/opt/household-assistant/coordination/calendar/applecal.py")

# How far ahead a planner run looks for an evening.
PLANNING_HORIZON = timedelta(days=14)

# And how far back it looks to learn from. The forward window is plans; only the
# past is attendance, so without this the taste store would have nothing real in it.
# A season is long enough to know what they do and short enough to still be true.
LEARNING_LOOKBACK = timedelta(days=90)

# What a planner run exits with when it correctly has nothing to propose: no free
# evening, the day's research turn already spent on another window, or a research turn
# that honestly found nothing. Type=oneshot with no SuccessExitStatus means systemd
# reads any non-zero as a failed unit, so returning 1 would have put the weekly planner
# in a failed state every time it behaved exactly as designed, with no symptom but a
# red unit nobody is watching. The reason goes to the journal either way; a non-zero
# exit is kept for the failures that are actually failures.
NOTHING_TO_PROPOSE = 0

# And what it exits with when the installed calendar reader fails its root trust
# checks. Deliberately not NOTHING_TO_PROPOSE: the cases above are the planner working
# correctly and having nothing to say, while this one means the file root is about to
# execute is missing, replaced or writable by someone it should not be. Reporting that
# as a successful run leaves the weekly unit green and silently inert for as long as
# nobody looks, which is the one outcome a trust boundary must never have.
TRUST_BOUNDARY_FAULT = 1

# How long a crossing's answer stays readable in the outbox after it is written.
ANSWER_TTL = timedelta(hours=1)

# The two subprocesses a plan run waits on. Named rather than inlined because
# household-coordination@.service sizes its TimeoutStartSec from their sum, and a
# test holds that sum to the unit file so changing one of these cannot silently
# start killing the weekly planner run.
CALENDAR_TIMEOUT_SECONDS = 180
RESEARCH_TIMEOUT_SECONDS = 900


class CalendarReaderRefused(RuntimeError):
    """The installed calendar reader failed its host-root trust checks."""


# What is worth suggesting depends on when the evening is, and this job runs every
# Wednesday indefinitely. The prompt used to assert "it is autumn" as a fixed line,
# which was true on the day it was written and would have been asking a model for
# pumpkin patches in February, getting nothing useful and failing nowhere visible.
# Four seasons, indexed by (month % 12) // 3: December through February is 0, and so
# on round the year. Written once each rather than repeated per month, so a reworded
# hint cannot end up saying two different things in two of its three copies.
SEASONS: tuple[tuple[str, str], ...] = (
    ("winter", "lights, markets, indoor music and a warm room"),
    ("spring", "first patios, garden shows and the lake opening up"),
    ("summer", "festivals, beaches, boats and outdoor music"),
    ("autumn", "patches, haunted houses, corn mazes, fall festivals, lake weekends"),
)


def season_of(month: int) -> tuple[str, str]:
    """What is worth suggesting in that month, and what it looks like."""
    return SEASONS[(month % 12) // 3]


RESEARCH_PROMPT = """Find four things Franco and Gia could do together on {window}.
All times are US Central.

Home is Itasca, Illinois. Anywhere in Chicagoland counts, city or suburbs, and the
family has a lake house at Fontana on Lake Geneva, so events around the lake are
worth surfacing for a weekend without being asked for. It is {season}: {seasonal}
all count.

Weight them towards what they already enjoy: {interests}.

Be specific enough to act on: the actual name, and one line on why it is worth the
drive. Check it is actually open at that time.

Reply with a JSON array and nothing else. Each item:
  {{"name": "...", "area": "the town or neighbourhood, as you would say it aloud",
    "what": "one short line", "tags": ["live music" | "worship" | "family" | "food"
    | "outdoors" | "autumn" | "lake"]}}
"""


def build() -> tuple[Relay, TasteMemory, ResearchBudget]:
    household = build_household(DATABASE_PATH)
    with household.database.write() as cx:
        cx.executemany(
            "INSERT OR IGNORE INTO channel_identity "
            "(channel, channel_user_id, person_id, enrolled_at) VALUES ('telegram', ?, ?, ?)",
            [
                (channel_user_id, person_id, datetime.now(UTC).isoformat())
                for channel_user_id, person_id in HOUSEHOLD_MEMBERS.items()
            ],
        )
    relay = Relay(
        household.database,
        RelayConfig(assistants=ASSISTANTS),
        DockerRelayTransport(GATEWAYS, group_chat_id=GROUP_CHAT_ID),
    )
    return relay, TasteMemory(household.database), ResearchBudget(household.database)


# -- tick ----------------------------------------------------------------------


def tick(relay: Relay, taste: TasteMemory) -> int:
    """One pass. Returns the number of messages that crossed."""
    should_skip_posts = False

    def refresh_group() -> bool:
        nonlocal should_skip_posts
        should_skip = read_the_group(relay, taste)
        should_skip_posts = should_skip_posts or should_skip
        return should_skip

    refresh_group()
    crossed = 0
    for gateway in GATEWAYS:
        try:
            opened = open_outbox(gateway)
            if opened is None:
                continue
            with opened as outbox:
                prune_outbox(outbox, gateway.persona_id)
                transport_attempts = 0
                for waiting in read_outbox(outbox, gateway.persona_id):
                    # The unit timeout covers two gateways at TURN_CAP transport
                    # attempts each, with a post timeout and delivery acknowledgement
                    # for every attempt. Refusals never reach the transport, so they
                    # leave this budget untouched for a later valid request.
                    if transport_attempts == TURN_CAP:
                        break
                    # The read at the top of the tick is the ingest. This one is the
                    # stop check, and it runs before every crossing rather than once
                    # per tick: a stop typed while the last crossing was being carried
                    # has to land before the next one goes out.
                    refresh_group()
                    current_turn = relay.open_turn()
                    try:
                        # Claimed by unlinking it, before anything is posted. While the
                        # file is there the words have not been said, which is what lets
                        # a skill that gave up waiting take its own request back; whoever
                        # wins the unlink owns it, and the loser never posts.
                        outbox.unlink(waiting.name)
                    except FileNotFoundError:
                        continue
                    if current_turn is not None and waiting.created_at < datetime.fromisoformat(
                        current_turn.opened_at
                    ):
                        result = {
                            "status": "refused",
                            "reason": "stale request from an earlier turn",
                            "detail": "the group never saw it",
                        }
                    else:
                        result = _carry(
                            relay,
                            waiting.request,
                            refresh_group,
                        )
                    transport_attempts += int(result["status"] != "refused")
                    crossed += int(result["status"] == "relayed")
                    write_answer(outbox, _answer_name(waiting), result)
        except (OutboxBoundaryError, OSError) as error:
            print(f"{gateway.persona_id}: outbox refused: {error}", file=sys.stderr)
    hand_over_group_posts(relay, taste, should_skip=should_skip_posts)
    return crossed


def hand_over_group_posts(relay: Relay, taste: TasteMemory, *, should_skip: bool = False) -> int:
    """What each assistant said in the group, handed to the other as context.

    Telegram shows no bot another bot's posts, so this is how Corey and Denise see each
    other in The Fam. It reads both plugins' outbox files and only reaches into a
    container when there is something new to hand over; see household/family_room.py.
    The group is read again before each assistant's posts go over, as it is before a
    crossing's handoff, so a switch pulled while this tick ran stops what follows it.
    A failure here is reported and left for the next tick: the crossings above are
    already done, and they are the part a person may be waiting on.
    """
    is_on = not should_skip

    def still_on() -> bool:
        nonlocal is_on
        off_switch_seen = read_the_group(relay, taste)
        is_on = is_on and not off_switch_seen and relay.enabled()
        return is_on

    try:
        return mirror(
            GATEWAYS,
            DockerPeerDelivery(),
            FAMILY_ROOM_STATE,
            handover=DockerPeerHandover(GROUP_CHAT_ID),
            now=relay.now(),
            still_on=still_on,
        )
    except OSError as error:
        print(f"family room: handover refused: {error}", file=sys.stderr)
        return 0


def _answer_name(waiting: OutboxRequest) -> str:
    return f"{waiting.name.removesuffix('.json')}{ANSWER_SUFFIX}"


def write_answer(outbox: OutboxDirectory, name: str, result: dict[str, str]) -> None:
    """Put the answer in place in one step, because someone is reading it as we write.

    The skill polls this exact path every couple of seconds. Writing in place truncates
    first, so a read landing inside the write sees an empty file, and the assistant
    gets a traceback where it expected a status. Written beside and renamed, the reader
    sees either the old state or the whole answer, which is the same move the skill
    already makes when it writes a request.
    """
    if Path(name).name != name:
        raise ValueError("an answer name must not contain a path")
    staging = name + ".partial"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    descriptor: int | None = None
    for attempt in range(2):
        try:
            descriptor = os.open(staging, flags, 0o600, dir_fd=outbox.descriptor)
            break
        except FileExistsError:
            if attempt == 1:
                raise
            with contextlib.suppress(FileNotFoundError):
                outbox.unlink(staging)
    if descriptor is None:
        raise RuntimeError(f"could not create answer staging file: {staging}")
    try:
        os.fchown(descriptor, outbox.owner_uid, outbox.owner_gid)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            descriptor = None
            stream.write(json.dumps(result))
    finally:
        if descriptor is not None:
            os.close(descriptor)
    outbox.replace(staging, name)


def prune_outbox(outbox: OutboxDirectory, persona_id: str) -> None:
    """Drop what nobody is coming back for: old answers, and requests gone stale.

    Answers, because the skill never deletes one so that asking twice about the same
    request gets the same answer twice, which makes this the only thing that removes
    them. An hour is far longer than any assistant waits.

    Requests, because until now nothing aged one out and a request outlived every
    reason it existed. An `ask` whose process died before its own deadline never runs
    the withdrawal, so the file stayed; hours later a person says something that opens
    a fresh turn and the tick posts those stale words into it, spending a slot of a
    conversation they were never part of. TURN_TTL is the right age for it because it
    is the same fact: past that, the exchange the request belonged to is over, and any
    turn open now is a different one.

    A dropped request gets the answer its author would have written for itself, so a
    later `check` says the group never saw it rather than that nobody knows. There is
    no race with a live `ask` doing the same: TURN_TTL is fifteen minutes and an ask
    gives up after sixty seconds, so anything old enough to be pruned here has had no
    waiter for fourteen of them.

    Requests are found by name rather than through `read_outbox`, which skips a file
    it cannot parse. Going through it would have left a corrupt request immortal,
    which is the thing this function exists to stop.
    """
    now = datetime.now(UTC)
    for name in outbox.names(persona_id):
        if not name.endswith(".json"):
            continue
        metadata = outbox.metadata(name)
        if metadata is None:
            continue
        if not stat.S_ISREG(metadata.st_mode):
            # Removed rather than left alone. Nothing legitimate puts a non-regular
            # entry in here, so it is an attack or a corruption either way, and a
            # FIFO named like a request blocked the whole tick until it was gone.
            # An earlier round skipped these instead, which is what turned a nuisance
            # into indefinite starvation of the other assistant.
            print(f"{persona_id}: removing a non-regular outbox entry: {name}", file=sys.stderr)
            try:
                outbox.unlink(name)
            except OSError as error:
                # A directory cannot be unlinked, and this does not delete trees as
                # root inside a directory an assistant owns. It stays and it is said
                # out loud; read_outbox rejects it too, so it blocks nothing.
                print(f"{persona_id}: could not remove {name}: {error}", file=sys.stderr)
            continue
        age = now - datetime.fromtimestamp(metadata.st_mtime, UTC)
        if name.endswith(ANSWER_SUFFIX):
            if age > ANSWER_TTL:
                with contextlib.suppress(FileNotFoundError):
                    outbox.unlink(name)
            continue
        if age <= TURN_TTL:
            continue
        print(f"dropping a stale request: {name}", file=sys.stderr)
        try:
            outbox.unlink(name)
        except FileNotFoundError:
            continue
        write_answer(
            outbox,
            f"{name.removesuffix('.json')}{ANSWER_SUFFIX}",
            {
                "status": "unsent",
                "reason": "the request went stale before anything carried it",
                "detail": "the group never saw it. You are free to say it yourself in "
                "the group, in your own words.",
            },
        )


def read_the_group(relay: Relay, taste: TasteMemory) -> bool:
    """What the people have said since last time, from both gateways' own records."""
    should_skip_posts = not relay.enabled()
    off_switch_seen = False
    for gateway in GATEWAYS:
        messages = group_messages(
            gateway.agent_database,
            group_chat_id=GROUP_CHAT_ID,
            after_seq=relay.cursor(gateway.persona_id),
        )
        for message in messages:
            person_id = relay.person_for(message.sender_channel_id)
            if person_id is not None:
                taste.learn_from_group(text=message.text, person_id=person_id, ref=message.key)
        for effect in relay.ingest(gateway.persona_id, messages):
            print(f"{gateway.persona_id}: {effect}", file=sys.stderr)
            off_switch_seen = off_switch_seen or "switch:off" in effect.split()
    return should_skip_posts or off_switch_seen or not relay.enabled()


def _carry(relay: Relay, request: PeerRequest, refresh_group: Callable[[], bool]) -> dict[str, str]:
    """One crossing, and the honest word for how it went.

    The assistant is about to decide whether to say something in the group, so the
    only thing that matters is what is known about whether the family read these
    words. Two of the three say the group never saw them, and they say it because
    the relay established it, not because that is the usual case:

    * ``refused`` - a guard said no. Nothing was attempted and nothing was seen.
    * ``unsent`` - the send failed or never started, and the group never saw it.
    * ``unconfirmed`` - everything else, which is every case where the group having
      seen the words cannot be ruled out. ``reason`` and ``detail`` still carry what
      actually went wrong, for a person reading the journal; the status deliberately
      claims less than they do, because the status is what the assistant acts on.

    Whatever the answer, the request is spent: the caller has already unlinked the
    file to claim it, so a failed crossing is reported once rather than retried into
    a group that would read the same sentence twice.
    """
    try:
        record = relay.relay(request, refresh_group)
    except CoordinationRefused as refusal:
        print(f"refused: {type(refusal).__name__}: {refusal}", file=sys.stderr)
        return {"status": "refused", "reason": type(refusal).__name__, "detail": str(refusal)}
    except GroupPostFailed as unsent:
        print(f"unsent: {unsent}", file=sys.stderr)
        return {"status": "unsent", "reason": type(unsent).__name__, "detail": str(unsent)}
    except Exception as failure:
        print(f"unconfirmed: {type(failure).__name__}: {failure}", file=sys.stderr)
        return {
            "status": "unconfirmed",
            "reason": type(failure).__name__,
            "detail": str(failure),
        }
    if record.delivered_at is None:
        return {
            "status": "unconfirmed",
            "reason": "unacknowledged peer handoff",
            "detail": "the group saw the words, but the peer did not acknowledge receiving them",
        }
    return {"status": "relayed", "turn_id": record.turn_id, "posted_at": record.posted_at}


# -- plan ----------------------------------------------------------------------


def shared_calendar(start: datetime, end: datetime) -> list[CalendarEvent]:
    """The one shared household calendar, read on the host, over CalDAV.

    ``--apple-id`` is a global flag and goes before the subcommand. The password comes
    from the process environment, which systemd fills from the root-only env file, and
    is never written anywhere by this script.
    """
    try:
        metadata = os.lstat(APPLECAL)
    except OSError as error:
        raise CalendarReaderRefused(f"calendar reader cannot be inspected: {error}") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise CalendarReaderRefused("calendar reader is a symlink")
    if not stat.S_ISREG(metadata.st_mode):
        raise CalendarReaderRefused("calendar reader is not a regular file")
    if metadata.st_uid != 0:
        raise CalendarReaderRefused("calendar reader is not owned by root")
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise CalendarReaderRefused("calendar reader is group or world writable")

    completed = subprocess.run(
        [
            sys.executable,
            str(APPLECAL),
            "--apple-id",
            SHARED_CALENDAR_APPLE_ID,
            "events",
            "list",
            "--calendar",
            SHARED_CALENDAR,
            "--from",
            start.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "--to",
            end.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        ],
        capture_output=True,
        text=True,
        timeout=CALENDAR_TIMEOUT_SECONDS,
        check=True,
    )
    payload = json.loads(completed.stdout)
    if isinstance(payload, dict) and "error" in payload:
        raise RuntimeError(f"the shared calendar read failed: {payload['error']}")
    return [_as_event(item) for item in payload]


def _as_event(item: dict[str, object]) -> CalendarEvent:
    all_day = bool(item.get("all_day"))
    return CalendarEvent(
        uid=str(item["uid"]),
        summary=str(item.get("summary") or ""),
        start=_moment(str(item["start"]), all_day=all_day),
        end=_moment(str(item["end"]), all_day=all_day),
        all_day=all_day,
    )


def _moment(value: str, *, all_day: bool) -> datetime:
    """An all-day entry is a local date, not a UTC one.

    Reading it as UTC shifts the day it blocks by five hours, which is the same class
    of mistake that put a seven o'clock concert on the calendar at breakfast.
    """
    if all_day:
        return datetime.fromisoformat(value).replace(tzinfo=HOUSEHOLD_TZ)
    return datetime.fromisoformat(value)


def research(window: Window, interests: Sequence[str]) -> list[Candidate]:
    """One agent turn on Corey's gateway. This is the whole research spend."""
    season, seasonal = season_of(window.start.astimezone(HOUSEHOLD_TZ).month)
    completed = subprocess.run(
        [
            "docker",
            "exec",
            GATEWAYS[0].container,
            "node",
            "dist/index.js",
            "agent",
            "--session-key",
            f"agent:main:coordination-research:{uuid.uuid4().hex}",
            "--message",
            RESEARCH_PROMPT.format(
                window=window.describe(),
                season=season,
                seasonal=seasonal,
                interests=", ".join(interests) or "an evening out together",
            ),
        ],
        capture_output=True,
        text=True,
        timeout=RESEARCH_TIMEOUT_SECONDS,
        check=True,
    )
    return _parse_candidates(completed.stdout)


def _is_a_candidate_array(found: list[object]) -> bool:
    """Whether this array is the answer rather than something else in the prose.

    The research turn is a model's, so "reply with a JSON array and nothing else" is
    an instruction, not a guarantee. A citation marker like "[1]" decodes as a list
    perfectly well and would then be indexed by name.

    An empty array is accepted, and that is the difference between a planner that
    honestly found nothing and a failed unit. This used to require a non-empty list,
    so a research turn that came back with `[]` found no acceptable array at all,
    raised, and marked the weekly unit failed for doing exactly what it is supposed to
    do when Chicagoland has nothing on. Dropping the emptiness test costs nothing
    against the citation case, because `[1]` is still not a dict carrying the three
    fields, and `all` of nothing is true.

    An empty array is accepted as the answer only when nothing containing it was
    decoded and refused first, because :func:`first_json_value` skips a refused value
    whole. So the empty `tags` list inside a malformed answer, one item with a null
    area, is never reached, and that answer still fails the unit rather than reading
    as found nothing. What remains is a standalone empty array printed ahead of the
    real one, which the gateway does not do, and whose failure would be a run with
    nothing to propose rather than a wrong proposal.
    """
    return all(
        isinstance(item, dict)
        and all(isinstance(item.get(field), str) for field in ("name", "area", "what"))
        for item in found
    )


def _tags_of(value: object) -> tuple[str, ...]:
    """The tags on one candidate, from a model that was asked for a list of strings.

    A list of strings is the one spelling the prompt asks for, so it is the one
    spelling read here. Anything else is no tags rather than a guess: a bare string
    is iterable, and taking it at its word turned "autumn" into six one-letter tags
    that matched nothing and were then printed as the reason for the pick.
    """
    if not isinstance(value, list):
        return ()
    return tuple(tag for tag in value if isinstance(tag, str))


def _parse_candidates(output: str) -> list[Candidate]:
    """The JSON array in the CLI's stdout, found by decoding rather than by matching."""
    found = first_json_value(output, list, where=_is_a_candidate_array)
    if found is None:
        raise RuntimeError("the research turn returned no JSON array of candidates")
    return [
        Candidate(
            name=str(item["name"]),
            area=str(item["area"]),
            what=str(item["what"]),
            tags=_tags_of(item.get("tags")),
        )
        for item in found
    ]


def off_is_pending(relay: Relay) -> bool:
    """Whether anybody has switched coordination off since the tick last read the group.

    Reads both transcripts and applies nothing: no cursor moves, no turn opens, no
    taste is recorded. The planner is a separate systemd instance from the tick, and
    an earlier version of this had it call :func:`read_the_group`, which made it a
    second process ingesting the same group. That broke the single writer the storage
    layer is built on: two processes could each claim the same human message and each
    open a turn, which doubles the two-message cap, and a planner consuming an off and
    then an on could leave a crossing in flight believing the switch was never pulled.
    Asking without applying removes the second writer rather than serialising it.
    """
    for gateway in GATEWAYS:
        messages = group_messages(
            gateway.agent_database,
            group_chat_id=GROUP_CHAT_ID,
            after_seq=relay.cursor(gateway.persona_id),
        )
        if relay.off_is_pending(messages):
            print(f"{gateway.persona_id}: an unapplied off is pending", file=sys.stderr)
            return True
    return False


def off_was_typed_since(relay: Relay, cursors: dict[str, int], since: datetime) -> bool:
    for gateway in GATEWAYS:
        messages = group_messages(
            gateway.agent_database,
            group_chat_id=GROUP_CHAT_ID,
            after_seq=cursors[gateway.persona_id],
        )
        if relay.off_was_typed_since(messages, since):
            print(f"{gateway.persona_id}: off was typed during planning", file=sys.stderr)
            return True
    return False


def plan(relay: Relay, taste: TasteMemory, budget: ResearchBudget, *, dry_run: bool) -> int:
    # The cursor is the floor of the final scan and run_start is its time boundary.
    # Capture every cursor first so no message can land between the boundaries and
    # be excluded by both.
    starting_cursors = {
        gateway.persona_id: relay.cursor(gateway.persona_id) for gateway in GATEWAYS
    }
    run_start = relay.now()
    # The switch is checked against what the people have actually typed, not against
    # the position as of the last tick, by reading the group without applying it. This
    # is before the calendar read and long before the research turn, and it applies to
    # a dry run too: a dry run still reserves the day's only research turn in the
    # database when coordination is on, so letting one through while the pair are
    # switched off would spend the day.
    if off_is_pending(relay) or not relay.enabled():
        print("coordination is switched off; not planning", file=sys.stderr)
        return NOTHING_TO_PROPOSE
    # One read covering both jobs. Everything behind the run start is what they did,
    # which is what taste is made of; everything ahead is what they have planned,
    # which decides whether an evening is free. learn_from_calendar keeps to the first half.
    try:
        events = shared_calendar(run_start - LEARNING_LOOKBACK, run_start + PLANNING_HORIZON)
    except CalendarReaderRefused as refusal:
        print(f"refusing to plan: {refusal}", file=sys.stderr)
        return TRUST_BOUNDARY_FAULT
    taste.learn_from_calendar(events)

    window = choose_window(
        free_windows(
            events,
            horizon_start=run_start + PLANNING_LEAD,
            horizon_end=run_start + PLANNING_HORIZON,
        )
    )
    if window is None:
        print("no evening in the next fortnight has a free two hours", file=sys.stderr)
        return NOTHING_TO_PROPOSE

    try:
        candidates = budget.candidates(
            window, lambda: research(window, [tag for tag, _ in taste.ranked()])
        )
    except ResearchBudgetSpent as spent:
        # A designed outcome, not a crash: the day's one turn went on a different
        # window. The two other nothing-to-propose paths either side of this report
        # and exit the same way.
        print(f"no proposal today: {spent}", file=sys.stderr)
        return NOTHING_TO_PROPOSE
    if not candidates:
        # Nothing to pick, so nothing to post. A message listing no options that still
        # ends "say a number" is the assistant sounding confident about nothing, which
        # is the failure this whole surface is built to avoid in every other form.
        print("the research turn found nothing worth proposing", file=sys.stderr)
        return NOTHING_TO_PROPOSE
    proposal = compose_proposal(window=window, candidates=candidates, taste=taste)

    if dry_run:
        print(proposal)
        return 0

    # Like the refresh before a crossing hands words to the peer, this final check
    # stops work that was in flight when somebody pulled the switch.
    if off_was_typed_since(relay, starting_cursors, run_start):
        print("coordination was switched off during planning; not posting", file=sys.stderr)
        return NOTHING_TO_PROPOSE

    # Posted to the two of them, and it stops there. A proposal asks the other
    # assistant for nothing, and crossing it would carry venue prose the research turn
    # read off the open web into a peer's prompt.
    relay.announce("corey", proposal)
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("tick", help="carry what is waiting, once")
    planner = subcommands.add_parser("plan", help="one proactive planner run")
    planner.add_argument(
        "--dry-run",
        action="store_true",
        help="print the proposal instead of posting it in the group",
    )
    arguments = parser.parse_args(argv)

    relay, taste, budget = build()
    if arguments.command == "tick":
        tick(relay, taste)
        return 0
    return plan(relay, taste, budget, dry_run=arguments.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
