"""The household file: who lives here, their assistants, and what the box needs to know.

It lives on the box in a root-only file the repository does not hold,
/etc/household-assistant/household.json; deploy/household.example.json shows its shape,
and HOUSEHOLD_FILE points the test suite at that example.

Each adult of the household is a member with an assistant of their own, on a gateway of
their own. The household app's family room is shared by exactly two people and their two
assistants, so a household file names two members.

This module needs nothing but the standard library, so the installers that copy
themselves to the box, and run from there, can carry it beside them. The shell installers
read the members through it too:

    python3 scripts/household_file.py members      # one tab-separated line per member
    python3 scripts/household_file.py has-members  # exits 0 when the file names them
    python3 scripts/household_file.py has-push-relay  # exits 0 when it names a push relay
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HOUSEHOLD_FILE = Path(os.environ.get("HOUSEHOLD_FILE", "/etc/household-assistant/household.json"))
# Where each gateway's root-only env file lives, and its state, one of each per member.
# Both overridable, as the household file is, so the tests can point them at a scratch tree.
ENV_ROOT = Path(os.environ.get("HOUSEHOLD_ENV_ROOT", "/etc/household-assistant"))
STATE_ROOT = Path(os.environ.get("HOUSEHOLD_STATE_ROOT", "/var/lib/household-assistant"))
# The first gateway's port on the box's loopback; each member after it takes the next one.
FIRST_PORT = 18789
MEMBERS = 2
# What a gateway may hold in memory when the household file does not say, which leaves a
# 4 GB box room for both and the system.
MEMORY = "1536M"
TIMEZONE = "America/Chicago"
# The network a household's gateways share on a box whose file names its members, on a
# subnet docker's default pools do not hand out, so the host's address on it, which each
# gateway trusts as the tailnet proxy in front of it, is known before they start.
GATEWAY_SUBNET = "172.31.240.0/24"
GATEWAY_BRIDGE = "172.31.240.1"

ID = re.compile(r"[a-z][a-z0-9-]{0,31}")
NAME = re.compile(r"[A-Za-z][A-Za-z .'-]{0,39}")
DIRECTORY = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}")
SIZE = re.compile(r"[1-9][0-9]{2,4}M")
ZONE = re.compile(r"UTC|[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+){1,2}")
RELAY_URL = re.compile(r"https://[a-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._/-]*)?")


class UnsupportedConfig(ValueError):
    """A config shape a script does not evaluate, rather than guess at."""


@dataclass(frozen=True, slots=True)
class Member:
    """One adult of the household, their assistant, and the gateway it runs on."""

    person: str
    name: str
    assistant: str
    assistant_name: str
    # The gateway's container, its state directory under STATE_ROOT, and the port the box
    # publishes it on, which the phones' tailnet route reaches.
    container: str
    state: str
    port: int
    # The most memory the gateway's container may hold, as compose writes it.
    memory: str = MEMORY

    @property
    def state_dir(self) -> Path:
        return STATE_ROOT / self.state

    @property
    def env_file(self) -> Path:
        """The gateway's root-only env file: its token, and its keys."""
        return ENV_ROOT / f"{self.state}.env"

    @property
    def _suffix(self) -> str:
        # The first household's Corey keeps codex and bin; every other gateway's are
        # named after its state, as Denise's codex-denise and bin-denise are.
        if self.state == "openclaw":
            return ""
        return "-" + self.state.removeprefix("openclaw-")

    @property
    def secrets_dir(self) -> Path:
        """The key that recovers OpenClaw's legacy encrypted sidecar credentials."""
        return STATE_ROOT / f"{self.state}-auth-secrets"

    @property
    def codex_dir(self) -> Path:
        return STATE_ROOT / f"codex{self._suffix}"

    @property
    def bin_dir(self) -> Path:
        """Binaries the gateway's bundled skills need, beside its state."""
        return STATE_ROOT / f"bin{self._suffix}"


# A household file written before it named its members is the first household's own:
# Franco with Corey and Gia with Denise, on the gateways their box already runs.
LEGACY_MEMBERS = (
    Member("franco", "Franco", "corey", "Corey", "openclaw-gateway", "openclaw", 18789, "1664M"),
    Member("gia", "Gia", "denise", "Denise", "openclaw-denise", "openclaw-denise", 18790, "2048M"),
)


@dataclass(frozen=True, slots=True)
class PushRelay:
    """The app publisher's push relay, which holds the app's Apple push key so that a
    household's box never does, and the name the household is known by there."""

    url: str
    household: str


@dataclass(frozen=True, slots=True)
class Household:
    """The members, who lets in a phone that signed in with Apple and nobody linked, where
    the phones reach the gateways, the app's Google client, the calendar the planner reads,
    the Bible edition the household reads, the household's time zone and the push relay
    its phones are notified through, if any. The Telegram group and accounts a file
    written before Telegram was retired still names are not read."""

    members: tuple[Member, ...]
    approver: str
    gateway_host: str
    google_client_id: str
    shared_calendar: str
    shared_calendar_apple_id: str
    bible_version: str
    timezone: str = TIMEZONE
    push_relay: PushRelay | None = None
    # Whether the file names its members. One written before it did is the first
    # household's, whose box runs the compose file the repository holds.
    names_members: bool = False

    def member(self, persona: str) -> Member:
        """The member whose assistant is `persona`."""
        found = next((member for member in self.members if member.assistant == persona), None)
        if found is None:
            raise UnsupportedConfig(f"no member of the household has the assistant {persona!r}")
        return found


