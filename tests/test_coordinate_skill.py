"""The skill the assistants actually run, against the reader the daemon actually uses.

The skill writes and the daemon reads, in two different processes on two different
sides of a container boundary, so the test runs the real file as a subprocess and
answers it with :func:`household.openclaw.read_outbox`. If the two ever stop agreeing
on the file, this goes red rather than the relay going quiet on the box.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import time
from pathlib import Path
from types import ModuleType

import pytest

from household.openclaw import (
    GatewayContainer,
    OutboxBoundaryError,
    open_outbox,
    read_outbox,
)

SKILL = Path(__file__).resolve().parents[1] / "deploy/openclaw/skills/coordinate/coordinate.py"


def run_ask(home: Path, text: str) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [sys.executable, str(SKILL), "ask", text],
        env={"OPENCLAW_HOME": str(home), "PATH": "", "SYSTEMROOT": ""},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def await_request(gateway: GatewayContainer) -> tuple[Path, str]:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        opened = open_outbox(gateway)
        if opened is not None:
            with opened as outbox:
                found = read_outbox(outbox, gateway.persona_id)
            if found:
                waiting = found[0]
                return gateway.outbox / waiting.name, waiting.request.text
        time.sleep(0.05)
    raise AssertionError("the skill never wrote a request the daemon could read")


def answer(path: Path, payload: dict[str, str]) -> None:
    path.with_suffix(".result.json").write_text(json.dumps(payload), encoding="utf-8")
    path.unlink()


@pytest.fixture
def gateway(tmp_path: Path) -> GatewayContainer:
    gateway = GatewayContainer("corey", "openclaw-gateway", tmp_path / ".openclaw")
    try:
        open_outbox(gateway)
    except OutboxBoundaryError as error:
        pytest.skip(str(error))
    return gateway


@pytest.fixture
def skill() -> ModuleType:
    """The same file, imported, for the waiting that would otherwise take a minute."""
    spec = importlib.util.spec_from_file_location("coordinate_skill", SKILL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_skill_writes_what_the_daemon_reads(tmp_path: Path, gateway: GatewayContainer) -> None:
    process = run_ask(tmp_path, "Denise, is Gia free Friday after six?")

    path, text = await_request(gateway)
    assert text == "Denise, is Gia free Friday after six?"
    answer(path, {"status": "relayed", "turn_id": "abc", "posted_at": "2026-09-19T18:00:00+00:00"})

    stdout, _ = process.communicate(timeout=30)
    assert process.returncode == 0
    reported = json.loads(stdout)
    assert reported["status"] == "relayed"
    assert path.name == f"{reported['request_id']}.json"


def test_a_refusal_comes_back_as_a_failure(tmp_path: Path, gateway: GatewayContainer) -> None:
    """A non-zero exit is what stops an assistant treating a refusal as a delivery."""
    process = run_ask(tmp_path, "Denise, one more thing")

    path, _ = await_request(gateway)
    answer(path, {"status": "refused", "reason": "TurnCapReached", "detail": "two is the cap"})

    stdout, _ = process.communicate(timeout=30)
    assert process.returncode == 1
    assert json.loads(stdout)["reason"] == "TurnCapReached"


def test_a_delivery_that_broke_after_the_post_is_a_failure_too(
    tmp_path: Path, gateway: GatewayContainer
) -> None:
    """The group has already read it, so the assistant must not treat this as a send."""
    process = run_ask(tmp_path, "Denise, is Gia free Friday after six?")

    path, _ = await_request(gateway)
    answer(path, {"status": "unconfirmed", "reason": "RuntimeError", "detail": "denise is down"})

    stdout, _ = process.communicate(timeout=30)
    assert process.returncode == 1
    assert json.loads(stdout)["status"] == "unconfirmed"


def test_giving_up_takes_the_request_back_so_it_can_never_be_posted_later(
    skill: ModuleType,
    gateway: GatewayContainer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A request left in the outbox was posted by a later tick, after we gave up.

    The family then read the failure notice and, minutes later, the message it was
    about. Withdrawing it is what makes `unsent` true when we say it.
    """
    monkeypatch.setattr(skill, "OUTBOX", gateway.outbox)
    monkeypatch.setattr(skill, "WAIT_SECONDS", 0)

    assert skill.ask("Denise, is Gia free Friday after six?") == 1

    printed = json.loads(capsys.readouterr().out)
    assert printed["status"] == "unsent"
    opened = open_outbox(gateway)
    assert opened is not None
    with opened as outbox:
        assert read_outbox(outbox, gateway.persona_id) == []

    # And it stays unsent. The relay never answers a request it did not get, so a
    # withdrawal that only printed would check back as `unconfirmed` forever, which
    # is the opposite instruction to the one the assistant was just given.
    assert skill.check(printed["request_id"]) == 1
    rechecked = json.loads(capsys.readouterr().out)
    assert rechecked["status"] == "unsent"
    assert rechecked["detail"] == printed["detail"]

    # Twice more, because a record destroyed by reading it is not a record.
    skill.check(printed["request_id"])
    assert json.loads(capsys.readouterr().out)["status"] == "unsent"


