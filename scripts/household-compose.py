#!/usr/bin/env python3
"""Write a household's compose file from its household file.

The first household's box runs deploy/openclaw/docker-compose.yml as the repository holds
it, Home Assistant and Gia's mailbox included. Every household whose file names its
members runs the file this writes instead: one gateway for each member, the same image,
the same hardening and the same mounts as the first household's, each gateway mounting
only the other's family-room share, read-only, and nothing else of its state.

The image is the one deploy/openclaw/docker-compose.yml pins, so a household is always on
the gateway the first one runs, and a release that moves the pin moves both.

Each gateway has a network of its own, so neither container can reach the other's gateway,
on a fixed subnet, so the address the host reaches it from, which it must trust as its
tailnet proxy, is known before it starts (GATEWAY_NETWORKS in household_file.py).

The output is YAML in the narrow form `emit` writes, every string quoted the way JSON
quotes it, so the box needs no YAML library to write it, and the shell checks
that read one service's `image:` or `memory:` out of the deployed file read it as they read
the first household's.

    python3 scripts/household-compose.py > /opt/household-assistant/docker-compose.yml
    python3 scripts/household-compose.py --check /opt/household-assistant/docker-compose.yml
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from household_file import (
    HOUSEHOLD_FILE,
    Household,
    Member,
    load_household,
)

ROOT = Path(__file__).resolve().parent.parent
PINNED = ROOT / "deploy" / "openclaw" / "docker-compose.yml"
IMAGE = re.compile(r"^\s+image: (openclaw/openclaw:\S+@sha256:[0-9a-f]{64})\s*$", re.MULTILINE)

# The plugins and the Bible, root-owned on the host and read-only in every gateway.
PLUGINS = "/opt/household-assistant/plugins:/opt/household-plugins:ro"
SCRIPTURE = "/var/lib/household-assistant/scripture:/opt/household-scripture:ro"
PEER_SHARE = "/opt/household-peer"
# What each gateway may use of the box's CPUs. Docker refuses a limit above the box's own
# count, so on a box with one CPU each gateway may use all of it.
CPUS = 1.5


def cpu_limit(available: int | None = None) -> str:
    count = available if available is not None else (os.cpu_count() or 1)
    return f"{min(CPUS, float(max(count, 1))):.2f}"


class ComposeError(ValueError):
    """The household cannot be written as a compose file."""


def pinned_image(source: Path = PINNED) -> str:
    """The one image the first household's compose file pins for its gateways."""
    images: set[str] = set(IMAGE.findall(source.read_text(encoding="utf-8")))
    if len(images) != 1:
        raise ComposeError(f"{source} must pin exactly one gateway image, not {sorted(images)}")
    return images.pop()


def network_name(member: Member) -> str:
    return f"gateway-{member.assistant}"


