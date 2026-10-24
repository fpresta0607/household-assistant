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
        (lambda data: data.update(sharedCalendar="Family"), "sharedCalendar is not an object"),
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


NEW_EXAMPLE = ROOT / "deploy" / "household.new.example.json"


def test_a_new_households_example_reads_with_its_zone_and_push_relay() -> None:
    household = load_household(NEW_EXAMPLE)

    assert [(m.person, m.assistant, m.container, m.port) for m in household.members] == [
        ("marina", "ada", "openclaw-ada", 18789),
        ("steve", "rex", "openclaw-rex", 18790),
    ]
    assert household.timezone == "America/New_York"
    assert household.push_relay is not None
    assert (household.push_relay.url, household.push_relay.household) == (
        "https://push.example.com",
        "marina-steve",
    )
    assert household.names_members


def test_the_first_households_file_needs_no_zone_or_relay(tmp_path: Path) -> None:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    del data["members"]
    del data["timezone"]

    household = load_household(written(tmp_path, data))

    assert household.timezone == "America/Chicago"
    assert household.push_relay is None
    assert not household.names_members


@pytest.mark.parametrize(
    ("change", "message"),
    [
        (lambda data: data.update(timezone="Mars/Olympus Mons"), "a time zone"),
        (lambda data: data.update(timezone="../../etc/passwd"), "a time zone"),
        (lambda data: data.update(pushRelay="https://push.example.com"), "not an object"),
        (
            lambda data: data.update(
                pushRelay={"url": "http://push.example.com", "household": "x"}
            ),
            "a push relay address",
        ),
        (
            lambda data: data.update(pushRelay={"url": "https://push.example.com"}),
            "a push relay household",
        ),
        (lambda data: data["members"][0].update(memory="lots"), "a memory limit"),
    ],
)
def test_a_zone_relay_or_memory_a_box_could_not_use_is_refused(
    tmp_path: Path, change: Callable[[dict[str, Any]], object], message: str
) -> None:
    data = json.loads(NEW_EXAMPLE.read_text(encoding="utf-8"))
    change(data)

    with pytest.raises(UnsupportedConfig, match=message):
        load_household(written(tmp_path, data))


def test_each_member_has_its_own_env_file_secrets_codex_and_bin() -> None:
    first, second = load_household(EXAMPLE).members
    new_first, _ = load_household(NEW_EXAMPLE).members
    root = Path("/var/lib/household-assistant")

    assert (first.env_file, first.secrets_dir, first.codex_dir, first.bin_dir) == (
        Path("/etc/household-assistant/openclaw.env"),
        root / "openclaw-auth-secrets",
        root / "codex",
        root / "bin",
    )
    assert (second.env_file, second.secrets_dir, second.codex_dir, second.bin_dir) == (
        Path("/etc/household-assistant/openclaw-denise.env"),
        root / "openclaw-denise-auth-secrets",
        root / "codex-denise",
        root / "bin-denise",
    )
    assert (new_first.env_file, new_first.codex_dir, new_first.bin_dir, new_first.memory) == (
        Path("/etc/household-assistant/openclaw-ada.env"),
        root / "codex-ada",
        root / "bin-ada",
        "1536M",
    )


def test_the_shell_installers_read_the_members_from_the_command_line(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    import household_file

    monkeypatch.setattr(household_file, "HOUSEHOLD_FILE", NEW_EXAMPLE)

    assert household_file.main(["members"]) == 0
    lines = [line.split("\t") for line in capsys.readouterr().out.splitlines()]
    assert [line[:5] for line in lines] == [
        ["marina", "ada", "openclaw-ada", "openclaw-ada", "18789"],
        ["steve", "rex", "openclaw-rex", "openclaw-rex", "18790"],
    ]
    assert lines[1][6] == "/etc/household-assistant/openclaw-rex.env"
    assert household_file.main(["has-members"]) == 0
    assert household_file.main(["something"]) == 2


def test_a_household_that_connects_its_calendars_through_the_app_names_none(
    tmp_path: Path,
) -> None:
    data = json.loads(NEW_EXAMPLE.read_text(encoding="utf-8"))
    del data["sharedCalendar"]

    household = load_household(written(tmp_path, data))

    assert (household.shared_calendar, household.shared_calendar_apple_id) == ("", "")
