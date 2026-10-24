#!/usr/bin/env python3
"""The household's OpenRouter spend this month, for the Spend page in the Steward app.

Both gateways share one OpenRouter key with whatever else holds it (SIQsermon's backend
did until it was retired), so neither gateway can tell on its own what each assistant
spent of it. This runs on the host every ten minutes on the clock (household-spend.timer)
and asks each gateway two things through its own CLI:

- the household-app plugin's figures (``household-app.spend.figures``): the key's usage as
  OpenRouter reports it, this assistant's name, and what its voice and its pictures and
  videos cost this month;
- OpenClaw's own ledger of what this assistant's answers cost this month, in the
  gateway's own days (``usage.cost`` with ``mode: gateway``).

It keeps every reading of the key's lifetime usage in a ledger only root reads, with
OpenRouter's own figures for the start of the UTC day, week and month, and from them adds
up one month in the gateways' time zone, the household's:

- The total is the key's usage since the month began: since the reading nearest midnight
  on the 1st, within one tick of it, or before the ledger has one, since OpenRouter's own
  start of its UTC month, which in the household's time zone is the evening before.
- Each day's point is the total by the end of that day, straight between readings where
  the ledger has none at that hour, as it has none before its first month.
- Each assistant's line is its answers, voice, pictures and videos, and Other is the rest
  of the total, so the lines always add up to it to the cent.

OpenClaw throws its ledger away and adds it up again after any change to a model's
price in its config, and answers from what it has added up so far meanwhile. So an
answer from a ledger with nothing added up yet is not taken, and a month's answers never
go down: the larger of the last one taken and the new one is kept.

The same month goes to both gateways through spend-in.mjs, which writes it as the
gateway's own user. Nothing here prints the key or anything anybody said.
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from itertools import pairwise
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from gateway_config import GATEWAYS, Gateway, Runner, ask_gateway, first_json_object

STATE_FILE = Path("/var/lib/household-assistant/coordination/household-spend.json")
SPEND_IN = "/opt/household-plugins/household-app/spend-in.mjs"
FIGURES_METHOD = "household-app.spend.figures"
OTHER_ID = "other"
OTHER_NAME = "Other use of the key"
# The timer's interval. A reading this close to midnight on the 1st starts the month.
TICK_MS = 10 * 60_000
# Readings on both sides of midnight on the 1st no further apart than this, as when the
# box was down across it, start the month straight between them.
GAP_MS = 24 * 3_600_000
# A reading older than this is no use to this month or the last.
KEPT_MS = 70 * 24 * 3_600_000
# One delivery is one `docker exec` of a small node script; a minute is a wedged one.
DELIVERY_TIMEOUT_SECONDS = 60


class ReadError(Exception):
    """A gateway that could not be read this tick, in words without any secret."""


@dataclass(frozen=True, slots=True)
class Reading:
    """What one gateway said this tick."""

    persona: str
    at: int
    month: str
    time_zone: str
    name: str
    key: dict[str, Any]
    voice: float
    media: float
    # None when OpenClaw had nothing of its ledger added up yet.
    answers: float | None


@dataclass
class TickResult:
    report: dict[str, Any] | None = None
    delivered: int = 0
    problems: list[str] = field(default_factory=list)


def cents(dollars: float) -> int:
    """Dollars to whole cents, a half cent rounding up, as the plugin's Math.round does."""
    return math.floor(dollars * 100 + 0.5)


def ms(moment: datetime) -> int:
    return int(moment.timestamp() * 1000)


def ask(
    gateway: Gateway, run: Runner, method: str, key: str, params: dict[str, Any]
) -> dict[str, Any]:
    arguments = ["gateway", "call", method, "--json"]
    if params:
        arguments += ["--params", json.dumps(params)]
    try:
        completed = ask_gateway(gateway, run, *arguments)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReadError(
            f"{gateway.persona}'s {method} did not answer: {type(error).__name__}"
        ) from error
    answer = first_json_object(completed.stdout, key)
    if completed.returncode != 0 or answer is None:
        detail = (completed.stderr or completed.stdout).strip().splitlines()[-1:] or ["no detail"]
        raise ReadError(f"{gateway.persona}'s {method} failed: {detail[0][:200]}")
    return answer


def _dollars(value: object, what: str) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float) or not math.isfinite(value):
        raise ReadError(f"the figures have no {what}")
    return float(value)


