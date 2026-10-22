#!/usr/bin/env python3
"""A spoken reply on both gateways is made by the household-speech plugin, under a ceiling.

What the plugin does, what a spoken reply costs and how to change a ceiling are in
docs/deploy/openclaw.md under "Speaking".
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
    session_patch,
    sessions_kept_apart,
)

# The plugin, as both gateways load it: from the read-only mount of
# /opt/household-assistant/plugins that scripts/openclaw-install.sh fills.
PLUGIN = "household-speech"
PLUGIN_PATH = f"/opt/household-plugins/{PLUGIN}"
PLUGIN_ON_HOST = Path(f"/opt/household-assistant/plugins/{PLUGIN}/openclaw.plugin.json")

# The tool the plugin gives the model, and OpenClaw's own, which it replaces. That one
# refuses a long text and leaves the split to the model, and nothing bounds its calls.
# Neither is in a tool profile, so `tools.alsoAllow` is what hands one to the model.
SPEAK_TOOL = "speak"
BUILT_IN_TOOL = "tts"

# OpenClaw 2026.9.4 picks the plugins a turn's tools come from out of the tool policy,
# and `tools.alsoAllow` asks for every plugin's default tools. These three plugins are
# asked for but not loaded when the gateway starts, so the turn's plugin tools, speak
# among them, are bound to a registry loaded on the spot without channels, and speak
# finds no Telegram voice adapter. None of their tools was used in the 21 days before
# 13 October. Denying them keeps speak on the gateway's own registry, which has Telegram.
UNLOADED_TOOL_OWNERS = ("codex", "memory-wiki", "onepassword")

# A turn's plugins are either the running gateway's, which hold the Telegram channel it
# started, or loaded afresh from the config, which hold it only when the config enables
# the telegram plugin by name. Denise's gateway started Telegram from its bot token alone,
# and a turn loaded afresh from her config had no voice adapter.
CHANNEL_PLUGIN = "telegram"

# The most characters one spoken reply may be, and the most a gateway may send to the
# speech provider in a day, every try counted. At two cents for each thousand
# characters that is 16 cents a reply and 50 cents a day for each assistant. They are
# written only where a gateway has none, so a ceiling a person set stays.
CEILINGS = {"replyCharacters": 8000, "dayCharacters": 25000}

# `/tts on` in a chat and a client's speech switch are kept outside openclaw.json, in
# this file under each gateway's state directory, and OpenClaw 2026.9.4 reads it ahead
# of `tts.auto`. The plugin answers `/tts on` itself, so a chat can no longer write it.
STORED_SWITCH = Path("settings") / "tts.json"
AUTOMATIC_MODES = ("always", "inbound", "tagged")
# Far more than a switch takes. A larger file is reported and not read.
STORED_SWITCH_BYTES = 65536


def _plugins(config: dict[str, Any]) -> dict[str, Any]:
    plugins = config.get("plugins")
    return plugins if isinstance(plugins, dict) else {}


def _entry(config: dict[str, Any]) -> dict[str, Any]:
    entries = _plugins(config).get("entries")
    entry = entries.get(PLUGIN) if isinstance(entries, dict) else None
    return entry if isinstance(entry, dict) else {}


def _load_paths(config: dict[str, Any]) -> list[object]:
    load = _plugins(config).get("load")
    paths = load.get("paths") if isinstance(load, dict) else None
    return paths if isinstance(paths, list) else []


def _also_allowed(config: dict[str, Any]) -> list[object]:
    tools = config.get("tools")
    allowed = tools.get("alsoAllow") if isinstance(tools, dict) else None
    return allowed if isinstance(allowed, list) else []


def _denied(config: dict[str, Any]) -> list[object]:
    tools = config.get("tools")
    denied = tools.get("deny") if isinstance(tools, dict) else None
    return denied if isinstance(denied, list) else []


def _channel_entry(config: dict[str, Any]) -> dict[str, Any]:
    entries = _plugins(config).get("entries")
    entry = entries.get(CHANNEL_PLUGIN) if isinstance(entries, dict) else None
    return entry if isinstance(entry, dict) else {}


def _undenied_owners(config: dict[str, Any]) -> list[str]:
    denied = _denied(config)
    return [owner for owner in UNLOADED_TOOL_OWNERS if owner not in denied]


def _is_ceiling(value: object) -> bool:
    """A whole number of characters, 1 or more, which is what the plugin accepts."""
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


def ceilings(config: dict[str, Any]) -> dict[str, int]:
    """The ceilings a gateway holds, with the default for each one it lacks."""
    held = _entry(config).get("config")
    held = held if isinstance(held, dict) else {}
    return {
        name: held[name] if _is_ceiling(held.get(name)) else default
        for name, default in CEILINGS.items()
    }


def automatic_speech(node: object, path: tuple[str, ...] = ()) -> Iterator[tuple[str, str]]:
    """Every setting in the config that speaks replies nobody asked for, and its value.

    Speech on request is the household's rule, and it is also what the ceilings rest
    on: a reply spoken automatically calls the provider from the reply itself, around
    the plugin. OpenClaw reads `tts` at the root and under an agent, a channel and an
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
    """Every way a spoken reply on this gateway could still go around the plugin."""
    wrong = []
    plugins = _plugins(config)
    if plugins.get("enabled") is False:
        wrong.append(f"plugins are switched off, so the {PLUGIN} plugin cannot run")
    if PLUGIN_PATH not in _load_paths(config):
        wrong.append(f"the {PLUGIN} plugin is not loaded from {PLUGIN_PATH}")
    deny = plugins.get("deny")
    if isinstance(deny, list) and PLUGIN in deny:
        wrong.append(f"plugins.deny blocks the {PLUGIN} plugin")
    allow = plugins.get("allow")
    if isinstance(allow, list) and allow and PLUGIN not in allow:
        wrong.append(f"plugins.allow leaves the {PLUGIN} plugin out")
    entry = _entry(config)
    if entry.get("enabled") is not True:
        wrong.append(f"the {PLUGIN} plugin is not enabled")
    # OpenClaw blocks a plugin's hook on the turn's prompt unless the config allows it.
    hooks = entry.get("hooks")
    if not isinstance(hooks, dict) or hooks.get("allowConversationAccess") is not True:
        wrong.append(
            f"the {PLUGIN} plugin may not read the turn, so a request to hear a reply "
            f"is not reminded to call {SPEAK_TOOL}"
        )
    held = entry.get("config")
    held = held if isinstance(held, dict) else {}
    wrong.extend(
        f"no {name} ceiling is set" for name in CEILINGS if not _is_ceiling(held.get(name))
    )
    # The plugin refuses a config with a key it does not know and registers nothing:
    # no `speak` tool, and no claim on `/tts`, which the built-in then answers.
    unknown = sorted(str(name) for name in held if name not in CEILINGS)
    if unknown:
        wrong.append(
            f"the {PLUGIN} plugin refuses its config and does not start: "
            f"it does not know {', '.join(unknown)}"
        )
    allowed = _also_allowed(config)
    if SPEAK_TOOL not in allowed:
        wrong.append(f"the assistant is not handed the {SPEAK_TOOL} tool")
    if BUILT_IN_TOOL in allowed:
        wrong.append(
            f"the assistant is still handed OpenClaw's own {BUILT_IN_TOOL} tool, "
            "which no ceiling covers"
        )
    if not sessions_kept_apart(config):
        wrong.append(
            "DMs are not kept per sender and groups per group, so speak refuses every chat"
        )
    undenied = _undenied_owners(config)
    if undenied:
        wrong.append(
            f"tools.deny leaves out {', '.join(undenied)}, whose tools are asked for but "
            "not loaded at start, so speak finds no voice adapter"
        )
    if _channel_entry(config).get("enabled") is not True:
        wrong.append(
            f"the {CHANNEL_PLUGIN} plugin is not enabled by name, so a turn whose plugins load "
            "from the config has no voice adapter"
        )
    wrong.extend(
        f"{setting} is {value}, so replies are spoken unasked and no ceiling covers them"
        for setting, value in automatic_speech(config)
    )
    return wrong


