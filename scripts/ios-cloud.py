#!/usr/bin/env python3
"""Build Steward AI on GitHub's hosted Macs from any computer, and keep the spend certain.

  ios-cloud.py preview [--ref BRANCH]
      A simulator build, the unit and UI tests, every screen as a PNG and a short
      recording, on one of GitHub's Macs. Waits for it, downloads what it made to
      apps/ios/build/preview-<run>/, and says what it cost.
  ios-cloud.py testflight
      Builds main, signs it, uploads it to TestFlight and waits until the testers'
      phones can install it. Says what it cost.
  ios-cloud.py rehearse [--ref BRANCH]
      The TestFlight path with nothing signed and nothing sent: shows every later
      step would run.
  ios-cloud.py cost --run ID
      The Mac minutes a run used, what they cost, and today's total.
  ios-cloud.py budget --ceiling-minutes N
      Run by the workflows before any Mac starts: refuses a run that could take
      today past the daily cap.

The owner chose GitHub's hosted Macs on 14 October 2026, with a cap of 5 dollars
a day. Every Mac run is started by hand, stops at its job's timeout, and is
refused when today's Mac minutes plus that timeout could pass the cap. Needs the
GitHub CLI, signed in with access to this repository.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "fpresta0607/household-assistant")
ROOT = Path(__file__).resolve().parent.parent
# GitHub's price for a standard macOS runner minute, rounded up per job, from
# docs.github.com/en/billing/reference/actions-runner-pricing, read 2026-10-14.
# This repository gets no included minutes against it: September's Mac runs
# billed in full.
MAC_MINUTE_USD = 0.062
DAILY_CAP_USD = 5.00
# One-day headroom requested by the owner on 17 October 2026 at 20:37 Chicago
# time. Keep GitHub's UTC billing day, but end this exception at his midnight.
TEMPORARY_CAP_USD = 15.00
TEMPORARY_CAP_START = datetime(2026, 10, 18, 1, 37, 44, tzinfo=UTC)
TEMPORARY_CAP_END = datetime(2026, 10, 18, 5, 0, tzinfo=UTC)
# The longest Mac job timeout in any workflow here. A Mac job still running in
# another run counts at this, since it may yet run that long.
LONGEST_MAC_JOB_MINUTES = 45
FIND_RUN_ATTEMPTS = 12
FIND_RUN_INTERVAL_SECONDS = 5
POLL_INTERVAL_SECONDS = 20

Json = dict[str, Any]
Gh = Callable[[Sequence[str]], str]


class CloudError(Exception):
    """A plain-words failure that names what to do about it."""


def run_gh(arguments: Sequence[str]) -> str:
    completed = subprocess.run(
        ["gh", *arguments], capture_output=True, text=True, encoding="utf-8", check=False
    )
    if completed.returncode != 0:
        raise CloudError(f"gh {' '.join(arguments[:2])} failed: {completed.stderr.strip()}")
    return completed.stdout


def gh_pages(gh: Gh, path: str, *fields: str) -> list[Json]:
    """Every page of a GitHub API list, as gh's --slurp returns them."""
    arguments = ["api", "--paginate", "--slurp", "-X", "GET", path]
    for field in fields:
        arguments += ["-f", field]
    pages: list[Json] = json.loads(gh(arguments))
    return pages


# ------------------------------------------------------------------------- minutes


def is_mac(job: Json) -> bool:
    return any(str(label).lower().startswith("macos") for label in job.get("labels") or [])


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def billed_minutes(job: Json) -> int:
    """What GitHub bills for one finished job: its run time rounded up to the minute."""
    if not job.get("started_at") or not job.get("completed_at"):
        return 0
    seconds = (parse_time(job["completed_at"]) - parse_time(job["started_at"])).total_seconds()
    return math.ceil(seconds / 60) if seconds > 0 else 0


def mac_jobs(gh: Gh, run_id: int) -> list[Json]:
    pages = gh_pages(
        gh, f"repos/{REPOSITORY}/actions/runs/{run_id}/jobs", "filter=all", "per_page=100"
    )
    return [job for page in pages for job in page["jobs"] if is_mac(job)]


@dataclass(frozen=True)
class Day:
    billed_minutes: int
    running_jobs: int

    @property
    def committed_minutes(self) -> int:
        return self.billed_minutes + self.running_jobs * LONGEST_MAC_JOB_MINUTES