def read_gateway(gateway: Gateway, run: Runner) -> Reading:
    figures = ask(gateway, run, FIGURES_METHOD, "key", {})
    at = figures.get("at")
    month = figures.get("month")
    time_zone = figures.get("timeZone")
    name = figures.get("assistant")
    key = figures.get("key")
    if not isinstance(at, int) or not isinstance(month, str) or not isinstance(time_zone, str):
        raise ReadError(f"{gateway.persona}'s figures have no time, month or time zone")
    if (
        not isinstance(name, str)
        or not name.strip()
        or not isinstance(key, dict)
        or not isinstance(key.get("id"), str)
    ):
        raise ReadError(f"{gateway.persona}'s figures have no assistant or key")
    usage = {
        part: _dollars(key.get(part), f"key {part}")
        for part in ("usage", "daily", "weekly", "monthly")
    }
    try:
        today = datetime.fromtimestamp(at / 1000, ZoneInfo(time_zone)).date()
    except (ZoneInfoNotFoundError, ValueError) as error:
        raise ReadError(f"{gateway.persona}'s time zone is not one: {time_zone[:60]}") from error
    cost = ask(
        gateway,
        run,
        "usage.cost",
        "totals",
        {"mode": "gateway", "startDate": f"{month}-01", "endDate": today.isoformat()},
    )
    return Reading(
        persona=gateway.persona,
        at=at,
        month=month,
        time_zone=time_zone,
        name=name.strip(),
        key={"id": key["id"], **usage},
        voice=_dollars(figures.get("voice"), "voice"),
        media=_dollars(figures.get("media"), "pictures and videos"),
        answers=answers_of(cost),
    )


def answers_of(cost: dict[str, Any]) -> float | None:
    """What usage.cost says the answers cost, or None when its ledger has nothing added up."""
    totals = cost.get("totals")
    total = totals.get("totalCost") if isinstance(totals, dict) else None
    if isinstance(total, bool) or not isinstance(total, int | float) or not math.isfinite(total):
        raise ReadError("usage.cost gave no total")
    status = cost.get("cacheStatus")
    if (
        isinstance(status, dict)
        and status.get("status") != "fresh"
        and status.get("cachedFiles") == 0
    ):
        return None
    return float(total)


def anchors(reading: Reading) -> list[tuple[int, float]]:
    """The key's lifetime usage at this reading, and at the starts OpenRouter counts from."""
    usage = reading.key["usage"]
    moment = datetime.fromtimestamp(reading.at / 1000, UTC)
    day = moment.replace(hour=0, minute=0, second=0, microsecond=0)
    week = day - timedelta(days=day.weekday())
    month = day.replace(day=1)
    return [
        (reading.at, usage),
        (ms(day), usage - reading.key["daily"]),
        (ms(week), usage - reading.key["weekly"]),
        (ms(month), usage - reading.key["monthly"]),
    ]


def record(state: dict[str, Any], readings: list[Reading]) -> None:
    """Keeps the readings' points and each assistant's newest figures for its month."""
    points = {int(at): float(usage) for at, usage in state.get("points", [])}
    for reading in readings:
        for at, usage in anchors(reading):
            # The same start read again keeps the value it was first read with.
            points.setdefault(at, usage)
    newest = max(points)
    state["points"] = sorted([at, usage] for at, usage in points.items() if at >= newest - KEPT_MS)
    assistants = state.setdefault("assistants", {})
    for reading in readings:
        kept = assistants.get(reading.persona)
        same_month = isinstance(kept, dict) and kept.get("month") == reading.month
        answers = kept.get("answers") if same_month else None
        if reading.answers is not None:
            answers = reading.answers if answers is None else max(answers, reading.answers)
        assistants[reading.persona] = {
            "month": reading.month,
            "name": reading.name,
            "answers": answers,
            "voice": reading.voice,
            "media": reading.media,
        }


def usage_at(points: list[tuple[int, float]], at: int) -> float:
    """The key's usage at `at`, straight between the two readings around it."""
    if at <= points[0][0]:
        return points[0][1]
    for (before_at, before), (after_at, after) in pairwise(points):
        if before_at <= at <= after_at:
            return before + (after - before) * (at - before_at) / (after_at - before_at)
    return points[-1][1]


def month_start_usage(points: list[tuple[int, float]], start: int) -> float:
    """The usage the month counts from: the reading nearest its start within one tick of
    it, or straight between the readings around it when they are less than a day apart,
    or else the last one before it, OpenRouter's own start of its UTC month at the least."""
    near = [point for point in points if abs(point[0] - start) <= TICK_MS]
    if near:
        return min(near, key=lambda point: abs(point[0] - start))[1]
    before = [point for point in points if point[0] <= start]
    after = [point for point in points if point[0] > start]
    if before and after and after[0][0] - before[-1][0] <= GAP_MS:
        return usage_at(points, start)
    return before[-1][1] if before else points[0][1]


