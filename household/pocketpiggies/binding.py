"""Whom a key holder's link and every read speak for, as PocketPiggies checks it.

PocketPiggies binds a grant to the identity its link was made under and checks that
identity on every read. The household's first two grants were made under each owner's
private Telegram chat, before Telegram was retired, so a key holder given that owner's
Telegram id keeps speaking for it: those grants keep working, and so does relinking them.
Every other key holder speaks for the household person its gateway's app belongs to,
which needs the PocketPiggies support described in docs/deploy/pocketpiggies-server.md.

Either way the owner inside the box is the household person: it is what the key holder
names to the gateway's plugin, and what the plugin checks against its turn's sender.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

PERSON = re.compile(r"[a-z][a-z0-9-]{0,31}")
TELEGRAM_ID = re.compile(r"[1-9][0-9]*")
CLIENT_ID = re.compile(r"[a-z][a-z0-9_-]{0,63}")
# Where PocketPiggies sends the owner back after consent: the Steward app.
APP_REDIRECT = "steward://pocketpiggies/linked"
SUBJECT_TYPE = "household_person"
# The bots the Telegram-bound links returned to, which PocketPiggies has registered as
# those two clients' redirects.
BOT_NAMES = {"corey": "Corey_the_man_bot", "denise": "Denise_the_woman_bot"}


@dataclass(frozen=True, slots=True)
class Binding:
    client_id: str
    owner: str
    telegram_id: str | None = None

    def __post_init__(self) -> None:
        if not CLIENT_ID.fullmatch(self.client_id):
            raise ValueError("the client id must be lowercase letters, digits, - and _")
        if not PERSON.fullmatch(self.owner):
            raise ValueError("the owner must be a household person id")
        if self.telegram_id is not None and (
            not TELEGRAM_ID.fullmatch(self.telegram_id) or self.client_id not in BOT_NAMES
        ):
            raise ValueError("a Telegram binding needs a numeric id and the corey or denise client")
        # PocketPiggies keeps corey and denise for the two Telegram clients and refuses either
        # as a household person's, so a key holder set up that way fails here, not there.
        if self.telegram_id is None and self.client_id in BOT_NAMES:
            raise ValueError("a household person's client is never corey or denise")

    @property
    def is_telegram(self) -> bool:
        return self.telegram_id is not None

    def link_fields(self) -> dict[str, str]:
        """Who a link request, exchange or revoke is for."""
        if self.telegram_id is not None:
            return {
                "telegramUserId": self.telegram_id,
                "chatId": self.telegram_id,
                "chatType": "private",
            }
        return {"subjectType": SUBJECT_TYPE, "subject": self.owner}

    def read_headers(self) -> dict[str, str]:
        """Who every read with the grant is for."""
        if self.telegram_id is not None:
            subject = {
                "X-PocketPiggies-Telegram-User-Id": self.telegram_id,
                "X-PocketPiggies-Chat-Id": self.telegram_id,
                "X-PocketPiggies-Chat-Type": "private",
            }
        else:
            subject = {
                "X-PocketPiggies-Subject-Type": SUBJECT_TYPE,
                "X-PocketPiggies-Subject": self.owner,
            }
        return {"X-PocketPiggies-Client-Id": self.client_id, **subject}

    @property
    def redirect_uri(self) -> str:
        if self.telegram_id is not None:
            return f"https://t.me/{BOT_NAMES[self.client_id]}"
        return APP_REDIRECT

    def stored_identity(self) -> dict[str, str]:
        """What the state file names its owner by. A Telegram-bound key holder keeps the
        name its file was written with, so a connection made before still loads."""
        if self.telegram_id is not None:
            return {"ownerTelegramId": self.telegram_id}
        return {"owner": self.owner}
