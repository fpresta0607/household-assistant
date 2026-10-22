#!/usr/bin/env python3
"""Carries the app's family room between the two gateways, from the host, as root.

Each gateway's household-app plugin keeps what its own person and its own assistant did
in the family room in ``household-app/outbox.json`` under the gateway's state. This
reads both files, and pipes whatever the other gateway has not had yet, with the
attachments it names, into that gateway's container:

    docker exec -i -u node <the other container> node .../household-app/relay-in.mjs

relay-in.mjs writes it into the plugin's inbox as the gateway's own user, so root never
opens a path for writing inside a directory an assistant controls. Reading is the
mirror of that: every step to the outbox and to each attachment is opened without
following a symlink, as a regular file of bounded size.

Nothing here decides whether an entry is true. The receiving plugin checks every one,
and a person's message only counts when that person's phone signed it. This only
narrows what it carries to what the source may say at all: its own person and its own
assistant, in the family room, and the room's own photo, which either person may set.
The same holds for Sign in with Apple: the sign-ins
waiting on the source for its own person, and its approver's approvals for the other
person, each checked again by the plugin that receives them. And the household cart and
the household note: the steps the source's own assistant took in each, which the receiving
plugin checks one by one. They ride along with every delivery and are a delivery of their
own when they change, so a gateway that lost them gets them back with the next one.

Run by household-app-relay.service whenever either outbox changes, and every fifteen
seconds as a backstop. It loops until both sides are caught up, so a message written
while a run is under way is not left for the backstop.

Nothing any message said is printed.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import stat
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from gateway_config import GATEWAYS, Gateway

PLUGIN_DIRECTORY = "household-app"
OUTBOX = "outbox.json"
MEDIA = "media"
RELAY_IN = "/opt/household-plugins/household-app/relay-in.mjs"
STATE_FILE = Path("/var/lib/household-assistant/coordination/household-app-relay.json")
# What a family-room entry may be: a message, a map shared as one among them, a reaction
# or a read marker, a face, an assistant's page, a live map's newest update, a person's
# answer to a reminder by place that would watch them, and a person's change to the
# room's shared look (family-look.js in the plugin).
CARRIED_KINDS = {"message", "reaction", "read", "avatar", "profile", "live", "place", "look"}
# The family room's own photo, which either person may set, is the one entry that speaks
# for neither side's person nor assistant (FAMILY_FACE in the plugin's room.js).
FAMILY_FACE = "family"

# The plugin keeps the newest 500 entries in the outbox, each with at most 8,000
# characters of text, so a real one is well inside this.
MAX_OUTBOX_BYTES = 16 * 1024 * 1024
# The plugin's own ceiling on one attachment, and a ceiling on one delivery's worth.
MAX_MEDIA_BYTES = 50 * 1024 * 1024
MAX_BATCH_MEDIA_BYTES = 120 * 1024 * 1024
ENTRIES_PER_BATCH = 100
# One delivery is one `docker exec` of a small node script; a minute is a wedged one.
DELIVERY_TIMEOUT_SECONDS = 60
# How many rounds one run makes before leaving the rest to the next trigger.
MAX_ROUNDS = 20
NO_SIGN_INS = json.dumps({"approvals": [], "signIns": []}, sort_keys=True)
# What both assistants write and both gateways replay, each as the steps each assistant took:
# the household cart (cart.js in the plugin) and the household note (notes.js), and the
# wishlist's private steps (wishes.js), which no phone is shown.
STEP_LOGS = ("cart", "notes", "wishes")
NO_STEPS = json.dumps([])

Runner = Callable[..., "subprocess.CompletedProcess[str]"]


class BoundaryError(Exception):
    """A path under a gateway's state that is not what the relay reads."""


@dataclass
class TickResult:
    delivered: int = 0
    problems: list[str] = field(default_factory=list)


