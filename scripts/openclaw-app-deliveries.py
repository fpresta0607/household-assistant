#!/usr/bin/env python3
"""Moves each scheduled job that delivers to Telegram to the same people in the Steward app.

Household communication uses the app, and Telegram goes off (issue #6). Every job a gateway's
scheduler announces to Telegram goes to one of three chats, each with a home in the app for
the same people:

- The Fam, the family group: the app's family room, `household:family`.
- The gateway's own person's private chat: that person's own thread, `household:<person>`.
- Anything else, such as the other parent's private chat: no clear home, so apply refuses the
  whole gateway and names how many, for a person to decide.

Only the job's delivery changes: its channel, its target and its account. Its prompt, schedule,
session and everything else stay as they are, and nothing is read from them. A job's words
reach the same people they reached on Telegram, so Denise's privacy rule holds: Gia's own
chat's jobs go to Gia's thread, and The Fam's to the room both people read.

`check` reads both gateways and says how many jobs still deliver to Telegram and how many go to
the app; `apply --gateway <persona>` moves one gateway's and reads each job back. Each job's
own delivery preview (`automations show`) then names its app route, with no run.
What it does and how it was rolled out are in docs/deploy/openclaw.md under "Telegram off".
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from collections.abc import Sequence
from typing import Any

from gateway_config import (
    GATEWAY_TIMEOUT_SECONDS,
    GATEWAYS,
    Gateway,
    Runner,
    ask_gateway,
    first_json_object,
    gateway_cli,
    load_household,
)

IDENTIFIERS = load_household()
FAMILY = "family"
APP_ACCOUNT = "default"


def _section(value: dict[str, Any], key: str) -> dict[str, Any]:
    found = value.get(key)
    return found if isinstance(found, dict) else {}


def telegram_chat(delivery: dict[str, Any]) -> str | None:
    """The Telegram chat a delivery goes to, or None when it does not go to Telegram."""
    to = delivery.get("to")
    channel = delivery.get("channel")
    if not isinstance(to, str) or not to.strip():
        return None
    bare = to.strip()
    for prefix in ("telegram:", "tg:"):
        if bare.lower().startswith(prefix):
            bare = bare[len(prefix) :]
            if channel in (None, "last"):
                channel = "telegram"
    return bare if channel == "telegram" else None


def app_target(chat: str, gateway: Gateway) -> str | None:
    """The app conversation for the same people as a Telegram chat, or None."""
    if chat == IDENTIFIERS.family_group:
        return FAMILY
    if chat == IDENTIFIERS.telegram_ids.get(gateway.person):
        return gateway.person
    return None


def _jobs(gateway: Gateway, run: Runner) -> list[dict[str, Any]]:
    completed = ask_gateway(gateway, run, "automations", "list", "--all", "--json")
    found = first_json_object(completed.stdout, "jobs") if completed.returncode == 0 else None
    if found is None or not isinstance(found.get("jobs"), list):
        raise RuntimeError(f"{gateway.container} would not list its scheduled jobs")
    return [job for job in found["jobs"] if isinstance(job, dict)]


def plan(jobs: list[dict[str, Any]], gateway: Gateway) -> tuple[list[tuple[str, str]], int]:
    """Each Telegram job's id and its app target, and how many have no clear one."""
    moves: list[tuple[str, str]] = []
    unclear = 0
    for job in jobs:
        chat = telegram_chat(_section(job, "delivery"))
        if chat is None:
            continue
        target = app_target(chat, gateway)
        if target is None or not isinstance(job.get("id"), str):
            unclear += 1
        else:
            moves.append((job["id"], target))
    return moves, unclear


def _app_count(jobs: list[dict[str, Any]]) -> int:
    return sum(1 for job in jobs if _section(job, "delivery").get("channel") == "household")


def check(gateways: Sequence[Gateway], run: Runner) -> int:
    healthy = True
    for gateway in gateways:
        try:
            jobs = _jobs(gateway, run)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            print(f"{gateway.persona} ({gateway.container}): unreadable: {error}")
            healthy = False
            continue
        moves, unclear = plan(jobs, gateway)
        print(
            f"{gateway.persona} ({gateway.container}): {len(moves) + unclear} to Telegram "
            f"({unclear} with no clear app home), {_app_count(jobs)} to the app"
        )
        healthy = healthy and not moves and not unclear
    return 0 if healthy else 1


def apply(gateway: Gateway, *, run: Runner, dry_run: bool) -> int:
    try:
        moves, unclear = plan(_jobs(gateway, run), gateway)
        if unclear:
            print(
                f"{gateway.persona}: refused, nothing written: {unclear} job(s) deliver to a "
                "Telegram chat with no clear home in the app",
                file=sys.stderr,
            )
            return 1
        if not moves:
            print(f"{gateway.persona}: nothing to move")
            return 0
        to_room = sum(1 for _, target in moves if target == FAMILY)
        print(
            f"{gateway.persona}: {len(moves)} job(s) to move: {to_room} to the family room, "
            f"{len(moves) - to_room} to {gateway.person}'s own thread"
        )
        if dry_run:
            print("dry run: nothing written.")
            return 0
        for job_id, target in moves:
            completed = run(
                gateway_cli(
                    gateway,
                    "automations",
                    "edit",
                    job_id,
                    "--announce",
                    "--channel",
                    "household",
                    "--to",
                    f"household:{target}",
                    "--account",
                    APP_ACCOUNT,
                ),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=GATEWAY_TIMEOUT_SECONDS,
                check=False,
            )
            if completed.returncode != 0:
                raise RuntimeError(f"{gateway.container} refused to move a job's delivery")
        left, unclear = plan(_jobs(gateway, run), gateway)
        if left or unclear:
            raise RuntimeError(f"{len(left) + unclear} job(s) still deliver to Telegram")
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"{gateway.persona}: not finished: {error}", file=sys.stderr)
        return 1
    print(f"{gateway.persona}: {len(moves)} job(s) moved; none delivers to Telegram")
    return 0


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways' deliveries")
    applier = commands.add_parser("apply", help="move one gateway's Telegram deliveries")
    applier.add_argument(
        "--gateway", required=True, choices=[gateway.persona for gateway in GATEWAYS]
    )
    applier.add_argument(
        "--dry-run", action="store_true", help="show what would move, write nothing"
    )
    arguments = parser.parse_args(argv)
    if arguments.command == "check":
        return check(GATEWAYS, run)
    # The real runner reaches the containers, which only root may; a test hands in its own.
    if run is subprocess.run and hasattr(os, "geteuid") and os.geteuid() != 0:
        parser.error("run as root on the box")
    chosen = next(gateway for gateway in GATEWAYS if gateway.persona == arguments.gateway)
    return apply(chosen, run=run, dry_run=arguments.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
