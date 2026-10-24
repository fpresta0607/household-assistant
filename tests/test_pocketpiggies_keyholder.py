"""The PocketPiggies key holder: its store, link flow, reads and MCP socket, against a fake."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from collections.abc import Callable, Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

from household.pocketpiggies.api import PocketPiggiesApi
from household.pocketpiggies.binding import Binding
from household.pocketpiggies.errors import PocketPiggiesError
from household.pocketpiggies.link import AccountLink
from household.pocketpiggies.reads import SYNCS_PER_DAY, Reader
from household.pocketpiggies.server import (
    CALLS_PER_MINUTE,
    LINKS_PER_MINUTE,
    MAX_MESSAGE_BYTES,
    OWNER_META,
    READS_PER_HOUR,
    KeyHolder,
    check_socket_directory,
    prepare_socket,
    serve,
)
from household.pocketpiggies.store import CredentialStore, Grant, LinkState
from tests.pocketpiggies_fake import (
    ACCOUNT,
    CATALOG,
    CLIENT_CREDENTIAL,
    OWNER,
    PERSON,
    PUBLISHED_CATALOG,
    FakeState,
    Seen,
    fake_pocketpiggies,
)

ROOT = Path(__file__).resolve().parent.parent
SECRET = "ppa_ro_" + "Z" * 43
pytestmark = pytest.mark.skipif(os.name != "posix", reason="the key holder runs only on Linux")
# Corey's key holder as it runs for Franco: bound to his Telegram chat, where his grant was
# made, and, once he links again under the household binding, to him as the app names him.
TELEGRAM = Binding("corey", PERSON, OWNER)
HOUSEHOLD = Binding("hh-7f3a9c21ab12", PERSON)
IDENTITY = TELEGRAM.stored_identity()


class Clock:
    """Starts at the real time, because the fake's expiry times are real, and moves on demand."""

    def __init__(self) -> None:
        self.at = int(time.time() * 1000)

    def __call__(self) -> int:
        return self.at


@pytest.fixture
def fake() -> Iterator[FakeState]:
    with fake_pocketpiggies() as state:
        yield state


@pytest.fixture
def state_directory(tmp_path: Path) -> Path:
    directory = tmp_path / "state"
    directory.mkdir(mode=0o700)
    directory.chmod(0o700)
    return directory


def provisioned(directory: Path) -> CredentialStore:
    store = CredentialStore(directory, IDENTITY)
    store.save(LinkState(CLIENT_CREDENTIAL, None, None))
    return store


def make_link(
    fake: FakeState,
    store: CredentialStore,
    clock: Callable[[], int] | None = None,
    binding: Binding = TELEGRAM,
) -> AccountLink:
    return AccountLink(
        store=store,
        api=PocketPiggiesApi(fake.base_url, timeout=5),
        binding=binding,
        **({"now": clock} if clock else {}),
    )


def connected(fake: FakeState, directory: Path) -> AccountLink:
    link = make_link(fake, provisioned(directory))
    request_id = link.start()["url"].rsplit("=", 1)[1]
    fake.approve(request_id)
    link.complete(request_id)
    return link


# The store.


def test_store_round_trips_only_for_its_owner(state_directory: Path) -> None:
    store = CredentialStore(state_directory, IDENTITY)
    assert store.load() == LinkState(None, None, None)
    grant = Grant(SECRET, 2_000_000_000_000, ACCOUNT, ACCOUNT)
    store.save(LinkState(CLIENT_CREDENTIAL, None, grant))

    assert store.load().grant == grant
    with pytest.raises(PocketPiggiesError) as refused:
        CredentialStore(state_directory, {"ownerTelegramId": "7000000009"}).load()
    assert refused.value.code == "credential_store_invalid"
    assert sorted(path.name for path in state_directory.iterdir()) == ["connection.json"]
    assert (state_directory / "connection.json").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize(
    "content",
    [
        "not json",
        "[]",
        json.dumps({"version": 2, "ownerTelegramId": OWNER}),
        json.dumps(
            {"version": 1, "ownerTelegramId": OWNER, "clientCredential": None, "pending": None}
        ),
        json.dumps(
            {
                "version": 1,
                "ownerTelegramId": OWNER,
                "clientCredential": "ppc_short",
                "pending": None,
                "grant": None,
            }
        ),
        json.dumps(
            {
                "version": 1,
                "ownerTelegramId": OWNER,
                "clientCredential": None,
                "pending": None,
                "grant": {
                    "token": "ppa_" + "L" * 43,
                    "expiresAt": 1,
                    "accountId": ACCOUNT,
                    "grantId": ACCOUNT,
                },
            }
        ),
    ],
)
def test_store_refuses_corrupt_state_without_echoing_it(
    state_directory: Path, content: str
) -> None:
    path = state_directory / "connection.json"
    path.write_text(content)
    path.chmod(0o600)
    with pytest.raises(PocketPiggiesError) as refused:
        CredentialStore(state_directory, IDENTITY).load()
    assert refused.value.code == "credential_store_invalid"
    assert "ppc_" not in refused.value.message and "ppa_" not in refused.value.message


@pytest.mark.parametrize("unsafe", ["symlink", "hard link", "group readable", "open directory"])
def test_store_refuses_unsafe_files(state_directory: Path, tmp_path: Path, unsafe: str) -> None:
    store = provisioned(state_directory)
    path = state_directory / "connection.json"
    if unsafe == "symlink":
        target = tmp_path / "elsewhere.json"
        path.rename(target)
        path.symlink_to(target)
    elif unsafe == "hard link":
        os.link(path, tmp_path / "second-name.json")
    elif unsafe == "group readable":
        path.chmod(0o640)
    else:
        state_directory.chmod(0o750)
    for operation in (store.load, lambda: store.save(LinkState(CLIENT_CREDENTIAL, None, None))):
        with pytest.raises(PocketPiggiesError):
            operation()


# Linking.


def test_consent_binds_a_grant_that_never_leaves_the_key_holder(
    fake: FakeState, state_directory: Path
) -> None:
    clock = Clock()
    link = make_link(fake, provisioned(state_directory), clock)
    started = link.start()
    request_id = started["url"].rsplit("=", 1)[1]
    assert "names your assistant" not in started["text"], "a Telegram consent names its bot"
    assert started["url"] == f"{fake.base_url}/assistant/connect?request={request_id}"
    with pytest.raises(PocketPiggiesError) as pending:
        link.complete(request_id)
    assert pending.value.code == "authorization_pending"

    fake.approve(request_id)
    clock.at += 6_000
    finished = link.complete(request_id)

    assert "connected" in finished["text"]
    stored = link.store.load()
    assert stored.pending is None and stored.grant is not None
    assert stored.grant.token in fake.grants
    for answer in (started, finished):
        assert "ppa_" not in json.dumps(answer) and "ppc_" not in json.dumps(answer)
    exchange = [seen for seen in fake.seen if seen.path.endswith("/exchange")][-1]
    assert exchange.headers["authorization"] == f"Bearer {CLIENT_CREDENTIAL}"
    assert exchange.body["telegramUserId"] == OWNER and exchange.body["chatType"] == "private"


