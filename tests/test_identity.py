"""Identity resolution, personas and envelopes."""

from __future__ import annotations

import dataclasses
from datetime import timedelta

import pytest

from household.app import Household
from household.errors import EnvelopeInvalid, NotAuthorized, RouteNotApproved
from household.identity import (
    ENVELOPE_TTL,
    HOUSEHOLD_MEMBER_CAPABILITIES,
    PRIVATE_ROUTE_CAPABILITIES,
    ROUTE_DIRECT,
    SCOPE_FRANCO_PRIVATE,
    SCOPE_GIA_PRIVATE,
    SCOPE_HOUSEHOLD_SHARED,
    Capability,
    EnvelopeIssuer,
    private_scope_for,
    register_route,
)

from .conftest import (
    CHANNEL,
    CHAT_FRANCO_DENISE,
    CHAT_GIA_COREY,
    CHAT_HOUSEHOLD,
    FRANCO_TELEGRAM,
    GIA_TELEGRAM,
    FakeClock,
    franco_envelope,
    group_envelope,
    message,
)


def test_a_direct_route_carries_the_senders_own_private_scope(household: Household) -> None:
    franco = franco_envelope(household)
    assert franco.actor_person_id == "franco"
    assert franco.persona_id == "corey"
    assert franco.scopes == frozenset({SCOPE_FRANCO_PRIVATE, SCOPE_HOUSEHOLD_SHARED})

    gia = household.resolver.resolve(
        message(sender=GIA_TELEGRAM, chat=CHAT_GIA_COREY, persona="corey")
    )
    assert gia.scopes == frozenset({SCOPE_GIA_PRIVATE, SCOPE_HOUSEHOLD_SHARED})


def test_the_persona_is_the_face_not_the_principal(household: Household) -> None:
    to_denise = household.resolver.resolve(message(chat=CHAT_FRANCO_DENISE, persona="denise"))
    assert to_denise.actor_person_id == "franco"
    assert to_denise.persona_id == "denise"


def test_a_group_route_uses_the_persona_that_was_addressed(household: Household) -> None:
    to_corey = household.resolver.resolve(message(chat=CHAT_HOUSEHOLD, persona="corey"))
    to_denise = household.resolver.resolve(message(chat=CHAT_HOUSEHOLD, persona="denise"))
    assert to_corey.persona_id == "corey"
    assert to_denise.persona_id == "denise"
    assert to_corey.actor_person_id == to_denise.actor_person_id == "franco"


def test_an_unknown_persona_is_refused(household: Household) -> None:
    with pytest.raises(NotAuthorized):
        household.resolver.resolve(message(chat=CHAT_HOUSEHOLD, persona="jarvis"))


def test_both_people_resolve_in_the_household_group(household: Household) -> None:
    actors = {
        group_envelope(household, sender=sender).actor_person_id
        for sender in (FRANCO_TELEGRAM, GIA_TELEGRAM)
    }
    assert actors == {"franco", "gia"}


def test_private_scope_names_are_derived_from_the_person(household: Household) -> None:
    assert private_scope_for("franco") == SCOPE_FRANCO_PRIVATE
    assert private_scope_for("gia") == SCOPE_GIA_PRIVATE


def test_an_envelope_expires(household: Household, clock: FakeClock) -> None:
    franco = franco_envelope(household)
    household.issuer.verify(franco)
    clock.advance(ENVELOPE_TTL + timedelta(seconds=1))
    with pytest.raises(EnvelopeInvalid, match="expired"):
        household.issuer.verify(franco)


def test_an_envelope_from_another_household_is_refused(household: Household) -> None:
    stranger = EnvelopeIssuer(secret=b"someone-elses-secret")
    forged = stranger.issue(
        actor_person_id="franco",
        persona_id="corey",
        channel="telegram",
        route_id="telegram:direct:franco-corey",
        route_kind="direct",
        scopes={SCOPE_FRANCO_PRIVATE, SCOPE_HOUSEHOLD_SHARED},
        capabilities=set(Capability),
    )
    with pytest.raises(EnvelopeInvalid):
        household.issuer.verify(forged)


def test_every_signed_field_is_covered_by_the_signature(household: Household) -> None:
    franco = franco_envelope(household)
    tampered = [
        dataclasses.replace(franco, actor_person_id="gia"),
        dataclasses.replace(franco, persona_id="denise"),
        dataclasses.replace(franco, channel="imessage"),
        dataclasses.replace(franco, route_id="telegram:group:household"),
        dataclasses.replace(franco, route_kind="group"),
        dataclasses.replace(franco, scopes=frozenset({SCOPE_GIA_PRIVATE})),
        dataclasses.replace(franco, capabilities=frozenset({Capability.MEMORY_READ})),
        dataclasses.replace(franco, envelope_id="other"),
        dataclasses.replace(franco, expires_at=franco.expires_at + timedelta(days=1)),
    ]
    for envelope in tampered:
        with pytest.raises(EnvelopeInvalid):
            household.issuer.verify(envelope)


def test_a_group_route_carries_fewer_capabilities_than_a_direct_one(
    household: Household,
) -> None:
    franco = franco_envelope(household)
    in_the_group = group_envelope(household)
    assert franco.capabilities == HOUSEHOLD_MEMBER_CAPABILITIES
    assert in_the_group.capabilities == HOUSEHOLD_MEMBER_CAPABILITIES - PRIVATE_ROUTE_CAPABILITIES
    assert Capability.MEMORY_READ in in_the_group.capabilities


def test_delegation_narrows_and_keeps_the_actor(household: Household) -> None:
    franco = franco_envelope(household)
    narrowed = household.issuer.delegate(
        franco, capabilities={Capability.MEMORY_READ, Capability.LIST_READ}
    )
    household.issuer.verify(narrowed)
    assert narrowed.actor_person_id == "franco"
    assert narrowed.persona_id == "corey"
    assert narrowed.route_id == franco.route_id
    assert narrowed.capabilities == frozenset({Capability.MEMORY_READ, Capability.LIST_READ})
    assert narrowed.scopes == franco.scopes


def test_a_delegate_never_outlives_its_parent(household: Household, clock: FakeClock) -> None:
    franco = franco_envelope(household)
    clock.advance(ENVELOPE_TTL - timedelta(seconds=30))
    narrowed = household.issuer.delegate(franco, capabilities={Capability.MEMORY_READ})
    assert narrowed.expires_at == franco.expires_at
    clock.advance(timedelta(seconds=31))
    with pytest.raises(EnvelopeInvalid, match="expired"):
        household.issuer.verify(narrowed)


def test_an_expired_envelope_cannot_be_delegated(household: Household, clock: FakeClock) -> None:
    franco = franco_envelope(household)
    clock.advance(ENVELOPE_TTL + timedelta(seconds=1))
    with pytest.raises(EnvelopeInvalid):
        household.issuer.delegate(franco, capabilities={Capability.MEMORY_READ})


@pytest.mark.parametrize("members", [[], ["franco", "gia"]])
def test_a_direct_route_must_have_exactly_one_member(
    household: Household, members: list[str]
) -> None:
    """Two people in a direct route would each read the other's private answers."""
    with pytest.raises(ValueError, match="exactly one member"):
        register_route(
            household.database,
            route_id="telegram:direct:shared-phone",
            channel=CHANNEL,
            channel_chat_id="555",
            kind=ROUTE_DIRECT,
            members=members,
            persona_id="corey",
            approved=True,
        )
    with pytest.raises(RouteNotApproved):
        household.resolver.resolve(message(chat="555"))
