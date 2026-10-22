#!/usr/bin/env python3
"""What a family member asks an assistant to keep lasts, and older chats are found.

Each gateway gets the household-memory plugin, `recall` and `forget` in its owner's
private chat, and chat transcripts named as a memory source. What the plugin does and
how this was rolled out are in docs/deploy/openclaw.md under "The memory backend".
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

# The plugin, as both gateways load it: from the read-only mount of
# /opt/household-assistant/plugins.
PLUGIN = "household-memory"
PLUGIN_PATH = f"/opt/household-plugins/{PLUGIN}"
PLUGIN_ON_HOST = Path(f"/opt/household-assistant/plugins/{PLUGIN}/openclaw.plugin.json")
TOOLS = ["recall", "forget"]

# The family group and who is in it, from the box's household file. A request kept in
# the group is kept under the sender's name, so the plugin needs both.
IDENTIFIERS = load_household()
FAMILY_GROUP = IDENTIFIERS.family_group
HOUSEHOLD = IDENTIFIERS.telegram_ids
NAMES = {"franco": "Franco", "gia": "Gia"}

# The PocketPiggies guard rewrites `tools.alsoAllow` as everything else in its order,
# then these three. Putting the new tools before them leaves the guard nothing to do.
# Must equal FINANCE_TOOLS in pocket-piggies-install.py.
FINANCE_TOOLS = ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]

# Transcripts as a memory source, named outright. Without this, OpenClaw 2026.9.4
# indexes them only while "remember across conversations" is on, and that defaults to
# off as soon as private chats are kept per person, which is what paused memory search
# on both gateways on 13 October.
SOURCES = ["memory", "sessions"]


def _dict(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: object) -> list[Any]:
    return value if isinstance(value, list) else []


def _plugins(config: dict[str, Any]) -> dict[str, Any]:
    return _dict(config.get("plugins"))


def _entry(config: dict[str, Any]) -> dict[str, Any]:
    return _dict(_dict(_plugins(config).get("entries")).get(PLUGIN))


def _load_paths(config: dict[str, Any]) -> list[Any]:
    return _list(_dict(_plugins(config).get("load")).get("paths"))


def _also_allowed(config: dict[str, Any]) -> list[Any]:
    return _list(_dict(config.get("tools")).get("alsoAllow"))


def _agent_search(config: dict[str, Any]) -> dict[str, Any]:
    main = _dict(_dict(_dict(config.get("agents")).get("entries")).get("main"))
    return _dict(_dict(main.get("memory")).get("search"))


def _person(persona: str) -> str:
    return next(gateway.person for gateway in GATEWAYS if gateway.persona == persona)


def expected_settings(persona: str) -> dict[str, Any]:
    return {
        "groupChatId": FAMILY_GROUP,
        "ownerTelegramId": HOUSEHOLD[_person(persona)],
        "people": {HOUSEHOLD[person]: NAMES[person] for person in HOUSEHOLD},
        # The same people by their household app ids, as openclaw-household-app.py
        # names them, so the app's thread and family room share what is kept.
        "appPeople": {HOUSEHOLD[person]: person for person in HOUSEHOLD},
    }


def _normalized_sources(sources: list[Any] | None, has_sessions: bool) -> list[str]:
    found = []
    for source in sources or ["memory"]:
        if source == "memory" and "memory" not in found:
            found.append("memory")
        if source == "sessions" and has_sessions and "sessions" not in found:
            found.append("sessions")
    return found or ["memory"]


def indexed_sources(config: dict[str, Any]) -> list[str]:
    """What OpenClaw 2026.9.4 indexes for the main agent, as `resolveMemorySearchIndexConfig`
    and `resolveRememberAcrossConversations` work it out."""
    defaults = _dict(_dict(config.get("memory")).get("search"))
    overrides = _agent_search(config)
    if overrides.get("enabled", defaults.get("enabled", True)) is False:
        return []
    remember = overrides.get(
        "rememberAcrossConversations", defaults.get("rememberAcrossConversations")
    )
    if remember is None:
        dm_scope = _dict(config.get("session")).get("dmScope")
        remember = dm_scope in (None, "main") and not any(
            "dmScope" in _dict(_dict(binding).get("session"))
            for binding in _list(config.get("bindings"))
        )
    configured = _dict(overrides.get("experimental")).get(
        "sessionMemory", _dict(defaults.get("experimental")).get("sessionMemory", False)
    )
    sources = overrides.get("sources", defaults.get("sources"))
    searched = _normalized_sources(
        sources, bool(configured) or (bool(remember) and "sessions" in _list(sources))
    )
    return _normalized_sources(
        [*searched, "sessions"] if remember else sources, bool(remember) or bool(configured)
    )


def _transcripts_named(config: dict[str, Any]) -> bool:
    search = _agent_search(config)
    return (
        all(source in _list(search.get("sources")) for source in SOURCES)
        and _dict(search.get("experimental")).get("sessionMemory") is True
    )


def problems(config: dict[str, Any], persona: str) -> list[str]:
    """Every way what is kept could still be lost, or an older chat not found."""
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
    entry = _entry(config)
    if entry.get("enabled") is not True:
        wrong.append(f"the {PLUGIN} plugin is not enabled")
    if _dict(entry.get("hooks")).get("allowConversationAccess") is not True:
        wrong.append(f"the {PLUGIN} plugin may not read the turn, so it keeps and shows nothing")
    if entry.get("config") != expected_settings(persona):
        wrong.append(f"the {PLUGIN} plugin is not set up for The Fam and {_person(persona)}")
    allowed = _also_allowed(config)
    if any(tool not in allowed for tool in TOOLS):
        wrong.append("the assistant is not handed recall and forget in its private chat")
    if not _transcripts_named(config):
        wrong.append(
            "chat transcripts are not a memory source, so memory search leaves out older chats "
            "and pauses whenever the session setting changes"
        )
    return wrong


def memory_patch(config: dict[str, Any], persona: str) -> dict[str, Any]:
    """The plugin, its two tools and transcripts as a memory source.

    A patch replaces a list whole, so each list is written back with what it held.
    """
    plugins: dict[str, Any] = {
        "entries": {
            PLUGIN: {
                "enabled": True,
                "hooks": {"allowConversationAccess": True},
                "config": expected_settings(persona),
            }
        }
    }
    paths = _load_paths(config)
    if PLUGIN_PATH not in paths:
        plugins["load"] = {"paths": [*paths, PLUGIN_PATH]}
    allow = _list(_plugins(config).get("allow"))
    if allow and PLUGIN not in allow:
        plugins["allow"] = [*allow, PLUGIN]
    patch: dict[str, Any] = {"plugins": plugins}
    allowed = _also_allowed(config)
    if any(tool not in allowed for tool in TOOLS):
        others = [tool for tool in allowed if tool not in FINANCE_TOOLS and tool not in TOOLS]
        finance = [tool for tool in allowed if tool in FINANCE_TOOLS]
        patch["tools"] = {"alsoAllow": [*others, *TOOLS, *finance]}
    if not _transcripts_named(config):
        search = _agent_search(config)
        sources = [
            *_list(search.get("sources")),
            *(s for s in SOURCES if s not in _list(search.get("sources"))),
        ]
        patch["agents"] = {
            "entries": {
                "main": {
                    "memory": {
                        "search": {"sources": sources, "experimental": {"sessionMemory": True}}
                    }
                }
            }
        }
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
    wrong = problems(config, gateway.persona)
    field("indexes", ", ".join(indexed_sources(config)) or "nothing")
    field("verdict", "; ".join(wrong) if wrong else "kept requests and older chats are covered")
    print()
    return not wrong


def check(gateways: Sequence[Gateway]) -> int:
    print("What each gateway keeps, and what its memory search covers")
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
    patch = memory_patch(config, gateway.persona)
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
        saved = {p.gateway.persona: backup(p.gateway, "memory", stamp) for p in pending}
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
        print(
            f"  then rebuild its memory index once: docker exec {p.gateway.container} "
            "node dist/index.js memory status --index --agent main"
        )
    print()
    return check(gateways)


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways side by side")
    applier = commands.add_parser("apply", help="hand the memory plugin to the gateways")
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
