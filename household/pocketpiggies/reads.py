"""Calls with the owner's grant: the catalog, one functional read, one page of records, and
the one action a household grant has, starting PocketPiggies' own bank sync.

PocketPiggies decides what a household grant may read and publishes it as a catalog,
generated from the same table its gate enforces. This side only calls what that
catalog lists, pins the owner on every call, bounds what it sends and receives, and
removes anything shaped like a credential from what it returns.

Every answer says when the owner's banks last synced. A read that needs recent data
can ask for a sync first; it runs the app's own "Sync now", within the app's own
cooldowns, and this side starts at most one per cooling-off window.
"""

from __future__ import annotations

import json
import math
import re
import time
import urllib.parse
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Any

from .api import PocketPiggiesApi, Response
from .errors import PocketPiggiesError, redact
from .link import AccountLink

CATALOG_PATH = "/api/assistant/catalog"
RECORDS_PATH = "/api/assistant/records"
SYNC_PATH = "/api/assistant/sync"
CATALOG_TTL_SECONDS = 600
BANKS_TABLE = "plaid_items"
FRESHNESS_TTL_SECONDS = 60
# The freshness read and the sync are extras a read can answer without, so they wait less.
BANKS_SECONDS = 5
# PocketPiggies answers a sync when it ends or at 8 s.
SYNC_SECONDS = 15
# The app refuses a second sync it was asked for within an hour, so younger data is current.
STALE_AFTER_MINUTES = 60
SYNC_COOLING_OFF = timedelta(minutes=10)
# The app lets a failed sync be retried at once and prices it at nothing, so this side caps it.
SYNCS_PER_DAY = 12
# Further than this, a time PocketPiggies names is taken as a day.
LONGEST_SYNC_WAIT = timedelta(days=1)
SYNC_MODES = ("if_stale", "now")
SYNC_STATUSES = {"synced", "failed", "running", "cooldown", "over_limit", "no_banks"}
SYNC_COUNTS = ("banksSynced", "banksFailed", "plaidCalls")
READ_ID = re.compile(r"[a-z][a-z0-9_.-]{0,63}")
TABLE = re.compile(r"[a-z][a-z0-9_]{0,62}")
PARAMETER = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,40}")
PATH_VALUE = re.compile(r"[A-Za-z0-9_-]{1,64}")
CURSOR = re.compile(r"[A-Za-z0-9._~=-]{1,512}")
DAY = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
SEGMENT = r"(?:[a-z0-9_-]+|\{[A-Za-z][A-Za-z0-9_]{0,40}\})"
READ_PATH = re.compile(rf"/api(?:/{SEGMENT})+")
PATH_PARAMETER = re.compile(r"\{([A-Za-z][A-Za-z0-9_]{0,40})\}")
MAX_PARAMETERS = 20
MAX_TEXT = 500
MAX_LIST = 50
MAX_REQUEST_BYTES = 4096
MAX_RECORDS_PAGE = 500
DEFAULT_RECORDS_PAGE = 100
SCALAR_TYPES = {"string", "integer", "number", "boolean"}
PROPERTY_KEYS = {
    "type",
    "description",
    "enum",
    "minimum",
    "maximum",
    "minLength",
    "maxLength",
    "pattern",
    "items",
    "maxItems",
    "format",
    "default",
}
UPSTREAM_ERRORS = {
    401: ("credential_rejected", "The PocketPiggies connection is expired, revoked or invalid."),
    402: ("subscription_required", "This PocketPiggies account needs an active subscription."),
    403: ("scope_denied", "PocketPiggies refused this read for the assistant's read-only access."),
    404: ("not_found", "PocketPiggies has no such record for this account."),
    429: ("rate_limited", "PocketPiggies is rate limited. Wait before trying again."),
}


@dataclass(frozen=True, slots=True)
class ReadEntry:
    id: str
    method: str
    path: str
    parameters: dict[str, Any]


def _bad(message: str) -> PocketPiggiesError:
    return PocketPiggiesError("invalid_arguments", message)


def _invalid_catalog() -> PocketPiggiesError:
    return PocketPiggiesError(
        "invalid_response", "PocketPiggies returned an invalid read catalog. Nothing was read."
    )


