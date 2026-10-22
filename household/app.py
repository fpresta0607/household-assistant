"""Wiring. One call builds a household on a SQLite file with mocked providers."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .db import Database, migrate
from .gateway import Gateway
from .identity import Clock, EnvelopeIssuer, IdentityResolver, seed_household, system_clock
from .providers import Providers, mock_providers
from .service import HouseholdService


@dataclass(frozen=True, slots=True)
class Household:
    database: Database
    issuer: EnvelopeIssuer
    resolver: IdentityResolver
    service: HouseholdService
    providers: Providers
    gateway: Gateway


def build_household(
    database_path: str | Path,
    *,
    clock: Clock = system_clock,
    secret: bytes | None = None,
) -> Household:
    database = Database(database_path)
    migrate(database)
    seed_household(database)
    issuer = EnvelopeIssuer(secret=secret, clock=clock)
    resolver = IdentityResolver(database, issuer)
    providers = mock_providers()
    service = HouseholdService(database, issuer, providers, clock=clock)
    return Household(
        database=database,
        issuer=issuer,
        resolver=resolver,
        service=service,
        providers=providers,
        gateway=Gateway(resolver, service, providers.messaging),
    )
