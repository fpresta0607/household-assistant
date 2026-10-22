#!/usr/bin/env python3
"""Starts one home key holder: household-home@corey or household-home@denise.

It reads the house from the key holder's own state directory, which no container mounts:
config.json with Home Assistant's loopback address, the thermostat and Spotify entities,
the name the Apple TV's Spotify app goes by and the TV's tailnet address and Companion
port, and two root-written secrets, the assistants' Home Assistant token and the Apple
TV pairing, which can come after the first start. Then it serves household/home/server.py
on the socket its unit binds into that gateway's state. Nothing it reads is printed.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path

from household.home.actions import Entities, Home
from household.home.apple_tv import CompanionTV
from household.home.hass import HassClient
from household.home.server import KeyHolder, serve

STATE = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/household-home"))
SOCKET = Path("/run/household-home/home.sock")
LOOPBACK = ("http://127.0.0.1:", "http://localhost:")


def _secret(state: Path, name: str) -> str | None:
    try:
        value = (state / name).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    if not value:
        raise ValueError(f"the key holder's {name} is empty")
    return value


def build_home(state: Path) -> Home:
    config = json.loads((state / "config.json").read_text(encoding="utf-8"))
    base = config.get("hass")
    if not isinstance(base, str) or not base.startswith(LOOPBACK):
        raise ValueError("Home Assistant must be on loopback")
    entities = config.get("entities")
    names = ("thermostat", "spotify", "tv_spotify_name")
    if not isinstance(entities, dict) or any(
        not isinstance(entities.get(name), str) for name in names
    ):
        raise ValueError("config.json must name the thermostat, Spotify and the TV's Spotify name")
    tv = config.get("tv")
    port = tv.get("port") if isinstance(tv, dict) else None
    if (
        not isinstance(tv, dict)
        or not isinstance(tv.get("address"), str)
        or not isinstance(port, int)
        or not 0 < port < 65536
    ):
        raise ValueError("config.json must give the TV's address and Companion port")
    token = _secret(state, "token")
    if token is None:
        raise ValueError("the key holder has no token in its state")
    return Home(
        hass=HassClient(base=base, token=token),
        # Until the TV is paired, its steps answer that it is not, and the rest works.
        tv=CompanionTV(
            address=tv["address"], port=port, credentials=_secret(state, "apple-tv-credentials")
        ),
        entities=Entities(**{name: entities[name] for name in names}),
        wait=time.sleep,
    )


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: home-keyholder.py <persona>", file=sys.stderr)
        return 2
    print(f"household-home@{argv[0]}: serving {SOCKET}", file=sys.stderr, flush=True)
    asyncio.run(serve(KeyHolder(home=build_home(STATE)), SOCKET))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
