"""scripts/ios-cloud.py: what a Mac minute costs, and the cap that refuses a Mac run.

The owner chose GitHub's hosted Macs at 5 dollars a day. The workflows run `budget`
before any Mac starts and `cost` after it ends, so these tests drive both against a
fake `gh` that answers the way the GitHub API does, and check the arithmetic that
decides whether money is spent.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from collections.abc import Callable, Iterator, Sequence
from datetime import UTC, datetime
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "ios-cloud.py"
NOW = datetime(2026, 10, 14, 20, 0, tzinfo=UTC)
REPOSITORY = "fpresta0607/household-assistant"


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("ios_cloud", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["ios_cloud"] = module
    spec.loader.exec_module(module)
    return module


cloud = load()


@pytest.mark.parametrize(
    ("at", "cap"),
    [
        ("2026-10-18T01:37:43+00:00", 5.0),
        ("2026-10-18T01:37:44+00:00", 15.0),
        ("2026-10-18T04:59:59+00:00", 15.0),
        ("2026-10-18T00:00:00-05:00", 5.0),
        ("2026-10-19T01:37:44+00:00", 5.0),
        ("2027-10-18T01:37:44+00:00", 5.0),
    ],
)
def test_temporary_cap_ends_at_chicago_midnight(at: str, cap: float) -> None:
    assert cloud.daily_cap(datetime.fromisoformat(at)) == cap


def job(
    name: str,
    minutes_and_seconds: tuple[int, int] | None,
    *,
    labels: Sequence[str] = ("macos-26",),
    status: str = "completed",
) -> dict[str, Any]:
    started = "2026-10-14T18:00:00Z"
    completed = None
    if minutes_and_seconds is not None:
        minutes, seconds = minutes_and_seconds
        completed = f"2026-10-14T18:{minutes:02d}:{seconds:02d}Z"
    return {
        "name": name,
        "labels": list(labels),
        "status": status,
        "started_at": started,
        "completed_at": completed,
    }


class FakeGh:
    """Answers gh the way the GitHub API would, and records every call."""

    def __init__(self, runs: dict[int, list[dict[str, Any]]]) -> None:
        self.runs = runs
        self.calls: list[list[str]] = []
        self.views: Iterator[dict[str, Any]] = iter(())
        self.listed: list[dict[str, Any]] = []
        self.billing: dict[str, Any] | None = None
        self.artifacts: dict[str, list[str]] = {}
        self.visibility = "private"

    def __call__(self, arguments: Sequence[str]) -> str:
        arguments = list(arguments)
        self.calls.append(arguments)
        if arguments[:3] == ["api", "--paginate", "--slurp"]:
            path = arguments[5]
            if path == f"repos/{REPOSITORY}/actions/runs":
                return json.dumps([{"workflow_runs": [{"id": run} for run in self.runs]}])
            run_id = int(path.split("/")[-2])
            return json.dumps([{"jobs": self.runs[run_id]}])
        if arguments == ["api", f"repos/{REPOSITORY}"]:
            return json.dumps({"full_name": REPOSITORY, "visibility": self.visibility})
        if arguments[0] == "api" and "billing" in arguments[1]:
            if self.billing is None:
                raise cloud.CloudError("gh api failed: needs the user scope")
            return json.dumps(self.billing)
        if arguments[:2] == ["workflow", "run"]:
            return ""
        if arguments[:2] == ["run", "list"]:
            return json.dumps(self.listed)
        if arguments[:2] == ["run", "view"]:
            return json.dumps(next(self.views))
        if arguments[:2] == ["run", "download"]:
            # gh puts each artifact in a folder of its own name when asked for several.
            folder = Path(arguments[arguments.index("--dir") + 1])
            for name in names_after("--name", arguments):
                for file in self.artifacts.get(name, []):
                    (folder / name).mkdir(parents=True, exist_ok=True)
                    (folder / name / file).write_bytes(b"")
            return ""
        raise AssertionError(f"unexpected gh call {arguments}")


def names_after(flag: str, arguments: Sequence[str]) -> list[str]:
    return [arguments[i + 1] for i, part in enumerate(arguments) if part == flag]


@pytest.mark.parametrize(
    ("minutes_and_seconds", "billed"),
    [((0, 0), 0), ((0, 1), 1), ((1, 0), 1), ((1, 1), 2), ((4, 37), 5), (None, 0)],
)
def test_a_job_is_billed_by_the_minute_rounded_up(
    minutes_and_seconds: tuple[int, int] | None, billed: int
) -> None:
    assert cloud.billed_minutes(job("preview", minutes_and_seconds)) == billed


@pytest.mark.parametrize(
    ("labels", "is_mac"),
    [(["macos-26"], True), (["macOS-15-arm64"], True), (["ubuntu-latest"], False), ([], False)],
)
def test_only_mac_jobs_are_counted(labels: list[str], is_mac: bool) -> None:
    assert cloud.is_mac(job("any", (1, 0), labels=labels)) is is_mac


def test_budget_lets_a_run_start_when_even_its_timeout_stays_under_the_cap() -> None:
    # Arrange: 20 Mac minutes and one Linux job already today.
    gh = FakeGh({1: [job("preview", (19, 30)), job("lint", (5, 0), labels=["ubuntu-latest"])]})

    # Act
    said = cloud.budget(gh, NOW, ceiling_minutes=30, cap=5.0, this_run=None)

    # Assert: (20 + 30) minutes at $0.062 is $3.10.
    assert "20 Mac minutes, $1.24" in said
    assert "At most $3.10 of the $5.00 daily cap" in said


def test_budget_refuses_a_run_whose_timeout_could_pass_the_cap() -> None:
    gh = FakeGh({1: [job("preview", (30, 0)), job("preview", (25, 0))]})

    with pytest.raises(cloud.CloudError) as refused:
        cloud.budget(gh, NOW, ceiling_minutes=30, cap=5.0, this_run=None)

    # 55 minutes spent plus 30 possible is $5.27.
    assert "could pass the $5.00 daily cap" in str(refused.value)
    assert "refused" in str(refused.value)


def test_a_mac_job_still_running_elsewhere_counts_at_the_longest_timeout() -> None:
    gh = FakeGh({1: [job("testflight", None, status="in_progress")], 2: [job("preview", (5, 0))]})

    day = cloud.today(gh, NOW, leave_out=None)

    assert day.billed_minutes == 5
    assert day.running_jobs == 1
    assert day.committed_minutes == 5 + cloud.LONGEST_MAC_JOB_MINUTES


def test_budget_leaves_out_the_run_it_belongs_to() -> None:
    """The run's own Mac job is queued behind the budget job; its timeout is the ceiling."""
    gh = FakeGh({7: [job("preview", None, status="queued")]})

    day = cloud.today(gh, NOW, leave_out=7)

    assert day.running_jobs == 0
    assert not any("runs/7/jobs" in " ".join(call) for call in gh.calls)


