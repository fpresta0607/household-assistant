"""household-spend.py: the household's OpenRouter month for the Spend page.

The job asks each gateway for the household-app plugin's figures and OpenClaw's own
`usage.cost`, keeps the key's readings in a ledger, and hands both gateways one month
through spend-in.mjs. These tests replace `docker exec` with a box whose two gateways
share one made-up OpenRouter key, whose usage is the charges a test puts on it.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import ModuleType
from typing import Any, Protocol
from zoneinfo import ZoneInfo

import pytest

from tests.capabilities import needs_nofollow_open

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "household-spend.py"
CENTRAL = ZoneInfo("America/Chicago")
CONTAINERS = {"openclaw-gateway": "corey", "openclaw-denise": "denise"}


def load(path: Path, name: str) -> ModuleType:
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def spend() -> ModuleType:
    return load(SCRIPT, "household_spend")


def central(
    year: int, month: int, day: int, hour: int = 0, minute: int = 0, second: int = 0
) -> datetime:
    return datetime(year, month, day, hour, minute, second, tzinfo=CENTRAL)


def ms(moment: datetime) -> int:
    return int(moment.timestamp() * 1000)


@dataclass
class Assistant:
    name: str
    answers: float = 0.0
    voice: float = 0.0
    media: float = 0.0
    cache: dict[str, Any] = field(
        default_factory=lambda: {"status": "refreshing", "cachedFiles": 120, "pendingFiles": 1}
    )
    key: str = "a1b2c3d4e5f6"
    zone: str = "America/Chicago"


@dataclass
class Box:
    """Stands in for `docker exec` into both gateways, which share one OpenRouter key."""

    now: datetime
    charges: list[tuple[datetime, float]] = field(default_factory=list)
    lifetime_before: float = 12.40
    assistants: dict[str, Assistant] = field(
        default_factory=lambda: {"corey": Assistant("Corey"), "denise": Assistant("Denise")}
    )
    failing: set[str] = field(default_factory=set)
    asked: list[tuple[str, str, dict[str, Any]]] = field(default_factory=list)
    delivered: dict[str, list[dict[str, Any]]] = field(default_factory=dict)

    def usage(self, moment: datetime) -> float:
        return self.lifetime_before + sum(amount for when, amount in self.charges if when <= moment)

    def key_figures(self, assistant: Assistant) -> dict[str, Any]:
        moment = self.now.astimezone(UTC)
        day = moment.replace(hour=0, minute=0, second=0, microsecond=0)
        week = day - timedelta(days=day.weekday())
        month = day.replace(day=1)
        usage = self.usage(moment)
        return {
            "id": assistant.key,
            "usage": usage,
            "daily": usage - self.usage(day),
            "weekly": usage - self.usage(week),
            "monthly": usage - self.usage(month),
        }

    def __call__(self, command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        container = next(part for part in command if part in CONTAINERS)
        persona = CONTAINERS[container]
        assistant = self.assistants[persona]
        if persona in self.failing:
            return subprocess.CompletedProcess(
                command, 1, "", f"Error: No such container: {container}"
            )
        if "spend-in.mjs" in command[-1]:
            report = json.loads(str(options["input"]))
            self.delivered.setdefault(persona, []).append(report)
            answer = {"ok": True, "month": report["month"], "at": report["at"]}
            return subprocess.CompletedProcess(command, 0, json.dumps(answer) + "\n", "")
        method = command[command.index("call") + 1]
        params = json.loads(command[command.index("--params") + 1]) if "--params" in command else {}
        self.asked.append((persona, method, params))
        local = self.now.astimezone(ZoneInfo(assistant.zone))
        if method == "household-app.spend.figures":
            figures = {
                "at": ms(self.now),
                "month": f"{local.year:04d}-{local.month:02d}",
                "timeZone": assistant.zone,
                "assistant": assistant.name,
                "key": self.key_figures(assistant),
                "voice": assistant.voice,
                "media": assistant.media,
            }
            return subprocess.CompletedProcess(command, 0, "banner\n" + json.dumps(figures), "")
        assert method == "usage.cost"
        cost = {
            "totals": {"totalCost": assistant.answers},
            "cacheStatus": assistant.cache,
            "daily": [],
        }
        return subprocess.CompletedProcess(command, 0, json.dumps(cost), "")

    def latest(self, persona: str = "corey") -> dict[str, Any]:
        return self.delivered[persona][-1]


def lines(report: dict[str, Any]) -> dict[str, float]:
    return {line["id"]: line["amount"] for line in report["lines"]}


class TickResultLike(Protocol):
    """household-spend.py's TickResult, which the test loads from the script's file."""

    report: dict[str, Any] | None
    delivered: int
    problems: list[str]


def run_tick(spend: ModuleType, box: Box, state: Path) -> TickResultLike:
    result: TickResultLike = spend.tick(spend.GATEWAYS, state, box)
    return result


def every_ten_minutes(spend: ModuleType, box: Box, state: Path, until: datetime) -> TickResultLike:
    result = run_tick(spend, box, state)
    while box.now < until:
        box.now += timedelta(minutes=10)
        result = run_tick(spend, box, state)
    return result


pytestmark = needs_nofollow_open


@pytest.mark.parametrize(
    ("corey", "denise", "charged"),
    [
        ((5.457, 0.02, 0.0), (17.709, 0.013, 0.0), 32.446),
        ((0.005, 0.0, 0.0), (0.005, 0.0, 0.0), 0.01),
        ((1.0049, 0.0, 0.3333), (2.6666, 0.0, 0.0), 4.0),
        ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0), 0.0),
    ],
)
def test_the_lines_add_up_to_the_total_to_the_cent(
    spend: ModuleType,
    tmp_path: Path,
    corey: tuple[float, float, float],
    denise: tuple[float, float, float],
    charged: float,
) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40), charges=[(central(2026, 10, 9, 8), charged)])
    for persona, (answers, voice, media) in (("corey", corey), ("denise", denise)):
        box.assistants[persona].answers = answers
        box.assistants[persona].voice = voice
        box.assistants[persona].media = media

    # Act
    result = run_tick(spend, box, tmp_path / "state.json")

    # Assert
    report = box.latest()
    total = round(report["total"] * 100)
    assert sum(round(amount * 100) for amount in lines(report).values()) == total
    assert total == round(charged * 100)
    assert result.problems == []


def test_each_assistant_is_its_answers_voice_and_pictures_and_other_is_the_rest(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40), charges=[(central(2026, 10, 3, 9), 32.45)])
    box.assistants["corey"] = Assistant("Corey", answers=5.46, voice=0.02, media=0.40)
    box.assistants["denise"] = Assistant("Denise", answers=17.71, voice=0.01, media=0.0)

    # Act
    run_tick(spend, box, tmp_path / "state.json")

    # Assert
    report = box.latest()
    assert report["lines"] == [
        {"id": "corey", "name": "Corey", "amount": 5.88},
        {"id": "denise", "name": "Denise", "amount": 17.72},
        {"id": "other", "name": "Other use of the key", "amount": 8.85},
    ]
    assert report["total"] == 32.45


def test_before_the_ledger_has_a_reading_at_midnight_the_month_is_openrouters_own(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange: the evening of 30 September in Central is 1 October in UTC.
    box = Box(
        now=central(2026, 10, 17, 12, 40),
        charges=[
            (central(2026, 9, 30, 18), 1.00),
            (central(2026, 9, 30, 20), 2.00),
            (central(2026, 10, 5), 4.00),
        ],
    )

    # Act
    run_tick(spend, box, tmp_path / "state.json")

    # Assert: OpenRouter's month began at 19:00 Central on the 30th.
    assert box.latest()["total"] == 6.00


def test_the_month_starts_at_midnight_in_the_household_time_zone_not_utc(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange: 7 pm Central on 31 October is already November in UTC.
    box = Box(
        now=central(2026, 10, 31, 18, 0),
        charges=[
            (central(2026, 10, 31, 20, 0), 1.50),
            (central(2026, 11, 1, 0, 5), 0.25),
            (central(2026, 11, 1, 9, 0), 0.75),
        ],
    )
    state = tmp_path / "state.json"

    # Act
    every_ten_minutes(spend, box, state, until=central(2026, 10, 31, 23, 50))
    october = box.latest()
    every_ten_minutes(spend, box, state, until=central(2026, 11, 1, 12, 0))
    november = box.latest()

    # Assert
    assert (october["month"], october["total"]) == ("2026-10", 1.50)
    assert october["resetsOn"] == "2026-11-01"
    assert (november["month"], november["total"]) == ("2026-11", 1.00)
    assert november["resetsOn"] == "2026-12-01"


def test_a_box_down_across_midnight_starts_the_month_straight_between_its_readings(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange: readings at 10 pm on 30 November and 2 am on 1 December, a dollar an hour
    # spent between them.
    box = Box(
        now=central(2026, 11, 30, 22),
        charges=[
            (central(2026, 11, 30, 22, 0, 30) + timedelta(hours=hour), 1.0) for hour in range(4)
        ],
    )
    state = tmp_path / "state.json"
    run_tick(spend, box, state)

    # Act
    box.now = central(2026, 12, 1, 2)
    run_tick(spend, box, state)

    # Assert: half of the four dollars is December's.
    assert box.latest()["total"] == 2.00


def test_each_day_is_the_total_by_the_end_of_that_household_day(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange
    box = Box(
        now=central(2026, 11, 1, 0, 0, 2),
        charges=[
            (central(2026, 11, 1, 10), 1.00),
            (central(2026, 11, 1, 23, 55), 0.50),
            (central(2026, 11, 2, 0, 5), 0.25),
            (central(2026, 11, 3, 8), 2.00),
        ],
    )

    # Act
    every_ten_minutes(spend, box, tmp_path / "state.json", until=central(2026, 11, 3, 12))

    # Assert
    report = box.latest()
    assert report["days"] == [
        {"day": "2026-11-01", "spent": 1.50},
        {"day": "2026-11-02", "spent": 1.75},
        {"day": "2026-11-03", "spent": 3.75},
    ]
    assert report["total"] == report["days"][-1]["spent"]


def test_the_first_of_november_ends_at_midnight_central_after_the_clocks_go_back(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange: 1 November 2026 is 25 hours long in Central; it ends at 06:00 UTC.
    box = Box(
        now=central(2026, 11, 1, 0, 0, 2),
        charges=[
            (datetime(2026, 11, 2, 5, 30, tzinfo=UTC), 1.00),
            (datetime(2026, 11, 2, 6, 30, tzinfo=UTC), 2.00),
        ],
    )

    # Act
    every_ten_minutes(spend, box, tmp_path / "state.json", until=central(2026, 11, 2, 9))

    # Assert
    assert box.latest()["days"][0] == {"day": "2026-11-01", "spent": 1.00}


def test_days_before_the_first_reading_run_straight_between_openrouters_own_starts(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange: OpenRouter's own starts in October 2026 are 30 September 19:00 Central
    # (its month), 11 October 19:00 (its week) and 16 October 19:00 (its day).
    box = Box(
        now=central(2026, 10, 17, 12, 40),
        charges=[(central(2026, 10, 2, 12), 11.0), (central(2026, 10, 13, 12), 5.0)],
    )

    # Act
    run_tick(spend, box, tmp_path / "state.json")

    # Assert: 1 October ends 29 of the 264 hours into OpenRouter's first 11 days, and
    # 11 October 5 of the 120 hours into the next 5, whatever day the charge fell on.
    days = {entry["day"]: entry["spent"] for entry in box.latest()["days"]}
    assert len(days) == 17
    assert days["2026-10-01"] == round(11.0 * 29 / 264, 2)
    assert days["2026-10-11"] == round(11.0 + 5.0 * 5 / 120, 2)
    assert days["2026-10-16"] == 16.0
    assert days["2026-10-17"] == 16.0
    assert list(days.values()) == sorted(days.values())


def test_a_ledger_with_nothing_added_up_yet_is_not_taken(spend: ModuleType, tmp_path: Path) -> None:
    # Arrange: OpenClaw threw its ledger away after a change to a model's price.
    box = Box(now=central(2026, 10, 17, 12, 40), charges=[(central(2026, 10, 3), 9.0)])
    box.assistants["corey"].answers = 0.03
    box.assistants["corey"].cache = {"status": "refreshing", "cachedFiles": 0, "pendingFiles": 123}

    # Act
    result = run_tick(spend, box, tmp_path / "state.json")

    # Assert: nothing goes out rather than Corey reading a few cents.
    assert box.delivered == {}
    assert result.problems == ["corey's answers for 2026-10 are not added up yet"]


def test_a_months_answers_never_go_down_while_openclaw_adds_them_up_again(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40), charges=[(central(2026, 10, 3), 30.0)])
    state = tmp_path / "state.json"
    box.assistants["corey"].answers = 5.40
    run_tick(spend, box, state)

    # Act: the ledger is being added up again, then is whole once more.
    box.now += timedelta(minutes=10)
    box.assistants["corey"].answers = 0.30
    box.assistants["corey"].cache = {"status": "refreshing", "cachedFiles": 4, "pendingFiles": 119}
    run_tick(spend, box, state)
    during = lines(box.latest())["corey"]
    box.now += timedelta(minutes=10)
    box.assistants["corey"].answers = 5.50
    run_tick(spend, box, state)

    # Assert
    assert during == 5.40
    assert lines(box.latest())["corey"] == 5.50


def test_a_new_month_starts_each_assistants_answers_over(spend: ModuleType, tmp_path: Path) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 31, 23, 50))
    state = tmp_path / "state.json"
    box.assistants["corey"].answers = 5.40
    run_tick(spend, box, state)

    # Act
    box.now = central(2026, 11, 1, 0, 0, 2)
    box.assistants["corey"].answers = 0.0
    run_tick(spend, box, state)

    # Assert
    assert box.latest()["month"] == "2026-11"
    assert lines(box.latest())["corey"] == 0.0


def test_usage_cost_is_asked_for_the_month_so_far_in_the_gateways_own_days(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange: 8 pm Central on the 17th is the 18th in UTC.
    box = Box(now=central(2026, 10, 17, 20, 0))

    # Act
    run_tick(spend, box, tmp_path / "state.json")

    # Assert
    asked = [params for persona, method, params in box.asked if method == "usage.cost"]
    assert asked == [{"mode": "gateway", "startDate": "2026-10-01", "endDate": "2026-10-17"}] * 2


def test_the_same_month_goes_to_both_gateways_through_spend_in(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40), charges=[(central(2026, 10, 3), 2.0)])
    commands: list[list[str]] = []

    def recording(command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        commands.append(command)
        return box(command, **options)

    # Act
    result: TickResultLike = spend.tick(spend.GATEWAYS, tmp_path / "state.json", recording)

    # Assert
    assert result.delivered == 2
    assert box.delivered["corey"] == box.delivered["denise"]
    spend_in = "/opt/household-plugins/household-app/spend-in.mjs"
    assert ["docker", "exec", "-i", "-u", "node", "openclaw-gateway", "node", spend_in] in commands
    assert ["docker", "exec", "-i", "-u", "node", "openclaw-denise", "node", spend_in] in commands


def test_a_gateway_that_does_not_answer_keeps_its_last_figures_for_the_month(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40), charges=[(central(2026, 10, 3), 30.0)])
    state = tmp_path / "state.json"
    box.assistants["denise"].answers = 17.70
    run_tick(spend, box, state)

    # Act
    box.now += timedelta(minutes=10)
    box.charges.append((box.now - timedelta(minutes=5), 1.0))
    box.failing.add("denise")
    result = run_tick(spend, box, state)

    # Assert
    assert lines(box.latest("corey"))["denise"] == 17.70
    assert box.latest("corey")["total"] == 31.0
    assert len(result.problems) == 2
    assert all("denise" in problem for problem in result.problems)


def test_two_different_keys_are_never_added_into_one_month(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40))
    box.assistants["denise"].key = "ffffffffffff"

    # Act
    result = run_tick(spend, box, tmp_path / "state.json")

    # Assert
    assert box.delivered == {}
    assert result.problems == [
        "the gateways use different keys or time zones, so no one month adds them up"
    ]


def test_a_new_key_starts_the_ledger_over(spend: ModuleType, tmp_path: Path) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40), charges=[(central(2026, 10, 3), 30.0)])
    state = tmp_path / "state.json"
    run_tick(spend, box, state)

    # Act: a new key whose month so far is 2 dollars.
    box.now += timedelta(minutes=10)
    box.charges = [(central(2026, 10, 16), 2.0)]
    box.lifetime_before = 0.0
    for assistant in box.assistants.values():
        assistant.key = "0123456789ab"
    run_tick(spend, box, state)

    # Assert
    assert box.latest()["total"] == 2.0


def test_the_summary_says_the_month_and_its_lines_and_nothing_else(
    spend: ModuleType, tmp_path: Path
) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40), charges=[(central(2026, 10, 3), 32.45)])
    box.assistants["corey"].answers = 5.48
    box.assistants["denise"].answers = 17.72

    # Act
    result = run_tick(spend, box, tmp_path / "state.json")

    # Assert
    assert spend.summary(result.report) == (
        "household-spend: October 32.45 = Corey 5.48 + Denise 17.72 + Other use of the key 9.25"
    )
    assert "a1b2c3d4e5f6" not in json.dumps(result.report)


def test_the_ledger_is_kept_for_root_only(spend: ModuleType, tmp_path: Path) -> None:
    # Arrange
    box = Box(now=central(2026, 10, 17, 12, 40))
    state = tmp_path / "coordination" / "household-spend.json"

    # Act
    run_tick(spend, box, state)

    # Assert
    assert state.stat().st_mode & 0o777 == 0o600
    assert json.loads(state.read_text(encoding="utf-8"))["key"] == "a1b2c3d4e5f6"