def stored_switch(gateway: Gateway) -> list[str]:
    """What a gateway's stored speech switch still lets go around the plugin.

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
    """The plugin, its ceilings and the `speak` tool in place of `tts`.

    A patch replaces a list whole, so each list is written back with what it held, and
    one that already holds what it should is left out of the patch. A config key the
    plugin does not know is taken out, since it would not start with it: a null in a
    patch is how a key is deleted.
    """
    held = _entry(config).get("config")
    held = held if isinstance(held, dict) else {}
    settings = {**dict.fromkeys(name for name in held if name not in CEILINGS), **ceilings(config)}
    plugins: dict[str, Any] = {
        "entries": {
            PLUGIN: {
                "enabled": True,
                "hooks": {"allowConversationAccess": True},
                "config": settings,
            }
        }
    }
    # A telegram plugin switched off by name is a person's choice, left for them.
    if "enabled" not in _channel_entry(config):
        plugins["entries"][CHANNEL_PLUGIN] = {"enabled": True}
    paths = _load_paths(config)
    if PLUGIN_PATH not in paths:
        plugins["load"] = {"paths": [*paths, PLUGIN_PATH]}
    allow = _plugins(config).get("allow")
    if isinstance(allow, list) and allow and PLUGIN not in allow:
        plugins["allow"] = [*allow, PLUGIN]
    patch: dict[str, Any] = {"plugins": plugins, **session_patch(config)}
    tools: dict[str, Any] = {}
    allowed = _also_allowed(config)
    if SPEAK_TOOL not in allowed or BUILT_IN_TOOL in allowed:
        kept = [tool for tool in allowed if tool not in (SPEAK_TOOL, BUILT_IN_TOOL)]
        tools["alsoAllow"] = [*kept, SPEAK_TOOL]
    undenied = _undenied_owners(config)
    if undenied:
        tools["deny"] = [*_denied(config), *undenied]
    if tools:
        patch["tools"] = tools
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
    tools = [str(tool) for tool in _also_allowed(config) if tool in (SPEAK_TOOL, BUILT_IN_TOOL)]
    field("speaks with", ", ".join(tools) or "no tool")
    held = _entry(config).get("config")
    held = held if isinstance(held, dict) else {}
    if all(_is_ceiling(held.get(name)) for name in CEILINGS):
        bounds = f"{held['replyCharacters']:,} characters a reply, {held['dayCharacters']:,} a day"
    else:
        bounds = "not set"
    field("ceilings", bounds)
    field("verdict", "; ".join(wrong) if wrong else "spoken replies go through the plugin")
    print()
    return not wrong


def check(gateways: Sequence[Gateway]) -> int:
    print("How each gateway makes a spoken reply, and what bounds it")
    print()
    healthy = [report(gateway) for gateway in gateways]
    return 0 if all(healthy) else 1


def verdict(container: str, state: Path) -> str:
    """One line for openclaw-verify.sh: `ok`, or what still goes around the plugin."""
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
    if not PLUGIN_ON_HOST.is_file():
        raise RuntimeError(
            f"the {PLUGIN} plugin is not installed at {PLUGIN_ON_HOST.parent}; run "
            "scripts/openclaw-install.sh first, which also mounts it into both containers"
        )
    config = read_config(gateway)
    patch = speech_patch(config)
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
    applier = commands.add_parser("apply", help="hand the speech plugin to both gateways")
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
