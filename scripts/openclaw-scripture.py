#!/usr/bin/env python3
"""The scripture skill's Open in Bible links open the edition the household reads.

Each gateway's config gets `skills.entries.scripture.env.HOUSEHOLD_BIBLE_VERSION`, the
household file's bibleVersion, which OpenClaw hands the scripture skill on every run. The
card's text stays the public-domain rendering SIQsermon stored; only its link changes.
Writing the config needs no restart: the gateway takes it in process.

    python3 scripts/openclaw-scripture.py check
    python3 scripts/openclaw-scripture.py apply --gateway corey --dry-run
    python3 scripts/openclaw-scripture.py apply --gateway corey
"""

from __future__ import annotations

import argparse
import importlib.util
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
    load_household,
    patched,
    read_config,
)

SKILL = "scripture"
VARIABLE = "HOUSEHOLD_BIBLE_VERSION"
BIBLE_VERSION = load_household().bible_version
SKILL_SCRIPT = (
    Path(__file__).resolve().parents[1] / "deploy" / "openclaw" / "skills" / SKILL / "scripture.py"
)


def _linkable_editions() -> dict[str, int]:
    """The skill's own table, so the installer cannot hand it an edition it would refuse."""
    spec = importlib.util.spec_from_file_location("scripture_skill", SKILL_SCRIPT)
    assert spec is not None and spec.loader is not None
    skill = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(skill)
    editions: dict[str, int] = skill.BIBLE_VERSIONS
    return editions


BIBLE_VERSIONS = _linkable_editions()


def _dict(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _entry(config: dict[str, Any]) -> dict[str, Any]:
    return _dict(_dict(_dict(config.get("skills")).get("entries")).get(SKILL))


def unlinkable() -> str | None:
    if BIBLE_VERSION in BIBLE_VERSIONS:
        return None
    return (
        f"the household's edition {BIBLE_VERSION} is not one the {SKILL} skill can link"
        f" ({', '.join(BIBLE_VERSIONS)})"
    )


def problems(config: dict[str, Any]) -> list[str]:
    entry = _entry(config)
    wrong = []
    refusal = unlinkable()
    if refusal:
        wrong.append(refusal)
    if entry.get("enabled") is False:
        wrong.append(f"the {SKILL} skill is switched off")
    if _dict(entry.get("env")).get(VARIABLE) != BIBLE_VERSION:
        wrong.append(f"the {SKILL} skill's links do not open {BIBLE_VERSION}")
    return wrong


def scripture_patch() -> dict[str, Any]:
    """Only the one variable: the entry's other fields and variables merge through."""
    return {"skills": {"entries": {SKILL: {"env": {VARIABLE: BIBLE_VERSION}}}}}


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
    field("verdict", "; ".join(wrong) if wrong else f"Open in Bible opens {BIBLE_VERSION}")
    print()
    return not wrong


def check(gateways: Sequence[Gateway]) -> int:
    print("Which Bible edition each gateway's scripture cards link")
    print()
    healthy = [report(gateway) for gateway in gateways]
    return 0 if all(healthy) else 1


def apply(gateways: Sequence[Gateway], *, run: Runner, dry_run: bool) -> int:
    """Validate the patch on every chosen gateway, and back each up, before writing any."""
    refusal = unlinkable()
    if refusal:
        print(f"refused, nothing written: {refusal}", file=sys.stderr)
        return 1
    patch = scripture_patch()
    try:
        configs = {gateway.persona: read_config(gateway) for gateway in gateways}
        pending = [
            gateway
            for gateway in gateways
            if patched(configs[gateway.persona], patch) != configs[gateway.persona]
        ]
        for gateway in gateways:
            if gateway in pending:
                config_patch(gateway, patch, run, dry_run=True)
                print(f"{gateway.persona}: the gateway validated the patch")
            else:
                print(f"{gateway.persona}: nothing to write")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    if dry_run:
        print()
        print(f"dry run: nothing written. Patch: {json.dumps(patch)}")
        return 0

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    try:
        saved = {gateway.persona: backup(gateway, "scripture", stamp) for gateway in pending}
    except (OSError, ValueError) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    for gateway in pending:
        try:
            config_patch(gateway, patch, run, dry_run=False)
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
    applier = commands.add_parser("apply", help="hand the household's edition to the skill")
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
    sys.exit(main())