def test_the_household_binding_links_and_reads_as_the_household_person(
    fake: FakeState, tmp_path: Path
) -> None:
    """A key holder with no Telegram id speaks for the person the app names, returns the
    owner to the Steward app and keeps its file under that name
    (docs/deploy/pocketpiggies-server.md)."""
    directory = tmp_path / "household"
    directory.mkdir(mode=0o700)
    directory.chmod(0o700)
    store = CredentialStore(directory, HOUSEHOLD.stored_identity())
    store.save(LinkState(CLIENT_CREDENTIAL, None, None))
    link = make_link(fake, store, binding=HOUSEHOLD)
    started_link = link.start()
    request_id = started_link["url"].rsplit("=", 1)[1]
    # PocketPiggies' page names the assistant by its client id, so the person can check it.
    assert f"names your assistant {HOUSEHOLD.client_id}" in started_link["text"]
    fake.approve(request_id)
    link.complete(request_id)
    Reader(api=PocketPiggiesApi(fake.base_url, timeout=5), link=link).catalog()

    for seen in fake.seen:
        if seen.path.startswith("/api/assistant/link/"):
            assert seen.body["subjectType"] == "household_person"
            assert seen.body["subject"] == PERSON
            assert "telegramUserId" not in seen.body and "chatId" not in seen.body
    started = next(seen for seen in fake.seen if seen.path.endswith("/requests"))
    assert started.body["redirectUri"] == "steward://pocketpiggies/linked"
    read = fake.seen[-1]
    assert read.headers["x-pocketpiggies-subject-type"] == "household_person"
    assert read.headers["x-pocketpiggies-subject"] == PERSON
    assert "x-pocketpiggies-telegram-user-id" not in read.headers
    stored = json.loads((directory / "connection.json").read_text())
    assert stored["owner"] == PERSON and "ownerTelegramId" not in stored
    # A file written under one binding is never read under the other.
    with pytest.raises(PocketPiggiesError) as refused:
        CredentialStore(directory, IDENTITY).load()
    assert refused.value.code == "credential_store_invalid"


def test_a_binding_is_refused_unless_it_names_a_person_and_a_known_telegram_client() -> None:
    assert TELEGRAM.redirect_uri == "https://t.me/Corey_the_man_bot"
    assert Binding("hh-marina", "marina").redirect_uri == "steward://pocketpiggies/linked"
    for client, owner, telegram in [
        ("corey", "Franco", None),
        ("corey", "", None),
        ("Corey", "franco", None),
        ("hh-marina", "marina", OWNER),
        ("corey", "marina", None),
        ("corey", "franco", "telegram:7000000001"),
    ]:
        with pytest.raises(ValueError):
            Binding(client, owner, telegram)


def test_an_exchange_is_single_use_and_bound_to_the_pending_request(
    fake: FakeState, state_directory: Path
) -> None:
    link = connected(fake, state_directory)
    other = link.start()["url"].rsplit("=", 1)[1]
    for request_id in ("not-a-uuid", "0b4d3c1e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"):
        with pytest.raises(PocketPiggiesError) as refused:
            link.complete(request_id)
        assert refused.value.code == "invalid_request"
    fake.approve(other)
    link.complete(other)
    with pytest.raises(PocketPiggiesError) as replayed:
        link.complete(other)
    assert replayed.value.code == "invalid_request"


def test_retries_are_spaced_and_capped_and_expiry_clears_the_request(
    fake: FakeState, state_directory: Path
) -> None:
    clock = Clock()
    link = make_link(fake, provisioned(state_directory), clock)
    request_id = link.start()["url"].rsplit("=", 1)[1]
    with pytest.raises(PocketPiggiesError):
        link.complete(request_id)
    with pytest.raises(PocketPiggiesError) as spaced:
        link.complete(request_id)
    assert spaced.value.code == "rate_limited"
    state = link.store.load()
    assert state.pending is not None
    state.pending.attempts = 120
    link.store.save(state)
    clock.at += 6_000
    with pytest.raises(PocketPiggiesError) as capped:
        link.status()
    assert capped.value.code == "expired_request"
    assert link.store.load().pending is None

    request_id = link.start()["url"].rsplit("=", 1)[1]
    clock.at += 600_001
    with pytest.raises(PocketPiggiesError) as expired:
        link.complete(request_id)
    assert expired.value.code == "expired_request"
    assert link.store.load().pending is None


def test_denied_consent_clears_the_request_and_connect_can_retry(
    fake: FakeState, state_directory: Path
) -> None:
    link = make_link(fake, provisioned(state_directory))
    request_id = link.start()["url"].rsplit("=", 1)[1]
    fake.approve(request_id, decision="access_denied")
    with pytest.raises(PocketPiggiesError) as denied:
        link.complete(request_id)
    assert denied.value.code == "access_denied"
    assert link.store.load().pending is None
    assert link.start()["url"]


def test_reconnect_keeps_the_old_grant_and_refuses_a_different_account(
    fake: FakeState, state_directory: Path
) -> None:
    link = connected(fake, state_directory)
    before = link.store.load().grant
    request_id = link.start()["url"].rsplit("=", 1)[1]
    assert link.store.load().grant == before
    fake.account_id = "99999999-2222-4333-8444-555555555555"
    fake.approve(request_id)
    with pytest.raises(PocketPiggiesError) as refused:
        link.complete(request_id)
    assert refused.value.code == "invalid_binding"
    assert link.store.load().grant == before


def test_disconnect_clears_here_first_and_a_retry_still_revokes(
    fake: FakeState, state_directory: Path
) -> None:
    link = connected(fake, state_directory)
    fake.is_revoke_failing = True
    with pytest.raises(PocketPiggiesError) as unconfirmed:
        link.disconnect()
    assert unconfirmed.value.code == "revoke_unconfirmed"
    assert link.store.load().grant is None
    fake.is_revoke_failing = False
    assert "revoked" in link.disconnect()["text"]
    assert all(grant["revoked"] for grant in fake.grants.values())


def test_linking_needs_a_provisioned_client_credential(
    fake: FakeState, state_directory: Path
) -> None:
    link = make_link(fake, CredentialStore(state_directory, IDENTITY))
    with pytest.raises(PocketPiggiesError) as refused:
        link.start()
    assert refused.value.code == "invalid_client"
    assert fake.seen == []


@pytest.mark.parametrize(
    "answer",
    [
        {"requestId": "nope", "verificationUri": "x", "expiresAt": "2099-01-01T00:00:00Z"},
        {
            "requestId": ACCOUNT,
            "verificationUri": f"https://evil.example/assistant/connect?request={ACCOUNT}",
        },
        {"requestId": ACCOUNT, "verificationUri": "", "expiresAt": "1999-01-01T00:00:00Z"},
    ],
)
def test_malformed_link_answers_never_store_a_request(
    fake: FakeState, state_directory: Path, answer: dict[str, Any]
) -> None:
    fake.raw_answer = json.dumps(answer).encode()
    link = make_link(fake, provisioned(state_directory))
    with pytest.raises(PocketPiggiesError) as refused:
        link.start()
    assert refused.value.code == "link_unavailable"
    assert link.store.load().pending is None


# Reads.


def test_catalog_and_reads_carry_the_pinned_owner_binding(
    fake: FakeState, state_directory: Path
) -> None:
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    catalog = reader.catalog()
    assert catalog["data"]["reads"][0]["id"] == "account.safe_to_transfer"
    reader.read("account.safe_to_transfer", {})
    for seen in fake.seen[-2:]:
        assert seen.headers["x-pocketpiggies-client-id"] == "corey"
        assert seen.headers["x-pocketpiggies-telegram-user-id"] == OWNER
        assert seen.headers["x-pocketpiggies-chat-id"] == OWNER
        assert seen.headers["x-pocketpiggies-chat-type"] == "private"
        assert seen.headers["authorization"].startswith("Bearer ppa_ro_")


def test_reads_fill_path_params_and_send_query_or_body(
    fake: FakeState, state_directory: Path
) -> None:
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    piggy = "0b4d3c1e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"
    result = reader.read(
        "piggies.income_percent", {"piggyId": piggy, "month": "2026-09", "piggy": ["a", "b"]}
    )
    assert result["data"]["path"] == f"/api/piggies/{piggy}/income-percent"
    assert fake.seen[-1].query == {"month": ["2026-09"], "piggy": ["a", "b"]}
    reader.read("pnl", {"periodKey": "2026-09"})
    assert fake.seen[-1].method == "POST" and fake.seen[-1].body == {"periodKey": "2026-09"}
    assert result["source"] == "PocketPiggies" and result["read"] == "piggies.income_percent"


