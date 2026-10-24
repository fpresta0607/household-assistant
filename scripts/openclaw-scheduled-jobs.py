#!/usr/bin/env python3
"""Each gateway's own scheduled jobs for its person: prep packets and the Sunday digest.

Each gateway gets these jobs of its own, the way apply gives it the Today card's, each with a
declaration key so adding it again brings the one job to this shape rather than add a second:

- Prep packets. A reminder says "dentist at 3:30". What helps is one message two days out
  with the address, the drive time from where the person will be, what to bring, any form
  to fill and the confirmation number. Once a day the run reads the family's shared calendar
  and its person's own, finds the events that start between 36 and 60 hours from then, and
  sends its person one packet for each in their own thread of the Steward app. Those windows
  meet end to end, so every event is in exactly one day's run, about 48 hours before it.
  Nothing is written to the household note: an appointment can be one person's own.
- The Sunday digest. Sunday evening the run reads the coming week's calendar and calls
  household_digest with the week's events and the decisions it needs; the plugin draws the
  events as the week at a glance (an agenda card) and adds what is
  slipping, the litter's weight trend, the cart and the open promises from the household
  note and posts the whole digest in its person's own thread (digest.js), so the run delivers
  nothing itself.

What each does and how it was rolled out are in docs/deploy/openclaw.md under "Prep packets"
and "The Sunday digest".
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass
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

SHARED_CALENDAR = load_household().shared_calendar
OTHERS = "Use another person's plans only from what they told you or said in the family room. "


@dataclass(frozen=True, slots=True)
class Job:
    key: str
    name: str
    # On the gateway's own clock, the household's.
    schedule: str
    prompt: str
    # Whether the run's last words go to its person's own thread, or the job's tool posts.
    is_announced: bool


PREP_PACKETS = Job(
    key="household-app:prep-packets",
    name="Prep packets",
    # 8:00: a packet for an event between 8 PM tomorrow and 8 PM the day after, read over
    # breakfast.
    schedule="0 8 * * *",
    prompt=(
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
        "each of those that you found, and say plainly what you could not find. "
        f"{OTHERS}Send nothing to anyone else, book or change nothing. When nothing is coming "
        "in that window, reply NO_REPLY."
    ),
    is_announced=True,
)
SUNDAY_DIGEST = Job(
    key="household-app:sunday-digest",
    name="Sunday digest",
    # Sunday, 7 PM: after the weekend, before the week.
    schedule="0 19 * * 0",
    prompt=(
        f'It is Sunday evening. Read the family\'s shared calendar, "{SHARED_CALENDAR}" in '
        "iCloud, and your person's own calendars for the coming week, Monday to Sunday. Then call "
        "household_digest once: events, the week's main events your person goes to, at most "
        "twelve, each with its title and its start as the calendar gives it, with its offset, or "
        "its day when it is all day (only when you cannot, week instead, at most four short "
        "lines, each with its day and time); and decide, the two or three things that "
        "need your person's decision this week, such as a clash, something to book or a reply "
        f"owed, each one short line, or none. {OTHERS}Send nothing to any chat or person and "
        "change nothing. Once it is posted, reply NO_REPLY."
    ),
    is_announced=False,
)
JOBS = (PREP_PACKETS, SUNDAY_DIGEST)


def command(job: Job, gateway: Gateway) -> list[str]:
    delivery = (
        ["--announce", "--channel", "household", "--to", f"household:{gateway.person}"]
        if job.is_announced
        else ["--no-deliver"]
    )
    return [
        "automations",
        "add",
        "--declaration-key",
        job.key,
        "--name",
        job.name,
        "--cron",
        job.schedule,
        "--agent",
        "main",
        "--session",
        "isolated",
        "--message",
        job.prompt,
        *delivery,
        "--json",
    ]


def shape(job: Job, gateway: Gateway) -> dict[str, object]:
    """What `automations list --json` shows of the job when it is as apply adds it."""
    return {
        "name": job.name,
        "agent": "main",
        "schedule": ("cron", job.schedule, None),
        "session": "isolated",
        "prompt": ("agentTurn", job.prompt, None),
        "delivery": (
            ("announce", "household", f"household:{gateway.person}")
            if job.is_announced
            else ("none", None, None)
        ),
    }


def _section(value: dict[str, Any], key: str) -> dict[str, Any]:
    found = value.get(key)
    return found if isinstance(found, dict) else {}


def job_of(jobs: dict[str, Any], job: Job) -> dict[str, Any] | None:
    rows = jobs.get("jobs")
    return next(
        (
            row
            for row in (rows if isinstance(rows, list) else [])
            if isinstance(row, dict) and row.get("declarationKey") == job.key
        ),
        None,
    )


def changes(found_job: dict[str, Any], job: Job, gateway: Gateway) -> list[str]:
    """The parts of the job that are not as apply adds them."""
    schedule = _section(found_job, "schedule")
    payload = _section(found_job, "payload")
    delivery = _section(found_job, "delivery")
    # OpenClaw 2026.9.4 stores "last" as the channel of a job added with no channel at all,
    # and a job that delivers to nobody reaches no chat through it, so that is no change.
    channel = None if delivery.get("channel") == "last" else delivery.get("channel")
    found = {
        "name": found_job.get("name"),
        "agent": found_job.get("agentId"),
        "schedule": (schedule.get("kind"), schedule.get("expr"), schedule.get("tz")),
        "session": found_job.get("sessionTarget"),
        "prompt": (payload.get("kind"), payload.get("message"), payload.get("model")),
        "delivery": (delivery.get("mode"), channel, delivery.get("to")),
    }
    expected = shape(job, gateway)
    return [part for part, value in found.items() if value != expected[part]]


def describe(found_job: dict[str, Any] | None, job: Job, gateway: Gateway) -> str:
    if found_job is None:
        return "missing"
    changed = changes(found_job, job, gateway)
    if changed:
        return "changed: " + ", ".join(changed)
    return "switched off" if found_job.get("enabled") is False else "ok"


def _jobs(gateway: Gateway, run: Runner) -> dict[str, Any]:
    completed = ask_gateway(gateway, run, "automations", "list", "--all", "--json")
    jobs = first_json_object(completed.stdout, "jobs") if completed.returncode == 0 else None
    if jobs is None:
        raise RuntimeError(f"{gateway.container} would not list its scheduled jobs")
    return jobs


def _scheduler(gateway: Gateway, run: Runner, arguments: list[str], job: Job) -> None:
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
        raise RuntimeError(f"{gateway.container} refused the {job.name} job: {detail}")


def check(gateways: Sequence[Gateway], run: Runner) -> int:
    healthy = True
    for gateway in gateways:
        try:
            jobs = _jobs(gateway, run)
            said = {job.name: describe(job_of(jobs, job), job, gateway) for job in JOBS}
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            said = {job.name: f"unreadable: {error}" for job in JOBS}
        for name, state in said.items():
            print(f"{gateway.persona} ({gateway.container}): {name} {state}")
            healthy = healthy and state == "ok"
    return 0 if healthy else 1


def apply(gateway: Gateway, *, run: Runner, dry_run: bool) -> int:
    if not SHARED_CALENDAR:
        print(
            f"{gateway.persona}: refused, nothing written: the household file names no shared "
            "calendar (sharedCalendar), which every one of these jobs reads",
            file=sys.stderr,
        )
        return 1
    try:
        jobs = _jobs(gateway, run)
        written = 0
        for job in JOBS:
            said = describe(job_of(jobs, job), job, gateway)
            if said == "ok":
                continue
            if said == "switched off":
                print(f"{gateway.persona}: {job.name} switched off, left as it is")
                continue
            print(
                f"{gateway.persona}: {job.name} {said}, apply writes it at {job.schedule} in the "
                "gateway's time zone, as a run of the main agent of its own"
            )
            if dry_run:
                continue
            _scheduler(gateway, run, command(job, gateway), job)
            # OpenClaw 2026.9.4 brings a job it already has by the declaration key to the
            # schedule, prompt and delivery it is given, but keeps the job's name.
            found = job_of(_jobs(gateway, run), job)
            if found is not None and found.get("name") != job.name:
                _scheduler(
                    gateway, run, ["cron", "edit", str(found.get("id")), "--name", job.name], job
                )
            print(f"{gateway.persona}: the {job.name} job written")
            written += 1
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"{gateway.persona}: not written: {error}", file=sys.stderr)
        return 1
    if dry_run:
        print("dry run: nothing written.")
    elif written == 0:
        print(f"{gateway.persona}: nothing to write")
    return 0


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways' jobs")
    applier = commands.add_parser("apply", help="add or correct one gateway's jobs")
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
