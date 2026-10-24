"""SIQsermon's sermons and study plans, exported once for the household-scripture plugin."""

from __future__ import annotations

import importlib.util
import json
import stat
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "siqsermon-export.py"


@pytest.fixture(scope="module")
def export() -> ModuleType:
    spec = importlib.util.spec_from_file_location("siqsermon_export", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["siqsermon_export"] = module
    spec.loader.exec_module(module)
    return module


class FakeBackend:
    """SIQsermon's backend as the old skill knew it: a login that sets a Secure cookie."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, str] | None, str | None]] = []

    def __call__(
        self, url: str, payload: dict[str, str] | None, cookie: str | None
    ) -> tuple[Any, list[str]]:
        self.calls.append((url, payload, cookie))
        path = url.removeprefix("http://deploy-backend-1:8000")
        if path == "/login":
            return {"ok": True}, ["siqsermon_session=signed.cookie; Path=/; Secure; HttpOnly"]
        assert cookie == "signed.cookie", "every read replays the session cookie"
        answers: dict[str, Any] = {
            "/sermons": {
                "sermons": [{"id": 12, "created_at": "2026-08-03T10:00:00Z", "topic": "Patience"}]
            },
            "/sermons/12": {
                "id": 12,
                "topic": "Patience",
                "passage": "James 5:7-11",
                "created_at": "2026-08-03T10:00:00Z",
                "outline": "1. The farmer waits.\n2. The prophets endured.",
                "illustrations": ["a seed", "a harvest"],
            },
            "/projects": {
                "projects": [{"id": 5, "title": "Romans in a month", "study_method": "inductive"}]
            },
            "/projects/5": {
                "id": 5,
                "title": "Romans in a month",
                "study_method": "inductive",
                "notes": "Day 1",
            },
        }
        return answers[path], []


def test_every_sermon_and_plan_is_written_for_the_plugin_to_keep(
    export: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SIQSERMON_USERNAME", "franco")
    monkeypatch.setenv("SIQSERMON_PASSWORD", "secret")
    backend = FakeBackend()
    out = tmp_path / "import"
    assert export.main(["--out", str(out)], fetch=backend) == 0

    assert backend.calls[0] == (
        "http://deploy-backend-1:8000/login",
        {"username": "franco", "password": "secret"},
        None,
    )
    sermons = json.loads((out / "siqsermon-sermons.json").read_text())
    assert sermons == [
        {
            "kind": "sermon",
            "title": "Patience",
            "detail": "James 5:7-11",
            "body": "## Outline\n\n1. The farmer waits.\n2. The prophets endured.\n\n"
            '## Illustrations\n\n[\n  "a seed",\n  "a harvest"\n]\n\n## Passage\n\nJames 5:7-11',
            "createdAt": "2026-08-03T10:00:00Z",
            "source": "siqsermon",
            "originId": "12",
        }
    ]
    plans = json.loads((out / "siqsermon-plans.json").read_text())
    assert plans[0]["kind"] == "plan"
    assert plans[0]["title"] == "Romans in a month"
    assert plans[0]["detail"] == "inductive"
    assert plans[0]["body"] == "## Notes\n\nDay 1"
    for name in ("siqsermon-sermons.json", "siqsermon-plans.json"):
        assert stat.S_IMODE((out / name).stat().st_mode) == 0o600
    assert sorted(path.name for path in out.iterdir()) == [
        "siqsermon-plans.json",
        "siqsermon-sermons.json",
    ]


def test_without_the_account_it_says_so_and_writes_nothing(
    export: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.delenv("SIQSERMON_USERNAME", raising=False)
    monkeypatch.delenv("SIQSERMON_PASSWORD", raising=False)
    out = tmp_path / "import"
    assert export.main(["--out", str(out)], fetch=FakeBackend()) == 1
    assert "SIQSERMON_USERNAME and SIQSERMON_PASSWORD are not set here" in capsys.readouterr().err
    assert not out.exists()


def test_a_login_without_a_cookie_is_reported(
    export: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("SIQSERMON_USERNAME", "franco")
    monkeypatch.setenv("SIQSERMON_PASSWORD", "secret")

    def no_cookie(
        url: str, payload: dict[str, str] | None, cookie: str | None
    ) -> tuple[Any, list[str]]:
        return {"ok": True}, []

    assert export.main(["--out", str(tmp_path / "import")], fetch=no_cookie) == 1
    assert "issued no session cookie" in capsys.readouterr().err