@pytest.mark.parametrize(
    ("read", "params", "code"),
    [
        ("account.transfer_money", {}, "unknown_read"),
        ("Bad Id", {}, "invalid_arguments"),
        ("piggies.income_percent", {}, "invalid_arguments"),
        ("piggies.income_percent", {"piggyId": "../../admin"}, "invalid_arguments"),
        ("pnl", {"periodKey": {"nested": True}}, "invalid_arguments"),
        ("pnl", {"periodKey": "x" * 501}, "invalid_arguments"),
        ("pnl", {f"k{index}": index for index in range(21)}, "invalid_arguments"),
        ("pnl", {"user-id": "someone"}, "invalid_arguments"),
        ("pnl", [], "invalid_arguments"),
        ("pnl", {"periodKey": "2026-09", "userId": "someone"}, "invalid_arguments"),
        ("pnl", {}, "invalid_arguments"),
        ("pnl", {"periodKey": 202609}, "invalid_arguments"),
        ("pnl", {"periodKey": "2026-09-30-x"}, "invalid_arguments"),
        ("piggies.income_percent", {"piggyId": "0" * 36, "limit": 11}, "invalid_arguments"),
        ("piggies.income_percent", {"piggyId": "0" * 36, "limit": True}, "invalid_arguments"),
        (
            "piggies.income_percent",
            {"piggyId": "0" * 36, "piggy": ["a", "b", "c", "d"]},
            "invalid_arguments",
        ),
    ],
)
def test_reads_outside_the_catalog_or_with_bad_params_send_nothing(
    fake: FakeState, state_directory: Path, read: str, params: object, code: str
) -> None:
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    reader.catalog()
    before = len(fake.seen)
    with pytest.raises(PocketPiggiesError) as refused:
        reader.read(read, params)
    assert refused.value.code == code
    assert len(fake.seen) == before


@pytest.mark.parametrize(
    "catalog",
    [
        {"schemaVersion": 2, "reads": [], "tables": []},
        {
            "schemaVersion": 1,
            "reads": [{"id": "x", "method": "PATCH", "path": "/api/transactions/{id}"}],
            "tables": [],
        },
        {
            "schemaVersion": 1,
            "reads": [{"id": "x", "method": "GET", "path": "https://evil.example/api"}],
            "tables": [],
        },
        {
            "schemaVersion": 1,
            "reads": [{"id": "x", "method": "GET", "path": "/api/../admin"}],
            "tables": [],
        },
        {
            "schemaVersion": 1,
            "reads": [{"id": "x", "method": "POST", "path": "/api/assistant/link/revoke"}],
            "tables": [],
        },
        {
            "schemaVersion": 1,
            "reads": [{"id": "x", "method": "GET", "path": "/api/a"}] * 2,
            "tables": [],
        },
        {"schemaVersion": 1, "reads": [], "tables": [{"name": "Drop Table"}]},
        {"schemaVersion": 1, "reads": [{**CATALOG["reads"][0], "readOnly": False}], "tables": []},
        {"schemaVersion": 1, "reads": [{**CATALOG["reads"][0], "parameters": None}], "tables": []},
        {
            "schemaVersion": 1,
            "reads": [{**CATALOG["reads"][0], "parameters": {"type": "object", "properties": {}}}],
            "tables": [],
        },
        {
            "schemaVersion": 1,
            "reads": [
                {
                    **CATALOG["reads"][1],
                    "parameters": {**CATALOG["reads"][1]["parameters"], "required": []},
                }
            ],
            "tables": [],
        },
        {
            "schemaVersion": 1,
            "reads": [
                {
                    **CATALOG["reads"][2],
                    "parameters": {
                        "type": "object",
                        "properties": {"periodKey": {"type": "string", "pattern": ["("]}},
                        "additionalProperties": False,
                    },
                }
            ],
            "tables": [],
        },
    ],
)
def test_an_invalid_catalog_is_refused(
    fake: FakeState, state_directory: Path, catalog: dict[str, Any]
) -> None:
    fake.catalog = catalog
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    with pytest.raises(PocketPiggiesError) as refused:
        reader.catalog()
    assert refused.value.code == "invalid_response"


def test_records_page_through_a_catalog_table(fake: FakeState, state_directory: Path) -> None:
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    page = reader.records(
        "transactions", cursor="abc.DEF_1", limit=500, since="2026-01-01", until="2026-09-30"
    )
    assert page["table"] == "transactions" and page["data"]["rows"][0]["amount"] == "12.34"
    assert fake.seen[-1].path == "/api/assistant/records/transactions"
    assert fake.seen[-1].query == {
        "limit": ["500"],
        "cursor": ["abc.DEF_1"],
        "from": ["2026-01-01"],
        "to": ["2026-09-30"],
    }
    before = len(fake.seen)
    for arguments in (
        {"table": "transactions", "since": "2026-02-30"},
        # Full-width digits, which a bare \d would accept.
        {
            "table": "transactions",
            "since": "".join(chr(0xFF10 + int(digit)) for digit in "2026") + "-01-01",
        },
        {"table": "assistant_tokens"},
        {"table": "transactions", "limit": 501},
        {"table": "transactions", "limit": True},
        {"table": "transactions", "cursor": "a b"},
        {"table": "transactions", "since": "09/30/2026"},
        {"table": "../users"},
    ):
        table = arguments.pop("table")
        with pytest.raises(PocketPiggiesError):
            reader.records(table, **arguments)
    assert len(fake.seen) == before


def test_a_rejected_grant_is_cleared_and_needs_reconnecting(
    fake: FakeState, state_directory: Path
) -> None:
    link = connected(fake, state_directory)
    reader = Reader(api=PocketPiggiesApi(fake.base_url, timeout=5), link=link)
    for grant in fake.grants.values():
        grant["revoked"] = True
    with pytest.raises(PocketPiggiesError) as rejected:
        reader.catalog()
    assert rejected.value.code == "credential_rejected"
    assert link.store.load().grant is None
    before = len(fake.seen)
    with pytest.raises(PocketPiggiesError) as disconnected:
        reader.catalog()
    assert disconnected.value.code == "connection_required"
    assert len(fake.seen) == before


@pytest.mark.parametrize(
    ("status", "headers", "code"),
    [
        (402, {}, "subscription_required"),
        (403, {}, "scope_denied"),
        (404, {}, "not_found"),
        (422, {}, "invalid_arguments"),
        (429, {"Retry-After": "30"}, "rate_limited"),
        (500, {}, "upstream_error"),
    ],
)
def test_upstream_refusals_map_to_codes_and_carry_no_figure(
    fake: FakeState, state_directory: Path, status: int, headers: dict[str, str], code: str
) -> None:
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    fake.read_answer = (
        status,
        {"error": {"code": "x", "reason": f"echo {SECRET}"}, "safeCents": 99},
        headers,
    )
    with pytest.raises(PocketPiggiesError) as refused:
        reader.catalog()
    assert refused.value.code == code
    rendered = json.dumps(refused.value.as_result())
    assert SECRET not in rendered and "safeCents" not in rendered
    if status == 429:
        assert refused.value.details["retryAfterSeconds"] == 30
    # Only a 401 retires the grant.
    assert reader.link.store.load().grant is not None


def test_credential_shaped_text_from_pocketpiggies_is_redacted(
    fake: FakeState, state_directory: Path
) -> None:
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    reader.catalog()
    fake.read_answer = (200, {"note": f"merchant {SECRET} and {CLIENT_CREDENTIAL}"}, {})
    result = reader.read("account.safe_to_transfer", None)
    assert result["data"]["note"] == "merchant [redacted] and [redacted]"