def today(gh: Gh, now: datetime, leave_out: int | None) -> Day:
    """Mac minutes this repository used today (UTC), as GitHub bills them, and Mac jobs going.

    GitHub bills a job to the day it finished: on 15 October 2026 it billed a preview
    created at 23:54Z the day before to the 15th. So runs created since yesterday are
    read, and each finished job counts on its own finishing day. Only runs started by
    hand can hold a Mac job, and reading every run's jobs spent the workflow token's
    hourly API calls on a day of 440 runs, so only those are read.
    """
    pages = gh_pages(
        gh,
        f"repos/{REPOSITORY}/actions/runs",
        f"created=>={now - timedelta(days=1):%Y-%m-%d}",
        "event=workflow_dispatch",
        "per_page=100",
    )
    billed = 0
    running = 0
    for page in pages:
        for run in page["workflow_runs"]:
            if run["id"] == leave_out:
                continue
            for job in mac_jobs(gh, run["id"]):
                if job["status"] != "completed":
                    running += 1
                elif (
                    job.get("completed_at") and parse_time(job["completed_at"]).date() == now.date()
                ):
                    billed += billed_minutes(job)
    return Day(billed, running)


def dollars(minutes: int) -> str:
    return f"${minutes * MAC_MINUTE_USD:.2f}"


def daily_cap(now: datetime) -> float:
    """The owner's temporary cap expires without a later edit or scheduled job."""
    if TEMPORARY_CAP_START <= now < TEMPORARY_CAP_END:
        return TEMPORARY_CAP_USD
    return DAILY_CAP_USD


def budget(gh: Gh, now: datetime, ceiling_minutes: int, cap: float, this_run: int | None) -> str:
    day = today(gh, now, this_run)
    worst = (day.committed_minutes + ceiling_minutes) * MAC_MINUTE_USD
    so_far = (
        f"Today so far: {day.billed_minutes} Mac minutes, {dollars(day.billed_minutes)}"
        + (f", and {day.running_jobs} Mac job(s) still running" if day.running_jobs else "")
        + f". This run can take at most {ceiling_minutes} minutes, {dollars(ceiling_minutes)}."
    )
    if worst > cap + 1e-9:
        raise CloudError(
            f"{so_far} Together that could pass the ${cap:.2f} daily cap, so this Mac run is "
            "refused. It can run after midnight UTC."
        )
    return f"{so_far} At most ${worst:.2f} of the ${cap:.2f} daily cap. Going ahead."


def fit(
    gh: Gh, now: datetime, ceiling_minutes: int, minimum_minutes: int, cap: float,
    this_run: int | None,
) -> tuple[str, int]:  # fmt: skip
    """The minutes a run may take so the day's real cost stays under the cap.

    The owner allowed this for the TestFlight uploads he asks for on 15 October
    2026: such a run may pass the worst-case check, and its timeout is cut to what
    is left of the day instead. One minute is held back, because GitHub rounds a
    job's time up and the cleanup after a timeout still runs.
    """
    day = today(gh, now, this_run)
    left = math.floor((cap - day.committed_minutes * MAC_MINUTE_USD) / MAC_MINUTE_USD + 1e-9) - 1
    minutes = min(ceiling_minutes, left)
    so_far = (
        f"Today so far: {day.billed_minutes} Mac minutes, {dollars(day.billed_minutes)}"
        + (f", and {day.running_jobs} Mac job(s) still running" if day.running_jobs else "")
        + "."
    )
    if minutes < minimum_minutes:
        raise CloudError(
            f"{so_far} Only {max(minutes, 0)} Mac minutes are left under the ${cap:.2f} daily "
            f"cap, fewer than the {minimum_minutes} this run needs, so it is refused. "
            "It can run after midnight UTC."
        )
    return (
        f"{so_far} This run may take {minutes} minutes, {dollars(minutes)}, which keeps the "
        f"day under the ${cap:.2f} cap. Going ahead.",
        minutes,
    )


def billed_today(gh: Gh, now: datetime) -> str:
    owner = REPOSITORY.split("/")[0]
    try:
        summary = json.loads(
            gh(
                [
                    "api",
                    f"users/{owner}/settings/billing/usage/summary?year={now.year}"
                    f"&month={now.month}&day={now.day}&repository={REPOSITORY}&sku=actions_macos",
                ]
            )
        )
    except CloudError:
        return "GitHub's bill for today is not readable with this sign-in. It needs the user scope."
    items = summary.get("usageItems") or []
    minutes = sum(float(item.get("grossQuantity", 0)) for item in items)
    paid = sum(float(item.get("netAmount", 0)) for item in items)
    return f"GitHub's bill for today so far: {minutes:.0f} Mac minutes, ${paid:.2f} (it lags)."


def step_seconds(step: Json) -> int:
    if not step.get("started_at") or not step.get("completed_at"):
        return 0
    elapsed = parse_time(step["completed_at"]) - parse_time(step["started_at"])
    return round(elapsed.total_seconds())


