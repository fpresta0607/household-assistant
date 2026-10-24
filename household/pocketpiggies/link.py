"""Linking one owner's PocketPiggies account: PKCE consent, exchange, status and revoke.

The protocol is PocketPiggies' (docs/ASSISTANT_API_SPEC.md section 7, PR 140), with the
household binding in docs/deploy/pocketpiggies-server.md. This side holds the client
credential and the verifier, so the request id that travels through the owner's browser
is never enough to finish a link on its own.
"""

from __future__ import annotations

import base64
import hashlib
import secrets
import time
from collections.abc import Callable
from datetime import datetime
from typing import Any

from .api import PocketPiggiesApi
from .binding import Binding
from .errors import PocketPiggiesError
from .store import (
    GRANT_TOKEN,
    MAX_ATTEMPTS,
    UUID,
    CredentialStore,
    Grant,
    LinkState,
    PendingLink,
)

SCOPE = "household:read"
REQUEST_LIFETIME_MS = 600_000
RETRY_SPACING_MS = 5_000
MAX_GRANT_MS = 181 * 86_400_000
MAX_LINK_RESPONSE_BYTES = 64 * 1024
MESSAGES = {
    "invalid_client": (
        "PocketPiggies linking needs administrator setup. Please try again after setup."
    ),
    "invalid_request": (
        "This connection request is unavailable. Use /pocketpiggies connect to try again."
    ),
    "invalid_binding": (
        "This connection does not belong to your account and your own thread. Start again here."
    ),
    "authorization_pending": (
        "Finish signing in and allowing access in PocketPiggies, then come back here and send "
        "/pocketpiggies status."
    ),
    "access_denied": (
        "PocketPiggies connection was cancelled. Use /pocketpiggies connect to try again."
    ),
    "expired_request": (
        "This connection request expired. Use /pocketpiggies connect to try again."
    ),
    "request_consumed": (
        "This connection request was already used. Use /pocketpiggies connect to try again."
    ),
    "rate_limited": "PocketPiggies is busy. Wait before trying again.",
    "link_unavailable": "PocketPiggies linking is unavailable. Please try again shortly.",
}
# Answers after which the pending request can never succeed, so it is dropped.
FINAL_EXCHANGE_CODES = {
    "access_denied",
    "expired_request",
    "request_consumed",
    "invalid_binding",
    "invalid_request",
}


def link_error(code: str) -> PocketPiggiesError:
    return PocketPiggiesError(code, MESSAGES[code])


def _now_ms() -> int:
    return int(time.time() * 1000)


