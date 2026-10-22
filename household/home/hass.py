"""Home Assistant's REST API as the home key holder uses it: read one state, run one action.

The token travels only in the Authorization header and never into a URL, a log line or an
error, and an entity or action name is checked before it reaches a URL.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from collections.abc import Callable
from typing import IO, Any

from .actions import HomeError

# Longer than household_home.play_spotify, which waits up to 8 seconds for the play to start.
TIMEOUT_SECONDS = 45
MAX_ANSWER_BYTES = 1024 * 1024
MAX_MESSAGE_CHARACTERS = 300
ENTITY = re.compile(r"^[a-z_]+\.[a-z0-9_]+$")
NAME = re.compile(r"^[a-z_]+$")

Opener = Callable[..., IO[bytes]]


class HassClient:
    def __init__(self, *, base: str, token: str, opener: Opener = urllib.request.urlopen) -> None:
        self.base = base.rstrip("/")
        self.token = token
        self.opener = opener

    def _request(self, method: str, path: str, body: dict[str, Any] | None = None) -> object:
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(f"{self.base}{path}", data=data, method=method)
        request.add_header("Authorization", f"Bearer {self.token}")
        request.add_header("Content-Type", "application/json")
        try:
            with self.opener(request, timeout=TIMEOUT_SECONDS) as answer:
                return json.loads(answer.read(MAX_ANSWER_BYTES) or b"null")
        except urllib.error.HTTPError as error:
            message = self._message(error)
            if error.code == 404:
                raise HomeError(
                    "not_found", message or "Home Assistant has no such entity."
                ) from None
            raise HomeError(
                "home_assistant_refused", message or f"Home Assistant answered {error.code}."
            ) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise HomeError(
                "home_assistant_unreachable", "Home Assistant did not answer."
            ) from None

    def _message(self, error: urllib.error.HTTPError) -> str:
        try:
            body = json.loads(error.read(MAX_ANSWER_BYTES) or b"{}")
        except ValueError:
            return ""
        message = str(body.get("message", "")) if isinstance(body, dict) else ""
        return message.replace(self.token, "<token>")[:MAX_MESSAGE_CHARACTERS]

    def state(self, entity_id: str) -> dict[str, Any]:
        if not ENTITY.fullmatch(entity_id):
            raise HomeError("invalid_arguments", "Not an entity id.")
        answer = self._request("GET", f"/api/states/{entity_id}")
        return answer if isinstance(answer, dict) else {}

    def call(self, domain: str, service: str, data: dict[str, Any]) -> None:
        if not NAME.fullmatch(domain) or not NAME.fullmatch(service):
            raise HomeError("invalid_arguments", "Not an action name.")
        self._request("POST", f"/api/services/{domain}/{service}", data)

    def ask(self, domain: str, service: str, data: dict[str, Any]) -> dict[str, Any]:
        """Run an action that answers, and return its answer."""
        if not NAME.fullmatch(domain) or not NAME.fullmatch(service):
            raise HomeError("invalid_arguments", "Not an action name.")
        answer = self._request("POST", f"/api/services/{domain}/{service}?return_response", data)
        response = answer.get("service_response") if isinstance(answer, dict) else None
        return response if isinstance(response, dict) else {}
