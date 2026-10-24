"""A new household's answers, asked once on its own box."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
from collections.abc import Iterator
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "household-setup.py"
KEY = "sk-or-v1-" + "0123456789abcdef" * 4


@pytest.fixture
def setup(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    monkeypatch.setenv("HOUSEHOLD_ENV_ROOT", str(tmp_path / "etc"))
    sys.path.insert(0, str(SCRIPT.parent))
    import household_file

    monkeypatch.setattr(household_file, "ENV_ROOT", tmp_path / "etc")
    spec = importlib.util.spec_from_file_location("household_setup", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scripted(*answers: str) -> tuple[list[str], object]:
    asked: list[str] = []
    replies: Iterator[str] = iter(answers)

    def ask(prompt: str) -> str:
        asked.append(prompt)
        return next(replies)

    return asked, ask


# The two adults and their assistants, then the approver, the tailnet name, the Bible and the
# time zone, an empty answer taking what is offered.
ANSWERS = ("Marina", "Ada", "Steve", "Rex", "", "", "NIV", "")


def run(
    setup: ModuleType, tmp_path: Path, answers: tuple[str, ...], keys: tuple[str, ...], **kw: object
) -> int:
    _, ask = scripted(*answers)
    _, secret = scripted(*keys)
    options = {
        "path": tmp_path / "etc" / "household.json",
        "key_only": False,
        "timezone": "America/Denver",
        "host": "box.tail1234.ts.net",
        "known": {"googleClientId": "1-abc.apps.googleusercontent.com"},
    }
    options.update(kw)
    code: int = setup.setup(ask=ask, secret=secret, **options)
    return code


def test_the_answers_become_the_household_file_and_the_key_each_env_file(
    setup: ModuleType, tmp_path: Path
) -> None:
    assert run(setup, tmp_path, ANSWERS, (KEY,)) == 0

    path = tmp_path / "etc" / "household.json"
    written = json.loads(path.read_text(encoding="utf-8"))
    assert written["members"] == [
        {"person": "marina", "name": "Marina", "assistant": "ada", "assistantName": "Ada"},
        {"person": "steve", "name": "Steve", "assistant": "rex", "assistantName": "Rex"},
    ]
    assert written["approver"] == "marina"
    assert written["gatewayHost"] == "box.tail1234.ts.net"
    assert written["timezone"] == "America/Denver"
    assert written["bibleVersion"] == "NIV"
    assert "pushRelay" not in written
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    for state in ("openclaw-ada", "openclaw-rex"):
        env = tmp_path / "etc" / f"{state}.env"
        assert env.read_text(encoding="utf-8") == f"OPENROUTER_API_KEY={KEY}\n"
        assert stat.S_IMODE(env.stat().st_mode) == 0o600


def test_the_publishers_relay_names_the_household_there(setup: ModuleType, tmp_path: Path) -> None:
    known = {
        "googleClientId": "1-abc.apps.googleusercontent.com",
        "pushRelay": "https://push.example.com",
    }

    assert run(setup, tmp_path, (*ANSWERS, ""), (KEY,), known=known) == 0

    written = json.loads((tmp_path / "etc" / "household.json").read_text(encoding="utf-8"))
    assert written["pushRelay"] == {"url": "https://push.example.com", "household": "marina-steve"}


def test_a_key_that_is_not_openrouters_is_asked_again_and_never_printed(
    setup: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert run(setup, tmp_path, ANSWERS, ("hunter2", KEY)) == 0

    out = capsys.readouterr().out
    assert "does not look like an OpenRouter key" in out
    assert KEY not in out and "hunter2" not in out


def test_a_household_file_already_there_is_kept_and_only_a_missing_key_is_asked(
    setup: ModuleType, tmp_path: Path
) -> None:
    path = tmp_path / "etc" / "household.json"
    path.parent.mkdir()
    example = (ROOT / "deploy" / "household.new.example.json").read_text(encoding="utf-8")
    path.write_text(example, encoding="utf-8")
    (tmp_path / "etc" / "openclaw-ada.env").write_text(
        f"OPENCLAW_GATEWAY_TOKEN=t\nOPENROUTER_API_KEY={KEY}\n", encoding="utf-8"
    )
    (tmp_path / "etc" / "openclaw-rex.env").write_text(
        "OPENCLAW_GATEWAY_TOKEN=t\n", encoding="utf-8"
    )

    assert run(setup, tmp_path, (), (KEY,)) == 0

    assert path.read_text(encoding="utf-8") == example
    assert (tmp_path / "etc" / "openclaw-rex.env").read_text(encoding="utf-8") == (
        f"OPENCLAW_GATEWAY_TOKEN=t\nOPENROUTER_API_KEY={KEY}\n"
    )


def test_a_new_key_replaces_the_old_one_in_every_env_file(
    setup: ModuleType, tmp_path: Path
) -> None:
    run(setup, tmp_path, ANSWERS, (KEY,))
    newer = KEY.replace("0123", "9876")

    assert run(setup, tmp_path, (), (newer,), key_only=True) == 0

    for state in ("openclaw-ada", "openclaw-rex"):
        text = (tmp_path / "etc" / f"{state}.env").read_text(encoding="utf-8")
        assert text == f"OPENROUTER_API_KEY={newer}\n"


def test_two_people_with_one_name_still_get_ids_of_their_own(
    setup: ModuleType, tmp_path: Path
) -> None:
    answers = ("Sam", "Sam", "Sam", "Ada", "", "", "BSB", "")

    assert run(setup, tmp_path, answers, (KEY,)) == 0

    written = json.loads((tmp_path / "etc" / "household.json").read_text(encoding="utf-8"))
    ids = [m["person"] for m in written["members"]] + [m["assistant"] for m in written["members"]]
    assert len(set(ids)) == 4


@pytest.mark.parametrize(
    ("name", "expected"), [("Mary Jo", "mary-jo"), ("Zoë", "zoe"), ("José", "jose"), ("42", "x-42")]
)
def test_a_name_becomes_an_id_the_file_allows(setup: ModuleType, name: str, expected: str) -> None:
    assert setup.slug(name) == expected


def test_the_publisher_has_not_filled_anything_in_yet(setup: ModuleType) -> None:
    assert setup.publisher() == {}
    assert os.path.isfile(ROOT / "deploy" / "publisher.json")


def test_an_answer_the_file_would_refuse_is_asked_again_at_once(
    setup: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    answers = (
        "José",
        "<b>Ada</b>",
        "Ada",
        "Zoë",
        "R2-D2",
        "",
        "",
        "NIV",
        "EST",
        "America/New_York",
    )

    assert run(setup, tmp_path, answers, (KEY,)) == 0

    written = json.loads((tmp_path / "etc" / "household.json").read_text(encoding="utf-8"))
    assert [(m["person"], m["name"], m["assistantName"]) for m in written["members"]] == [
        ("jose", "José", "Ada"),
        ("zoe", "Zoë", "R2-D2"),
    ]
    assert written["timezone"] == "America/New_York"
    out = capsys.readouterr().out
    assert "a name of up to 40 letters" in out
    assert "a time zone like America/New_York" in out