def _open_under(gateway: Gateway, *names: str) -> int | None:
    """A read descriptor on state/<names...>, no step a symlink. None when missing."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    opened: list[int] = []
    try:
        opened.append(os.open(gateway.state, directory_flags))
        for name in names[:-1]:
            opened.append(os.open(name, directory_flags, dir_fd=opened[-1]))
        # O_NONBLOCK, so a FIFO planted under the name cannot hang the run on open.
        return os.open(names[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=opened[-1])
    except FileNotFoundError:
        return None
    except OSError as error:
        raise BoundaryError(f"refusing {gateway.persona}'s {'/'.join(names)}: {error}") from error
    finally:
        for descriptor in opened:
            os.close(descriptor)


def _read_bounded(gateway: Gateway, limit: int, *names: str) -> bytes | None:
    descriptor = _open_under(gateway, *names)
    if descriptor is None:
        return None
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise BoundaryError(f"{gateway.persona}'s {'/'.join(names)} is not a regular file")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise BoundaryError(f"{gateway.persona}'s {'/'.join(names)} is over its size bound")
    return data


def read_outbox(gateway: Gateway) -> dict[str, Any] | None:
    """The plugin's outbox, or None when there is none yet or it does not parse."""
    raw = _read_bounded(gateway, MAX_OUTBOX_BYTES, PLUGIN_DIRECTORY, OUTBOX)
    if raw is None:
        return None
    try:
        outbox = json.loads(raw)
    except (RecursionError, UnicodeDecodeError, ValueError):
        return None
    return outbox if isinstance(outbox, dict) else None


def read_media(gateway: Gateway, media_id: str) -> bytes | None:
    """An attachment's bytes, only when they hash to the name the entry gave them."""
    if len(media_id) != 64 or any(character not in "0123456789abcdef" for character in media_id):
        return None
    try:
        data = _read_bounded(gateway, MAX_MEDIA_BYTES, PLUGIN_DIRECTORY, MEDIA, media_id)
    except BoundaryError:
        return None
    if data is None or hashlib.sha256(data).hexdigest() != media_id:
        return None
    return data


def carried(gateway: Gateway, outbox: dict[str, Any]) -> list[dict[str, Any]]:
    """The outbox's entries this source may say at all, oldest first."""
    entries = outbox.get("entries")
    if not isinstance(entries, list):
        return []
    allowed = {gateway.person, gateway.persona}
    kept = [
        entry
        for entry in entries
        if isinstance(entry, dict)
        and (
            entry.get("author") in allowed
            or (entry.get("author") == FAMILY_FACE and entry.get("kind") == "avatar")
        )
        and entry.get("conversation") == "family"
        and entry.get("kind") in CARRIED_KINDS
        and isinstance(entry.get("rev"), int)
    ]
    return sorted(kept, key=lambda entry: entry["rev"])


def sign_ins(source: Gateway, target: Gateway, outbox: dict[str, Any]) -> dict[str, Any]:
    """The sign-ins waiting on the source for its person, and approvals for the target's."""

    def rows(key: str, person: str) -> list[dict[str, Any]]:
        value = outbox.get(key)
        listed = value if isinstance(value, list) else []
        return [row for row in listed if isinstance(row, dict) and row.get("person") == person]

    return {
        "signIns": rows("signIns", source.person),
        "approvals": rows("approvals", target.person),
    }


def assistant_steps(source: Gateway, outbox: dict[str, Any], key: str) -> list[dict[str, Any]]:
    """The steps the source's own assistant took in one of STEP_LOGS."""
    value = outbox.get(key)
    listed = value if isinstance(value, list) else []
    return [
        step for step in listed if isinstance(step, dict) and step.get("author") == source.persona
    ]


def load_state(path: Path) -> dict[str, Any]:
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return {}
    return state if isinstance(state, dict) else {}


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(state, stream)
    os.replace(temporary, path)