def _iso_ms(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


class AccountLink:
    """The owner's link state machine. Callers serialize every method."""

    def __init__(
        self,
        *,
        store: CredentialStore,
        api: PocketPiggiesApi,
        binding: Binding,
        now: Callable[[], int] = _now_ms,
    ) -> None:
        self.store = store
        self.api = api
        self.binding = binding
        self.client_id = binding.client_id
        self.owner = binding.owner
        self.redirect_uri = binding.redirect_uri
        self.now = now

    def _request(self, operation: str, state: LinkState, **fields: str) -> dict[str, Any]:
        if state.client_credential is None:
            raise link_error("invalid_client")
        try:
            answer = self.api.call(
                "POST",
                f"/api/assistant/link/{operation}",
                bearer=state.client_credential,
                body={**self.binding.link_fields(), **fields},
                limit=MAX_LINK_RESPONSE_BYTES,
            )
        except PocketPiggiesError as error:
            raise link_error("link_unavailable") from error
        payload = answer.payload
        if not 200 <= answer.status < 300:
            code = payload.get("code") if isinstance(payload, dict) else None
            raise link_error(
                code if isinstance(code, str) and code in MESSAGES else "link_unavailable"
            )
        if answer.status != (201 if operation == "requests" else 200) or not isinstance(
            payload, dict
        ):
            raise link_error("link_unavailable")
        return payload

    def start(self) -> dict[str, str]:
        state = self.store.load()
        verifier = secrets.token_urlsafe(32)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        result = self._request(
            "requests",
            state,
            codeChallenge=challenge.rstrip(b"=").decode(),
            codeChallengeMethod="S256",
            scope=SCOPE,
            redirectUri=self.redirect_uri,
        )
        request_id = result.get("requestId")
        expires_at = _iso_ms(result.get("expiresAt"))
        now = self.now()
        if (
            not isinstance(request_id, str)
            or not UUID.fullmatch(request_id)
            or expires_at is None
            or not now < expires_at <= now + REQUEST_LIFETIME_MS + 30_000
            or result.get("verificationUri")
            != f"{self.api.base_url}/assistant/connect?request={request_id}"
        ):
            raise link_error("link_unavailable")
        state.pending = PendingLink(
            request_id=request_id,
            code_verifier=verifier,
            expires_at=min(expires_at, now + REQUEST_LIFETIME_MS),
            last_attempt_at=None,
            attempts=0,
        )
        self.store.save(state)
        # PocketPiggies' page names a household person's assistant by its client id, so the
        # person can tell their own household's request from one somebody else registered
        # to their account.
        check = (
            ""
            if self.binding.is_telegram
            else f" The page names your assistant {self.client_id}; allow it only if it does."
        )
        return {
            "text": (
                "Connect your PocketPiggies account. Sign in if needed and allow read-only access, "
                "then come back here and send /pocketpiggies status. This link expires in "
                f"10 minutes.{check}"
            ),
            "url": f"{self.api.base_url}/assistant/connect?request={request_id}",
        }

    def _complete(self, state: LinkState, request_id: str) -> dict[str, str]:
        pending = state.pending
        if pending is None or not UUID.fullmatch(request_id) or pending.request_id != request_id:
            raise link_error("invalid_request")
        now = self.now()
        if pending.expires_at <= now or pending.attempts >= MAX_ATTEMPTS:
            state.pending = None
            self.store.save(state)
            raise link_error("expired_request")
        if pending.last_attempt_at is not None and now - pending.last_attempt_at < RETRY_SPACING_MS:
            raise link_error("rate_limited")
        pending.last_attempt_at = now
        pending.attempts += 1
        self.store.save(state)
        try:
            result = self._request(
                "exchange",
                state,
                requestId=request_id,
                codeVerifier=pending.code_verifier,
                redirectUri=self.redirect_uri,
            )
        except PocketPiggiesError as error:
            if error.code in FINAL_EXCHANGE_CODES:
                state.pending = None
                self.store.save(state)
            raise
        token, account_id, grant_id = (
            result.get("accessToken"),
            result.get("accountId"),
            result.get("grantId"),
        )
        expires_at = _iso_ms(result.get("expiresAt"))
        if (
            not isinstance(token, str)
            or not GRANT_TOKEN.fullmatch(token)
            or result.get("tokenType") != "Bearer"
            or result.get("scope") != SCOPE
            or not isinstance(account_id, str)
            or not UUID.fullmatch(account_id)
            or not isinstance(grant_id, str)
            or not UUID.fullmatch(grant_id)
            or expires_at is None
            or not now < expires_at <= now + MAX_GRANT_MS
            or (state.grant is not None and state.grant.account_id != account_id)
        ):
            raise link_error("invalid_binding")
        state.grant = Grant(token, expires_at, account_id, grant_id)
        state.pending = None
        self.store.save(state)
        return {
            "text": (
                "PocketPiggies is connected with read-only access. "
                "You can now ask about your finances in your own thread."
            )
        }

    def complete(self, request_id: str) -> dict[str, str]:
        return self._complete(self.store.load(), request_id)

    def status(self) -> dict[str, str]:
        state = self.store.load()
        if state.pending is not None:
            return self._complete(state, state.pending.request_id)
        if state.grant is not None and state.grant.expires_at > self.now():
            return {
                "text": (
                    "PocketPiggies has a saved read-only connection. Your next financial question "
                    "will check that access is still active. Use /pocketpiggies disconnect to "
                    "revoke it."
                )
            }
        return {
            "text": (
                "PocketPiggies is disconnected or expired. "
                "Use /pocketpiggies connect to connect your account."
            )
        }

    def disconnect(self) -> dict[str, str]:
        state = self.store.load()
        # With a client credential the revoke is always sent, so a retry after an
        # unconfirmed revocation still reaches PocketPiggies.
        if state.client_credential is None and state.grant is None and state.pending is None:
            return {"text": "PocketPiggies is already disconnected."}
        state.grant = None
        state.pending = None
        self.store.save(state)
        try:
            result = self._request("revoke", state)
            if result.get("revoked") is not True:
                raise link_error("link_unavailable")
        except PocketPiggiesError as error:
            raise PocketPiggiesError(
                "revoke_unconfirmed",
                "PocketPiggies is disconnected here. Remote revocation could not be confirmed. "
                "Retry /pocketpiggies disconnect.",
            ) from error
        return {
            "text": (
                "PocketPiggies is disconnected and access is revoked. "
                "Use /pocketpiggies connect whenever you want to reconnect."
            )
        }

    def grant(self) -> Grant:
        grant = self.store.load().grant
        if grant is None or grant.expires_at <= self.now():
            raise PocketPiggiesError(
                "connection_required",
                "Connect your account by sending /pocketpiggies connect in your own thread.",
            )
        return grant

    def rejected_grant(self, grant_id: str) -> None:
        state = self.store.load()
        if state.grant is not None and state.grant.grant_id == grant_id:
            state.grant = None
            self.store.save(state)