def test_budget_reads_runs_back_to_yesterday() -> None:
    gh = FakeGh({})

    cloud.today(gh, NOW, leave_out=None)

    assert "created=>=2026-10-13" in gh.calls[0]


def test_the_day_reads_only_runs_started_by_hand() -> None:
    """Only a hand-started run has a Mac job here, and reading every run's jobs ran the
    workflow token out of its hourly API calls on 15 October, with 440 runs that day."""
    gh = FakeGh({})

    cloud.today(gh, NOW, leave_out=None)

    assert "event=workflow_dispatch" in gh.calls[0]


def test_a_job_counts_on_the_day_it_finished_as_github_bills_it() -> None:
    """GitHub billed a preview started at 23:54Z on the 14th to the 15th, past the cap."""
    # Arrange: one job across midnight into today, one wholly yesterday.
    across = {
        "name": "preview",
        "labels": ["macos-26"],
        "status": "completed",
        "started_at": "2026-10-13T23:54:58Z",
        "completed_at": "2026-10-14T00:01:40Z",
    }
    yesterday = {"name": "preview", "labels": ["macos-26"], "status": "completed",
                 "started_at": "2026-10-13T22:00:00Z",
                 "completed_at": "2026-10-13T22:08:00Z"}  # fmt: skip
    gh = FakeGh({1: [across], 2: [yesterday], 3: [job("testflight", (8, 0))]})

    # Act
    day = cloud.today(gh, NOW, leave_out=None)

    # Assert: the 7 minutes across midnight and today's 8, not yesterday's.
    assert day.billed_minutes == 7 + 8


