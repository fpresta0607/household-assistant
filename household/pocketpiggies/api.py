"""The only HTTP the key holder makes: JSON calls to PocketPiggies, bounded and unredirected."""

from __future__ import annotations

import http.client
import json
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from email.message import Message
from typing import IO, Any

from .errors import PocketPiggiesError

API_BASE_URL = "https://pocketpiggies.app"
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
TIMEOUT_SECONDS = 20
# The socket timeout bounds each read; this bounds a slow drip of them.
TOTAL_SECONDS = 30
CHUNK_BYTES = 64 * 1024


@dataclass(frozen=True, slots=True)
class Response:
    status: int
    payload: object
    retry_after: str | None


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect could carry the bearer credential to another origin, so none is followed."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: IO[bytes],
        code: int,
        msg: str,
        headers: Message,
        newurl: str,
    ) -> urllib.request.Request | None:
        raise PocketPiggiesError(
            "connection_failed", "PocketPiggies answered with a redirect, which is refused."
        )


class PocketPiggiesApi:
    """JSON over HTTPS to one fixed origin. Tests point it at a loopback fake."""

    def __init__(self, base_url: str = API_BASE_URL, timeout: float = TIMEOUT_SECONDS) -> None:
        self.base_url = base_url
        self.timeout = timeout
        self._opener = urllib.request.build_opener(_RefuseRedirects())

    def call(
        self,
        method: str,
        path_and_query: str,
        *,
        bearer: str,
        headers: dict[str, str] | None = None,
        body: dict[str, Any] | None = None,
        limit: int = MAX_RESPONSE_BYTES,
        seconds: float | None = None,
    ) -> Response:
        """`seconds` bounds a call the answer can do without more tightly than a read."""
        request = urllib.request.Request(
            f"{self.base_url}{path_and_query}",
            method=method,
            data=None if body is None else json.dumps(body).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {bearer}",
                "Accept": "application/json",
                "Cache-Control": "no-store",
                **({} if body is None else {"Content-Type": "application/json"}),
                **(headers or {}),
            },
        )
        total = TOTAL_SECONDS if seconds is None else seconds
        deadline = time.monotonic() + total
        try:
            with self._opener.open(request, timeout=min(self.timeout, total)) as answer:
                return self._read(
                    answer.status, answer.read1, answer.headers.get("Retry-After"), limit, deadline
                )
        except urllib.error.HTTPError as error:
            # The error's body is the same response object, so it reads the same way.
            read = getattr(error, "read1", error.read)
            return self._read(error.code, read, error.headers.get("Retry-After"), limit, deadline)
        except PocketPiggiesError:
            raise
        except (OSError, ValueError, http.client.HTTPException) as error:
            raise PocketPiggiesError(
                "connection_failed",
                "PocketPiggies could not be reached. No financial figure is available.",
            ) from error

    @staticmethod
    def _read(
        status: int,
        read: Callable[[int], bytes],
        retry_after: str | None,
        limit: int,
        deadline: float,
    ) -> Response:
        """`read` returns what has arrived, so a slow drip still reaches the deadline check."""
        chunks: list[bytes] = []
        size = 0
        while chunk := read(CHUNK_BYTES):
            size += len(chunk)
            if size > limit:
                raise PocketPiggiesError(
                    "response_too_large", "PocketPiggies returned too much data. Ask for less."
                )
            if time.monotonic() > deadline:
                raise PocketPiggiesError(
                    "request_timeout", "PocketPiggies answered too slowly. No figure is available."
                )
            chunks.append(chunk)
        raw = b"".join(chunks)
        try:
            payload = json.loads(raw) if raw else None
        except (RecursionError, UnicodeDecodeError, ValueError):
            payload = None
        return Response(status, payload, retry_after)