def _scalar(value: object) -> bool:
    if value is None or isinstance(value, bool | str):
        return not isinstance(value, str) or len(value) <= MAX_TEXT
    if isinstance(value, int):
        return abs(value) <= 2**53 - 1
    return isinstance(value, float) and math.isfinite(value)


def check_parameters(params: object) -> dict[str, Any]:
    """A flat object of bounded scalars or short scalar lists, and nothing else."""
    if params is None:
        return {}
    if not isinstance(params, dict):
        raise _bad("params must be a JSON object.")
    if len(params) > MAX_PARAMETERS:
        raise _bad(f"params may have at most {MAX_PARAMETERS} keys.")
    for key, value in params.items():
        if not isinstance(key, str) or not PARAMETER.fullmatch(key):
            raise _bad("Each params key must be a plain identifier.")
        is_list = isinstance(value, list) and len(value) <= MAX_LIST
        if not (_scalar(value) or (is_list and all(_scalar(item) for item in value))):
            raise _bad(f"params.{key} must be a short string, number, boolean, null or list.")
    if len(json.dumps(params)) > MAX_REQUEST_BYTES:
        raise _bad("params are too large.")
    return params


def _is_property(value: object, *, is_item: bool = False) -> bool:
    if not isinstance(value, dict) or not set(value) <= PROPERTY_KEYS:
        return False
    kind = value.get("type")
    if not isinstance(kind, str):
        return False
    for bound in ("minimum", "maximum"):
        if bound in value and (
            isinstance(value[bound], bool) or not isinstance(value[bound], int | float)
        ):
            return False
    if "default" in value and not _scalar(value["default"]):
        return False
    for size in ("minLength", "maxLength", "maxItems"):
        if size in value and (
            isinstance(value[size], bool) or not isinstance(value[size], int) or value[size] < 0
        ):
            return False
    if kind == "array":
        return not is_item and _is_property(value.get("items"), is_item=True)
    if kind not in SCALAR_TYPES or "items" in value:
        return False
    # A pattern is shown to the model but enforced by PocketPiggies, not here: matching a
    # catalog-supplied pattern in this process could stall every call behind it.
    if "pattern" in value and not isinstance(value["pattern"], str):
        return False
    return "enum" not in value or (
        isinstance(value["enum"], list) and all(_scalar(item) for item in value["enum"])
    )


def _is_closed_schema(schema: object, path: str) -> bool:
    """An object schema that names every parameter, including each path placeholder."""
    if (
        not isinstance(schema, dict)
        or schema.get("type") != "object"
        or schema.get("additionalProperties") is not False
        or not isinstance(schema.get("properties"), dict)
        or not isinstance(schema.get("required", []), list)
        or not all(isinstance(key, str) for key in schema.get("required", []))
    ):
        return False
    properties: dict[str, object] = schema["properties"]
    required = schema.get("required", [])
    placeholders = PATH_PARAMETER.findall(path)
    return (
        all(PARAMETER.fullmatch(key) and _is_property(value) for key, value in properties.items())
        and all(key in properties for key in required)
        and all(name in required for name in placeholders)
    )


def check_against(entry: ReadEntry, params: dict[str, Any]) -> None:
    """Only the parameters the catalog declares for this read, of the declared kind."""
    properties: dict[str, dict[str, Any]] = entry.parameters["properties"]
    for key, value in params.items():
        if key not in properties:
            raise _bad(f"{key} is not a parameter of {entry.id}.")
        _check_value(properties[key], value, f"params.{key}")
    for key in entry.parameters.get("required", []):
        if key not in params:
            raise _bad(f"params.{key} is required for {entry.id}.")