def gateway(member: Member, peer: Member, household: Household, image: str) -> dict[str, Any]:
    return {
        "image": image,
        "container_name": member.container,
        "restart": "unless-stopped",
        # The gateway's token and keys, mode 0600, made on the box and never committed.
        "env_file": [str(member.env_file)],
        "environment": {
            "HOME": "/home/node",
            "OPENCLAW_HOME": "/home/node",
            # Container-side paths, so a host path in the env file cannot leak into them.
            "OPENCLAW_STATE_DIR": "/home/node/.openclaw",
            "OPENCLAW_CONFIG_DIR": "/home/node/.openclaw",
            "OPENCLAW_CONFIG_PATH": "/home/node/.openclaw/openclaw.json",
            "OPENCLAW_WORKSPACE_DIR": "/home/node/.openclaw/workspace",
            "OPENCLAW_GATEWAY_PORT": "18789",
            "OPENCLAW_DISABLE_BONJOUR": "1",
            # The household's own clock, so a 7pm event is 7pm where they live.
            "TZ": household.timezone,
            "GOG_HOME": "/home/node/.openclaw/gog",
            "GOG_KEYRING_BACKEND": "file",
        },
        "volumes": [
            f"{member.state_dir}:/home/node/.openclaw",
            f"{member.secrets_dir}:/home/node/.config/openclaw",
            f"{member.codex_dir}:/home/node/.codex",
            f"{member.bin_dir}:/home/node/.local/bin",
            PLUGINS,
            SCRIPTURE,
            # The other gateway's half of the family room and nothing else of its state.
            f"{peer.state_dir / 'household-app' / 'share'}:{PEER_SHARE}:ro",
        ],
        # Loopback only; `tailscale serve` carries the port onto the household's tailnet.
        "ports": [f"127.0.0.1:{member.port}:18789"],
        "networks": [network_name(member)],
        "cap_drop": ["NET_RAW", "NET_ADMIN"],
        "security_opt": ["no-new-privileges:true"],
        "init": True,
        "command": ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"],
        "healthcheck": {
            "test": ["CMD", "node", "dist/docker-healthcheck.js"],
            "interval": "30s",
            "timeout": "5s",
            "retries": 5,
            "start_period": "30s",
        },
        "logging": {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}},
        "deploy": {"resources": {"limits": {"cpus": cpu_limit(), "memory": member.memory}}},
    }


def compose(household: Household, image: str) -> dict[str, Any]:
    if not household.names_members:
        raise ComposeError(
            "the household file names no members: this is the first household's box, "
            "which runs deploy/openclaw/docker-compose.yml as the repository holds it"
        )
    first, second = household.members
    return {
        "name": "household-assistant",
        "services": {
            first.container: gateway(first, second, household, image),
            second.container: gateway(second, first, household, image),
        },
        "networks": {
            network_name(member): {"ipam": {"config": [{"subnet": subnet, "gateway": bridge}]}}
            for member in household.members
            for subnet, bridge in [household.network(member)]
        },
    }


def _scalar(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value)
    raise ComposeError(f"cannot write {value!r} into a compose file")


def _key(key: str) -> str:
    return key if re.fullmatch(r"[A-Za-z0-9_.-]+", key) else json.dumps(key)


def emit(value: object, indent: int = 0) -> list[str]:
    """YAML lines for nested dicts and lists of strings, numbers and booleans."""
    pad = " " * indent
    lines: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, (dict, list)) and item:
                lines.append(f"{pad}{_key(key)}:")
                lines.extend(emit(item, indent + 2))
            elif isinstance(item, (dict, list)):
                lines.append(f"{pad}{_key(key)}: {'{}' if isinstance(item, dict) else '[]'}")
            else:
                lines.append(f"{pad}{_key(key)}: {_scalar(item)}")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, (dict, list)):
                nested = emit(item, indent + 2)
                lines.append(f"{pad}- {nested[0].lstrip()}")
                lines.extend(nested[1:])
            else:
                lines.append(f"{pad}- {_scalar(item)}")
    else:
        raise ComposeError(f"cannot write {value!r} as a block")
    return lines


def rendered(household: Household, image: str) -> str:
    header = [
        "# Written by scripts/household-compose.py from the household file. Edit the",
        "# household file and write it again rather than editing this.",
    ]
    return "\n".join([*header, *emit(compose(household, image))]) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--household", type=Path, default=HOUSEHOLD_FILE)
    parser.add_argument(
        "--check", type=Path, help="exit 1 when this file is not what would be written"
    )
    arguments = parser.parse_args(argv)
    try:
        text = rendered(load_household(arguments.household), pinned_image())
    except ComposeError as error:
        print(f"household-compose: {error}", file=sys.stderr)
        return 2
    if arguments.check is not None:
        current = arguments.check.read_text(encoding="utf-8") if arguments.check.exists() else ""
        if current != text:
            print(f"household-compose: {arguments.check} is not the household's", file=sys.stderr)
            return 1
        return 0
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