def test_cost_reads_back_each_mac_job_and_the_day() -> None:
    gh = FakeGh(
        {
            3: [job("preview", (7, 10)), job("cost", (0, 20), labels=["ubuntu-latest"])],
            4: [job("preview", (4, 0))],
        }
    )

    lines = cloud.cost(gh, 3, NOW)

    assert lines[0] == "preview: 8 Mac minutes"
    assert "This run: 8 Mac minutes, $0.50" in lines[1]
    assert lines[2] == "Today on this repository: 12 Mac minutes, $0.74 of the $5.00 daily cap."


def test_cost_says_where_each_mac_job_spent_its_minutes() -> None:
    # Arrange: a preview whose steps ran, one skipped.
    preview = job("preview", (7, 10))
    preview["steps"] = [
        {"name": "build", "conclusion": "success",
         "started_at": "2026-10-14T18:00:05Z", "completed_at": "2026-10-14T18:01:38Z"},
        {"name": "unit tests", "conclusion": "failure",
         "started_at": "2026-10-14T18:01:38Z", "completed_at": "2026-10-14T18:03:01Z"},
        {"name": "screenshots", "conclusion": "skipped",
         "started_at": "2026-10-14T18:03:01Z", "completed_at": "2026-10-14T18:03:01Z"},
    ]  # fmt: skip
    gh = FakeGh({3: [preview]})

    # Act
    lines = cloud.cost(gh, 3, NOW)

    # Assert: each step that ran, in order, under its job.
    assert lines[:3] == ["preview: 8 Mac minutes", "  build: 93 s", "  unit tests: 83 s"]


def test_the_bill_is_read_when_the_sign_in_allows_it() -> None:
    gh = FakeGh({})
    gh.billing = {"usageItems": [{"grossQuantity": 24.0, "netAmount": 1.488}]}

    said = cloud.billed_today(gh, NOW)

    assert said == "GitHub's bill for today so far: 24 Mac minutes, $1.49 (it lags)."
    assert "day=14&repository=fpresta0607/household-assistant&sku=actions_macos" in gh.calls[0][1]


def test_an_unreadable_bill_says_why_instead_of_failing() -> None:
    assert "needs the user scope" in cloud.billed_today(FakeGh({}), NOW)


def no_sleep(_: float) -> None:
    return None


def test_start_finds_the_run_its_dispatch_made() -> None:
    gh = FakeGh({})
    gh.listed = [
        {"databaseId": 1, "createdAt": "2020-01-01T00:00:00Z", "url": "old"},
    ]
    found: list[dict[str, Any]] = []

    def appear_on_second_look(_: float) -> None:
        if found:
            gh.listed = [{"databaseId": 9, "createdAt": "2999-01-01T00:00:00Z", "url": "new"}]
        found.append({})

    run = cloud.start(gh, "ios-ci.yml", "feat/x", [], appear_on_second_look)

    assert run["databaseId"] == 9
    assert gh.calls[0] == ["workflow", "run", "ios-ci.yml", "--ref", "feat/x"]


def test_start_gives_up_when_no_run_appears() -> None:
    gh = FakeGh({})

    with pytest.raises(cloud.CloudError, match=r"no ios-release.yml run appeared"):
        cloud.start(gh, "ios-release.yml", "main", ["confirm=UPLOAD"], no_sleep)

    assert gh.calls[0][-2:] == ["-f", "confirm=UPLOAD"]
    assert len(gh.calls) == 1 + cloud.FIND_RUN_ATTEMPTS