def _check_value(rule: dict[str, Any], value: object, label: str) -> None:
    kind = rule["type"]
    if kind == "array":
        if not isinstance(value, list) or len(value) > rule.get("maxItems", MAX_LIST):
            raise _bad(f"{label} must be a list of at most {rule.get('maxItems', MAX_LIST)}.")
        for item in value:
            _check_value(rule["items"], item, label)
        return
    is_number = isinstance(value, int | float) and not isinstance(value, bool)
    matches = {
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": is_number,
        "boolean": isinstance(value, bool),
    }[kind]
    if not matches:
        raise _bad(f"{label} must be a {kind}.")
    if "enum" in rule and value not in rule["enum"]:
        raise _bad(f"{label} must be one of {rule['enum']}.")
    if is_number and isinstance(value, int | float):
        if "minimum" in rule and value < rule["minimum"]:
            raise _bad(f"{label} must be at least {rule['minimum']}.")
        if "maximum" in rule and value > rule["maximum"]:
            raise _bad(f"{label} must be at most {rule['maximum']}.")
    if isinstance(value, str) and "minLength" in rule and len(value) < rule["minLength"]:
        raise _bad(f"{label} must have at least {rule['minLength']} characters.")
    if isinstance(value, str) and "maxLength" in rule and len(value) > rule["maxLength"]:
        raise _bad(f"{label} must have at most {rule['maxLength']} characters.")


def _is_served_by_its_own_tool(path: str) -> bool:
    # Anything under the records path, not only /records/{table}, so no records-shaped
    # route can be reached around the records tool's own checks. The sync is reached only
    # through a read's sync argument, so no read can start one past the cooling-off window.
    return path == CATALOG_PATH or path.startswith(RECORDS_PATH) or path.startswith(SYNC_PATH)


def parse_catalog(payload: object) -> dict[str, Any]:
    """Accept only a catalog whose every read is a GET or POST under /api/ with a closed
    parameter schema, and none marked anything but read-only.

    PocketPiggies publishes the catalog and the records read among its reads; they are
    reached through their own tools, so they are left out of the reads offered here.
    """
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise _invalid_catalog()
    reads, tables = payload.get("reads"), payload.get("tables")
    if not isinstance(reads, list) or not isinstance(tables, list):
        raise _invalid_catalog()
    # The sync is reached only through a read's sync argument, so however the catalog lists
    # it, it is never offered as a read and never refuses the whole catalog.
    reads = [
        entry
        for entry in reads
        if not (
            isinstance(entry, dict)
            and isinstance(entry.get("path"), str)
            and entry["path"].startswith(SYNC_PATH)
        )
    ]
    seen: set[str] = set()
    for entry in reads:
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("id"), str)
            or not READ_ID.fullmatch(entry["id"])
            or entry["id"] in seen
            or entry.get("method") not in ("GET", "POST")
            or entry.get("readOnly", True) is not True
            or not isinstance(entry.get("path"), str)
            or not READ_PATH.fullmatch(entry["path"])
            or entry["path"].startswith("/api/assistant/link")
            or not _is_closed_schema(entry.get("parameters"), entry["path"])
        ):
            raise _invalid_catalog()
        seen.add(entry["id"])
    names: set[str] = set()
    for table in tables:
        if (
            not isinstance(table, dict)
            or not isinstance(table.get("name"), str)
            or not TABLE.fullmatch(table["name"])
            or table["name"] in names
        ):
            raise _invalid_catalog()
        names.add(table["name"])
    return {
        **payload,
        "reads": [entry for entry in reads if not _is_served_by_its_own_tool(entry["path"])],
    }


def _is_day(value: object) -> bool:
    if not isinstance(value, str) or not DAY.fullmatch(value):
        return False
    try:
        date.fromisoformat(value)
    except ValueError:
        return False
    return True


def _sync_mode(value: object) -> str | None:
    if value is None or (isinstance(value, str) and value in SYNC_MODES):
        return value
    raise _bad("sync must be if_stale or now.")


def _instant(value: object) -> datetime | None:
    """A UTC ISO 8601 instant from PocketPiggies, or None for anything else."""
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.astimezone(UTC) if parsed.tzinfo is not None else None


def _iso(value: datetime | None) -> str | None:
    return None if value is None else value.isoformat(timespec="seconds").replace("+00:00", "Z")


def _banks(payload: object) -> list[dict[str, Any]] | None:
    """Each connected bank's name, last completed sync and sync state, from one whole page of
    plaid_items rows; None when the page is not whole, since a missing bank could be older."""
    if not isinstance(payload, dict) or not isinstance(payload.get("rows"), list):
        return None
    page = payload.get("page")
    if not isinstance(page, dict) or page.get("hasMore") is not False:
        return None
    banks: list[dict[str, Any]] = []
    for row in payload["rows"]:
        if not isinstance(row, dict) or row.get("disconnected_at") is not None:
            continue
        name, status = row.get("institution_name"), row.get("sync_status")
        banks.append(
            {
                "name": name[:100] if isinstance(name, str) else None,
                "syncedAt": _instant(row.get("last_sync_completed_at")),
                "status": status[:20] if isinstance(status, str) else None,
            }
        )
    return banks


