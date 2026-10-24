#!/usr/bin/env python3
"""Speech on both gateways is asked for: Speak and Talk in the app, under a daily ceiling.

The household-app plugin makes all of it (speak.js) and refuses every other way a turn
could speak (speech-guard.js). This says, from each gateway's config, whether anything
still speaks a reply nobody asked for, and takes away what the household-speech plugin
left behind when Telegram, the one channel its voice notes went to, was retired: its
plugin entry, its load path and the `speak` tool it handed the assistant.

What a spoken word costs and how to change Talk's ceiling are in docs/deploy/openclaw.md
under "Speaking".
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
import time
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from gateway_config import (
    GATEWAYS,
    Gateway,
    Runner,
    backup,
    config_patch,
    field,
    gateway_for,
    patched,
    read_config,
)

# The plugin that spoke replies as Telegram voice notes, as both gateways loaded it, and
# the tool it handed the model in place of OpenClaw's own.
RETIRED_PLUGIN = "household-speech"
RETIRED_PATH = f"/opt/household-plugins/{RETIRED_PLUGIN}"
RETIRED_TOOL = "speak"
# OpenClaw's own speech tool. It is in no tool profile, so only `tools.alsoAllow` could
# hand it to the model, and nothing would bound what it spends.
BUILT_IN_TOOL = "tts"
# What takes the retired plugin's place: household-app's guard, which refuses both tools
# and answers `/tts` in a chat. Its plugin entry must be installed before the old one goes,
# or `/tts on` would reach OpenClaw's own command.
GUARD_ON_HOST = Path("/opt/household-assistant/plugins/household-app/speech-guard.js")
# Talk's daily ceiling, which scripts/openclaw-household-app.py writes.
CHANNEL = "household"

# `/tts on` in a chat and a client's speech switch are kept outside openclaw.json, in
# this file under each gateway's state directory, and OpenClaw 2026.9.4 reads it ahead
# of `tts.auto`. The app's guard answers `/tts on` itself, so a chat can no longer write it.
STORED_SWITCH = Path("settings") / "tts.json"
AUTOMATIC_MODES = ("always", "inbound", "tagged")
# Far more than a switch takes. A larger file is reported and not read.
STORED_SWITCH_BYTES = 65536


def _section(config: dict[str, Any], key: str) -> dict[str, Any]:
    value = config.get(key)
    return value if isinstance(value, dict) else {}


def _list(section: dict[str, Any], key: str) -> list[object]:
    value = section.get(key)
    return value if isinstance(value, list) else []


def _also_allowed(config: dict[str, Any]) -> list[object]:
    return _list(_section(config, "tools"), "alsoAllow")


def _load_paths(config: dict[str, Any]) -> list[object]:
    return _list(_section(_section(config, "plugins"), "load"), "paths")


def _is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def leftovers(config: dict[str, Any]) -> list[str]:
    """Where the retired plugin is still named in a gateway's config."""
    plugins = _section(config, "plugins")
    found = []
    if RETIRED_PLUGIN in _section(plugins, "entries"):
        found.append(f"plugins.entries.{RETIRED_PLUGIN}")
    if RETIRED_PATH in _load_paths(config):
        found.append("plugins.load.paths")
    if RETIRED_PLUGIN in _list(plugins, "allow"):
        found.append("plugins.allow")
    return found


def automatic_speech(node: object, path: tuple[str, ...] = ()) -> Iterator[tuple[str, str]]:
    """Every setting in the config that speaks replies nobody asked for, and its value.

    Speech on request is the household's rule, and it is also what Talk's ceiling rests
    on: a reply spoken automatically calls the provider from the reply itself, around
    the app. OpenClaw reads `tts` at the root and under an agent, a channel and an
    account, so the whole config is walked rather than a list of places kept. With no
    `auto`, 2026.9.4 still reads the older `enabled: true` as `always`.
    """
    if not isinstance(node, dict):
        return
    for key, value in node.items():
        here = (*path, str(key))
        if key == "tts" and isinstance(value, dict):
            where = ".".join(here)
            if "auto" in value and value["auto"] != "off":
                yield f"{where}.auto", str(value["auto"])
            elif "auto" not in value and value.get("enabled") is True:
                yield f"{where}.enabled", "true"
        yield from automatic_speech(value, here)


