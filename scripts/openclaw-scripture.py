#!/usr/bin/env python3
"""Both gateways read the Bible through the household-scripture plugin, not SIQsermon.

The plugin in deploy/openclaw/plugins/household-scripture gives each assistant the
`scripture` tool, which reads the database scripts/scripture-build.py writes to
/var/lib/household-assistant/scripture/bible.sqlite, mounted read-only into both
containers at /opt/household-scripture. Its scripture cards' Open in Bible links open the
edition the household reads, the household file's bibleVersion, whatever public-domain
translation the card's text is.

This script hands each gateway the plugin, that edition and the tool, and takes away the
SIQsermon skill's variable from before. Writing the config needs no restart: the gateway
takes it in process.

    python3 scripts/openclaw-scripture.py check
    python3 scripts/openclaw-scripture.py apply --gateway corey --dry-run
    python3 scripts/openclaw-scripture.py apply --gateway corey
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from collections.abc import Sequence
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
    load_household,
    patched,
    read_config,
)

PLUGIN = "household-scripture"
PLUGIN_PATH = f"/opt/household-plugins/{PLUGIN}"
PLUGIN_DIR = Path(__file__).resolve().parents[1] / "deploy" / "openclaw" / "plugins" / PLUGIN
PLUGIN_ON_HOST = Path(f"/opt/household-assistant/plugins/{PLUGIN}/openclaw.plugin.json")
BIBLE_ON_HOST = Path("/var/lib/household-assistant/scripture/bible.sqlite")
TOOL = "scripture"
# The SIQsermon skill's link setting, which this plugin's config replaces.
OLD_SKILL = "scripture"
OLD_VARIABLE = "HOUSEHOLD_BIBLE_VERSION"
BIBLE_VERSION = load_household().bible_version


def _editions() -> list[str]:
    """The editions the plugin can link, from its own manifest, so the two cannot differ."""
    manifest = json.loads((PLUGIN_DIR / "openclaw.plugin.json").read_text())
    editions: list[str] = manifest["configSchema"]["properties"]["edition"]["enum"]
    return editions


EDITIONS = _editions()
CONFIG_KEYS = frozenset({"bibleFile", "edition"})


def _dict(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def _plugins(config: dict[str, Any]) -> dict[str, Any]:
    return _dict(config.get("plugins"))


def _entry(config: dict[str, Any]) -> dict[str, Any]:
    return _dict(_dict(_plugins(config).get("entries")).get(PLUGIN))


def _load_paths(config: dict[str, Any]) -> list[object]:
    return _list(_dict(_plugins(config).get("load")).get("paths"))


def _also_allow(config: dict[str, Any]) -> list[object]:
    return _list(_dict(config.get("tools")).get("alsoAllow"))


def _old_variable(config: dict[str, Any]) -> object:
    skills = _dict(_dict(config.get("skills")).get("entries"))
    return _dict(_dict(skills.get(OLD_SKILL)).get("env")).get(OLD_VARIABLE)


def unlinkable() -> str | None:
    if BIBLE_VERSION in EDITIONS:
        return None
    linkable = ", ".join(EDITIONS)
    return f"the household's edition {BIBLE_VERSION} is not one a card can link ({linkable})"


def problems(config: dict[str, Any]) -> list[str]:
    """Every way a gateway still lacks the plugin, or would link the wrong edition."""
    wrong = []
    refusal = unlinkable()
    if refusal:
        wrong.append(refusal)
    plugins = _plugins(config)
    if plugins.get("enabled") is False:
        wrong.append(f"plugins are switched off, so the {PLUGIN} plugin cannot run")
    if PLUGIN_PATH not in _load_paths(config):
        wrong.append(f"the {PLUGIN} plugin is not loaded from {PLUGIN_PATH}")
    if PLUGIN in _list(plugins.get("deny")):
        wrong.append(f"plugins.deny blocks the {PLUGIN} plugin")
    allow = _list(plugins.get("allow"))
    if allow and PLUGIN not in allow:
        wrong.append(f"plugins.allow leaves the {PLUGIN} plugin out")
    entry = _entry(config)
    if entry.get("enabled") is not True:
        wrong.append(f"the {PLUGIN} plugin is not enabled")
    held = _dict(entry.get("config"))
    unknown = sorted(str(name) for name in held if name not in CONFIG_KEYS)
    if unknown:
        wrong.append(
            f"the {PLUGIN} plugin refuses its config and does not start: "
            f"it does not know {', '.join(unknown)}"
        )
    if held.get("edition") != BIBLE_VERSION:
        wrong.append(f"scripture cards do not open {BIBLE_VERSION}")
    if TOOL not in _also_allow(config):
        wrong.append(f"the assistant is not handed the {TOOL} tool")
    if _old_variable(config) is not None:
        wrong.append(f"the SIQsermon skill's {OLD_VARIABLE} is still set")
    return wrong


def scripture_patch(config: dict[str, Any]) -> dict[str, Any]:
    """The plugin, the household's edition and the tool; the old skill variable removed.

    A patch replaces a list whole, so each list is written back with what it held, and a
    null deletes a key: an unknown plugin key, and the SIQsermon skill's variable.
    """
    held = _dict(_entry(config).get("config"))
    settings: dict[str, Any] = {
        **dict.fromkeys(name for name in held if name not in CONFIG_KEYS),
        "edition": BIBLE_VERSION,
    }
    plugins: dict[str, Any] = {"entries": {PLUGIN: {"enabled": True, "config": settings}}}
    paths = _load_paths(config)
    if PLUGIN_PATH not in paths:
        plugins["load"] = {"paths": [*paths, PLUGIN_PATH]}
    allow = _list(_plugins(config).get("allow"))
    if allow and PLUGIN not in allow:
        plugins["allow"] = [*allow, PLUGIN]
    patch: dict[str, Any] = {"plugins": plugins}
    allowed = _also_allow(config)
    if TOOL not in allowed:
        patch["tools"] = {"alsoAllow": [*allowed, TOOL]}
    if _old_variable(config) is not None:
        patch["skills"] = {"entries": {OLD_SKILL: {"env": {OLD_VARIABLE: None}}}}
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
    field("bible", str(BIBLE_ON_HOST) if BIBLE_ON_HOST.is_file() else "not built yet")
    field(
        "verdict",
        "; ".join(wrong) if wrong else f"scripture reads the Bible; cards open {BIBLE_VERSION}",
    )
    print()
    return not wrong


def check(gateways: Sequence[Gateway]) -> int:
    print("How each gateway reads the Bible, and which edition its cards open")
    print()
    healthy = [report(gateway) for gateway in gateways]
    if not BIBLE_ON_HOST.is_file():
        print(f"{BIBLE_ON_HOST} is missing: build it with scripts/scripture-build.py --embed")
        return 1
    return 0 if all(healthy) else 1


def verdict(container: str, state: Path) -> str:
    """One line for openclaw-verify.sh: `ok`, or what the gateway still lacks."""
    gateway = gateway_for(container, state)
    if gateway is None:
        return f"no policy for container {container}"
    try:
        wrong = problems(read_config(gateway))
    except (OSError, ValueError) as error:
        return f"unreadable: {error}"
    if not BIBLE_ON_HOST.is_file():
        wrong.append(f"{BIBLE_ON_HOST} is not built")
    return "; ".join(wrong) if wrong else "ok"


def apply(gateways: Sequence[Gateway], *, run: Runner, dry_run: bool) -> int:
    """Validate the patch on every chosen gateway, and back each up, before writing any."""
    refusal = unlinkable()
    if refusal:
        print(f"refused, nothing written: {refusal}", file=sys.stderr)
        return 1
    if not PLUGIN_ON_HOST.is_file():
        print(
            f"refused, nothing written: the {PLUGIN} plugin is not installed at "
            f"{PLUGIN_ON_HOST.parent}; run scripts/openclaw-install.sh first",
            file=sys.stderr,
        )
        return 1
    try:
        configs = {gateway.persona: read_config(gateway) for gateway in gateways}
        patches = {
            gateway.persona: scripture_patch(configs[gateway.persona]) for gateway in gateways
        }
        pending = [
            gateway
            for gateway in gateways
            if patched(configs[gateway.persona], patches[gateway.persona])
            != configs[gateway.persona]
        ]
        for gateway in gateways:
            if gateway in pending:
                config_patch(gateway, patches[gateway.persona], run, dry_run=True)
                print(f"{gateway.persona}: the gateway validated the patch")
            else:
                print(f"{gateway.persona}: nothing to write")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    if dry_run:
        print()
        print("dry run: nothing written.")
        for gateway in pending:
            print(f"  {gateway.persona} patch: {json.dumps(patches[gateway.persona])}")
        return 0

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    try:
        saved = {gateway.persona: backup(gateway, "scripture", stamp) for gateway in pending}
    except (OSError, ValueError) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    for gateway in pending:
        try:
            config_patch(gateway, patches[gateway.persona], run, dry_run=False)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            print(
                f"{gateway.persona}: write failed, previous config at {saved[gateway.persona]}",
                file=sys.stderr,
            )
            print(f"  {error}", file=sys.stderr)
            return 1
        print(f"{gateway.persona}: written; previous config at {saved[gateway.persona]}")
    print()
    return check(gateways)


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways side by side")
    applier = commands.add_parser("apply", help="hand the scripture plugin to the gateways")
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
    sys.exit(main())
