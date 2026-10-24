#!/usr/bin/env python3
"""Each gateway takes the phones' connections that `tailscale serve` carries to it.

`tailscale serve` is a reverse proxy in front of each gateway's loopback port, and a
gateway refuses proxied traffic from an address it has not been told is a proxy: the
phone's WebSocket is answered `403 proxy_attribution_required` and the app sits on
"Connecting". On the first household's box both gateways were told by hand on
2026-09-24 (docs/deploy/openclaw.md, "Why the gateway trusts the host as a proxy").

A box whose household file names its members runs the compose file
scripts/household-compose.py writes, whose network gives the host one fixed address,
GATEWAY_BRIDGE, so this writes it: `gateway.trustedProxies` is that address alone, and
`gateway.controlUi.allowedOrigins` gains the gateway's own tailnet address, which lets
the Control UI load from it. The first household's box is left as it was set by hand.

    python3 scripts/openclaw-tailnet.py check
    python3 scripts/openclaw-tailnet.py apply [--gateway <assistant>] [--dry-run]
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

LABEL = "tailnet"


def origin(gateway: Gateway) -> str:
    """The address a phone or browser on the household's tailnet reaches `gateway` at."""
    household = load_household()
    member = household.member(gateway.persona)
    return f"https://{household.gateway_host}:{member.port}"


def _gateway_section(config: dict[str, Any]) -> dict[str, Any]:
    section = config.get("gateway")
    return section if isinstance(section, dict) else {}


def tailnet_patch(config: dict[str, Any], gateway: Gateway) -> dict[str, Any]:
    """What lets the gateway take its tailnet traffic, or {} when it already does."""
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
    return {"gateway": patch} if patch else {}


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
    return found


def _refuse_the_first_household() -> str | None:
    if load_household().names_members:
        return None
    return (
        "this box's household file names no members, so it is the first household's, whose "
        "proxies were set by hand for its own networks; nothing was written"
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
            + ("takes its tailnet traffic" if not found else "; ".join(found))
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
            patch = tailnet_patch(config, gateway)
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
