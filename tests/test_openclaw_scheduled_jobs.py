"""openclaw-scheduled-jobs.py: each gateway's own jobs for its person, prep packets and the
Sunday digest.

The tests replace `docker exec` with a runner whose scheduler keeps jobs the way
OpenClaw 2026.9.4's `automations add --declaration-key` converges them: it creates the
job, or brings the one with that key to what it was given but its name, and leaves
whether it is on alone.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-scheduled-jobs.py"


def _flag(command: list[str], name: str) -> str | None:
    return command[command.index(name) + 1] if name in command else None


@pytest.fixture(scope="module")
def jobs() -> ModuleType:
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("openclaw_scheduled_jobs", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # Its dataclass looks its module up by name.
    sys.modules["openclaw_scheduled_jobs"] = module
    spec.loader.exec_module(module)
    return module


class FakeSchedulers:
    """Both gateways' schedulers, reached through `docker exec`."""

    def __init__(self, jobs: ModuleType) -> None:
        self.containers = {gateway.container: gateway.persona for gateway in jobs.GATEWAYS}
        self.jobs: dict[str, list[dict[str, Any]]] = {
            persona: [] for persona in self.containers.values()
        }
        self.added: list[tuple[str, str]] = []
        self.unreadable: set[str] = set()

    def __call__(self, command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        persona = self.containers[command[command.index("exec") + 1]]
        kept = self.jobs[persona]
        if "list" in command:
            if persona in self.unreadable:
                return subprocess.CompletedProcess(command, 1, "", "gateway closed")
            return subprocess.CompletedProcess(
                command, 0, "Automations\n" + json.dumps({"jobs": kept}), ""
            )
        if "edit" in command:
            job = next(job for job in kept if job["id"] == command[command.index("edit") + 1])
            job["name"] = _flag(command, "--name")
            return subprocess.CompletedProcess(command, 0, "{}", "")
        key = _flag(command, "--declaration-key")
        delivery: dict[str, Any] = (
            {"mode": "none", "channel": "last"}
            if "--no-deliver" in command
            else {
                "mode": "announce",
                "channel": _flag(command, "--channel"),
                "to": _flag(command, "--to"),
                "accountId": "default",
            }
        )
        spec: dict[str, Any] = {
            "name": _flag(command, "--name"),
            "agentId": _flag(command, "--agent"),
            "schedule": {"kind": "cron", "expr": _flag(command, "--cron")},
            "sessionTarget": _flag(command, "--session"),
            "payload": {"kind": "agentTurn", "message": _flag(command, "--message")},
            "delivery": delivery,
        }
        existing = next((job for job in kept if job.get("declarationKey") == key), None)
        if existing is None:
            kept.append(
                {"id": f"job-{len(kept) + 1}", "declarationKey": key, "enabled": True, **spec}
            )
        else:
            existing.update({part: value for part, value in spec.items() if part != "name"})
        self.added.append((persona, str(key)))
        return subprocess.CompletedProcess(command, 0, "{}", "")


@pytest.fixture
def schedulers(jobs: ModuleType) -> FakeSchedulers:
    return FakeSchedulers(jobs)


def _gateway(jobs: ModuleType, persona: str) -> object:
    return next(gateway for gateway in jobs.GATEWAYS if gateway.persona == persona)


@pytest.mark.parametrize(("persona", "person"), [("corey", "franco"), ("denise", "gia")])
def test_each_gateway_sends_its_own_person_one_packet_a_day_in_their_app_thread(
    jobs: ModuleType, persona: str, person: str
) -> None:
    # Act
    command = jobs.command(jobs.PREP_PACKETS, _gateway(jobs, persona))

    # Assert
    assert command[:2] == ["automations", "add"]
    assert _flag(command, "--declaration-key") == "household-app:prep-packets"
    assert _flag(command, "--cron") == "0 8 * * *"
    assert "--tz" not in command, "the gateway's own clock, the household's"
    assert _flag(command, "--agent") == "main"
    assert _flag(command, "--session") == "isolated"
    assert "--announce" in command
    assert (_flag(command, "--channel"), _flag(command, "--to")) == (
        "household",
        f"household:{person}",
    )
    assert "--no-deliver" not in command


def test_the_packet_names_what_helps_reads_the_shared_calendar_and_sends_nothing_else(
    jobs: ModuleType,
) -> None:
    # Act
    prompt = jobs.PREP_PACKETS.prompt

    # Assert: the made-up household file's calendar, and windows that meet end to end.
    assert '"Family Calendar" in iCloud' in prompt
    assert "between 36 and 60 hours from now" in prompt
    for asked in (
        "address",
        "drive time",
        "when to leave",
        "what to bring",
        "form to fill",
        "confirmation number",
    ):
        assert asked in prompt
    for kind in ("appointment", "flight", "school or church event"):
        assert kind in prompt
    assert "Send nothing to anyone else, book or change nothing" in prompt
    assert "household_note" not in prompt, (
        "a packet can be one person's own, so the shared note is not written"
    )
    assert prompt.endswith("reply NO_REPLY.")


@pytest.mark.parametrize("persona", ["corey", "denise"])
def test_the_sunday_digest_runs_sunday_evening_and_posts_through_its_tool_alone(
    jobs: ModuleType, persona: str
) -> None:
    # Act
    command = jobs.command(jobs.SUNDAY_DIGEST, _gateway(jobs, persona))
    prompt = jobs.SUNDAY_DIGEST.prompt

    # Assert
    assert _flag(command, "--declaration-key") == "household-app:sunday-digest"
    assert _flag(command, "--cron") == "0 19 * * 0", "Sunday, 7 PM, the gateway's own clock"
    assert _flag(command, "--session") == "isolated"
    assert "--no-deliver" in command, "the digest is posted by household_digest, never twice"
    assert not {"--announce", "--channel", "--to"} & set(command)
    assert '"Family Calendar" in iCloud' in prompt
    assert "call household_digest once" in prompt
    assert "at most four short lines" in prompt
    assert "two or three things that need your person's decision" in prompt
    assert "Send nothing to any chat or person and change nothing" in prompt


def test_the_sunday_digest_asks_for_the_weeks_events_with_their_starts(jobs: ModuleType) -> None:
    # Arrange: the plugin draws the events as an agenda card, a calendar mark for each day.
    prompt = jobs.SUNDAY_DIGEST.prompt

    # Act and Assert
    assert "household_digest once: events, the week's main events" in prompt
    assert "its start as the calendar gives it, with its offset" in prompt
    assert "its day when it is all day" in prompt


def test_apply_adds_both_jobs_once_and_check_sees_them(
    jobs: ModuleType, schedulers: FakeSchedulers, capsys: pytest.CaptureFixture[str]
) -> None:
    # Act
    first = jobs.main(["apply", "--gateway", "corey"], run=schedulers)
    again = jobs.main(["apply", "--gateway", "corey"], run=schedulers)
    said = capsys.readouterr().out
    checked = jobs.main(["check"], run=schedulers)

    # Assert
    assert (first, again) == (0, 0)
    assert schedulers.added == [
        ("corey", "household-app:prep-packets"),
        ("corey", "household-app:sunday-digest"),
    ], "apply again changes nothing"
    assert "corey: nothing to write" in said
    prep, digest = schedulers.jobs["corey"]
    assert prep["delivery"]["to"] == "household:franco"
    assert digest["delivery"]["mode"] == "none"
    assert schedulers.jobs["denise"] == [], "Denise's scheduler is never written"
    out = capsys.readouterr().out
    assert "corey (openclaw-gateway): Prep packets ok" in out
    assert "corey (openclaw-gateway): Sunday digest ok" in out
    assert "denise (openclaw-denise): Prep packets missing" in out
    assert "denise (openclaw-denise): Sunday digest missing" in out
    assert checked == 1


@pytest.mark.parametrize(
    ("change", "said"),
    [
        (lambda job: job["schedule"].update({"expr": "0 7 * * *"}), "changed: schedule"),
        (lambda job: job["schedule"].update({"tz": "UTC"}), "changed: schedule"),
        (lambda job: job["delivery"].update({"to": "household:gia"}), "changed: delivery"),
        (
            lambda job: job["delivery"].update({"channel": "telegram", "to": "7100000001"}),
            "changed: delivery",
        ),
        (lambda job: job["payload"].update({"message": "Say hello."}), "changed: prompt"),
        (lambda job: job.update({"sessionTarget": "main"}), "changed: session"),
        (lambda job: job.update({"name": "Prep"}), "changed: name"),
    ],
)
def test_check_reports_a_changed_job_and_apply_puts_it_back(
    jobs: ModuleType,
    schedulers: FakeSchedulers,
    capsys: pytest.CaptureFixture[str],
    change: Callable[[dict[str, Any]], object],
    said: str,
) -> None:
    # Arrange
    for persona in ("corey", "denise"):
        jobs.main(["apply", "--gateway", persona], run=schedulers)
    change(schedulers.jobs["corey"][0])
    capsys.readouterr()

    # Act
    before = jobs.main(["check"], run=schedulers)
    reported = capsys.readouterr().out
    jobs.main(["apply", "--gateway", "corey"], run=schedulers)
    capsys.readouterr()
    after = jobs.main(["check"], run=schedulers)

    # Assert
    assert before == 1
    assert f"Prep packets {said}" in reported
    assert after == 0
    assert len(schedulers.jobs["corey"]) == 2
    assert schedulers.jobs["corey"][0]["name"] == "Prep packets"


def test_a_job_someone_switched_off_is_left_off_and_a_dry_run_writes_nothing(
    jobs: ModuleType, schedulers: FakeSchedulers, capsys: pytest.CaptureFixture[str]
) -> None:
    # Arrange
    jobs.main(["apply", "--dry-run", "--gateway", "denise"], run=schedulers)
    dry = capsys.readouterr().out
    jobs.main(["apply", "--gateway", "corey"], run=schedulers)
    schedulers.jobs["corey"][1]["enabled"] = False
    capsys.readouterr()

    # Act
    result = jobs.main(["apply", "--gateway", "corey"], run=schedulers)

    # Assert
    assert "denise: Prep packets missing, apply writes it at 0 8 * * *" in dry
    assert "denise: Sunday digest missing, apply writes it at 0 19 * * 0" in dry
    assert "dry run: nothing written." in dry
    assert schedulers.jobs["denise"] == []
    assert result == 0
    assert "Sunday digest switched off, left as it is" in capsys.readouterr().out
    assert schedulers.jobs["corey"][1]["enabled"] is False
    assert len(schedulers.added) == 2


def test_a_scheduler_that_cannot_be_read_writes_nothing_and_fails(
    jobs: ModuleType, schedulers: FakeSchedulers, capsys: pytest.CaptureFixture[str]
) -> None:
    # Arrange
    schedulers.unreadable.add("corey")

    # Act
    result = jobs.main(["apply", "--gateway", "corey"], run=schedulers)

    # Assert
    assert result == 1
    assert "would not list its scheduled jobs" in capsys.readouterr().err
    assert schedulers.added == []
