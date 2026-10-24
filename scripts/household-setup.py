#!/usr/bin/env python3
"""A new household's answers, asked once on its own box: who lives there, what their
assistants are called, and the household's own OpenRouter key.

It writes the household file, /etc/household-assistant/household.json, root-only, and puts
the OpenRouter key into each gateway's env file. The key is typed here, on the box, and is
never echoed, printed or written anywhere else: the repository's rule is that keys and
passwords never come through a chat, an email or a ticket.

    python3 scripts/household-setup.py              # asks, then writes
    python3 scripts/household-setup.py --key-only   # only the OpenRouter key, for a new key

A household file that is already there is kept as it is; delete it first to answer again.
What the publisher of the app fills in for every household, its Google client and its push
relay, comes from deploy/publisher.json when it names them, so a household is not asked.
scripts/new-household.sh runs this; docs/deploy/new-household.md walks through it.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

from household_file import (
    HOUSEHOLD_FILE,
    TIMEZONE,
    UnsupportedConfig,
    load_household,
)

ROOT = Path(__file__).resolve().parent.parent
PUBLISHER = ROOT / "deploy" / "publisher.json"
SCRIPTURE_MANIFEST = (
    ROOT / "deploy" / "openclaw" / "plugins" / "household-scripture" / "openclaw.plugin.json"
)
OPENROUTER_KEY = "OPENROUTER_API_KEY"
# OpenRouter's keys start this way; anything else is most likely a paste of something else.
KEY_SHAPE = re.compile(r"sk-or-[A-Za-z0-9_-]{16,200}")

Ask = Callable[[str], str]


def editions() -> list[str]:
    manifest = json.loads(SCRIPTURE_MANIFEST.read_text(encoding="utf-8"))
    found: list[str] = manifest["configSchema"]["properties"]["edition"]["enum"]
    return found


def publisher(path: Path = PUBLISHER) -> dict[str, Any]:
    """What the app's publisher fills in for every household, or {} when nothing is."""
    if not path.is_file():
        return {}
    loaded = json.loads(path.read_text(encoding="utf-8"))
    return (
        {key: value for key, value in loaded.items() if value} if isinstance(loaded, dict) else {}
    )


def slug(name: str) -> str:
    """A name as an id the household file allows: lowercase letters, digits and hyphens."""
    flat = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return (flat if flat[:1].isalpha() else f"x-{flat}")[:32].rstrip("-")