def test_oversized_and_redirected_answers_are_refused(
    fake: FakeState, state_directory: Path
) -> None:
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    reader.catalog()
    fake.raw_answer = b'{"x":"' + b"a" * (2 * 1024 * 1024) + b'"}'
    with pytest.raises(PocketPiggiesError) as oversized:
        reader.read("account.safe_to_transfer", None)
    assert oversized.value.code == "response_too_large"
    fake.raw_answer = None
    fake.read_answer = (302, {}, {"Location": "https://evil.example/steal"})
    with pytest.raises(PocketPiggiesError) as redirected:
        reader.read("account.safe_to_transfer", None)
    assert redirected.value.code == "connection_failed"


# Freshness and the sync a read may start.

BANKS_PATH = "/api/assistant/records/plaid_items"
SYNC_PATH = "/api/assistant/sync"


class Moment:
    """One test clock for the wall time and the monotonic one, moved on demand."""

    def __init__(self) -> None:
        self.start = datetime.now(UTC).replace(microsecond=0)
        self.elapsed = 0.0

    def wall(self) -> datetime:
        return self.start + timedelta(seconds=self.elapsed)

    def monotonic(self) -> float:
        return self.elapsed

    def advance(self, *, minutes: float) -> None:
        self.elapsed += minutes * 60


def instant(moment: datetime) -> str:
    """As PocketPiggies writes an instant: UTC ISO 8601 with milliseconds."""
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def seconds(moment: datetime) -> str:
    """As the key holder writes an instant."""
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


def bank(
    moment: Moment, name: str, minutes_old: float | None, *, status: str = "idle"
) -> dict[str, Any]:
    synced = None if minutes_old is None else moment.wall() - timedelta(minutes=minutes_old)
    return {
        "id": str(uuid.uuid4()),
        "institution_name": name,
        "institution_id": "ins_3",
        "sync_status": status,
        "last_sync_completed_at": None if synced is None else instant(synced),
        "disconnected_at": None,
        "created_at": instant(moment.start - timedelta(days=90)),
    }


def paths(fake: FakeState, path: str) -> list[Seen]:
    return [seen for seen in fake.seen if seen.path == path]


@pytest.fixture
def moment(fake: FakeState) -> Moment:
    """The published catalog, which lists plaid_items, on a clock the test moves."""
    clock = Moment()
    fake.catalog = PUBLISHED_CATALOG
    fake.now = clock.wall
    return clock


def timed_reader(fake: FakeState, state_directory: Path, moment: Moment) -> Reader:
    return Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5),
        link=connected(fake, state_directory),
        clock=moment.monotonic,
        now=moment.wall,
    )


def test_every_answer_says_when_the_banks_last_synced_read_once_a_minute(
    fake: FakeState, state_directory: Path, moment: Moment
) -> None:
    removed = {**bank(moment, "Old bank", 900), "disconnected_at": instant(moment.wall())}
    fake.banks = [bank(moment, "Chase", 95), bank(moment, "Amex", 12), removed]
    reader = timed_reader(fake, state_directory, moment)

    answers = [
        reader.catalog(),
        reader.read("plaid.status", {}),
        reader.records("transactions", limit=5),
    ]

    # The oldest connected bank bounds how fresh the data is; a removed bank is not counted.
    expected = {
        "syncedAt": seconds(moment.wall() - timedelta(minutes=95)),
        "minutesOld": 95,
        "syncing": False,
        "banks": [
            {
                "name": "Chase",
                "syncedAt": seconds(moment.wall() - timedelta(minutes=95)),
                "status": "idle",
            },
            {
                "name": "Amex",
                "syncedAt": seconds(moment.wall() - timedelta(minutes=12)),
                "status": "idle",
            },
        ],
    }
    assert [answer["freshness"] for answer in answers] == [expected] * 3
    assert len(paths(fake, BANKS_PATH)) == 1
    assert all("sync" not in answer for answer in answers) and paths(fake, SYNC_PATH) == []
    moment.advance(minutes=1)
    assert reader.read("plaid.status", {})["freshness"]["minutesOld"] == 96
    assert len(paths(fake, BANKS_PATH)) == 2


def test_while_a_bank_syncs_each_answer_looks_again(
    fake: FakeState, state_directory: Path, moment: Moment
) -> None:
    fake.banks = [bank(moment, "Chase", 5, status="running")]
    reader = timed_reader(fake, state_directory, moment)

    first = reader.read("plaid.status", {})
    fake.banks[0]["sync_status"] = "idle"
    second = reader.read("plaid.status", {})
    third = reader.read("plaid.status", {})

    assert [answer["freshness"]["syncing"] for answer in (first, second, third)] == [
        True,
        False,
        False,
    ]
    assert len(paths(fake, BANKS_PATH)) == 2


@pytest.mark.parametrize(
    "unknown",
    [
        "never synced",
        "banks read fails",
        "banks read refused",
        "more than one page",
        "no banks table",
    ],
)
def test_freshness_no_one_can_vouch_for_is_null_and_never_blocks_the_read(
    fake: FakeState, state_directory: Path, moment: Moment, unknown: str
) -> None:
    fake.banks = [bank(moment, "Chase", 30), bank(moment, "New bank", None)]
    fake.banks_status = {"banks read fails": 503, "banks read refused": 401}.get(unknown, 200)
    if unknown == "more than one page":
        fake.banks_page = {"limit": 500, "hasMore": True, "nextCursor": "next.page"}
    if unknown == "no banks table":
        fake.catalog = CATALOG
    reader = timed_reader(fake, state_directory, moment)

    catalog = reader.catalog()
    answer = reader.read("account.safe_to_transfer", {})

    assert catalog["data"]["reads"] and answer["data"]["safeCents"] == 4200
    # Only the read itself retires a grant PocketPiggies rejects.
    assert reader.link.store.load().grant is not None
    if unknown == "never synced":
        assert answer["freshness"]["syncedAt"] is None
        assert answer["freshness"]["minutesOld"] is None
    else:
        assert catalog["freshness"] is None and answer["freshness"] is None


@pytest.mark.parametrize(
    ("mode", "minutes_old", "syncs"),
    [
        ("if_stale", 0, 0),
        ("if_stale", 59, 0),
        ("if_stale", 60, 1),
        ("if_stale", None, 1),
        ("now", 0, 1),
    ],
)
def test_only_stale_data_or_the_owners_own_ask_starts_a_sync(
    fake: FakeState,
    state_directory: Path,
    moment: Moment,
    mode: str,
    minutes_old: int | None,
    syncs: int,
) -> None:
    fake.banks = [bank(moment, "Chase", minutes_old)]
    reader = timed_reader(fake, state_directory, moment)

    answer = reader.records("transactions", sync=mode)

    assert len(paths(fake, SYNC_PATH)) == syncs
    assert answer["sync"]["status"] == ("synced" if syncs else "not_needed")
    assert answer["data"]["rows"][0]["amount"] == "12.34"


def test_a_stale_read_syncs_first_and_answers_from_the_fresh_data(
    fake: FakeState, state_directory: Path, moment: Moment
) -> None:
    fake.banks = [bank(moment, "Chase", 180)]
    allowed = moment.wall() + timedelta(hours=1)
    fake.sync_answer = (
        200,
        {
            "status": "synced",
            "banksSynced": 1,
            "banksFailed": 0,
            "plaidCalls": 1,
            "nextAllowedSyncAt": instant(allowed),
        },
    )
    reader = timed_reader(fake, state_directory, moment)

    answer = reader.read("plaid.status", {}, "if_stale")

    [sync] = paths(fake, SYNC_PATH)
    assert sync.method == "POST" and sync.body is None and sync.query == {}
    assert sync.headers["x-pocketpiggies-telegram-user-id"] == OWNER
    assert sync.headers["x-pocketpiggies-chat-type"] == "private"
    # Freshness is read again after the sync, then the read itself.
    assert [seen.path for seen in fake.seen[-4:]] == [
        BANKS_PATH,
        SYNC_PATH,
        BANKS_PATH,
        "/api/plaid/status",
    ]
    assert answer["sync"] == {
        "status": "synced",
        "banksSynced": 1,
        "banksFailed": 0,
        "plaidCalls": 1,
        "nextAllowedSyncAt": seconds(allowed),
    }
    assert answer["freshness"]["minutesOld"] == 0


