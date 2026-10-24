#!/usr/bin/env python3
"""Run one assistant's PocketPiggies key holder. systemd starts it as
household-pocketpiggies@<persona>.service, under that persona's own system user.

The owner, the PocketPiggies client and, for a grant made before Telegram was retired,
the owner's Telegram id come from the instance drop-in the installer writes; the state
directory from systemd's StateDirectory=; and the socket path is the bind mount of the
gateway's own pocketpiggies directory.
"""

from __future__ import annotations

import argparse
import asyncio
import os
from collections.abc import Sequence
from pathlib import Path

from household.pocketpiggies.api import PocketPiggiesApi
from household.pocketpiggies.binding import PERSON, Binding
from household.pocketpiggies.link import AccountLink
from household.pocketpiggies.reads import Reader
from household.pocketpiggies.server import KeyHolder, serve
from household.pocketpiggies.store import CredentialStore

SOCKET = Path("/run/household-pocketpiggies/broker.sock")


def binding_from(persona: str, environment: dict[str, str]) -> Binding:
    """The drop-in's binding: POCKETPIGGIES_OWNER, POCKETPIGGIES_CLIENT_ID (the persona when
    unset) and POCKETPIGGIES_TELEGRAM_ID for a Telegram-bound grant."""
    return Binding(
        client_id=environment.get("POCKETPIGGIES_CLIENT_ID") or persona,
        owner=environment.get("POCKETPIGGIES_OWNER", ""),
        telegram_id=environment.get("POCKETPIGGIES_TELEGRAM_ID") or None,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("persona")
    persona = parser.parse_args(argv).persona
    state = os.environ.get("STATE_DIRECTORY", "")
    if not PERSON.fullmatch(persona) or not state.startswith("/"):
        parser.error("name a persona, and STATE_DIRECTORY must be set")
    try:
        binding = binding_from(persona, dict(os.environ))
    except ValueError as error:
        parser.error(f"the drop-in's binding is refused: {error}")
    api = PocketPiggiesApi()
    link = AccountLink(
        store=CredentialStore(Path(state), binding.stored_identity()),
        api=api,
        binding=binding,
    )
    asyncio.run(serve(KeyHolder(link=link, reader=Reader(api=api, link=link)), SOCKET))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