def _text(section: dict[str, Any], key: str, path: Path) -> str:
    value = section.get(key)
    if not isinstance(value, str) or not value:
        raise UnsupportedConfig(f"{path} has no {key}")
    return value


def _matching(value: object, pattern: re.Pattern[str], what: str, path: Path) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise UnsupportedConfig(f"{path}: {what} {value!r} is not allowed")
    return value


def _member(raw: object, index: int, path: Path) -> Member:
    if not isinstance(raw, dict):
        raise UnsupportedConfig(f"{path}: member {index + 1} is not an object")
    person = _matching(raw.get("person"), ID, "a person id", path)
    assistant = _matching(raw.get("assistant"), ID, "an assistant id", path)
    port = raw.get("port", FIRST_PORT + index)
    if not isinstance(port, int) or isinstance(port, bool) or not 1024 <= port <= 65535:
        raise UnsupportedConfig(f"{path}: {assistant}'s port {port!r} is not allowed")
    return Member(
        person=person,
        name=_matching(raw.get("name", person.capitalize()), NAME, "a name", path),
        assistant=assistant,
        assistant_name=_matching(
            raw.get("assistantName", assistant.capitalize()), NAME, "an assistant name", path
        ),
        container=_matching(
            raw.get("container", f"openclaw-{assistant}"), DIRECTORY, "a container", path
        ),
        state=_matching(raw.get("state", f"openclaw-{assistant}"), DIRECTORY, "a state", path),
        port=port,
        memory=_matching(raw.get("memory", MEMORY), SIZE, "a memory limit", path),
    )


def members_from(loaded: dict[str, Any], path: Path) -> tuple[Member, ...]:
    """The household's members, every id, container, state directory and port its own."""
    raw = loaded.get("members")
    if raw is None:
        return LEGACY_MEMBERS
    if not isinstance(raw, list) or len(raw) != MEMBERS:
        raise UnsupportedConfig(
            f"{path} must name exactly {MEMBERS} members, the two people of the family room"
        )
    members = tuple(_member(entry, index, path) for index, entry in enumerate(raw))
    for field in ("container", "state", "port"):
        values = [getattr(member, field) for member in members]
        if len(set(values)) != len(values):
            raise UnsupportedConfig(f"{path}: two members share a {field}")
    ids = [member.person for member in members] + [member.assistant for member in members]
    if len(set(ids)) != len(ids):
        raise UnsupportedConfig(f"{path}: every person and assistant needs an id of its own")
    return members


def load_household(path: Path = HOUSEHOLD_FILE) -> Household:
    loaded = json.loads(path.read_bytes())
    if not isinstance(loaded, dict):
        raise UnsupportedConfig(f"{path} is not a JSON object")
    members = members_from(loaded, path)
    approver = loaded.get("approver", members[0].person)
    if approver not in [member.person for member in members]:
        raise UnsupportedConfig(f"{path}: the approver {approver!r} is not a member")
    # The family's shared iCloud calendar, which only the scheduled jobs read; a household
    # that connects its calendars through the app may leave it out.
    calendar = loaded.get("sharedCalendar", {"name": "", "appleId": ""})
    if not isinstance(calendar, dict):
        raise UnsupportedConfig(f"{path}: sharedCalendar is not an object")
    if calendar != {"name": "", "appleId": ""}:
        _text(calendar, "name", path)
        _text(calendar, "appleId", path)
    return Household(
        members=members,
        approver=approver,
        gateway_host=_text(loaded, "gatewayHost", path),
        google_client_id=_text(loaded, "googleClientId", path),
        shared_calendar=str(calendar.get("name", "")),
        shared_calendar_apple_id=str(calendar.get("appleId", "")),
        bible_version=_text(loaded, "bibleVersion", path),
        timezone=_matching(loaded.get("timezone", TIMEZONE), ZONE, "a time zone", path),
        push_relay=_push_relay(loaded.get("pushRelay"), path),
        names_members="members" in loaded,
    )


def _push_relay(raw: object, path: Path) -> PushRelay | None:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise UnsupportedConfig(f"{path}: pushRelay is not an object")
    return PushRelay(
        url=_matching(raw.get("url"), RELAY_URL, "a push relay address", path),
        household=_matching(raw.get("household"), ID, "a push relay household", path),
    )


def main(argv: Sequence[str] | None = None) -> int:
    command = list(sys.argv[1:] if argv is None else argv)
    if command == ["members"]:
        for member in load_household(HOUSEHOLD_FILE).members:
            fields = (
                member.person,
                member.assistant,
                member.container,
                member.state,
                str(member.port),
                str(member.state_dir),
                str(member.env_file),
                str(member.secrets_dir),
                str(member.codex_dir),
                str(member.bin_dir),
            )
            print("\t".join(fields))
        return 0
    if command == ["has-members"]:
        return 0 if load_household(HOUSEHOLD_FILE).names_members else 1
    if command == ["has-push-relay"]:
        return 0 if load_household(HOUSEHOLD_FILE).push_relay else 1
    print("usage: household_file.py members | has-members | has-push-relay", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