def batch_from(
    source: Gateway, entries: list[dict[str, Any]], outbox: dict[str, Any]
) -> tuple[dict[str, Any], dict[str, str], int]:
    """The next delivery: entries up to the bounds, their attachments, and the last rev."""
    batch_entries: list[dict[str, Any]] = []
    media: dict[str, str] = {}
    media_bytes = 0
    last_rev = 0
    for entry in entries[:ENTRIES_PER_BATCH]:
        wanted = [
            item["id"]
            for item in entry.get("media") or []
            if isinstance(item, dict)
            and isinstance(item.get("id"), str)
            and item["id"] not in media
        ]
        found = {
            media_id: data
            for media_id in wanted
            if (data := read_media(source, media_id)) is not None
        }
        size = sum(len(data) for data in found.values())
        if batch_entries and media_bytes + size > MAX_BATCH_MEDIA_BYTES:
            break
        media.update(
            {media_id: base64.b64encode(data).decode("ascii") for media_id, data in found.items()}
        )
        media_bytes += size
        batch_entries.append(entry)
        last_rev = entry["rev"]
    batch: dict[str, Any] = {"entries": batch_entries, "typing": outbox.get("typing") or {}}
    if isinstance(outbox.get("identity"), dict):
        batch["identity"] = outbox["identity"]
    return batch, media, last_rev


def deliver(
    source: Gateway, target: Gateway, batch: dict[str, Any], media: dict[str, str], run: Runner
) -> bool:
    command = ["docker", "exec", "-i", "-u", "node", target.container, "node", RELAY_IN]
    try:
        completed = run(
            command,
            input=json.dumps({"from": source.persona, "batch": batch, "media": media}),
            capture_output=True,
            text=True,
            timeout=DELIVERY_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        print(
            f"household-app relay: {source.persona} to {target.persona} timed out", file=sys.stderr
        )
        return False
    if completed.returncode != 0:
        detail = (completed.stderr or "").strip().splitlines()[-1:] or ["no detail"]
        print(
            f"household-app relay: {source.persona} to {target.persona} failed: {detail[0][:200]}",
            file=sys.stderr,
        )
        return False
    return True


def carry(
    source: Gateway, target: Gateway, state: dict[str, Any], run: Runner, result: TickResult
) -> bool:
    """One delivery from source to target, if anything is new. True when it delivered."""
    try:
        outbox = read_outbox(source)
    except BoundaryError as error:
        result.problems.append(str(error))
        return False
    if outbox is None:
        return False
    sent = state.setdefault(source.persona, {"rev": 0, "typing": "{}"})
    pending = [entry for entry in carried(source, outbox) if entry["rev"] > sent["rev"]]
    typing = json.dumps(outbox.get("typing") or {}, sort_keys=True)
    typing_changed = typing != sent["typing"]
    waiting = sign_ins(source, target, outbox)
    waiting_text = json.dumps(waiting, sort_keys=True)
    waiting_changed = waiting_text != sent.get("signIns", NO_SIGN_INS)
    steps = {key: assistant_steps(source, outbox, key) for key in STEP_LOGS}
    steps_text = {key: json.dumps(value, sort_keys=True) for key, value in steps.items()}
    steps_changed = any(steps_text[key] != sent.get(key, NO_STEPS) for key in STEP_LOGS)
    if not pending and not typing_changed and not waiting_changed and not steps_changed:
        return False
    batch, media, last_rev = batch_from(source, pending, outbox)
    batch.update(waiting)
    batch.update(steps)
    if not deliver(source, target, batch, media, run):
        result.problems.append(f"delivery from {source.persona} to {target.persona} failed")
        return False
    sent["rev"] = max(sent["rev"], last_rev)
    sent["typing"] = typing
    sent["signIns"] = waiting_text
    sent.update(steps_text)
    result.delivered += len(batch["entries"])
    return True


def tick(gateways: tuple[Gateway, Gateway], state_path: Path, run: Runner) -> TickResult:
    state = load_state(state_path)
    result = TickResult()
    first, second = gateways
    for _ in range(MAX_ROUNDS):
        moved = [carry(first, second, state, run, result), carry(second, first, state, run, result)]
        save_state(state_path, state)
        if not any(moved):
            break
    return result


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] != "tick":
        print("usage: household-app-relay.py tick", file=sys.stderr)
        return 2
    result = tick((GATEWAYS[0], GATEWAYS[1]), STATE_FILE, subprocess.run)
    for problem in result.problems:
        print(f"household-app relay: {problem}", file=sys.stderr)
    if result.delivered:
        print(f"household-app relay: carried {result.delivered} entries")
    return 1 if result.problems else 0


if __name__ == "__main__":
    sys.exit(main())
