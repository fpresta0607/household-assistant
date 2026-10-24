#!/usr/bin/env python3
"""What the first household's gateways were given by hand, given to a new household's.

Two settings, each of which a gateway on a new box would otherwise fail
openclaw-verify.sh on.

The phones' connections. `tailscale serve` is a reverse proxy in front of each gateway's
loopback port, and a gateway refuses proxied traffic from an address it has not been told
is a proxy: the phone's WebSocket is answered `403 proxy_attribution_required` and the app
sits on "Connecting". On the first household's box both gateways were told by hand on
2026-09-24 (docs/deploy/openclaw.md, "Why the gateway trusts the host as a proxy").

A box whose household file names its members runs the compose file
scripts/household-compose.py writes, whose network gives the host one fixed address,
GATEWAY_BRIDGE, so this writes it: `gateway.trustedProxies` is that address alone, and
`gateway.controlUi.allowedOrigins` gains the gateway's own tailnet address, which lets
the Control UI load from it.

The heartbeat. OpenClaw runs a model turn every 30 minutes out of the box and delivers
anything but a silent reply to the owner, which sent messages nobody asked for until both
of the first household's gateways were set to `agents.defaults.heartbeat.every` "0m" on
2026-09-25 (docs/deploy/openclaw.md, "The heartbeat is off"); a fresh onboarding brings it
back, so a new household's gateways get the same.

The first household's box is left as it was set by hand.

    python3 scripts/openclaw-box.py check
    python3 scripts/openclaw-box.py apply [--gateway <assistant>] [--dry-run]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from collections.abc import Sequence
from typing import Any

from gateway_config import (
    GATEWAYS,
    Gateway,
    Runner,
    backup,
    config_patch,
    load_household,
    patched,
    read_config,
)
from household_file import GATEWAY_BRIDGE

LABEL = "box"
# What `agents.defaults.heartbeat.every` is when the recurring heartbeat is off.
NO_HEARTBEAT = "0m"


def origin(gateway: Gateway) -> str:
    """The address a phone or browser on the household's tailnet reaches `gateway` at."""
    household = load_household()
    member = household.member(gateway.persona)
    return f"https://{household.gateway_host}:{member.port}"


def _gateway_section(config: dict[str, Any]) -> dict[str, Any]:
    section = config.get("gateway")
    return section if isinstance(section, dict) else {}


def _heartbeat_every(config: dict[str, Any]) -> object:
    agents = config.get("agents")
    defaults = agents.get("defaults") if isinstance(agents, dict) else None
    heartbeat = defaults.get("heartbeat") if isinstance(defaults, dict) else None
    return heartbeat.get("every") if isinstance(heartbeat, dict) else None


def box_patch(config: dict[str, Any], gateway: Gateway) -> dict[str, Any]:
    """What the gateway still lacks of its tailnet traffic and a heartbeat that is off, or
    {} when it has both."""
    section = _gateway_section(config)
    ui = section.get("controlUi")
    ui = ui if isinstance(ui, dict) else {}
    origins = ui.get("allowedOrigins")
    origins = (
        [entry for entry in origins if isinstance(entry, str)] if isinstance(origins, list) else []
    )
    patch: dict[str, Any] = {}
    if section.get("trustedProxies") != [GATEWAY_BRIDGE]:
        patch["trustedProxies"] = [GATEWAY_BRIDGE]
    if origin(gateway) not in origins:
        patch["controlUi"] = {"allowedOrigins": [*origins, origin(gateway)]}
    whole: dict[str, Any] = {"gateway": patch} if patch else {}
    if _heartbeat_every(config) != NO_HEARTBEAT:
        whole["agents"] = {"defaults": {"heartbeat": {"every": NO_HEARTBEAT}}}
    return whole


def problems(config: dict[str, Any], gateway: Gateway) -> list[str]:
    section = _gateway_section(config)
    found = []
    if section.get("trustedProxies") != [GATEWAY_BRIDGE]:
        found.append(
            f"does not trust {GATEWAY_BRIDGE}, the host's address on the gateways' network"
        )
    ui = section.get("controlUi")
    origins = ui.get("allowedOrigins") if isinstance(ui, dict) else None
    if not isinstance(origins, list) or origin(gateway) not in origins:
        found.append(f"the Control UI does not allow {origin(gateway)}")
    if _heartbeat_every(config) != NO_HEARTBEAT:
        found.append("the recurring heartbeat is on")
    return found


def _refuse_the_first_household() -> str | None:
    if load_household().names_members:
        return None
    return (
        "this box's household file names no members, so it is the first household's, whose "
        "gateways were set by hand; nothing was written"
    )


def check(gateways: Sequence[Gateway]) -> int:
    refusal = _refuse_the_first_household()
    if refusal:
        print(refusal)
        return 0
    failed = False
    for gateway in gateways:
        found = problems(read_config(gateway), gateway)
        print(
            f"{gateway.persona}: "
            + ("set as the first household's are" if not found else "; ".join(found))
        )
        failed = failed or bool(found)
    return 1 if failed else 0


def apply(gateways: Sequence[Gateway], *, run: Runner, dry_run: bool) -> int:
    refusal = _refuse_the_first_household()
    if refusal:
        print(f"refused: {refusal}", file=sys.stderr)
        return 1
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for gateway in gateways:
        try:
            config = read_config(gateway)
            patch = box_patch(config, gateway)
            if not patch:
                print(f"{gateway.persona}: nothing to write")
                continue
            config_patch(gateway, patch, run, dry_run=True)
            if dry_run:
                print(f"{gateway.persona}: the gateway validated {patch}; dry run, nothing written")
                continue
            saved = backup(gateway, LABEL, stamp)
            config_patch(gateway, patch, run, dry_run=False)
            remaining = problems(patched(config, patch), gateway)
            if remaining:
                raise RuntimeError("; ".join(remaining))
            print(f"{gateway.persona}: written; previous config at {saved}")
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            print(f"{gateway.persona}: not written: {error}", file=sys.stderr)
            return 1
    return 0


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    applier = commands.add_parser("apply")
    applier.add_argument("--dry-run", action="store_true", help="validate the patch, write nothing")
    applier.add_argument("--gateway", choices=[gateway.persona for gateway in GATEWAYS])
    arguments = parser.parse_args(argv)
    if arguments.command == "check":
        return check(GATEWAYS)
    chosen = [gateway for gateway in GATEWAYS if arguments.gateway in (None, gateway.persona)]
    return apply(chosen, run=run, dry_run=arguments.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
