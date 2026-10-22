"""Every refusal this package can make. All of them are fail-closed."""

from __future__ import annotations


class HouseholdError(Exception):
    """Base class for every refusal the household service makes."""


class UnknownSender(HouseholdError):
    """The channel identity that sent this message is not enrolled."""


class RouteNotApproved(HouseholdError):
    """The conversation this message arrived in is not an approved route."""


class EnvelopeInvalid(HouseholdError):
    """The identity envelope was forged, tampered with, or has expired."""


class NotAuthorized(HouseholdError):
    """The actor in the envelope may not do this."""


class ScopeDenied(NotAuthorized):
    """The record sits in a memory scope the envelope does not carry."""


class CapabilityDenied(NotAuthorized):
    """The envelope does not carry the capability this tool needs."""


class ApprovalInvalid(NotAuthorized):
    """The approval does not bind this action, this actor, this route, or this moment."""


class ToolUnknown(HouseholdError):
    """No scoped tool by that name. There is no unscoped fallback."""


class ArgumentInvalid(HouseholdError):
    """The arguments do not match the tool's typed contract."""