def test_wait_returns_the_conclusion_once_the_run_ends(capsys: pytest.CaptureFixture[str]) -> None:
    gh = FakeGh({})
    gh.views = iter(
        [
            {"status": "in_progress", "jobs": [{"name": "preview", "status": "in_progress"}]},
            {"status": "completed", "conclusion": "success",
             "jobs": [{"name": "preview", "status": "completed", "conclusion": "success"}]},
        ]
    )  # fmt: skip

    conclusion = cloud.wait(gh, 5, cloud.timedelta(minutes=5), no_sleep)

    assert conclusion == "success"
    assert capsys.readouterr().out.splitlines() == ["  preview: in_progress", "  preview: success"]


def test_wait_is_bounded() -> None:
    gh = FakeGh({})
    gh.views = iter([{"status": "queued", "jobs": []}] * 3)

    with pytest.raises(cloud.CloudError, match="had not ended"):
        cloud.wait(gh, 5, cloud.timedelta(0), no_sleep)


@pytest.fixture
def summary(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    path = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(path))
    monkeypatch.setenv("GITHUB_RUN_ID", "77")
    return path


def run_main(arguments: list[str], gh: Callable[[Sequence[str]], str]) -> int:
    result: int = cloud.main(arguments, gh=gh, sleep=no_sleep, clock=lambda: NOW)
    return result


def test_the_budget_command_fails_the_job_and_says_why_on_the_summary(summary: Path) -> None:
    gh = FakeGh({1: [job("preview", (59, 0))], 77: [job("preview", None, status="queued")]})

    status = run_main(["budget", "--ceiling-minutes", "30"], gh)

    assert status == 1
    assert "refused" in summary.read_text(encoding="utf-8")


def test_the_budget_command_passes_under_the_cap(summary: Path) -> None:
    gh = FakeGh({1: [job("preview", (5, 0))]})

    status = run_main(["budget", "--ceiling-minutes", "30"], gh)

    assert status == 0
    assert "Going ahead." in summary.read_text(encoding="utf-8")


@pytest.mark.parametrize(
    ("at", "extra_arguments", "expected"),
    [
        ("2026-10-18T02:00:00+00:00", [], 0),
        ("2026-10-18T02:00:00+00:00", ["--cap", "5"], 1),
        ("2026-10-18T05:00:00+00:00", [], 1),
    ],
)
def test_todays_blocked_preview_gets_headroom_only_until_midnight(
    summary: Path, at: str, extra_arguments: list[str], expected: int
) -> None:
    # The actual blocked run: 55 minutes used, another Mac still running, and
    # a new preview with a 30-minute timeout. Its worst case is $8.06.
    jobs = [
        job("preview", (30, 0)),
        job("preview", (25, 0)),
        job("preview", None, status="in_progress"),
    ]
    for item in jobs:
        for key in ("started_at", "completed_at"):
            if item[key]:
                item[key] = item[key].replace("2026-10-14", "2026-10-18")
    gh = FakeGh({1: jobs})

    status = cloud.main(
        ["budget", "--ceiling-minutes", "30", *extra_arguments],
        gh=gh,
        sleep=no_sleep,
        clock=lambda: datetime.fromisoformat(at),
    )

    assert status == expected
    said = summary.read_text(encoding="utf-8")
    if expected == 0:
        assert "At most $8.06 of the $15.00 daily cap" in said
        assert "midnight Chicago" in said
        assert "normal $5.00 cap returns automatically" in said
    else:
        assert "could pass the $5.00 daily cap" in said


def test_cost_reports_the_temporary_cap_only_while_it_applies() -> None:
    gh = FakeGh({1: []})
    during = datetime(2026, 10, 18, 2, 0, tzinfo=UTC)
    after = datetime(2026, 10, 18, 5, 0, tzinfo=UTC)

    assert "of the $15.00 daily cap" in cloud.cost(gh, 1, during)[-1]
    assert "of the $5.00 daily cap" in cloud.cost(gh, 1, after)[-1]


