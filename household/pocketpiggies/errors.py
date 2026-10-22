"""The one error the key holder reports, with a code a client can branch on."""

from __future__ import annotations

import re

# Any length from 20 up, so a longer token format is still caught.
SECRET_SHAPE = re.compile(r"pp(?:a_(?:ro_)?|c_)[A-Za-z0-9_-]{20,}")


class PocketPiggiesError(Exception):
    """A refusal or failure whose message is safe to show the owner and the model."""

    def __init__(self, code: str, message: str, details: dict[str, object] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}

    def as_result(self) -> dict[str, object]:
        return {"code": self.code, "message": self.message, **self.details}


def redact(text: str) -> str:
    """Remove anything shaped like a PocketPiggies credential, wherever it came from."""
    return SECRET_SHAPE.sub("[redacted]", text)