@pytest.mark.parametrize("answered", ["synced", "cooldown"])
def test_one_sync_per_cooling_off_window_and_none_before_the_apps_own_time(
    fake: FakeState, state_directory: Path, moment: Moment, answered: str
) -> None:
    fake.banks = [bank(moment, "Chase", 180)]
    allowed = moment.wall() + timedelta(hours=1)
    fake.sync_answer = (200, {"status": answered, "nextAllowedSyncAt": instant(allowed)})
    reader = timed_reader(fake, state_directory, moment)
    assert reader.read("plaid.status", {}, "now")["sync"]["status"] == answered

    moment.advance(minutes=30)
    waiting = reader.read("plaid.status", {}, "now")
    moment.advance(minutes=31)
    again = reader.read("plaid.status", {}, "now")

    assert waiting["sync"] == {"status": "cooling_off", "nextAllowedSyncAt": seconds(allowed)}
    assert again["sync"]["status"] == answered
    assert len(paths(fake, SYNC_PATH)) == 2


def test_an_attempt_that_fails_still_starts_the_cooling_off_window(
    fake: FakeState, state_directory: Path, moment: Moment
) -> None:
    fake.banks = [bank(moment, "Chase", 180)]
    fake.sync_answer = (503, {"error": "unavailable", "code": "sync_unavailable"})
    reader = timed_reader(fake, state_directory, moment)
    first = reader.read("plaid.status", {}, "if_stale")

    moment.advance(minutes=9)
    waiting = reader.read("plaid.status", {}, "if_stale")
    moment.advance(minutes=2)
    reader.read("plaid.status", {}, "if_stale")

    assert first["sync"] == {"status": "unavailable", "code": "upstream_error"}
    assert waiting["sync"] == {
        "status": "cooling_off",
        "nextAllowedSyncAt": seconds(moment.start + timedelta(minutes=10)),
    }
    assert len(paths(fake, SYNC_PATH)) == 2


@pytest.mark.parametrize(
    ("status", "body", "expected"),
    [
        (
            200,
            {"status": "failed", "banksFailed": 2, "plaidCalls": 2, "nextAllowedSyncAt": None},
            {"status": "failed", "banksFailed": 2, "plaidCalls": 2},
        ),
        (202, {"status": "running"}, {"status": "running"}),
        (200, {"status": "over_limit"}, {"status": "over_limit"}),
        (200, {"status": "no_banks"}, {"status": "no_banks"}),
        (
            200,
            {"status": "synced", "banksSynced": "1", "plaidCalls": -1, "note": "x"},
            {"status": "synced"},
        ),
        (200, {"status": "done"}, {"status": "unavailable", "code": "invalid_response"}),
        (200, ["synced"], {"status": "unavailable", "code": "invalid_response"}),
        (
            403,
            {"code": "assistant_scope_denied"},
            {"status": "unavailable", "code": "scope_denied"},
        ),
        (429, {"code": "rate_limited"}, {"status": "unavailable", "code": "rate_limited"}),
        (
            401,
            {"error": {"code": "credential_rejected"}},
            {"status": "unavailable", "code": "credential_rejected"},
        ),
    ],
)
def test_a_sync_that_fails_or_is_refused_never_fails_the_read(
    fake: FakeState,
    state_directory: Path,
    moment: Moment,
    status: int,
    body: object,
    expected: dict[str, Any],
) -> None:
    fake.banks = [bank(moment, "Chase", 180)]
    fake.sync_answer = (status, body)
    reader = timed_reader(fake, state_directory, moment)

    answer = reader.read("account.safe_to_transfer", {}, "if_stale")

    assert answer["sync"] == expected
    assert answer["data"]["safeCents"] == 4200
    # Only a 401 means the grant is gone; a refused sync keeps the connection.
    assert reader.link.store.load().grant is not None


def test_a_read_that_fails_after_a_sync_still_reports_and_journals_it(
    fake: FakeState, state_directory: Path, moment: Moment
) -> None:
    fake.banks = [bank(moment, "Chase", 180)]
    fake.sync_answer = (200, {"status": "synced", "banksSynced": 1, "plaidCalls": 2})
    fake.failing_paths = {"/api/plaid/status"}
    link = connected(fake, state_directory)
    lines: list[str] = []
    holder = KeyHolder(
        link=link,
        reader=Reader(
            api=PocketPiggiesApi(fake.base_url, timeout=5),
            link=link,
            clock=moment.monotonic,
            now=moment.wall,
        ),
        log=lines.append,
    )

    result = asyncio.run(
        holder.call("pocketpiggies_read", {"read": "plaid.status", "sync": "if_stale"})
    )

    refusal = json.loads(result["content"][0]["text"])
    assert result["isError"] is True and refusal["code"] == "upstream_error"
    assert refusal["sync"] == {"status": "synced", "banksSynced": 1, "plaidCalls": 2}
    journaled = json.loads(lines[-1])
    assert (journaled["outcome"], journaled["sync"], journaled["plaidCalls"]) == (
        "upstream_error",
        "synced",
        2,
    )


def test_attempts_are_capped_each_day_however_often_they_fail(
    fake: FakeState, state_directory: Path, moment: Moment
) -> None:
    fake.banks = [bank(moment, "Chase", 180)]
    fake.sync_answer = (200, {"status": "failed", "banksFailed": 1, "plaidCalls": 0})
    reader = timed_reader(fake, state_directory, moment)
    for _ in range(SYNCS_PER_DAY):
        assert reader.read("plaid.status", {}, "now")["sync"]["status"] == "failed"
        moment.advance(minutes=11)

    capped = reader.read("plaid.status", {}, "now")
    moment.advance(minutes=24 * 60 - SYNCS_PER_DAY * 11)
    again = reader.read("plaid.status", {}, "now")

    assert capped["sync"] == {
        "status": "cooling_off",
        "nextAllowedSyncAt": seconds(moment.start + timedelta(days=1)),
    }
    assert again["sync"]["status"] == "failed"
    assert len(paths(fake, SYNC_PATH)) == SYNCS_PER_DAY + 1


def test_a_next_sync_time_further_than_a_day_waits_only_a_day(
    fake: FakeState, state_directory: Path, moment: Moment
) -> None:
    fake.banks = [bank(moment, "Chase", 180)]
    far = moment.wall() + timedelta(days=3)
    fake.sync_answer = (200, {"status": "cooldown", "nextAllowedSyncAt": instant(far)})
    reader = timed_reader(fake, state_directory, moment)

    first = reader.read("plaid.status", {}, "now")
    moment.advance(minutes=60)
    waiting = reader.read("plaid.status", {}, "now")

    assert first["sync"] == {"status": "cooldown", "nextAllowedSyncAt": seconds(far)}
    assert waiting["sync"] == {
        "status": "cooling_off",
        "nextAllowedSyncAt": seconds(moment.start + timedelta(days=1)),
    }


@pytest.mark.parametrize(
    "listed", [{"readOnly": False}, {"parameters": {"type": "object"}}, {"id": "Not An Id"}]
)
def test_a_catalog_that_lists_the_sync_is_accepted_without_offering_it(
    fake: FakeState, state_directory: Path, listed: dict[str, Any]
) -> None:
    entry = {
        "id": "assistant.sync",
        "method": "POST",
        "path": "/api/assistant/sync",
        "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
        **listed,
    }
    fake.catalog = {**PUBLISHED_CATALOG, "reads": [*PUBLISHED_CATALOG["reads"], entry]}
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )

    offered = [read["id"] for read in reader.catalog()["data"]["reads"]]

    # The published catalog's own catalog and records reads are left out as before.
    assert len(offered) == len(PUBLISHED_CATALOG["reads"]) - 2
    assert "assistant.sync" not in offered