def cost(gh: Gh, run_id: int, now: datetime) -> list[str]:
    """Each Mac job's billed minutes with the seconds of every step that ran, then the day."""
    jobs = mac_jobs(gh, run_id)
    lines = []
    for job in jobs:
        lines.append(f"{job['name']}: {billed_minutes(job)} Mac minutes")
        lines += [
            f"  {step['name']}: {step_seconds(step)} s"
            for step in job.get("steps") or []
            if step.get("conclusion") != "skipped"
        ]
    total = sum(billed_minutes(job) for job in jobs)
    day = today(gh, now, None)
    lines.append(f"This run: {total} Mac minutes, {dollars(total)} at ${MAC_MINUTE_USD}/minute.")
    lines.append(
        f"Today on this repository: {day.billed_minutes} Mac minutes, "
        f"{dollars(day.billed_minutes)} of the ${daily_cap(now):.2f} daily cap."
    )
    return lines


# ---------------------------------------------------------------------------- runs


def current_branch() -> str:
    branch = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True,
        text=True,
        cwd=ROOT,
        check=True,
    ).stdout.strip()
    if branch == "HEAD":
        raise CloudError("this checkout is on no branch. Name one with --ref.")
    return branch


def start(
    gh: Gh, workflow: str, ref: str, fields: Sequence[str], sleep: Callable[[float], None]
) -> Json:
    """Dispatch a workflow and find the run it made."""
    started = datetime.now(UTC) - timedelta(seconds=30)
    arguments = ["workflow", "run", workflow, "--ref", ref]
    for field in fields:
        arguments += ["-f", field]
    gh(arguments)
    for _ in range(FIND_RUN_ATTEMPTS):
        sleep(FIND_RUN_INTERVAL_SECONDS)
        runs: list[Json] = json.loads(
            gh(
                [
                    "run", "list", "--workflow", workflow, "--branch", ref,
                    "--event", "workflow_dispatch", "--limit", "5",
                    "--json", "databaseId,createdAt,url",
                ]
            )
        )  # fmt: skip
        for run in runs:
            if parse_time(run["createdAt"]) >= started:
                return run
    raise CloudError(f"GitHub accepted the start but no {workflow} run appeared for {ref}.")


def wait(gh: Gh, run_id: int, limit: timedelta, sleep: Callable[[float], None]) -> str:
    """Poll the run until it ends or the limit passes; print each job as it changes."""
    deadline = time.monotonic() + limit.total_seconds()
    seen: dict[str, str] = {}
    while True:
        view: Json = json.loads(
            gh(["run", "view", str(run_id), "--json", "status,conclusion,jobs"])
        )
        for job in view.get("jobs") or []:
            state = job.get("conclusion") or job.get("status") or ""
            if seen.get(job["name"]) != state:
                seen[job["name"]] = state
                print(f"  {job['name']}: {state}", flush=True)
        if view["status"] == "completed":
            return str(view["conclusion"])
        if time.monotonic() >= deadline:
            raise CloudError(
                f"run {run_id} had not ended after {limit}. It keeps going on GitHub "
                "and its timeout still bounds it."
            )
        sleep(POLL_INTERVAL_SECONDS)


def report(gh: Gh, run_id: int) -> None:
    now = datetime.now(UTC)
    for line in cost(gh, run_id, now):
        print(line)
    print(billed_today(gh, now))


def approved(gh: Gh, now: datetime, ceiling_minutes: int, this_run: int | None) -> str:
    """A run the owner approved past the cap: it is reported, never refused."""
    day = today(gh, now, this_run)
    return (
        f"Today so far: {day.billed_minutes} Mac minutes, {dollars(day.billed_minutes)}. "
        f"The owner approved this run's spend past the daily cap, so it may take its full "
        f"{ceiling_minutes} minutes, {dollars(ceiling_minutes)}. Going ahead."
    )


def approval(is_approved: bool) -> list[str]:
    return ["owner_approved_spend=true"] if is_approved else []


def preview(
    gh: Gh,
    ref: str,
    sleep: Callable[[float], None],
    is_approved: bool = False,
    lane: str = "fix",
    ui_tests: str = "",
    screenshots: str = "",
) -> int:
    fields = [*approval(is_approved), f"lane={lane}"]
    if ui_tests:
        fields.append(f"ui_tests={ui_tests}")
    if screenshots:
        fields.append(f"screenshots={screenshots}")
    run = start(gh, "ios-ci.yml", ref, fields, sleep)
    run_id = int(run["databaseId"])
    print(f"Preview of {ref} started: {run['url']}", flush=True)
    conclusion = wait(gh, run_id, timedelta(minutes=60), sleep)
    print(f"Preview {conclusion}.")
    folder = ROOT / "apps" / "ios" / "build" / f"preview-{run_id}"
    names = ["--name", "ios-screenshots", "--name", "ios-motion-demo", "--name", "ios-preview"]
    try:
        gh(["run", "download", str(run_id), *names, "--dir", str(folder)])
        pictures = sorted(folder.rglob("*.png"))
        films = sorted(folder.rglob("*.mp4"))
        print(
            f"Downloaded to {folder}: {len(pictures)} screenshots, "
            f"{len(films)} demo films and the log."
        )
    except CloudError as error:
        print(f"Nothing to download: {error}")
    report(gh, run_id)
    return 0 if conclusion == "success" else 1