def box_timezone(run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> str:
    try:
        found = run(
            ["timedatectl", "show", "--property=Timezone", "--value"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
    except OSError:
        found = ""
    return found if found and found != "Etc/UTC" else TIMEZONE


def tailnet_name(run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> str:
    """The box's name on the household's tailnet, which the phones reach it by."""
    try:
        status = run(
            ["tailscale", "status", "--self", "--json"], capture_output=True, text=True, check=False
        )
        name = json.loads(status.stdout or "{}").get("Self", {}).get("DNSName", "")
    except (OSError, ValueError, AttributeError):
        name = ""
    return str(name).rstrip(".")


def asked(ask: Ask, question: str, default: str = "") -> str:
    shown = f"{question} [{default}]: " if default else f"{question}: "
    while True:
        answer = ask(shown).strip()
        if answer or default:
            return answer or default


def choice(ask: Ask, question: str, options: Sequence[str], default: str) -> str:
    while True:
        answer = asked(ask, f"{question} ({'/'.join(options)})", default)
        if answer in options:
            return answer
        print(f"  one of {', '.join(options)}, please")


def household_answers(
    ask: Ask,
    *,
    timezone: str,
    host: str,
    known: dict[str, Any],
) -> dict[str, Any]:
    """The household file, from the household's answers and what the publisher filled in."""
    print("Two adults share the household, each with an assistant of their own.")
    members = []
    used: set[str] = set()
    for which in ("first", "second"):
        name = asked(ask, f"The {which} adult's first name")
        assistant_name = asked(ask, f"What should {name}'s assistant be called?")
        person, assistant = slug(name), slug(assistant_name)
        if person in used:
            person = f"{person}-2"
        if assistant in used or assistant == person:
            assistant = f"{assistant}-ai"
        used.update({person, assistant})
        members.append(
            {
                "person": person,
                "name": name,
                "assistant": assistant,
                "assistantName": assistant_name,
            }
        )
    approver = choice(
        ask,
        "Who lets in a phone that signed in with Apple and nobody linked",
        [member["person"] for member in members],
        members[0]["person"],
    )
    answers: dict[str, Any] = {
        "members": members,
        "approver": approver,
        "gatewayHost": asked(ask, "The box's name on your tailnet", host),
        "googleClientId": known.get("googleClientId")
        or asked(ask, "The app's Google client id (from the app's publisher)"),
        "bibleVersion": choice(ask, "The Bible your household reads", editions(), "BSB"),
        "timezone": asked(ask, "Your time zone", timezone),
    }
    relay = known.get("pushRelay")
    if isinstance(relay, str):
        default = f"{members[0]['person']}-{members[1]['person']}"
        name = asked(ask, "A name for your household at the app's push relay", default)
        answers["pushRelay"] = {"url": relay, "household": slug(name)}
    return answers


def write_household(answers: dict[str, Any], path: Path) -> None:
    """Writes the file only once it reads back as a household, root-only, all at once."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".household.")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(answers, stream, indent=2)
            stream.write("\n")
        load_household(Path(temporary))
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def has_key(env_file: Path) -> bool:
    if not env_file.is_file():
        return False
    return any(
        line.startswith(f"{OPENROUTER_KEY}=") and len(line) > len(OPENROUTER_KEY) + 1
        for line in env_file.read_text(encoding="utf-8").splitlines()
    )


def put_key(env_file: Path, key: str) -> None:
    """Adds the key to the env file, or replaces the one there, keeping every other line."""
    lines = env_file.read_text(encoding="utf-8").splitlines() if env_file.is_file() else []
    kept = [line for line in lines if not line.startswith(f"{OPENROUTER_KEY}=")]
    env_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=env_file.parent, prefix=".env.")
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write("\n".join([*kept, f"{OPENROUTER_KEY}={key}"]) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, env_file)


def openrouter_key(secret: Ask) -> str:
    print(
        "Your household's OpenRouter key pays for what the assistants say. Make one at "
        "openrouter.ai/keys, with a monthly limit, and type or paste it here; it is not shown."
    )
    while True:
        key = secret("OpenRouter key: ").strip()
        if KEY_SHAPE.fullmatch(key):
            return key
        print("  that does not look like an OpenRouter key (they start with sk-or-); try again")


def setup(
    *,
    ask: Ask,
    secret: Ask,
    path: Path,
    key_only: bool,
    timezone: str,
    host: str,
    known: dict[str, Any],
) -> int:
    if not key_only:
        if path.exists():
            print(f"{path} is already there and is kept; delete it first to answer again.")
        else:
            answers = household_answers(ask, timezone=timezone, host=host, known=known)
            try:
                write_household(answers, path)
            except UnsupportedConfig as error:
                print(
                    f"those answers are not a household the box can run: {error}", file=sys.stderr
                )
                return 1
            print(f"wrote {path}")
    household = load_household(path)
    missing = [member for member in household.members if not has_key(member.env_file)]
    if not missing and not key_only:
        print("each gateway already has an OpenRouter key")
        return 0
    key = openrouter_key(secret)
    for member in household.members if key_only else missing:
        put_key(member.env_file, key)
        print(f"{member.assistant_name}'s gateway has the key")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--key-only", action="store_true", help="only the OpenRouter key")
    arguments = parser.parse_args(argv)
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        parser.error("run as root on the box")
    return setup(
        ask=input,
        secret=getpass.getpass,
        path=HOUSEHOLD_FILE,
        key_only=arguments.key_only,
        timezone=box_timezone(),
        host=tailnet_name(),
        known=publisher(),
    )


if __name__ == "__main__":
    raise SystemExit(main())