def test_no_connected_bank_means_no_sync_is_asked_for(
    fake: FakeState, state_directory: Path, moment: Moment
) -> None:
    fake.banks = [{**bank(moment, "Old bank", 900), "disconnected_at": instant(moment.wall())}]
    reader = timed_reader(fake, state_directory, moment)

    answer = reader.read("plaid.status", {}, "now")

    assert answer["sync"] == {"status": "no_banks"}
    assert answer["freshness"] == {
        "syncedAt": None,
        "minutesOld": None,
        "syncing": False,
        "banks": [],
    }
    assert paths(fake, SYNC_PATH) == []


@pytest.mark.parametrize("mode", ["always", "NOW", True, 1, ""])
def test_a_sync_mode_other_than_the_two_is_refused_before_anything_is_sent(
    fake: FakeState, state_directory: Path, moment: Moment, mode: object
) -> None:
    reader = timed_reader(fake, state_directory, moment)
    before = len(fake.seen)
    attempts: list[Callable[[], object]] = [
        lambda: reader.read("plaid.status", {}, mode),
        lambda: reader.records("transactions", sync=mode),
    ]
    for attempt in attempts:
        with pytest.raises(PocketPiggiesError) as refused:
            attempt()
        assert refused.value.code == "invalid_arguments"
    assert len(fake.seen) == before


# The MCP socket.


class Holder:
    """The real `serve`, on a real Unix socket, from a background event loop.

    The socket directory is a short one under /tmp, made as the installer makes it,
    because a Unix socket path cannot be longer than 107 bytes.
    """

    def __init__(self, holder: KeyHolder) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="pp-"))
        self.directory.chmod(0o2750)
        self.path = self.directory / "broker.sock"
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.task = asyncio.run_coroutine_threadsafe(serve(holder, self.path), self.loop)
        deadline = time.monotonic() + 10
        while not self.path.exists():
            assert not self.task.done(), self.task.exception()
            assert time.monotonic() < deadline, "the key holder did not start"
            time.sleep(0.02)

    def close(self) -> None:
        self.task.cancel()
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(timeout=10)
        shutil.rmtree(self.directory, ignore_errors=True)


