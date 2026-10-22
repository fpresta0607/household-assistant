"""openclaw-prep-packets.py: each gateway's own job that sends its person a prep packet.

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
SCRIPT = ROOT / "scripts" / "openclaw-prep-packets.py"


def _flag(command: list[str], name: str) -> str | None:
    return command[command.index(name) + 1] if name in command else None


@pytest.fixture(scope="module")
def prep() -> ModuleType:
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("openclaw_prep_packets", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeSchedulers:
    """Both gateways' schedulers, reached through `docker exec`."""

    def __init__(self, prep: ModuleType) -> None:
        self.containers = {gateway.container: gateway.persona for gateway in prep.GATEWAYS}
        self.jobs: dict[str, list[dict[str, Any]]] = {
            persona: [] for persona in self.containers.values()
        }
        self.added: list[str] = []
        self.renamed: list[str] = []
        self.unreadable: set[str] = set()

    def __call__(self, command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        persona = self.containers[command[command.index("exec") + 1]]
        jobs = self.jobs[persona]
        if "list" in command:
            if persona in self.unreadable:
                return subprocess.CompletedProcess(command, 1, "", "gateway closed")
            return subprocess.CompletedProcess(
                command, 0, "Automations\n" + json.dumps({"jobs": jobs}), ""
            )
        if "edit" in command:
            job = next(job for job in jobs if job["id"] == command[command.index("edit") + 1])
            job["name"] = _flag(command, "--name")
            self.renamed.append(persona)
            return subprocess.CompletedProcess(command, 0, "{}", "")
        key = _flag(command, "--declaration-key")
        spec: dict[str, Any] = {
            "name": _flag(command, "--name"),
            "agentId": _flag(command, "--agent"),
            "schedule": {"kind": "cron", "expr": _flag(command, "--cron")},
            "sessionTarget": _flag(command, "--session"),
            "payload": {"kind": "agentTurn", "message": _flag(command, "--message")},
            "delivery": {
                "mode": "announce",
                "channel": _flag(command, "--channel"),
                "to": _flag(command, "--to"),
                "accountId": "default",
            },
        }
        existing = next((job for job in jobs if job.get("declarationKey") == key), None)
        if existing is None:
            jobs.append(
                {"id": f"job-{len(jobs) + 1}", "declarationKey": key, "enabled": True, **spec}
            )
        else:
            existing.update({part: value for part, value in spec.items() if part != "name"})
        self.added.append(persona)
        return subprocess.CompletedProcess(command, 0, "{}", "")


@pytest.fixture
def schedulers(prep: ModuleType) -> FakeSchedulers:
    return FakeSchedulers(prep)


@pytest.mark.parametrize(("persona", "person"), [("corey", "franco"), ("denise", "gia")])
def test_each_gateway_sends_its_own_person_one_packet_a_day_in_their_app_thread(
    prep: ModuleType, persona: str, person: str
) -> None:
    # Arrange
    gateway = next(gateway for gateway in prep.GATEWAYS if gateway.persona == persona)

    # Act
    command = prep.command(gateway)

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
    prep: ModuleType,
) -> None:
    # Act
    prompt = prep.prompt()

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


def test_apply_adds_the_job_once_and_check_sees_it(
    prep: ModuleType, schedulers: FakeSchedulers, capsys: pytest.CaptureFixture[str]
) -> None:
    # Act
    first = prep.main(["apply", "--gateway", "corey"], run=schedulers)
    again = prep.main(["apply", "--gateway", "corey"], run=schedulers)
    said = capsys.readouterr().out
    checked = prep.main(["check"], run=schedulers)

    # Assert
    assert (first, again) == (0, 0)
    assert schedulers.added == ["corey"], "apply again changes nothing"
    assert "corey: nothing to write" in said
    [job] = schedulers.jobs["corey"]
    assert job["delivery"]["to"] == "household:franco"
    assert schedulers.jobs["denise"] == [], "Denise's scheduler is never written"
    out = capsys.readouterr().out
    assert "corey (openclaw-gateway): prep packets ok" in out
    assert "denise (openclaw-denise): prep packets missing" in out
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
    prep: ModuleType,
    schedulers: FakeSchedulers,
    capsys: pytest.CaptureFixture[str],
    change: Callable[[dict[str, Any]], object],
    said: str,
) -> None:
    # Arrange
    for persona in ("corey", "denise"):
        prep.main(["apply", "--gateway", persona], run=schedulers)
    change(schedulers.jobs["corey"][0])
    capsys.readouterr()

    # Act
    before = prep.main(["check"], run=schedulers)
    reported = capsys.readouterr().out
    prep.main(["apply", "--gateway", "corey"], run=schedulers)
    capsys.readouterr()
    after = prep.main(["check"], run=schedulers)

    # Assert
    assert before == 1
    assert f"prep packets {said}" in reported
    assert after == 0
    assert len(schedulers.jobs["corey"]) == 1
    assert schedulers.jobs["corey"][0]["name"] == "Prep packets"


def test_a_job_someone_switched_off_is_left_off_and_a_dry_run_writes_nothing(
    prep: ModuleType, schedulers: FakeSchedulers, capsys: pytest.CaptureFixture[str]
) -> None:
    # Arrange
    prep.main(["apply", "--dry-run", "--gateway", "denise"], run=schedulers)
    dry = capsys.readouterr().out
    prep.main(["apply", "--gateway", "corey"], run=schedulers)
    schedulers.jobs["corey"][0]["enabled"] = False
    capsys.readouterr()

    # Act
    result = prep.main(["apply", "--gateway", "corey"], run=schedulers)

    # Assert
    assert "denise: prep packets missing, apply writes it at 0 8 * * *" in dry
    assert "dry run: nothing written." in dry
    assert schedulers.jobs["denise"] == []
    assert result == 0
    assert "switched off, left as it is" in capsys.readouterr().out
    assert schedulers.jobs["corey"][0]["enabled"] is False
    assert schedulers.added == ["corey"]


def test_a_scheduler_that_cannot_be_read_writes_nothing_and_fails(
    prep: ModuleType, schedulers: FakeSchedulers, capsys: pytest.CaptureFixture[str]
) -> None:
    # Arrange
    schedulers.unreadable.add("corey")

    # Act
    result = prep.main(["apply", "--gateway", "corey"], run=schedulers)

    # Assert
    assert result == 1
    assert "would not list its scheduled jobs" in capsys.readouterr().err
    assert schedulers.added == []
