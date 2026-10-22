"""The box's household file, which holds the identifiers the repository does not."""

from __future__ import annotations

import json
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from gateway_config import UnsupportedConfig, load_household  # noqa: E402

EXAMPLE = ROOT / "deploy" / "household.example.json"


def written(tmp_path: Path, content: object) -> Path:
    path = tmp_path / "household.json"
    path.write_text(json.dumps(content), encoding="utf-8")
    return path


def test_the_example_reads_as_the_household() -> None:
    household = load_household(EXAMPLE)

    assert household.family_group == "-5100000001"
    assert household.telegram_ids == {"franco": "7100000001", "gia": "7100000002"}
    assert household.gateway_host == "household.example.ts.net"
    assert household.google_client_id.endswith(".apps.googleusercontent.com")
    assert household.shared_calendar == "Family Calendar"
    assert household.shared_calendar_apple_id == "owner@example.com"
    assert household.bible_version == "NIV"


def test_the_tests_read_the_example() -> None:
    import gateway_config

    assert gateway_config.HOUSEHOLD_FILE == EXAMPLE


@pytest.mark.parametrize(
    ("change", "message"),
    [
        (lambda data: data.pop("familyGroup"), "has no familyGroup"),
        (lambda data: data.update(familyGroup=""), "has no familyGroup"),
        (lambda data: data.pop("gatewayHost"), "has no gatewayHost"),
        (lambda data: data.update(googleClientId=7), "has no googleClientId"),
        (lambda data: data["telegram"].pop("gia"), "exactly franco, gia"),
        (lambda data: data["telegram"].update(denise="7100000003"), "exactly franco, gia"),
        (lambda data: data["telegram"].update(franco=7100000001), "has no franco"),
        (lambda data: data.pop("sharedCalendar"), "has no sharedCalendar"),
        (lambda data: data["sharedCalendar"].pop("appleId"), "has no appleId"),
        (lambda data: data.pop("bibleVersion"), "has no bibleVersion"),
    ],
)
def test_a_household_file_missing_a_value_is_refused(
    tmp_path: Path, change: Callable[[dict[str, Any]], object], message: str
) -> None:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    change(data)

    with pytest.raises(UnsupportedConfig, match=message):
        load_household(written(tmp_path, data))


def test_a_household_file_that_is_not_an_object_is_refused(tmp_path: Path) -> None:
    with pytest.raises(UnsupportedConfig, match="not a JSON object"):
        load_household(written(tmp_path, ["familyGroup"]))


def test_a_missing_household_file_stops_the_installer(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_household(tmp_path / "household.json")