def exchange(path: Path, *messages: dict[str, Any] | bytes) -> list[dict[str, Any]]:
    """Send each message and collect every answer until the server goes quiet."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(path))
        answers: list[dict[str, Any]] = []
        buffered = b""
        for message in messages:
            raw = message if isinstance(message, bytes) else json.dumps(message).encode() + b"\n"
            client.sendall(raw)
            if isinstance(message, dict) and "id" not in message:
                continue
            while b"\n" not in buffered:
                chunk = client.recv(65536)
                if not chunk:
                    return answers
                buffered += chunk
            line, buffered = buffered.split(b"\n", 1)
            answers.append(json.loads(line))
        return answers


INITIALIZE = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test"}},
}
INITIALIZED = {"jsonrpc": "2.0", "method": "notifications/initialized"}


def call(identifier: int, name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": identifier,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments or {}},
    }


@pytest.fixture
def served(
    fake: FakeState, state_directory: Path, tmp_path: Path
) -> Iterator[tuple[Holder, list[str]]]:
    link = connected(fake, state_directory)
    lines: list[str] = []
    holder = KeyHolder(
        link=link,
        reader=Reader(api=PocketPiggiesApi(fake.base_url, timeout=5), link=link),
        log=lines.append,
    )
    running = Holder(holder)
    yield running, lines
    running.close()


def test_mcp_lifecycle_over_the_socket(served: tuple[Holder, list[str]]) -> None:
    running, _ = served
    early = exchange(running.path, {"jsonrpc": "2.0", "id": 9, "method": "tools/list"})
    assert early[0]["error"]["code"] == -32000
    answers = exchange(
        running.path,
        INITIALIZE,
        INITIALIZED,
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        call(3, "pocketpiggies_read", {"read": "account.safe_to_transfer"}),
        call(4, "transfer_money"),
        {"jsonrpc": "2.0", "id": 5, "method": "ping"},
        b"not json\n",
    )
    assert answers[0]["result"]["protocolVersion"] == "2025-11-25"
    assert answers[0]["result"]["_meta"] == {OWNER_META: PERSON}
    assert [tool["name"] for tool in answers[1]["result"]["tools"]][:3] == [
        "pocketpiggies_catalog",
        "pocketpiggies_read",
        "pocketpiggies_records",
    ]
    assert answers[2]["result"]["structuredContent"]["data"]["safeCents"] == 4200
    assert answers[3]["error"]["code"] == -32602
    assert answers[4]["result"] == {}
    assert answers[5]["error"]["code"] == -32700


def test_tool_refusals_are_results_with_codes(served: tuple[Holder, list[str]]) -> None:
    running, _ = served
    answers = exchange(
        running.path,
        INITIALIZE,
        INITIALIZED,
        call(2, "pocketpiggies_read", {"read": "account.safe_to_transfer", "user": OWNER}),
        call(3, "link_complete", {"requestId": 7}),
    )
    for answer, code in zip(answers[1:], ("invalid_arguments", "invalid_request"), strict=True):
        assert answer["result"]["isError"] is True
        assert json.loads(answer["result"]["content"][0]["text"])["code"] == code


class Ticking:
    """A monotonic clock that moves on by `step` seconds every time it is read."""

    def __init__(self, step: float) -> None:
        self.at = 0.0
        self.step = step

    def __call__(self) -> float:
        self.at += self.step
        return self.at


def code_of(result: dict[str, Any]) -> str | None:
    return json.loads(result["content"][0]["text"]).get("code") if result.get("isError") else None


def test_reads_and_link_operations_are_rate_limited(fake: FakeState, state_directory: Path) -> None:
    link = connected(fake, state_directory)
    holder = KeyHolder(
        link=link,
        reader=Reader(api=PocketPiggiesApi(fake.base_url, timeout=5), link=link),
        clock=Ticking(0.6),
        log=lambda line: None,
    )

    async def run() -> tuple[list[str | None], list[str | None], list[str | None]]:
        reads = [code_of(await holder.call("pocketpiggies_catalog", {})) for _ in range(121)]
        links = [code_of(await holder.call("link_status", {})) for _ in range(LINKS_PER_MINUTE + 1)]
        # Disconnect keeps its own budget, so the spent link budget cannot block a revoke.
        disconnect = [code_of(await holder.call("link_disconnect", {}))]
        return reads, links, disconnect

    reads, links, disconnect = asyncio.run(run())
    assert READS_PER_HOUR == 120
    assert reads[:-1] == [None] * 120 and reads[-1] == "rate_limited"
    assert links[:-1] == [None] * LINKS_PER_MINUTE and links[-1] == "rate_limited"
    assert disconnect == [None]


def test_a_flood_of_bad_calls_is_refused_and_counted_not_logged_line_by_line(
    fake: FakeState, state_directory: Path
) -> None:
    link = connected(fake, state_directory)
    lines: list[str] = []
    holder = KeyHolder(
        link=link,
        reader=Reader(api=PocketPiggiesApi(fake.base_url, timeout=5), link=link),
        clock=Ticking(0.001),
        log=lines.append,
    )

    async def run() -> list[str | None]:
        flood = [
            code_of(await holder.call("pocketpiggies_read", {"read": "x", "bogus": 1}))
            for _ in range(CALLS_PER_MINUTE + 40)
        ]
        holder.clock = Ticking(61)
        flood.append(code_of(await holder.call("link_status", {})))
        return flood

    codes = asyncio.run(run())
    assert codes[:CALLS_PER_MINUTE] == ["invalid_arguments"] * CALLS_PER_MINUTE
    assert codes[CALLS_PER_MINUTE:-1] == ["rate_limited"] * 40
    assert codes[-1] is None
    assert len(lines) == CALLS_PER_MINUTE + 1
    assert json.loads(lines[-1])["refusedCalls"] == 40
    assert all(json.loads(line)["subject"] in ("", "x") for line in lines)


def test_an_oversized_message_is_refused(served: tuple[Holder, list[str]]) -> None:
    running, _ = served
    answers = exchange(running.path, b"x" * (MAX_MESSAGE_BYTES + 10) + b"\n")
    assert answers[0]["error"]["message"] == "MCP message exceeds the size limit."


def test_audit_lines_name_the_read_but_carry_no_figure_or_credential(
    served: tuple[Holder, list[str]],
) -> None:
    running, lines = served
    exchange(
        running.path,
        INITIALIZE,
        INITIALIZED,
        call(2, "pocketpiggies_read", {"read": "account.safe_to_transfer"}),
    )
    assert json.loads(lines[-1])["subject"] == "account.safe_to_transfer"
    assert all("4200" not in line and "ppa_" not in line and "ppc_" not in line for line in lines)


def test_a_sync_is_journaled_with_what_it_did_and_its_plaid_calls(
    fake: FakeState, served: tuple[Holder, list[str]]
) -> None:
    running, lines = served
    fake.sync_answer = (200, {"status": "synced", "banksSynced": 2, "plaidCalls": 3})
    answers = exchange(
        running.path,
        INITIALIZE,
        INITIALIZED,
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        call(3, "pocketpiggies_read", {"read": "account.safe_to_transfer", "sync": "now"}),
        call(4, "pocketpiggies_read", {"read": "account.safe_to_transfer", "sync": "now"}),
    )

    schemas = {tool["name"]: tool["inputSchema"] for tool in answers[1]["result"]["tools"]}
    for name in ("pocketpiggies_read", "pocketpiggies_records"):
        assert schemas[name]["properties"]["sync"]["enum"] == ["if_stale", "now"]
    assert "sync" not in schemas["pocketpiggies_catalog"]["properties"]
    assert answers[2]["result"]["structuredContent"]["sync"]["plaidCalls"] == 3
    # The second ask is inside the cooling-off window, so it cost nothing.
    assert answers[3]["result"]["structuredContent"]["sync"]["status"] == "cooling_off"
    journaled = [json.loads(line) for line in lines[-2:]]
    assert [(line["sync"], line.get("plaidCalls")) for line in journaled] == [
        ("synced", 3),
        ("cooling_off", None),
    ]


def test_the_socket_is_group_connectable_and_foreign_files_are_never_replaced(
    served: tuple[Holder, list[str]], tmp_path: Path
) -> None:
    running, _ = served
    assert running.path.stat().st_mode & 0o777 == 0o660
    planted = tmp_path / "planted.sock"
    planted.write_text("not a socket")
    with pytest.raises(SystemExit):
        prepare_socket(planted)
    assert planted.read_text() == "not a socket"


@pytest.mark.parametrize("planted", ["symlink", "open mode", "plain directory"])
def test_a_socket_directory_the_installer_did_not_make_is_refused(
    tmp_path: Path, planted: str
) -> None:
    real = tmp_path / "real"
    real.mkdir()
    real.chmod(0o2750)
    check_socket_directory(real)
    candidate = tmp_path / "candidate"
    if planted == "symlink":
        candidate.symlink_to(real, target_is_directory=True)
    else:
        candidate.mkdir()
        candidate.chmod(0o2777 if planted == "open mode" else 0o750)
    with pytest.raises(SystemExit):
        check_socket_directory(candidate)


# The OpenClaw plugin, a real MCP client, through the real key holder.


def test_the_openclaw_plugin_reads_through_the_real_key_holder(
    fake: FakeState, state_directory: Path, tmp_path: Path
) -> None:
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is not installed")
    link = make_link(fake, provisioned(state_directory))
    request_id = link.start()["url"].rsplit("=", 1)[1]
    fake.approve(request_id)
    holder = KeyHolder(
        link=link,
        reader=Reader(api=PocketPiggiesApi(fake.base_url, timeout=5), link=link),
        log=lambda line: None,
    )
    running = Holder(holder)
    try:
        completed = subprocess.run(
            [
                node,
                str(ROOT / "tests" / "pocket-piggies" / "fixtures" / "drive-plugin.mjs"),
                str(running.path),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    finally:
        running.close()
    assert completed.returncode == 0, completed.stderr[-2000:]
    outcome = json.loads(completed.stdout)
    assert outcome["completed"]["text"].startswith(
        "PocketPiggies is connected with read-only access."
    )
    assert outcome["tools"] == [
        "pocketpiggies_catalog",
        "pocketpiggies_read",
        "pocketpiggies_records",
    ]
    assert outcome["groupTools"] is None
    assert outcome["read"]["details"]["data"]["safeCents"] == 4200
    assert outcome["records"]["details"]["data"]["rows"][0]["amount"] == "12.34"
    assert outcome["synced"]["details"]["sync"] == {
        "status": "synced",
        "banksSynced": 1,
        "plaidCalls": 1,
    }
    assert [seen.method for seen in fake.seen if seen.path == "/api/assistant/sync"] == ["POST"]
    assert "ppa_" not in completed.stdout and "ppc_" not in completed.stdout


def test_the_owners_disconnect_gets_through_a_flood_of_other_calls(
    fake: FakeState, state_directory: Path
) -> None:
    link = connected(fake, state_directory)
    holder = KeyHolder(
        link=link,
        reader=Reader(api=PocketPiggiesApi(fake.base_url, timeout=5), link=link),
        clock=Ticking(0.001),
        log=lambda line: None,
    )

    async def run() -> tuple[str | None, str | None]:
        for _ in range(CALLS_PER_MINUTE + 5):
            await holder.call("pocketpiggies_read", {"read": "x", "bogus": 1})
        flooded = code_of(await holder.call("link_status", {}))
        return flooded, code_of(await holder.call("link_disconnect", {}))

    flooded, disconnect = asyncio.run(run())

    assert flooded == "rate_limited"
    assert disconnect is None
    assert all(grant["revoked"] for grant in fake.grants.values())


@pytest.mark.parametrize(
    "rule",
    [
        {"type": ["string", "null"]},
        {"type": "integer", "minimum": "1"},
        {"type": "integer", "maximum": True},
        {"type": "string", "maxLength": "10"},
        {"type": "string", "pattern": 5},
        {"type": "array", "items": {"type": "string"}, "maxItems": -1},
    ],
)
def test_a_catalog_rule_the_key_holder_cannot_enforce_safely_is_refused(
    fake: FakeState, state_directory: Path, rule: dict[str, Any]
) -> None:
    fake.catalog = {
        "schemaVersion": 1,
        "reads": [
            {
                **CATALOG["reads"][2],
                "parameters": {
                    "type": "object",
                    "properties": {"periodKey": rule},
                    "additionalProperties": False,
                },
            }
        ],
        "tables": [],
    }
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    with pytest.raises(PocketPiggiesError) as refused:
        reader.catalog()
    assert refused.value.code == "invalid_response"


@pytest.mark.parametrize("status", [b"200 OK", b"500 Internal Server Error"])
def test_a_slow_drip_answer_runs_out_of_time(
    monkeypatch: pytest.MonkeyPatch, status: bytes
) -> None:
    """A real socket sending one byte at a time, each well inside the socket timeout."""
    monkeypatch.setattr("household.pocketpiggies.api.TOTAL_SECONDS", 1)
    listener = socket.create_server(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    done = threading.Event()

    def drip() -> None:
        connection, _ = listener.accept()
        with connection:
            connection.recv(65536)
            connection.sendall(
                b"HTTP/1.1 "
                + status
                + b"\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n"
            )
            while not done.wait(0.2):
                try:
                    connection.sendall(b" ")
                except OSError:
                    return

    thread = threading.Thread(target=drip, daemon=True)
    thread.start()
    started = time.monotonic()
    try:
        with pytest.raises(PocketPiggiesError) as slow:
            PocketPiggiesApi(f"http://127.0.0.1:{port}", timeout=5).call("GET", "/x", bearer="t")
    finally:
        done.set()
        listener.close()
        thread.join(timeout=5)
    assert slow.value.code == "request_timeout"
    assert time.monotonic() - started < 5


def test_a_catalog_requiring_a_non_name_is_refused(fake: FakeState, state_directory: Path) -> None:
    fake.catalog = {
        "schemaVersion": 1,
        "reads": [
            {
                **CATALOG["reads"][2],
                "parameters": {**CATALOG["reads"][2]["parameters"], "required": [["periodKey"]]},
            }
        ],
        "tables": [],
    }
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    with pytest.raises(PocketPiggiesError) as refused:
        reader.catalog()
    assert refused.value.code == "invalid_response"


def test_refused_disconnects_are_counted_not_logged_one_by_one(
    fake: FakeState, state_directory: Path
) -> None:
    link = connected(fake, state_directory)
    lines: list[str] = []
    holder = KeyHolder(
        link=link,
        reader=Reader(api=PocketPiggiesApi(fake.base_url, timeout=5), link=link),
        clock=Ticking(0.001),
        log=lines.append,
    )

    async def run() -> list[str | None]:
        codes = [code_of(await holder.call("link_disconnect", {})) for _ in range(10)]
        codes.append(code_of(await holder.call("link_status", {})))
        return codes

    codes = asyncio.run(run())
    assert codes[:6] == [None] * 6 and codes[6:10] == ["rate_limited"] * 4 and codes[10] is None
    assert len(lines) == 7
    assert json.loads(lines[-1])["refusedCalls"] == 4


def test_the_catalog_pocketpiggies_publishes_is_accepted_and_enforced(
    fake: FakeState, state_directory: Path
) -> None:
    fake.catalog = PUBLISHED_CATALOG
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )

    catalog = reader.catalog()["data"]

    # The catalog and the records read have their own tools, so they are not offered as reads.
    assert [entry["id"] for entry in catalog["reads"]] == [
        entry["id"]
        for entry in PUBLISHED_CATALOG["reads"]
        if entry["id"] not in ("assistant.catalog", "assistant.records")
    ]
    assert len(catalog["reads"]) == len(PUBLISHED_CATALOG["reads"]) - 2
    assert catalog["tables"] == PUBLISHED_CATALOG["tables"]
    piggy = "0b4d3c1e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"
    reader.read("transactions.period", {"period": "2026-Q3", "piggy": [piggy, piggy]})
    assert fake.seen[-1].query == {"period": ["2026-Q3"], "piggy": [piggy, piggy]}
    reader.read("ask_piggy.answer", {"question": "What did we spend on food?"})
    assert fake.seen[-1].body == {"question": "What did we spend on food?"}
    reader.read("account.net_worth_history", {})
    before = len(fake.seen)
    for read, params, code in (
        ("assistant.records", {"table": "transactions"}, "unknown_read"),
        ("assistant.catalog", {}, "unknown_read"),
        ("ask_piggy.answer", {"question": ""}, "invalid_arguments"),
        ("account.net_worth_history", {"days": 6}, "invalid_arguments"),
        ("transactions.period", {"period": "2026", "piggy": [piggy] * 51}, "invalid_arguments"),
        ("transactions.unassigned_by_month", {"include": "everything"}, "invalid_arguments"),
        ("piggies.review", {}, "invalid_arguments"),
    ):
        with pytest.raises(PocketPiggiesError) as refused:
            reader.read(read, params)
        assert refused.value.code == code, read
    assert len(fake.seen) == before
    page = reader.records("transactions", limit=50, since="2026-01-01")
    assert page["table"] == "transactions"
    assert fake.seen[-1].path == "/api/assistant/records/transactions"


def test_a_read_marked_anything_but_read_only_refuses_the_catalog(
    fake: FakeState, state_directory: Path
) -> None:
    entry = {**PUBLISHED_CATALOG["reads"][-1], "readOnly": False}
    fake.catalog = {**PUBLISHED_CATALOG, "reads": [entry]}
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    with pytest.raises(PocketPiggiesError) as refused:
        reader.catalog()
    assert refused.value.code == "invalid_response"


@pytest.mark.parametrize(
    "path",
    [
        "/api/assistant/records",
        "/api/assistant/recordsx",
        "/api/assistant/records/{table}",
        "/api/assistant/sync",
    ],
)
def test_no_read_is_offered_around_the_records_tool_or_the_sync_window(
    fake: FakeState, state_directory: Path, path: str
) -> None:
    entry = {
        **PUBLISHED_CATALOG["reads"][-1],
        "id": "records.lookalike",
        "path": path,
        "parameters": {
            "type": "object",
            "properties": {"table": {"type": "string"}} if "{table}" in path else {},
            "required": ["table"] if "{table}" in path else [],
            "additionalProperties": False,
        },
    }
    fake.catalog = {**PUBLISHED_CATALOG, "reads": [entry]}
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    assert reader.catalog()["data"]["reads"] == []
    with pytest.raises(PocketPiggiesError) as refused:
        reader.read("records.lookalike", {"table": "transactions"} if "{table}" in path else {})
    assert refused.value.code == "unknown_read"


@pytest.mark.parametrize("filled", ["records", "link", "sync"])
def test_a_template_filled_onto_the_records_link_or_sync_route_is_refused(
    fake: FakeState, state_directory: Path, filled: str
) -> None:
    entry = {
        **PUBLISHED_CATALOG["reads"][-1],
        "id": "assistant.anything",
        "path": "/api/assistant/{area}/{name}",
        "parameters": {
            "type": "object",
            "properties": {"area": {"type": "string"}, "name": {"type": "string"}},
            "required": ["area", "name"],
            "additionalProperties": False,
        },
    }
    fake.catalog = {**PUBLISHED_CATALOG, "reads": [entry]}
    reader = Reader(
        api=PocketPiggiesApi(fake.base_url, timeout=5), link=connected(fake, state_directory)
    )
    reader.catalog()
    before = len(fake.seen)
    with pytest.raises(PocketPiggiesError) as refused:
        reader.read("assistant.anything", {"area": filled, "name": "revoke"})
    assert refused.value.code == "invalid_arguments"
    assert len(fake.seen) == before


# The key holder's entry point, as systemd starts it.


def test_the_drop_in_names_the_binding() -> None:
    spec = importlib.util.spec_from_file_location(
        "pocketpiggies_keyholder", ROOT / "scripts" / "pocketpiggies-keyholder.py"
    )
    assert spec is not None and spec.loader is not None
    entry = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(entry)

    franco = {"POCKETPIGGIES_OWNER": PERSON, "POCKETPIGGIES_TELEGRAM_ID": OWNER}
    assert entry.binding_from("corey", franco) == TELEGRAM
    household = {"POCKETPIGGIES_OWNER": PERSON, "POCKETPIGGIES_CLIENT_ID": HOUSEHOLD.client_id}
    assert entry.binding_from("corey", household) == HOUSEHOLD
    marina = {"POCKETPIGGIES_OWNER": "marina", "POCKETPIGGIES_CLIENT_ID": "hh-7f3a"}
    assert entry.binding_from("ada", marina) == Binding("hh-7f3a", "marina")
    # A drop-in that names no client and no Telegram id would make corey a household
    # person's client, which PocketPiggies refuses.
    for refused in (
        {},
        {"POCKETPIGGIES_OWNER_TELEGRAM_ID": OWNER},
        {"POCKETPIGGIES_OWNER": PERSON},
    ):
        with pytest.raises(ValueError):
            entry.binding_from("corey", refused)
