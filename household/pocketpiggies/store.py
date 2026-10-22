"""The key holder's one state file: client credential, pending link and read grant."""

from __future__ import annotations

import contextlib
import json
import os
import re
import secrets
import stat
from dataclasses import dataclass
from pathlib import Path

from .errors import PocketPiggiesError

MAX_STORE_BYTES = 64 * 1024
STORE_VERSION = 1
CLIENT_CREDENTIAL = re.compile(r"ppc_[A-Za-z0-9_-]{43}")
GRANT_TOKEN = re.compile(r"ppa_ro_[A-Za-z0-9_-]{43}")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.IGNORECASE)
CODE_VERIFIER = re.compile(r"[A-Za-z0-9_-]{43}")
MAX_ATTEMPTS = 120


@dataclass(slots=True)
class PendingLink:
    request_id: str
    code_verifier: str
    expires_at: int
    last_attempt_at: int | None
    attempts: int


@dataclass(frozen=True, slots=True)
class Grant:
    token: str
    expires_at: int
    account_id: str
    grant_id: str


@dataclass(slots=True)
class LinkState:
    client_credential: str | None
    pending: PendingLink | None
    grant: Grant | None


def invalid_store() -> PocketPiggiesError:
    return PocketPiggiesError(
        "credential_store_invalid",
        "PocketPiggies credential storage needs administrator attention. No account was connected.",
    )


def _text(value: object, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise invalid_store()
    return value


def _non_negative(value: object) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise invalid_store()
    return value


def _pending(value: object) -> PendingLink | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise invalid_store()
    attempts = _non_negative(value.get("attempts"))
    if attempts > MAX_ATTEMPTS:
        raise invalid_store()
    last_attempt_at = value.get("lastAttemptAt")
    return PendingLink(
        request_id=_text(value.get("requestId"), UUID),
        code_verifier=_text(value.get("codeVerifier"), CODE_VERIFIER),
        expires_at=_non_negative(value.get("expiresAt")),
        last_attempt_at=None if last_attempt_at is None else _non_negative(last_attempt_at),
        attempts=attempts,
    )


def _grant(value: object) -> Grant | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise invalid_store()
    return Grant(
        token=_text(value.get("token"), GRANT_TOKEN),
        expires_at=_non_negative(value.get("expiresAt")),
        account_id=_text(value.get("accountId"), UUID),
        grant_id=_text(value.get("grantId"), UUID),
    )


def _client_credential(value: object) -> str | None:
    return None if value is None else _text(value, CLIENT_CREDENTIAL)


def _serialize(owner_telegram_id: str, state: LinkState) -> bytes:
    pending = state.pending
    grant = state.grant
    document = {
        "version": STORE_VERSION,
        "ownerTelegramId": owner_telegram_id,
        "clientCredential": state.client_credential,
        "pending": None
        if pending is None
        else {
            "requestId": pending.request_id,
            "codeVerifier": pending.code_verifier,
            "expiresAt": pending.expires_at,
            "lastAttemptAt": pending.last_attempt_at,
            "attempts": pending.attempts,
        },
        "grant": None
        if grant is None
        else {
            "token": grant.token,
            "expiresAt": grant.expires_at,
            "accountId": grant.account_id,
            "grantId": grant.grant_id,
        },
    }
    return json.dumps(document, separators=(",", ":")).encode("utf-8")


class CredentialStore:
    """One owner's link state in a 0600 file inside a 0700 directory this uid owns.

    Every open refuses symlinks, other owners, group or world access, hard links and
    oversized files, and every write replaces the file atomically, so a crash leaves
    either the old state or the new one and never a partial credential.
    """

    def __init__(self, directory: Path, owner_telegram_id: str) -> None:
        self.directory = directory
        self.owner_telegram_id = owner_telegram_id
        self.name = "connection.json"

    def _open_directory(self) -> int | None:
        try:
            descriptor = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return None
        except OSError as error:
            raise invalid_store() from error
        metadata = os.fstat(descriptor)
        if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            os.close(descriptor)
            raise invalid_store()
        return descriptor

    def load(self) -> LinkState:
        directory = self._open_directory()
        if directory is None:
            return LinkState(None, None, None)
        try:
            try:
                descriptor = os.open(
                    self.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory
                )
            except FileNotFoundError:
                return LinkState(None, None, None)
            except OSError as error:
                raise invalid_store() from error
            with os.fdopen(descriptor, "rb") as stream:
                metadata = os.fstat(stream.fileno())
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_nlink != 1
                    or metadata.st_uid != os.geteuid()
                    or stat.S_IMODE(metadata.st_mode) != 0o600
                    or metadata.st_size > MAX_STORE_BYTES
                ):
                    raise invalid_store()
                raw = stream.read(MAX_STORE_BYTES + 1)
        finally:
            os.close(directory)
        try:
            stored = json.loads(raw)
        except (RecursionError, UnicodeDecodeError, ValueError) as error:
            raise invalid_store() from error
        if (
            not isinstance(stored, dict)
            or stored.get("version") != STORE_VERSION
            or stored.get("ownerTelegramId") != self.owner_telegram_id
            or not {"clientCredential", "pending", "grant"} <= stored.keys()
        ):
            raise invalid_store()
        return LinkState(
            _client_credential(stored["clientCredential"]),
            _pending(stored["pending"]),
            _grant(stored["grant"]),
        )

    def save(self, state: LinkState) -> None:
        # Whatever is there must still be this owner's own private file; anything else
        # was changed behind the key holder's back and is left for an administrator.
        self.load()
        serialized = _serialize(self.owner_telegram_id, state)
        if len(serialized) > MAX_STORE_BYTES:
            raise invalid_store()
        directory = self._open_directory()
        if directory is None:
            raise invalid_store()
        temporary = f".connection-{secrets.token_hex(16)}"
        try:
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory,
            )
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(serialized)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.name, src_dir_fd=directory, dst_dir_fd=directory)
                os.fsync(directory)
            except BaseException:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(temporary, dir_fd=directory)
                raise
        except OSError as error:
            raise invalid_store() from error
        finally:
            os.close(directory)
