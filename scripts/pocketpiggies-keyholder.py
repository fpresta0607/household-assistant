#!/usr/bin/env python3
"""Run one assistant's PocketPiggies key holder. systemd starts it as
household-pocketpiggies@<persona>.service, under that persona's own system user.

The owner's Telegram id comes from the instance drop-in the installer writes, the
state directory from systemd's StateDirectory=, and the socket path is the bind
mount of the gateway's own pocketpiggies directory.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import re
from collections.abc import Sequence
from pathlib import Path

from household.pocketpiggies.api import PocketPiggiesApi
from household.pocketpiggies.link import BOT_NAMES, AccountLink
from household.pocketpiggies.reads import Reader
from household.pocketpiggies.server import KeyHolder, serve
from household.pocketpiggies.store import CredentialStore

SOCKET = Path("/run/household-pocketpiggies/broker.sock")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("persona", choices=sorted(BOT_NAMES))
    persona = parser.parse_args(argv).persona
    owner = os.environ.get("POCKETPIGGIES_OWNER_TELEGRAM_ID", "")
    state = os.environ.get("STATE_DIRECTORY", "")
    if not re.fullmatch(r"[1-9][0-9]*", owner) or not state.startswith("/"):
        parser.error("POCKETPIGGIES_OWNER_TELEGRAM_ID and STATE_DIRECTORY must be set")
    api = PocketPiggiesApi()
    link = AccountLink(
        store=CredentialStore(Path(state), owner),
        api=api,
        client_id=persona,
        telegram_user_id=owner,
    )
    asyncio.run(serve(KeyHolder(link=link, reader=Reader(api=api, link=link)), SOCKET))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
