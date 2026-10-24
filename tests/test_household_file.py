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
        (lambda data: data.pop("gatewayHost"), "has no gatewayHost"),
        (lambda data: data.update(googleClientId=7), "has no googleClientId"),
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
        load_household(written(tmp_path, ["gatewayHost"]))


def test_the_telegram_identifiers_a_file_from_before_still_names_are_not_read(
    tmp_path: Path,
) -> None:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    data["familyGroup"] = "-5100000001"
    data["telegram"] = {"franco": "7100000001"}

    assert load_household(written(tmp_path, data)) == load_household(EXAMPLE)


def test_a_missing_household_file_stops_the_installer(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_household(tmp_path / "household.json")


# MARK: - Members


def test_the_example_names_franco_and_gia_with_their_assistants_and_gateways() -> None:
    household = load_household(EXAMPLE)

    assert [(m.person, m.name, m.assistant, m.assistant_name) for m in household.members] == [
        ("franco", "Franco", "corey", "Corey"),
        ("gia", "Gia", "denise", "Denise"),
    ]
    assert [(m.container, m.state, m.port) for m in household.members] == [
        ("openclaw-gateway", "openclaw", 18789),
        ("openclaw-denise", "openclaw-denise", 18790),
    ]
    assert household.approver == "franco"
    assert household.member("denise").person == "gia"
    with pytest.raises(UnsupportedConfig, match="no member"):
        household.member("ada")


def test_the_gateways_are_the_members(tmp_path: Path) -> None:
    import gateway_config

    assert [(g.persona, g.container, g.state.name, g.person) for g in gateway_config.GATEWAYS] == [
        ("corey", "openclaw-gateway", "openclaw", "franco"),
        ("denise", "openclaw-denise", "openclaw-denise", "gia"),
    ]


def test_a_new_household_names_its_people_and_assistants_and_takes_the_rest_by_default(
    tmp_path: Path,
) -> None:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    data["members"] = [
        {"person": "marina", "assistant": "ada"},
        {"person": "steve", "name": "Steve", "assistant": "rex", "assistantName": "Rex"},
    ]
    del data["approver"]

    household = load_household(written(tmp_path, data))

    assert [(m.name, m.assistant_name) for m in household.members] == [
        ("Marina", "Ada"),
        ("Steve", "Rex"),
    ]
    assert [(m.container, m.state, m.port) for m in household.members] == [
        ("openclaw-ada", "openclaw-ada", 18789),
        ("openclaw-rex", "openclaw-rex", 18790),
    ]
    assert household.approver == "marina"


def test_a_file_from_before_members_is_the_first_households_own(tmp_path: Path) -> None:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    del data["members"]
    del data["approver"]

    assert load_household(written(tmp_path, data)).members == load_household(EXAMPLE).members


@pytest.mark.parametrize(
    ("members", "message"),
    [
        ([{"person": "marina", "assistant": "ada"}], "exactly 2 members"),
        ([{"person": "a", "assistant": "b"}] * 3, "exactly 2 members"),
        ("marina", "exactly 2 members"),
        (["marina", {"person": "steve", "assistant": "rex"}], "member 1 is not an object"),
        (
            [{"person": "Marina", "assistant": "ada"}, {"person": "steve", "assistant": "rex"}],
            "a person id",
        ),
        (
            [{"person": "marina", "assistant": "ada"}, {"person": "steve", "assistant": "ada"}],
            "share a container",
        ),
        (
            [{"person": "marina", "assistant": "ada"}, {"person": "ada", "assistant": "rex"}],
            "id of its own",
        ),
        (
            [
                {"person": "marina", "assistant": "ada", "port": 18790},
                {"person": "steve", "assistant": "rex"},
            ],
            "share a port",
        ),
        (
            [
                {"person": "marina", "assistant": "ada", "port": 80},
                {"person": "steve", "assistant": "rex"},
            ],
            "port",
        ),
        (
            [
                {"person": "marina", "assistant": "ada", "container": "../etc"},
                {"person": "steve", "assistant": "rex"},
            ],
            "a container",
        ),
        (
            [
                {"person": "marina", "assistant": "ada", "name": "Marina<script>"},
                {"person": "steve", "assistant": "rex"},
            ],
            "a name",
        ),
    ],
)
def test_members_a_box_could_not_run_are_refused(
    tmp_path: Path, members: object, message: str
) -> None:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    data["members"] = members
    data.pop("approver")
    with pytest.raises(UnsupportedConfig, match=message):
        load_household(written(tmp_path, data))


def test_an_approver_who_is_not_a_member_is_refused(tmp_path: Path) -> None:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    data["approver"] = "steve"
    with pytest.raises(UnsupportedConfig, match="approver"):
        load_household(written(tmp_path, data))
