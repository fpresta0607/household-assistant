#!/usr/bin/env python3
"""A prep packet about 48 hours before each event, from each person's own assistant.

A reminder says "dentist at 3:30". What helps is one message two days out with the
address, the drive time from where the person will be, what to bring, any form to fill
and the confirmation number. Each gateway gets one scheduled job of its own, the way
apply gives it the Today card's: once a day it reads the family's shared calendar and its
person's own, finds the events that start between 36 and 60 hours from then, and sends
its person one packet for each in their own thread of the Steward app. Those windows meet
end to end, so every event is in exactly one day's run, about 48 hours before it.

Nothing is written to the household note: an appointment can be one person's own, and a
packet goes to that person alone. A day with nothing coming ends with no message.
What it does and how it was rolled out are in docs/deploy/openclaw.md under "Prep packets".
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

JOB_KEY = "household-app:prep-packets"
JOB_NAME = "Prep packets"
# 8:00 on the gateway's own clock, the household's: a packet for an event between 8 PM
# tomorrow and 8 PM the day after, read over breakfast.
SCHEDULE = "0 8 * * *"
SHARED_CALENDAR = load_household().shared_calendar


def prompt() -> str:
    return (
        f"Prepare your person for what is coming in about two days. Read the family's shared "
        f'calendar, "{SHARED_CALENDAR}" in iCloud, and your person\'s own calendars for events '
        "that start between 36 and 60 hours from now and that your person goes to: an "
        "appointment, a flight, a school or church event, or anything else with a place to be. "
        "Leave out all-day markers, birthdays and anything with nowhere to go. For each one, "
        "find what helps: the address; the drive time from where your person will be just "
        "before it, their previous event's place that day or home, and when to leave; what to "
        "bring; any form to fill, with its link; and the confirmation number, from the "
        "invitation, the event's notes or your person's mail. Then send your person one packet "
        "for each event, as one message: its title and time first, then one short line for "
        "each of those that you found, and say plainly what you could not find. Use another "
        "person's plans only from what they told you or said in the family room. Send nothing "
        "to anyone else, book or change nothing. When nothing is coming in that window, "
        "reply NO_REPLY."
    )


def command(gateway: Gateway) -> list[str]:
    return [
        "automations",
        "add",
        "--declaration-key",
        JOB_KEY,
        "--name",
        JOB_NAME,
        "--cron",
        SCHEDULE,
        "--agent",
        "main",
        "--session",
        "isolated",
        "--message",
        prompt(),
        "--announce",
        "--channel",
        "household",
        "--to",
        f"household:{gateway.person}",
        "--json",
    ]


def shape(gateway: Gateway) -> dict[str, object]:
    """What `automations list --json` shows of the job when it is as apply adds it."""
    return {
        "name": JOB_NAME,
        "agent": "main",
        "schedule": ("cron", SCHEDULE, None),
        "session": "isolated",
        "prompt": ("agentTurn", prompt(), None),
        "delivery": ("announce", "household", f"household:{gateway.person}"),
    }


def _section(value: dict[str, Any], key: str) -> dict[str, Any]:
    found = value.get(key)
    return found if isinstance(found, dict) else {}


def job_of(jobs: dict[str, Any]) -> dict[str, Any] | None:
    rows = jobs.get("jobs")
    return next(
        (
            row
            for row in (rows if isinstance(rows, list) else [])
            if isinstance(row, dict) and row.get("declarationKey") == JOB_KEY
        ),
        None,
    )


def changes(job: dict[str, Any], gateway: Gateway) -> list[str]:
    """The parts of the job that are not as apply adds them."""
    schedule = _section(job, "schedule")
    payload = _section(job, "payload")
    delivery = _section(job, "delivery")
    found = {
        "name": job.get("name"),
        "agent": job.get("agentId"),
        "schedule": (schedule.get("kind"), schedule.get("expr"), schedule.get("tz")),
        "session": job.get("sessionTarget"),
        "prompt": (payload.get("kind"), payload.get("message"), payload.get("model")),
        "delivery": (delivery.get("mode"), delivery.get("channel"), delivery.get("to")),
    }
    expected = shape(gateway)
    return [part for part, value in found.items() if value != expected[part]]


def describe(job: dict[str, Any] | None, gateway: Gateway) -> str:
    if job is None:
        return "missing"
    changed = changes(job, gateway)
    if changed:
        return "changed: " + ", ".join(changed)
    return "switched off" if job.get("enabled") is False else "ok"


def _jobs(gateway: Gateway, run: Runner) -> dict[str, Any]:
    completed = ask_gateway(gateway, run, "automations", "list", "--all", "--json")
    jobs = first_json_object(completed.stdout, "jobs") if completed.returncode == 0 else None
    if jobs is None:
        raise RuntimeError(f"{gateway.container} would not list its scheduled jobs")
    return jobs


def _scheduler(gateway: Gateway, run: Runner, arguments: list[str]) -> None:
    completed = run(
        gateway_cli(gateway, *arguments),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=GATEWAY_TIMEOUT_SECONDS,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()[-600:]
        raise RuntimeError(f"{gateway.container} refused the prep packets job: {detail}")


def check(gateways: Sequence[Gateway], run: Runner) -> int:
    healthy = True
    for gateway in gateways:
        try:
            said = describe(job_of(_jobs(gateway, run)), gateway)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            said = f"unreadable: {error}"
        print(f"{gateway.persona} ({gateway.container}): prep packets {said}")
        healthy = healthy and said == "ok"
    return 0 if healthy else 1


def apply(gateway: Gateway, *, run: Runner, dry_run: bool) -> int:
    try:
        job = job_of(_jobs(gateway, run))
        said = describe(job, gateway)
        if said in ("ok", "switched off"):
            print(
                f"{gateway.persona}: nothing to write"
                + (", prep packets switched off, left as it is" if said != "ok" else "")
            )
            return 0
        print(
            f"{gateway.persona}: prep packets {said}, apply writes it at {SCHEDULE} in the "
            "gateway's time zone, as a run of the main agent of its own that sends "
            f"{gateway.person} each packet in their own thread of the app"
        )
        if dry_run:
            print("dry run: nothing written.")
            return 0
        _scheduler(gateway, run, command(gateway))
        # OpenClaw 2026.9.4 brings a job it already has by the declaration key to the schedule,
        # prompt and delivery it is given, but keeps the job's name.
        job = job_of(_jobs(gateway, run))
        if job is not None and job.get("name") != JOB_NAME:
            _scheduler(gateway, run, ["cron", "edit", str(job.get("id")), "--name", JOB_NAME])
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"{gateway.persona}: not written: {error}", file=sys.stderr)
        return 1
    print(f"{gateway.persona}: the prep packets job written")
    return 0


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways' job")
    applier = commands.add_parser("apply", help="add or correct one gateway's job")
    applier.add_argument(
        "--gateway", required=True, choices=[gateway.persona for gateway in GATEWAYS]
    )
    applier.add_argument(
        "--dry-run", action="store_true", help="show what would change, write nothing"
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