def problems(config: dict[str, Any]) -> list[str]:
    """Every way a reply on this gateway could still be spoken unasked or unbounded."""
    wrong = []
    allowed = _also_allowed(config)
    if BUILT_IN_TOOL in allowed:
        wrong.append(
            f"the assistant is handed OpenClaw's own {BUILT_IN_TOOL} tool, which no ceiling covers"
        )
    if RETIRED_TOOL in allowed:
        wrong.append(
            f"the assistant is still handed {RETIRED_TOOL}, which nothing provides any more"
        )
    found = leftovers(config)
    if found:
        wrong.append(f"the retired {RETIRED_PLUGIN} plugin is still in {', '.join(found)}")
    wrong.extend(
        f"{setting} is {value}, so replies are spoken unasked and no ceiling covers them"
        for setting, value in automatic_speech(config)
    )
    return wrong


def stored_switch(gateway: Gateway) -> list[str]:
    """What a gateway's stored speech switch still speaks unasked.

    The state directory is the assistant's own and this runs as root, so the file is
    opened without following a symlink and checked before it is read. OpenClaw reads a
    file it cannot parse as no switch at all, and so does this.
    """
    where = f"{STORED_SWITCH.as_posix()} under the state directory"
    unseen = f"{where} cannot be read, so a switch that speaks replies unasked would go unseen"
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        descriptor = os.open(gateway.state / STORED_SWITCH, flags)
    except (FileNotFoundError, NotADirectoryError):
        return []
    except OSError as error:
        return [f"{unseen}: {error.strerror}"]
    with os.fdopen(descriptor, "rb") as stream:
        status = os.fstat(stream.fileno())
        if not stat.S_ISREG(status.st_mode) or status.st_size > STORED_SWITCH_BYTES:
            return [f"{unseen}: it is not a small regular file"]
        content = stream.read()
    try:
        stored = json.loads(content)
    except ValueError:
        return []
    switch = stored.get("tts") if isinstance(stored, dict) else None
    switch = switch if isinstance(switch, dict) else {}
    mode = switch.get("auto")
    # With no mode it knows, 2026.9.4 reads the older toggle, as it does in the config.
    if mode not in ("off", *AUTOMATIC_MODES):
        mode = "always" if switch.get("enabled") is True else "off"
    if mode == "off":
        return []
    return [
        f"{where} holds a stored switch ({mode}), "
        "so replies are spoken unasked and no ceiling covers them"
    ]


def gateway_problems(gateway: Gateway, config: dict[str, Any]) -> list[str]:
    """`problems` for a gateway's config, and for what it keeps outside that config."""
    return [*problems(config), *stored_switch(gateway)]


def speech_patch(config: dict[str, Any]) -> dict[str, Any]:
    """The retired plugin and both speech tools taken out, and nothing else.

    A patch replaces a list whole, so each list is written back with what else it held,
    and one with nothing to take out is left out of the patch. A null in a patch is how a
    key is deleted.
    """
    plugins: dict[str, Any] = {}
    if RETIRED_PLUGIN in _section(_section(config, "plugins"), "entries"):
        plugins["entries"] = {RETIRED_PLUGIN: None}
    paths = _load_paths(config)
    if RETIRED_PATH in paths:
        plugins["load"] = {"paths": [path for path in paths if path != RETIRED_PATH]}
    allow = _list(_section(config, "plugins"), "allow")
    if RETIRED_PLUGIN in allow:
        plugins["allow"] = [name for name in allow if name != RETIRED_PLUGIN]
    patch: dict[str, Any] = {"plugins": plugins} if plugins else {}
    allowed = _also_allowed(config)
    if RETIRED_TOOL in allowed or BUILT_IN_TOOL in allowed:
        kept = [tool for tool in allowed if tool not in (RETIRED_TOOL, BUILT_IN_TOOL)]
        patch["tools"] = {"alsoAllow": kept}
    return patch


def report(gateway: Gateway) -> bool:
    print(f"{gateway.persona} ({gateway.container})")
    try:
        config = read_config(gateway)
    except (OSError, ValueError) as error:
        hint = " (run as root)" if isinstance(error, PermissionError) else ""
        field("unreadable", f"{error}{hint}")
        print()
        return False
    wrong = gateway_problems(gateway, config)
    talk = _section(_section(config, "channels"), CHANNEL).get("talkDailyCharacters")
    field("Talk a day", f"{talk:,} characters" if _is_count(talk) else "not set")
    field("verdict", "; ".join(wrong) if wrong else "speech only when someone asks for it")
    print()
    return not wrong


