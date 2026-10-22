#!/usr/bin/env python3
"""Pictures and videos on both gateways are made by the household-pictures plugin, under a ceiling.

OpenClaw 2026.9.4's own image_generate and video_generate drop the cost OpenRouter reports
for each request, name nobody, and let the model pick the model and the count, so nothing
can hold a day's spend. The plugin in deploy/openclaw/plugins/household-pictures makes
them itself, sends each to the chat it was asked in, logs its cost with who asked, and
refuses past each person's daily ceiling. This script hands it to both gateways and says,
from each gateway's config, whether a picture or a video could still go around it.

The models are openclaw-openrouter.py's and the phone's (agents.defaults.mediaModels),
and The Fam's tool list is pocket-piggies-install.py's; neither is written here.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from collections.abc import Sequence
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
PLUGIN = "household-pictures"
PLUGIN_PATH = f"/opt/household-plugins/{PLUGIN}"
PLUGIN_ON_HOST = Path(f"/opt/household-assistant/plugins/{PLUGIN}/openclaw.plugin.json")

# The tools the plugin gives the model, and OpenClaw's own, which they replace. Neither of
# the plugin's is in a tool profile, so `tools.alsoAllow` is what hands them to the model,
# and the built-ins are in every profile that has media, so only `tools.deny` takes them
# away.
TOOLS = ("picture", "video")
BUILT_IN_TOOLS = ("image_generate", "video_generate")

# What one person's pictures, and their videos, may cost on one gateway in a day. At
# OpenRouter's listed prices a six-second Veo 3.1 Fast video at 720p is 60 cents, so the
# video ceiling is a few short videos; a picture's cost depends on its model, size and
# quality, and OpenRouter reports each one. They are written only where a gateway has
# none, so a ceiling a person set stays.
CEILINGS = {"pictureDayDollars": 2.0, "videoDayDollars": 3.0}
MAX_CEILING = 100


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


def _tool_list(config: dict[str, Any], name: str) -> list[object]:
    tools = config.get("tools")
    listed = tools.get(name) if isinstance(tools, dict) else None
    return listed if isinstance(listed, list) else []


def _is_ceiling(value: object) -> bool:
    """A number of dollars above 0 and at most MAX_CEILING, which is what the plugin accepts."""
    return (
        isinstance(value, int | float) and not isinstance(value, bool) and 0 < value <= MAX_CEILING
    )


def ceilings(config: dict[str, Any]) -> dict[str, float]:
    """The ceilings a gateway holds, with the default for each one it lacks."""
    held = _entry(config).get("config")
    held = held if isinstance(held, dict) else {}
    return {
        name: held[name] if _is_ceiling(held.get(name)) else default
        for name, default in CEILINGS.items()
    }


def problems(config: dict[str, Any]) -> list[str]:
    """Every way a picture or a video on this gateway could still go around the plugin."""
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
    held = entry.get("config")
    held = held if isinstance(held, dict) else {}
    wrong.extend(
        f"no {name} ceiling is set" for name in CEILINGS if not _is_ceiling(held.get(name))
    )
    # The plugin refuses a config with a key it does not know and registers nothing.
    unknown = sorted(str(name) for name in held if name not in CEILINGS)
    if unknown:
        wrong.append(
            f"the {PLUGIN} plugin refuses its config and does not start: "
            f"it does not know {', '.join(unknown)}"
        )
    allowed = _tool_list(config, "alsoAllow")
    missing = [tool for tool in TOOLS if tool not in allowed]
    if missing:
        wrong.append(f"the assistant is not handed {', '.join(missing)}")
    denied = _tool_list(config, "deny")
    undenied = [tool for tool in BUILT_IN_TOOLS if tool not in denied]
    if undenied:
        wrong.append(
            f"the assistant is still handed OpenClaw's own {', '.join(undenied)}, "
            "which no ceiling covers"
        )
    if not sessions_kept_apart(config):
        wrong.append(
            "DMs are not kept per sender and groups per group, so picture and video refuse "
            "every chat"
        )
    return wrong


def pictures_patch(config: dict[str, Any]) -> dict[str, Any]:
    """The plugin, its ceilings, and picture and video in place of OpenClaw's own.

    A patch replaces a list whole, so each list is written back with what it held, and
    one that already holds what it should is left out of the patch. A config key the
    plugin does not know is taken out, since it would not start with it: a null in a
    patch is how a key is deleted.
    """
    held = _entry(config).get("config")
    held = held if isinstance(held, dict) else {}
    settings = {
        **dict.fromkeys(name for name in held if name not in CEILINGS),
        **ceilings(config),
    }
    plugins: dict[str, Any] = {"entries": {PLUGIN: {"enabled": True, "config": settings}}}
    paths = _load_paths(config)
    if PLUGIN_PATH not in paths:
        plugins["load"] = {"paths": [*paths, PLUGIN_PATH]}
    allow = _plugins(config).get("allow")
    if isinstance(allow, list) and allow and PLUGIN not in allow:
        plugins["allow"] = [*allow, PLUGIN]
    patch: dict[str, Any] = {"plugins": plugins, **session_patch(config)}
    tools: dict[str, Any] = {}
    allowed = _tool_list(config, "alsoAllow")
    if any(tool not in allowed for tool in TOOLS):
        tools["alsoAllow"] = [*allowed, *(tool for tool in TOOLS if tool not in allowed)]
    denied = _tool_list(config, "deny")
    if any(tool not in denied for tool in BUILT_IN_TOOLS):
        tools["deny"] = [*denied, *(tool for tool in BUILT_IN_TOOLS if tool not in denied)]
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
    wrong = problems(config)
    allowed = _tool_list(config, "alsoAllow")
    field("makes with", ", ".join(str(tool) for tool in TOOLS if tool in allowed) or "no tool")
    held = _entry(config).get("config")
    held = held if isinstance(held, dict) else {}
    if all(_is_ceiling(held.get(name)) for name in CEILINGS):
        bounds = (
            f"${held['pictureDayDollars']:.2f} of pictures and "
            f"${held['videoDayDollars']:.2f} of videos a person a day"
        )
    else:
        bounds = "not set"
    field("ceilings", bounds)
    field("verdict", "; ".join(wrong) if wrong else "pictures and videos go through the plugin")
    print()
    return not wrong


def check(gateways: Sequence[Gateway]) -> int:
    print("How each gateway makes a picture or a video, and what bounds it")
    print()
    healthy = [report(gateway) for gateway in gateways]
    return 0 if all(healthy) else 1


def verdict(container: str, state: Path) -> str:
    """One line for openclaw-verify.sh: `ok`, or what still goes around the plugin."""
    gateway = gateway_for(container, state)
    if gateway is None:
        return f"no policy for container {container}"
    try:
        wrong = problems(read_config(gateway))
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
    patch = pictures_patch(config)
    result = patched(config, patch)
    return Plan(gateway, patch, needed=result != config, left=tuple(problems(result)))


def apply(gateways: Sequence[Gateway], *, run: Runner, dry_run: bool) -> int:
    """Validate the patch on every chosen gateway, and back each up, before writing any.

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
        saved = {p.gateway.persona: backup(p.gateway, "pictures", stamp) for p in pending}
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
    applier = commands.add_parser("apply", help="hand the pictures plugin to both gateways")
    applier.add_argument("--dry-run", action="store_true", help="validate the patch, write nothing")
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