def month_report(state: dict[str, Any], order: list[str], zone: ZoneInfo) -> dict[str, Any]:
    """The month of the newest reading, for the page, or a ReadError saying what it lacks."""
    points = [(int(at), float(usage)) for at, usage in state["points"]]
    newest_at, newest = points[-1]
    now = datetime.fromtimestamp(newest_at / 1000, zone)
    first = datetime(now.year, now.month, 1, tzinfo=zone)
    next_first = datetime(now.year + now.month // 12, now.month % 12 + 1, 1, tzinfo=zone)
    month = f"{now.year:04d}-{now.month:02d}"
    lines = []
    for persona in order:
        kept = state.get("assistants", {}).get(persona)
        if not isinstance(kept, dict) or kept.get("month") != month or kept.get("answers") is None:
            raise ReadError(f"{persona}'s answers for {month} are not added up yet")
        amount = cents(kept["answers"] + kept["voice"] + kept["media"])
        lines.append({"id": persona, "name": kept["name"], "amount": amount})
    start = month_start_usage(points, ms(first))
    total = cents(newest - start)
    days = []
    spent = 0
    for number in range(1, now.day + 1):
        end = min(
            ms(datetime(now.year, now.month, number, tzinfo=zone) + timedelta(days=1)), newest_at
        )
        # Never down from one day to the next, nor over the month's total, whatever a
        # reading's rounding did.
        spent = min(max(spent, cents(usage_at(points, end) - start)), total)
        days.append({"day": f"{month}-{number:02d}", "spent": spent / 100})
    days[-1]["spent"] = total / 100
    lines.append(
        {
            "id": OTHER_ID,
            "name": OTHER_NAME,
            "amount": total - sum(line["amount"] for line in lines),
        }
    )
    return {
        "month": month,
        "at": newest_at,
        "total": total / 100,
        "days": days,
        "lines": [{**line, "amount": line["amount"] / 100} for line in lines],
        "resetsOn": next_first.date().isoformat(),
    }


def deliver(gateway: Gateway, report: dict[str, Any], run: Runner) -> str | None:
    """None once spend-in.mjs has written the month in the gateway, else what went wrong."""
    command = ["docker", "exec", "-i", "-u", "node", gateway.container, "node", SPEND_IN]
    try:
        completed = run(
            command,
            input=json.dumps(report),
            capture_output=True,
            text=True,
            timeout=DELIVERY_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"delivery to {gateway.persona} did not finish: {type(error).__name__}"
    if completed.returncode != 0:
        detail = (completed.stderr or "").strip().splitlines()[-1:] or ["no detail"]
        return f"delivery to {gateway.persona} failed: {detail[0][:200]}"
    return None


def tick(gateways: tuple[Gateway, ...], state_path: Path, run: Runner) -> TickResult:
    result = TickResult()
    readings: list[Reading] = []
    for gateway in gateways:
        try:
            readings.append(read_gateway(gateway, run))
        except ReadError as error:
            result.problems.append(str(error))
    if not readings:
        return result
    keys = {reading.key["id"] for reading in readings}
    zones = {reading.time_zone for reading in readings}
    if len(keys) > 1 or len(zones) > 1:
        result.problems.append(
            "the gateways use different keys or time zones, so no one month adds them up"
        )
        return result
    state = load_state(state_path)
    if state.get("key") != readings[0].key["id"]:
        # A new key's usage starts from nothing of the old one's.
        state = {"key": readings[0].key["id"]}
    record(state, readings)
    save_state(state_path, state)
    try:
        result.report = month_report(
            state, [gateway.persona for gateway in gateways], ZoneInfo(readings[0].time_zone)
        )
    except ReadError as error:
        result.problems.append(str(error))
        return result
    for gateway in gateways:
        problem = deliver(gateway, result.report, run)
        if problem is None:
            result.delivered += 1
        else:
            result.problems.append(problem)
    return result


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


def summary(report: dict[str, Any]) -> str:
    month = date.fromisoformat(f"{report['month']}-01").strftime("%B")
    lines = " + ".join(f"{line['name']} {line['amount']:.2f}" for line in report["lines"])
    return f"household-spend: {month} {report['total']:.2f} = {lines}"


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] != "tick":
        print("usage: household-spend.py tick", file=sys.stderr)
        return 2
    result = tick(GATEWAYS, STATE_FILE, subprocess.run)
    for problem in result.problems:
        print(f"household-spend: {problem}", file=sys.stderr)
    if result.report is not None:
        print(summary(result.report))
    return 1 if result.problems else 0


if __name__ == "__main__":
    sys.exit(main())