def check(gateways: Sequence[Gateway]) -> int:
    print("Whether anything on each gateway speaks a reply nobody asked for")
    print()
    healthy = [report(gateway) for gateway in gateways]
    return 0 if all(healthy) else 1


def verdict(container: str, state: Path) -> str:
    """One line for openclaw-verify.sh: `ok`, or what still speaks unasked."""
    gateway = gateway_for(container, state)
    if gateway is None:
        return f"no policy for container {container}"
    try:
        wrong = gateway_problems(gateway, read_config(gateway))
    except (OSError, ValueError) as error:
        return f"unreadable: {error}"
    return "; ".join(wrong) if wrong else "ok"


@dataclass(frozen=True, slots=True)
class Plan:
    gateway: Gateway
    patch: dict[str, Any]
    needed: bool
    left: tuple[str, ...]


def plan(gateway: Gateway) -> Plan:
    """The patch for one gateway, and what it would still leave for a person."""
    config = read_config(gateway)
    patch = speech_patch(config)
    if patch and not GUARD_ON_HOST.is_file():
        raise RuntimeError(
            f"household-app's speech guard is not installed at {GUARD_ON_HOST}; run "
            f"scripts/openclaw-install.sh first, so /tts is answered once {RETIRED_PLUGIN} goes"
        )
    result = patched(config, patch)
    left = tuple(gateway_problems(gateway, result))
    return Plan(gateway, patch, needed=result != config, left=left)


def apply(gateways: Sequence[Gateway], *, run: Runner, dry_run: bool) -> int:
    """Validate the patch on both gateways, and back both up, before writing either.

    A write that then fails on the second leaves the two apart, and says so: running
    `apply` again writes whichever is still behind.
    """
    try:
        plans = [plan(gateway) for gateway in gateways]
        for p in plans:
            if p.needed:
                config_patch(p.gateway, p.patch, run, dry_run=True)
                print(f"{p.gateway.persona}: the gateway validated the patch")
            else:
                print(f"{p.gateway.persona}: nothing to write")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    if dry_run:
        print()
        print("dry run: nothing written.")
        for p in plans:
            if p.needed:
                print(f"  {p.gateway.persona} patch: {json.dumps(p.patch)}")
            for item in p.left:
                print(f"  {p.gateway.persona} would still need a hand: {item}")
        return 0

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    pending = [p for p in plans if p.needed]
    try:
        saved = {p.gateway.persona: backup(p.gateway, "speech", stamp) for p in pending}
    except (OSError, ValueError) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    written: list[str] = []
    for p in pending:
        persona = p.gateway.persona
        try:
            config_patch(p.gateway, p.patch, run, dry_run=False)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            print(f"{persona}: write failed, previous config at {saved[persona]}", file=sys.stderr)
            print(f"  {error}", file=sys.stderr)
            for other in written:
                print(
                    f"  {other} is already written, so the two gateways are apart "
                    "until apply is run again",
                    file=sys.stderr,
                )
            return 1
        written.append(persona)
        print(f"{persona}: written; previous config at {saved[persona]}")
    for p in plans:
        for item in p.left:
            print(f"{p.gateway.persona}: still needs a hand: {item}")
    print()
    return check(gateways)


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways side by side")
    applier = commands.add_parser(
        "apply", help="take the retired speech plugin and its tool out of both gateways"
    )
    applier.add_argument(
        "--dry-run", action="store_true", help="validate the patch on both, write nothing"
    )
    applier.add_argument(
        "--gateway",
        choices=[gateway.persona for gateway in GATEWAYS],
        help="write only this gateway, to roll a change out one at a time",
    )
    one = commands.add_parser("verdict", help="one gateway, one line, for openclaw-verify.sh")
    one.add_argument("--container", required=True)
    one.add_argument("--state", required=True, type=Path)
    arguments = parser.parse_args(argv)

    if arguments.command == "verdict":
        print(verdict(arguments.container, arguments.state))
        return 0
    if arguments.command == "check":
        return check(GATEWAYS)
    if os.geteuid() != 0:
        parser.error("run as root on the box")
    chosen = [gateway for gateway in GATEWAYS if arguments.gateway in (None, gateway.persona)]
    return apply(chosen, run=run, dry_run=arguments.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
