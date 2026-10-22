"""openclaw-app-deliveries.py: each job that announces to Telegram, moved to the same people
in the Steward app, with nothing but its delivery changed.

The tests replace `docker exec` with a scheduler that keeps jobs the way `automations edit`
changes them: the delivery flags it is given, and nothing else. The household file is the
made-up example the test suite reads (tests/conftest.py).
"""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-app-deliveries.py"
THE_FAM = "-5100000001"
FRANCO_DM = "7100000001"
GIA_DM = "7100000002"


def _flag(command: list[str], name: str) -> str | None:
    return command[command.index(name) + 1] if name in command else None


@pytest.fixture(scope="module")
def moves() -> ModuleType:
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("openclaw_app_deliveries", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["openclaw_app_deliveries"] = module
    spec.loader.exec_module(module)
    return module


def job(job_id: str, delivery: dict[str, Any] | None, **extra: object) -> dict[str, Any]:
    return {
        "id": job_id,
        "name": f"made-up job {job_id}",
        "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 9 * * 6"},
        "sessionTarget": "current",
        "payload": {"kind": "agentTurn", "message": f"made-up prompt {job_id}"},
        **({"delivery": delivery} if delivery is not None else {}),
        **extra,
    }


def telegram(chat: str) -> dict[str, Any]:
    return {"mode": "announce", "channel": "telegram", "to": chat, "accountId": "bot"}


class FakeSchedulers:
    def __init__(self, jobs: dict[str, list[dict[str, Any]]]) -> None:
        self.jobs = jobs
        self.containers = {"openclaw-gateway": "corey", "openclaw-denise": "denise"}
        self.edits: list[tuple[str, list[str]]] = []
        self.refuse = False

    def __call__(self, command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        persona = self.containers[command[command.index("exec") + 1]]
        kept = self.jobs[persona]
        if "list" in command:
            return subprocess.CompletedProcess(
                command, 0, "Automations\n" + json.dumps({"jobs": kept}), ""
            )
        assert "edit" in command
        if self.refuse:
            return subprocess.CompletedProcess(command, 1, "", "refused")
        job_id = command[command.index("edit") + 1]
        found = next(each for each in kept if each["id"] == job_id)
        found["delivery"] = {
            "mode": "announce" if "--announce" in command else found["delivery"]["mode"],
            "channel": _flag(command, "--channel"),
            "to": _flag(command, "--to"),
            "accountId": _flag(command, "--account"),
        }
        self.edits.append((persona, command[command.index("edit") :]))
        return subprocess.CompletedProcess(command, 0, "{}", "")


def box() -> FakeSchedulers:
    return FakeSchedulers(
        {
            "corey": [
                job("c-own", telegram(FRANCO_DM)),
                job("c-fam", telegram(f"telegram:{THE_FAM}")),
                job(
                    "c-app", {"mode": "announce", "channel": "household", "to": "household:franco"}
                ),
                job("c-quiet", {"mode": "none"}),
                job("c-off", telegram(THE_FAM), enabled=False),
            ],
            "denise": [
                job("d-own", telegram(GIA_DM)),
                job("d-own-2", {"mode": "announce", "channel": "last", "to": f"tg:{GIA_DM}"}),
            ],
        }
    )


def test_each_telegram_job_moves_to_the_same_people_in_the_app_and_nothing_else_changes(
    moves: ModuleType,
) -> None:
    # Arrange
    schedulers = box()
    before = copy.deepcopy(schedulers.jobs)

    # Act
    corey = moves.main(["apply", "--gateway", "corey"], run=schedulers)
    denise = moves.main(["apply", "--gateway", "denise"], run=schedulers)

    # Assert
    assert (corey, denise) == (0, 0)
    targets = {
        each["id"]: each["delivery"].get("to")
        for persona in ("corey", "denise")
        for each in schedulers.jobs[persona]
    }
    assert targets == {
        "c-own": "household:franco",
        "c-fam": "household:family",
        "c-app": "household:franco",
        "c-quiet": None,
        "c-off": "household:family",
        "d-own": "household:gia",
        "d-own-2": "household:gia",
    }
    for persona in ("corey", "denise"):
        for was, now in zip(before[persona], schedulers.jobs[persona], strict=True):
            assert {key: value for key, value in was.items() if key != "delivery"} == {
                key: value for key, value in now.items() if key != "delivery"
            }, "only the delivery changes: name, prompt, schedule and session stay"
    moved = [command for _, command in schedulers.edits]
    assert all(_flag(command, "--account") == "default" for command in moved)
    assert all("--message" not in command and "--name" not in command for command in moved)


def test_check_reads_telegram_jobs_until_they_are_moved(
    moves: ModuleType, capsys: pytest.CaptureFixture[str]
) -> None:
    # Arrange
    schedulers = box()

    # Act
    before = moves.main(["check"], run=schedulers)
    said = capsys.readouterr().out
    for persona in ("corey", "denise"):
        moves.main(["apply", "--gateway", persona], run=schedulers)
    capsys.readouterr()
    after = moves.main(["check"], run=schedulers)

    # Assert
    assert before == 1
    assert (
        "corey (openclaw-gateway): 3 to Telegram (0 with no clear app home), 1 to the app" in said
    )
    assert (
        "denise (openclaw-denise): 2 to Telegram (0 with no clear app home), 0 to the app" in said
    )
    assert after == 0
    assert "corey (openclaw-gateway): 0 to Telegram" in capsys.readouterr().out


@pytest.mark.parametrize(
    "chat",
    [GIA_DM, "-5999999999", "@somechannel"],
    ids=["the other parent's own chat", "another group", "a channel by name"],
)
def test_a_job_with_no_clear_home_in_the_app_stops_the_gateway_with_nothing_written(
    moves: ModuleType, capsys: pytest.CaptureFixture[str], chat: str
) -> None:
    # Arrange: on Corey's gateway, a job to Gia's own chat would be hers, not Franco's.
    schedulers = box()
    schedulers.jobs["corey"].append(job("c-unclear", telegram(chat)))

    # Act
    result = moves.main(["apply", "--gateway", "corey"], run=schedulers)

    # Assert
    assert result == 1
    assert "1 job(s) deliver to a Telegram chat with no clear home" in capsys.readouterr().err
    assert schedulers.edits == []


def test_a_dry_run_writes_nothing_and_a_refused_edit_fails(
    moves: ModuleType, capsys: pytest.CaptureFixture[str]
) -> None:
    # Arrange
    schedulers = box()

    # Act
    dry = moves.main(["apply", "--gateway", "corey", "--dry-run"], run=schedulers)
    said = capsys.readouterr().out
    schedulers.refuse = True
    refused = moves.main(["apply", "--gateway", "corey"], run=schedulers)

    # Assert
    assert dry == 0
    assert "corey: 3 job(s) to move: 2 to the family room, 1 to franco's own thread" in said
    assert "dry run: nothing written." in said
    assert refused == 1
    assert "refused to move a job's delivery" in capsys.readouterr().err