def test_release_fit_uses_todays_cap_and_keeps_its_timeout(
    summary: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(cloud, "today", lambda *_args: cloud.Day(55, 1, cloud.MAC_MINUTE_USD))

    status = cloud.main(
        ["budget", "--ceiling-minutes", "45", "--fit-minimum", "10"],
        gh=FakeGh({}),
        sleep=no_sleep,
        clock=lambda: datetime(2026, 10, 18, 2, 0, tzinfo=UTC),
    )

    assert status == 0
    said = summary.read_text(encoding="utf-8")
    assert "may take 45 minutes" in said
    assert "under the $15.00 cap" in said


def test_an_upload_he_asked_for_is_cut_to_what_is_left_of_the_day() -> None:
    # Arrange: 68 Mac minutes, $4.22, as on 15 October 2026 when he said ship it.
    gh = FakeGh({1: [job("preview", (59, 0)), job("preview", (9, 0))]})

    # Act
    said, minutes = cloud.fit(
        gh, NOW, ceiling_minutes=45, minimum_minutes=10, cap=5.0, this_run=None
    )

    # Assert: $0.78 left is 12 minutes, less the one held back for rounding.
    assert minutes == 11
    assert 68 * cloud.MAC_MINUTE_USD + (minutes + 1) * cloud.MAC_MINUTE_USD < 5.0
    assert "may take 11 minutes, $0.68" in said


@pytest.mark.parametrize(("visibility", "price"), [("public", 0.0), ("private", 0.062)])
def test_a_mac_minute_costs_what_the_repository_visibility_says(
    visibility: str, price: float
) -> None:
    gh = FakeGh({})
    gh.visibility = visibility

    assert cloud.minute_usd(gh) == price


def test_budget_lets_any_run_start_on_a_public_repository() -> None:
    # Arrange: 89 Mac minutes today, past the $5.00 cap at the private price.
    gh = FakeGh({1: [job("preview", (59, 0))], 2: [job("preview", (30, 0))]})
    gh.visibility = "public"

    # Act
    said = cloud.budget(gh, NOW, ceiling_minutes=45, cap=5.0, this_run=None)

    # Assert
    assert said.startswith("This repository is public, so its Mac minutes are free.")
    assert "89 Mac minutes, $0.00" in said
    assert "At most $0.00 of the $5.00 daily cap. Going ahead." in said


def test_an_upload_keeps_its_full_timeout_on_a_public_repository() -> None:
    # Arrange: a day that would leave a private repository nothing.
    gh = FakeGh({1: [job("preview", (59, 0))], 2: [job("preview", (59, 0))]})
    gh.visibility = "public"

    # Act
    said, minutes = cloud.fit(
        gh, NOW, ceiling_minutes=45, minimum_minutes=10, cap=5.0, this_run=None
    )

    # Assert
    assert minutes == 45
    assert "may take 45 minutes, $0.00" in said


def test_cost_on_a_public_repository_is_free() -> None:
    gh = FakeGh({3: [job("preview", (7, 10))]})
    gh.visibility = "public"

    lines = cloud.cost(gh, 3, NOW)

    assert lines[1] == "This run: 8 Mac minutes, $0.00 at $0/minute."
    assert lines[2] == "Today on this repository: 8 Mac minutes, $0.00 of the $5.00 daily cap."


def test_an_upload_keeps_its_full_timeout_when_the_day_has_room() -> None:
    _, minutes = cloud.fit(
        FakeGh({}), NOW, ceiling_minutes=45, minimum_minutes=10, cap=5.0, this_run=None
    )

    assert minutes == 45


@pytest.mark.parametrize("spent_minutes", [72, 80, 90])
def test_an_upload_is_refused_when_too_little_is_left_to_finish(spent_minutes: int) -> None:
    gh = FakeGh({1: [job("preview", (59, 0))], 2: [job("preview", (spent_minutes - 59, 0))]})

    with pytest.raises(cloud.CloudError, match="fewer than the 10 this run needs"):
        cloud.fit(gh, NOW, ceiling_minutes=45, minimum_minutes=10, cap=5.0, this_run=None)


def test_the_budget_command_tells_the_workflow_how_long_the_mac_may_run(
    summary: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    gh = FakeGh({1: [job("preview", (59, 0)), job("preview", (9, 0))]})

    status = run_main(["budget", "--ceiling-minutes", "45", "--fit-minimum", "10"], gh)

    assert status == 0
    assert output.read_text(encoding="utf-8") == "minutes=11\n"


def test_a_rehearsal_budget_still_gives_its_full_timeout(
    summary: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))

    status = run_main(["budget", "--ceiling-minutes", "45"], FakeGh({}))

    assert status == 0
    assert output.read_text(encoding="utf-8") == "minutes=45\n"


def test_a_run_the_owner_approved_passes_the_cap_and_keeps_its_timeout(
    summary: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Arrange: a day already past the cap.
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    gh = FakeGh({1: [job("preview", (59, 0)), job("preview", (30, 0))]})

    # Act
    status = run_main(["budget", "--ceiling-minutes", "45", "--approved"], gh)

    # Assert: reported with today's spend, never refused, full timeout.
    assert status == 0
    assert output.read_text(encoding="utf-8") == "minutes=45\n"
    said = summary.read_text(encoding="utf-8")
    assert "89 Mac minutes, $5.52" in said
    assert "approved this run's spend past the daily cap" in said


@pytest.mark.parametrize(
    ("arguments", "workflow", "fields"),
    [
        (["preview", "--ref", "main", "--owner-approved-spend"], "ios-ci.yml",
         ["owner_approved_spend=true", "lane=fix"]),
        (["preview", "--ref", "main"], "ios-ci.yml", ["lane=fix"]),
        (["preview", "--ref", "main", "--lane", "full"], "ios-ci.yml", ["lane=full"]),
        (["preview", "--ref", "main", "--ui-tests", "ScrollHitchTests TapHitchTests"],
         "ios-ci.yml", ["lane=fix", "ui_tests=ScrollHitchTests TapHitchTests"]),
        (["preview", "--ref", "main", "--screenshots", "call. room.direct.call-row"],
         "ios-ci.yml", ["lane=fix", "screenshots=call. room.direct.call-row"]),
        (["testflight", "--owner-approved-spend"], "ios-release.yml",
         ["confirm=UPLOAD", "owner_approved_spend=true"]),
        (["testflight"], "ios-release.yml", ["confirm=UPLOAD"]),
    ],
)  # fmt: skip
def test_the_owners_word_reaches_the_workflow_only_when_given(
    arguments: list[str], workflow: str, fields: list[str]
) -> None:
    gh = FakeGh({})

    # The fake has no run to find, so the command stops right after starting it.
    status = run_main(arguments, gh)

    assert status == 1
    dispatched = gh.calls[0]
    assert dispatched[:3] == ["workflow", "run", workflow]
    assert [dispatched[i + 1] for i, part in enumerate(dispatched) if part == "-f"] == fields


def test_preview_brings_back_the_screenshots_the_demo_films_and_the_log(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # Arrange: a preview that ends green with the three artifacts ios-ci.yml keeps.
    monkeypatch.setattr(cloud, "ROOT", tmp_path)
    gh = FakeGh({3: [job("preview", (8, 0))]})
    created = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    gh.listed = [{"databaseId": 3, "createdAt": created, "url": "https://github.com/run/3"}]
    gh.views = iter([{"status": "completed", "conclusion": "success", "jobs": []}])
    gh.artifacts = {
        "ios-screenshots": ["room.family.png", "chats.populated.png"],
        "ios-motion-demo": ["recording.mp4", "recording-reduce-motion.mp4"],
        "ios-preview": ["test-ios.log"],
    }

    # Act
    status = run_main(["preview", "--ref", "main"], gh)

    # Assert: all three are asked for and counted.
    assert status == 0
    download = next(call for call in gh.calls if call[:2] == ["run", "download"])
    assert names_after("--name", download) == ["ios-screenshots", "ios-motion-demo", "ios-preview"]
    assert "2 screenshots, 2 demo films and the log" in capsys.readouterr().out
