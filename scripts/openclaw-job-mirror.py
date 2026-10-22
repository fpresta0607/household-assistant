#!/usr/bin/env python3
"""Each scheduled message a family member gets on Telegram reaches them in the app too.

Each gateway gets the household-job-mirror plugin, which copies a finished automation's
announced words from the owner's Telegram chat into the owner's app thread, and from
The Fam into the app's family room. What it does and how it was rolled out are in
docs/deploy/openclaw.md under "Scheduled messages in the app".
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
    load_household,
    patched,
    read_config,
)

PLUGIN = "household-job-mirror"
PLUGIN_PATH = f"/opt/household-plugins/{PLUGIN}"
PLUGIN_ON_HOST = Path(f"/opt/household-assistant/plugins/{PLUGIN}/openclaw.plugin.json")

# The family group and each person's private chat, from the box's household file, and
# the app's family room. Each person's app id is the name openclaw-household-app.py
# gives them.
IDENTIFIERS = load_household()
FAMILY_GROUP = IDENTIFIERS.family_group
HOUSEHOLD = IDENTIFIERS.telegram_ids
APP_FAMILY = "family"


def _dict(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: object) -> list[Any]:
    return value if isinstance(value, list) else []


def _plugins(config: dict[str, Any]) -> dict[str, Any]:
    return _dict(config.get("plugins"))


def _load_paths(config: dict[str, Any]) -> list[Any]:
    return _list(_dict(_plugins(config).get("load")).get("paths"))


def _person(persona: str) -> str:
    return next(gateway.person for gateway in GATEWAYS if gateway.persona == persona)


def expected_settings(persona: str) -> dict[str, Any]:
    person = _person(persona)
    return {"targets": {HOUSEHOLD[person]: person, FAMILY_GROUP: APP_FAMILY}}


def problems(config: dict[str, Any], persona: str) -> list[str]:
    """Every way a scheduled message could still reach Telegram and not the app."""
    wrong = []
    plugins = _plugins(config)
    if plugins.get("enabled") is False:
        wrong.append(f"plugins are switched off, so the {PLUGIN} plugin cannot run")
    if PLUGIN in _list(plugins.get("deny")):
        wrong.append(f"plugins.deny blocks the {PLUGIN} plugin")
    allow = _list(plugins.get("allow"))
    if allow and PLUGIN not in allow:
        wrong.append(f"plugins.allow leaves the {PLUGIN} plugin out")
    if PLUGIN_PATH not in _load_paths(config):
        wrong.append(f"the {PLUGIN} plugin is not loaded from {PLUGIN_PATH}")
    entry = _dict(_dict(plugins.get("entries")).get(PLUGIN))
    if entry.get("enabled") is not True:
        wrong.append(f"the {PLUGIN} plugin is not enabled")
    if _dict(entry.get("hooks")).get("allowConversationAccess") is not True:
        wrong.append(
            f"the {PLUGIN} plugin requires hooks.allowConversationAccess for complete output"
        )
    if entry.get("config") != expected_settings(persona):
        wrong.append(f"the {PLUGIN} plugin is not set up for The Fam and {_person(persona)}")
    household = _dict(_dict(config.get("channels")).get("household"))
    if not household or household.get("enabled") is False:
        wrong.append("the household app's channel is not on, so a copy has nowhere to go")
    return wrong


def mirror_patch(config: dict[str, Any], persona: str) -> dict[str, Any]:
    """The plugin, loaded and set up. A patch replaces a list whole, so each is kept."""
    plugins: dict[str, Any] = {
        "entries": {
            PLUGIN: {
                "enabled": True,
                "config": expected_settings(persona),
                "hooks": {"allowConversationAccess": True},
            }
        }
    }
    paths = _load_paths(config)
    if PLUGIN_PATH not in paths:
        plugins["load"] = {"paths": [*paths, PLUGIN_PATH]}
    allow = _list(_plugins(config).get("allow"))
    if allow and PLUGIN not in allow:
        plugins["allow"] = [*allow, PLUGIN]
    return {"plugins": plugins}


def report(gateway: Gateway) -> bool:
    print(f"{gateway.persona} ({gateway.container})")
    try:
        config = read_config(gateway)
    except (OSError, ValueError) as error:
        hint = " (run as root)" if isinstance(error, PermissionError) else ""
        field("unreadable", f"{error}{hint}")
        print()
        return False
    wrong = problems(config, gateway.persona)
    field("verdict", "; ".join(wrong) if wrong else "scheduled messages reach the app as well")
    print()
    return not wrong


def check(gateways: Sequence[Gateway]) -> int:
    print("Whether each gateway copies its scheduled messages into the app")
    print()
    healthy = [report(gateway) for gateway in gateways]
    return 0 if all(healthy) else 1


@dataclass(frozen=True, slots=True)
class Plan:
    gateway: Gateway
    patch: dict[str, Any]
    needed: bool


def plan(gateway: Gateway) -> Plan:
    if not PLUGIN_ON_HOST.is_file():
        raise RuntimeError(
            f"the {PLUGIN} plugin is not installed at {PLUGIN_ON_HOST.parent}; copy "
            f"deploy/openclaw/plugins/{PLUGIN} there, root-owned, first"
        )
    config = read_config(gateway)
    patch = mirror_patch(config, gateway.persona)
    return Plan(gateway, patch, needed=patched(config, patch) != config)


def apply(gateways: Sequence[Gateway], *, run: Runner, dry_run: bool) -> int:
    """Validate the patch on every chosen gateway, and back each up, before writing any."""
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
        return 0

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    pending = [p for p in plans if p.needed]
    try:
        saved = {p.gateway.persona: backup(p.gateway, "job-mirror", stamp) for p in pending}
    except (OSError, ValueError) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    for p in pending:
        persona = p.gateway.persona
        try:
            config_patch(p.gateway, p.patch, run, dry_run=False)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            print(f"{persona}: write failed, previous config at {saved[persona]}", file=sys.stderr)
            print(f"  {error}", file=sys.stderr)
            return 1
        print(f"{persona}: written; previous config at {saved[persona]}")
    print()
    return check(gateways)


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways side by side")
    applier = commands.add_parser("apply", help="hand the job mirror plugin to the gateways")
    applier.add_argument("--dry-run", action="store_true", help="validate the patch, write nothing")
    applier.add_argument(
        "--gateway",
        choices=[gateway.persona for gateway in GATEWAYS],
        help="write only this gateway, to roll a change out one at a time",
    )
    arguments = parser.parse_args(argv)
    if arguments.command == "check":
        return check(GATEWAYS)
    if os.geteuid() != 0:
        parser.error("run as root on the box")
    chosen = [gateway for gateway in GATEWAYS if arguments.gateway in (None, gateway.persona)]
    return apply(chosen, run=run, dry_run=arguments.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