def test_no_answer_on_disk_claims_nothing_about_what_happened(
    skill: ModuleType, gateway: GatewayContainer
) -> None:
    """Two different stories look identical from here, so it tells neither.

    The relay may be carrying the words right now, or it may have answered an hour
    ago and had that answer pruned. An earlier version asserted the first, which
    silently became false once the pruning caught up and turned an outcome the relay
    had established into the opposite instruction.
    """
    gateway.outbox.mkdir(parents=True)

    given_up = skill._gave_up(
        gateway.outbox / "req.json", gateway.outbox / "req.result.json", "req"
    )

    assert given_up["status"] == "unconfirmed"
    assert "check req" in given_up["detail"]
    # It must not claim the relay still holds them, because it cannot know that.
    assert "has not left an answer" in given_up["reason"]


def test_an_answer_that_lands_while_we_race_for_the_request_is_reported(
    skill: ModuleType, gateway: GatewayContainer
) -> None:
    """The relay claimed it and answered in the same breath. That answer is the truth.

    Claiming no answer here would tell the assistant it knows nothing, while the
    answer the relay actually wrote sat unread beside it.

    Asserted on the whole answer rather than on its status. Collapsing five states
    into four made `unconfirmed` the status of both branches, so a test that checked
    only the status stopped being able to fail for the regression it exists to catch:
    deleting the re-check left it green. The relay's own reason and detail are what
    tell the two apart.
    """
    gateway.outbox.mkdir(parents=True)
    written_by_the_relay = {
        "status": "relayed",
        "turn_id": "4e2329f3",
        "posted_at": "2026-09-19T15:38:13+00:00",
    }
    (gateway.outbox / "req.result.json").write_text(
        json.dumps(written_by_the_relay), encoding="utf-8"
    )

    given_up = skill._gave_up(
        gateway.outbox / "req.json", gateway.outbox / "req.result.json", "req"
    )

    assert given_up == written_by_the_relay
    assert given_up != skill._still_unknown("req")


def test_check_reads_the_answer_the_ask_gave_up_waiting_for(
    skill: ModuleType,
    gateway: GatewayContainer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An answer the ask never saw has to be reachable afterwards, or it is nothing.

    Twice, because an answer that a read destroys is not an answer. `unconfirmed` is
    the one the assistant checks again before saying anything in the group, and a
    read that spent the real answer would hand it `unconfirmed` forever instead.
    """
    monkeypatch.setattr(skill, "OUTBOX", gateway.outbox)
    gateway.outbox.mkdir(parents=True)
    (gateway.outbox / "req.result.json").write_text(
        json.dumps({"status": "unconfirmed", "reason": "RuntimeError", "detail": "denise is down"}),
        encoding="utf-8",
    )

    assert skill.main(["check", "req"]) == 1
    first = json.loads(capsys.readouterr().out)
    assert skill.main(["check", "req"]) == 1
    second = json.loads(capsys.readouterr().out)

    assert first["status"] == "unconfirmed"
    assert first["request_id"] == "req"
    assert second == first


def test_a_torn_or_missing_answer_is_read_as_not_yet(skill: ModuleType, tmp_path: Path) -> None:
    """One unreadable poll is a reason to look again, not to crash the assistant."""
    answer = tmp_path / "abc.result.json"

    assert skill._answer(answer) is None

    answer.write_text("", encoding="utf-8")
    assert skill._answer(answer) is None

    answer.write_text('{"status": "rela', encoding="utf-8")
    assert skill._answer(answer) is None

    answer.write_text(json.dumps({"status": "relayed"}), encoding="utf-8")
    assert skill._answer(answer) == {"status": "relayed"}
