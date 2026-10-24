"""A person's first iPhone gets its setup link from their assistant's gateway."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "household-pair.py"
LINK = "https://household.example.ts.net:18790/household-app/pair#ABC123"


@pytest.fixture(scope="module")
def pair() -> ModuleType:
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("household_pair", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def answering(stdout: str, code: int = 0) -> tuple[list[list[str]], object]:
    calls: list[list[str]] = []

    def run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        return subprocess.CompletedProcess(command, code, stdout, "")

    return calls, run


def test_a_person_or_their_assistant_names_the_gateway(pair: ModuleType) -> None:
    assert pair.gateway_named("Gia").container == "openclaw-denise"
    assert pair.gateway_named("corey").container == "openclaw-gateway"
    assert pair.gateway_named("ada") is None
    # By name as shown, as the setup's last words tell whoever runs the box.
    assert pair.gateway_named("  DENISE ").container == "openclaw-denise"


def test_the_link_comes_from_the_gateways_pair_call(
    pair: ModuleType, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(pair.shutil, "which", lambda _: None)
    calls, run = answering(f'banner\n{{"link": "{LINK}", "setupCode": "ABC123"}}\n')

    assert pair.main(["gia"], run=run) == 0

    assert calls[0][:3] == ["docker", "exec", "openclaw-denise"]
    assert "household-app.pair" in calls[0]
    assert LINK in capsys.readouterr().out


def test_a_gateway_that_gives_no_link_fails(pair: ModuleType) -> None:
    _, run = answering("gateway not reachable", code=1)

    assert pair.main(["franco"], run=run) == 1