def _sync_outcome(payload: object) -> tuple[dict[str, Any], datetime | None] | None:
    """The sync answer's own fields, of their agreed types, and the time it names for the next
    sync; None if it is not a sync answer."""
    if not isinstance(payload, dict) or payload.get("status") not in SYNC_STATUSES:
        return None
    outcome: dict[str, Any] = {"status": payload["status"]}
    for key in SYNC_COUNTS:
        count = payload.get(key)
        if isinstance(count, int) and not isinstance(count, bool) and 0 <= count <= 10_000:
            outcome[key] = count
    allowed = _instant(payload.get("nextAllowedSyncAt"))
    if allowed is not None:
        outcome["nextAllowedSyncAt"] = _iso(allowed)
    return outcome, allowed


class Reader:
    """The owner's reads. One instance per key holder; it never holds a second owner."""

    def __init__(
        self,
        *,
        api: PocketPiggiesApi,
        link: AccountLink,
        clock: Callable[[], float] = time.monotonic,
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self.api = api
        self.link = link
        self.clock = clock
        self.now = now
        self._catalog: dict[str, Any] | None = None
        self._catalog_grant: str | None = None
        self._catalog_at = 0.0
        self._banks: list[dict[str, Any]] | None = None
        self._banks_at = -math.inf
        self._next_sync_at: datetime | None = None
        self._sync_attempts: deque[datetime] = deque()

    def _headers(self) -> dict[str, str]:
        return self.link.binding.read_headers()

    def _call(
        self,
        method: str,
        path_and_query: str,
        body: dict[str, Any] | None = None,
        *,
        seconds: float | None = None,
        should_retire_grant: bool = True,
    ) -> object:
        grant = self.link.grant()
        answer = self.api.call(
            method,
            path_and_query,
            bearer=grant.token,
            headers=self._headers(),
            body=body,
            seconds=seconds,
        )
        if 200 <= answer.status < 300:
            if not isinstance(answer.payload, dict | list):
                raise PocketPiggiesError(
                    "invalid_response", "PocketPiggies returned a non-JSON answer."
                )
            return answer.payload
        # Only the read itself retires a rejected grant, never an extra it can do without.
        if answer.status == 401 and should_retire_grant:
            self.link.rejected_grant(grant.grant_id)
        raise self._upstream_error(answer)

    @staticmethod
    def _upstream_error(answer: Response) -> PocketPiggiesError:
        code, message = UPSTREAM_ERRORS.get(
            answer.status,
            (
                "invalid_arguments" if answer.status in (400, 422) else "upstream_error",
                "PocketPiggies could not complete this read. No financial figure is available.",
            ),
        )
        details: dict[str, object] = {"status": answer.status}
        payload = answer.payload
        if isinstance(payload, dict):
            nested = payload.get("error")
            source: dict[str, Any] = nested if isinstance(nested, dict) else payload
            for key in ("code", "reason", "message", "requestId"):
                if isinstance(source.get(key), str):
                    details[f"upstream{key[0].upper()}{key[1:]}"] = redact(source[key][:300])
        if answer.retry_after and re.fullmatch(r"\d{1,6}", answer.retry_after):
            details["retryAfterSeconds"] = int(answer.retry_after)
        return PocketPiggiesError(code, message, details)

    @staticmethod
    def _wrap(
        kind: str,
        name: str,
        payload: object,
        freshness: dict[str, Any] | None,
        sync: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        # Merchant text is data. Even an upstream echo must not hand back a credential.
        wrapped = {
            "source": "PocketPiggies",
            kind: name,
            "retrievedAt": datetime.now(UTC).isoformat(timespec="seconds"),
            "freshness": freshness,
            **({} if sync is None else {"sync": sync}),
            "data": payload,
        }
        result: dict[str, Any] = json.loads(redact(json.dumps(wrapped)))
        return result

    def _fresh_catalog(self) -> dict[str, Any]:
        catalog = parse_catalog(self._call("GET", CATALOG_PATH))
        self._catalog = catalog
        self._catalog_grant = self.link.grant().grant_id
        self._catalog_at = self.clock()
        return catalog

    def catalog(self) -> dict[str, Any]:
        catalog = self._fresh_catalog()
        return self._wrap("catalog", "household:read", catalog, self.freshness())

    def _read_banks(self) -> list[dict[str, Any]] | None:
        # Freshness never decides whether a read answers, so a failure here is only "unknown".
        try:
            if not any(entry["name"] == BANKS_TABLE for entry in self._cached_catalog()["tables"]):
                return None
            page = self._call(
                "GET",
                f"{RECORDS_PATH}/{BANKS_TABLE}?limit={MAX_RECORDS_PAGE}",
                seconds=BANKS_SECONDS,
                should_retire_grant=False,
            )
        except PocketPiggiesError:
            return None
        return _banks(page)

    def freshness(self) -> dict[str, Any] | None:
        """When the owner's connected banks last synced, read at most once a minute.

        syncedAt is the oldest bank's last completed sync, so the data is at least that
        fresh, and null when a bank has never synced. None means PocketPiggies could not
        say, and the assistant says so rather than guessing.
        """
        if self.clock() - self._banks_at >= FRESHNESS_TTL_SECONDS:
            self._banks = self._read_banks()
            # While a bank syncs, the next answer looks again rather than repeat "syncing".
            is_syncing = self._banks is not None and any(
                bank["status"] == "running" for bank in self._banks
            )
            self._banks_at = -math.inf if is_syncing else self.clock()
        if self._banks is None:
            return None
        times = [bank["syncedAt"] for bank in self._banks]
        oldest = min(times) if times and None not in times else None
        return {
            "syncedAt": _iso(oldest),
            "minutesOld": None
            if oldest is None
            else max(0, int((self.now() - oldest).total_seconds()) // 60),
            "syncing": any(bank["status"] == "running" for bank in self._banks),
            "banks": [{**bank, "syncedAt": _iso(bank["syncedAt"])} for bank in self._banks],
        }

    def _sync(self, mode: str) -> dict[str, Any]:
        """Start PocketPiggies' own sync when `mode` calls for one, and say what happened.

        At most one attempt per cooling-off window and SYNCS_PER_DAY a day, and none before
        the time PocketPiggies last named. A sync that fails or is refused never fails the
        read that asked for it.
        """
        freshness = self.freshness()
        if freshness is not None and not freshness["banks"]:
            return {"status": "no_banks"}
        minutes = None if freshness is None else freshness["minutesOld"]
        if mode == "if_stale" and minutes is not None and minutes < STALE_AFTER_MINUTES:
            return {"status": "not_needed"}
        now = self.now()
        while self._sync_attempts and now - self._sync_attempts[0] >= timedelta(days=1):
            self._sync_attempts.popleft()
        until = self._next_sync_at
        if len(self._sync_attempts) >= SYNCS_PER_DAY:
            day_full = self._sync_attempts[0] + timedelta(days=1)
            until = day_full if until is None else max(until, day_full)
        if until is not None and now < until:
            return {"status": "cooling_off", "nextAllowedSyncAt": _iso(until)}
        # Counted before the call, so an attempt that fails or times out still counts.
        self._sync_attempts.append(now)
        self._next_sync_at = now + SYNC_COOLING_OFF
        self._banks_at = -math.inf
        try:
            answer = _sync_outcome(
                self._call("POST", SYNC_PATH, seconds=SYNC_SECONDS, should_retire_grant=False)
            )
        except PocketPiggiesError as error:
            return {"status": "unavailable", "code": error.code}
        if answer is None:
            return {"status": "unavailable", "code": "invalid_response"}
        outcome, allowed = answer
        if allowed is not None:
            self._next_sync_at = max(self._next_sync_at, min(allowed, now + LONGEST_SYNC_WAIT))
        return outcome

    def _answer(
        self, kind: str, name: str, mode: str | None, request: Callable[[], object]
    ) -> dict[str, Any]:
        """Sync first if `mode` calls for it, then the read, with how fresh its data is."""
        synced = None if mode is None else self._sync(mode)
        freshness = self.freshness()
        try:
            payload = request()
        except PocketPiggiesError as error:
            # A sync that ran still happened, and cost what it cost, even if the read failed.
            if synced is not None:
                error.details["sync"] = synced
            raise
        return self._wrap(kind, name, payload, freshness, synced)

    def _cached_catalog(self) -> dict[str, Any]:
        if (
            self._catalog is None
            or self._catalog_grant != self.link.grant().grant_id
            or self.clock() - self._catalog_at > CATALOG_TTL_SECONDS
        ):
            return self._fresh_catalog()
        return self._catalog

    def _entry(self, read_id: str) -> ReadEntry:
        for entry in self._cached_catalog()["reads"]:
            if entry["id"] == read_id:
                return ReadEntry(entry["id"], entry["method"], entry["path"], entry["parameters"])
        raise PocketPiggiesError(
            "unknown_read",
            f"{read_id} is not in the PocketPiggies catalog. Call pocketpiggies_catalog first.",
        )

    def read(self, read_id: object, params: object, sync: object = None) -> dict[str, Any]:
        if not isinstance(read_id, str) or not READ_ID.fullmatch(read_id):
            raise _bad("read must be a catalog read id.")
        mode = _sync_mode(sync)
        values = dict(check_parameters(params))
        entry = self._entry(read_id)
        check_against(entry, values)

        def fill(match: re.Match[str]) -> str:
            value = values.pop(match.group(1), None)
            if isinstance(value, bool) or not isinstance(value, str | int):
                raise _bad(f"params.{match.group(1)} is required for {read_id}.")
            if not PATH_VALUE.fullmatch(str(value)):
                raise _bad(f"params.{match.group(1)} must be an id of letters, digits, - or _.")
            return str(value)

        path = PATH_PARAMETER.sub(fill, entry.path)
        if _is_served_by_its_own_tool(path) or path.startswith("/api/assistant/link"):
            raise _bad(f"{read_id} cannot reach that route; use its own tool.")
        if entry.method == "GET":
            query = urllib.parse.urlencode(
                [
                    (key, json.dumps(item) if not isinstance(item, str) else item)
                    for key, value in values.items()
                    for item in (value if isinstance(value, list) else [value])
                    if item is not None
                ]
            )
            target = f"{path}?{query}" if query else path
            return self._answer("read", read_id, mode, lambda: self._call("GET", target))
        return self._answer("read", read_id, mode, lambda: self._call("POST", path, body=values))

    def records(
        self,
        table: object,
        *,
        cursor: object = None,
        limit: object = None,
        since: object = None,
        until: object = None,
        sync: object = None,
    ) -> dict[str, Any]:
        if not isinstance(table, str) or not TABLE.fullmatch(table):
            raise _bad("table must be a catalog table name.")
        mode = _sync_mode(sync)
        if limit is None:
            limit = DEFAULT_RECORDS_PAGE
        if (
            not isinstance(limit, int)
            or isinstance(limit, bool)
            or not 1 <= limit <= MAX_RECORDS_PAGE
        ):
            raise _bad(f"limit must be an integer from 1 to {MAX_RECORDS_PAGE}.")
        if cursor is not None and (not isinstance(cursor, str) or not CURSOR.fullmatch(cursor)):
            raise _bad("cursor must be the nextCursor of the previous page.")
        for name, day in (("from", since), ("to", until)):
            if day is not None and not _is_day(day):
                raise _bad(f"{name} must be a YYYY-MM-DD date.")
        if not any(entry["name"] == table for entry in self._cached_catalog()["tables"]):
            raise PocketPiggiesError(
                "unknown_table",
                f"{table} is not in the PocketPiggies catalog. Call pocketpiggies_catalog first.",
            )
        query = urllib.parse.urlencode(
            [
                (key, value)
                for key, value in (
                    ("limit", str(limit)),
                    ("cursor", cursor),
                    ("from", since),
                    ("to", until),
                )
                if isinstance(value, str)
            ]
        )
        return self._answer(
            "table", table, mode, lambda: self._call("GET", f"{RECORDS_PATH}/{table}?{query}")
        )
