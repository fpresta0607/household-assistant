"""The channel-facing door.

The gateway's whole job is to turn an authenticated message into an identity
envelope and hand that to the service. It has no way to name an actor, and the
service would refuse it if it tried.
"""

from __future__ import annotations

from collections.abc import Mapping

from .approvals import ApprovalRecord
from .identity import IdentityEnvelope, IdentityResolver, InboundMessage
from .providers import MockMessagingProvider
from .service import HouseholdService


class Gateway:
    def __init__(
        self,
        resolver: IdentityResolver,
        service: HouseholdService,
        messaging: MockMessagingProvider,
    ) -> None:
        self._resolver = resolver
        self._service = service
        self._messaging = messaging

    def resolve(self, message: InboundMessage) -> IdentityEnvelope:
        return self._resolver.resolve(message)

    def handle_tool_call(
        self,
        message: InboundMessage,
        tool_name: str,
        arguments: Mapping[str, object] | None = None,
    ) -> object:
        # ponytail: the caller names the tool because the model is mocked in this phase.
        # Phase 2 puts a model between these two lines. The identity does not move when
        # it does, because the envelope is already minted before the model is consulted.
        envelope = self._resolver.resolve(message)
        return self._service.call(envelope, tool_name, arguments)

    def approve(self, message: InboundMessage, approval_id: str) -> ApprovalRecord:
        """A person's yes, carried by a message the channel authenticated.

        There is no tool named approval_grant, so a model driving handle_tool_call
        cannot mint the yes it needs for the write it just proposed.
        """
        envelope = self._resolver.resolve(message)
        return self._service.grant_approval(envelope, approval_id)

    def reply(self, envelope: IdentityEnvelope, text: str) -> None:
        self._messaging.send(envelope, text)