def release(
    gh: Gh, ref: str, confirm: str, sleep: Callable[[float], None], is_approved: bool = False
) -> int:
    run = start(gh, "ios-release.yml", ref, [f"confirm={confirm}", *approval(is_approved)], sleep)
    run_id = int(run["databaseId"])
    what = "TestFlight build of main" if confirm == "UPLOAD" else f"Rehearsal of {ref}"
    print(f"{what} started: {run['url']}", flush=True)
    conclusion = wait(gh, run_id, timedelta(minutes=100), sleep)
    print(f"{what} {conclusion}.")
    report(gh, run_id)
    return 0 if conclusion == "success" else 1


def main(argv: Sequence[str] | None = None, *, gh: Gh = run_gh,
         sleep: Callable[[float], None] = time.sleep,
         clock: Callable[[], datetime] = lambda: datetime.now(UTC)) -> int:  # fmt: skip
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    owner_word = "only on the owner's word: this run may pass the daily cap"
    for_preview = commands.add_parser("preview")
    for_rehearsal = commands.add_parser("rehearse")
    for command in (for_preview, for_rehearsal):
        command.add_argument("--ref", help="the branch to build, by default this checkout's")
    for_upload = commands.add_parser("testflight")
    for command in (for_preview, for_upload):
        command.add_argument("--owner-approved-spend", action="store_true", help=owner_word)
    for_preview.add_argument(
        "--lane",
        choices=("fix", "full"),
        default="fix",
        help="fix: the build, the unit tests and the UI tests --ui-tests names. "
        "full: also every UI test and both films, for the commit going to TestFlight",
    )
    for_preview.add_argument(
        "--ui-tests",
        default="",
        help="UI tests by class or class/test inside HouseholdAssistantUITests, "
        "separated by spaces. In the full lane, every UI test runs",
    )
    for_preview.add_argument(
        "--screenshots",
        default="",
        help="the screenshot states a change touches, by id or the start of one, "
        "separated by spaces, or all for every screen. None renders no screenshot",
    )
    for_cost = commands.add_parser("cost")
    for_cost.add_argument("--run", type=int, required=True)
    for_budget = commands.add_parser("budget")
    for_budget.add_argument("--ceiling-minutes", type=int, required=True)
    for_budget.add_argument("--cap", type=float, default=None)
    for_budget.add_argument(
        "--fit-minimum",
        type=int,
        help="instead of refusing on the worst case, cut the run to what is left of the day, "
        "and refuse only when fewer than these minutes are left",
    )
    for_budget.add_argument("--approved", action="store_true", help=owner_word)
    arguments = parser.parse_args(argv)

    try:
        if arguments.command == "preview":
            return preview(
                gh,
                arguments.ref or current_branch(),
                sleep,
                arguments.owner_approved_spend,
                arguments.lane,
                arguments.ui_tests,
                arguments.screenshots,
            )
        if arguments.command == "rehearse":
            return release(gh, arguments.ref or current_branch(), "", sleep)
        if arguments.command == "testflight":
            return release(gh, "main", "UPLOAD", sleep, arguments.owner_approved_spend)
        if arguments.command == "cost":
            lines = cost(gh, arguments.run, clock())
        else:
            this_run = int(os.environ["GITHUB_RUN_ID"]) if "GITHUB_RUN_ID" in os.environ else None
            now = clock()
            cap = daily_cap(now) if arguments.cap is None else arguments.cap
            if arguments.approved:
                said = approved(gh, now, arguments.ceiling_minutes, this_run)
                minutes = arguments.ceiling_minutes
            elif arguments.fit_minimum is None:
                said = budget(gh, now, arguments.ceiling_minutes, cap, this_run)
                minutes = arguments.ceiling_minutes
            else:
                said, minutes = fit(
                    gh, now, arguments.ceiling_minutes, arguments.fit_minimum, cap,
                    this_run,
                )  # fmt: skip
            lines = [said]
            if not arguments.approved and arguments.cap is None and cap != DAILY_CAP_USD:
                lines.insert(
                    0,
                    "Owner-requested temporary $15.00 cap until 18 October 2026 05:00 UTC "
                    "(midnight Chicago). The normal $5.00 cap returns automatically.",
                )
            output = os.environ.get("GITHUB_OUTPUT")
            if output:
                with open(output, "a", encoding="utf-8") as handle:
                    handle.write(f"minutes={minutes}\n")
    except CloudError as error:
        print(f"error  {error}", file=sys.stderr)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as handle:
                handle.write(f"{error}\n")
        return 1
    for line in lines:
        print(line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("\n\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
