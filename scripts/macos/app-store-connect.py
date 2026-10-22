#!/usr/bin/env python3
"""The App Store Connect half of a TestFlight release, run by .github/workflows/ios-release.yml.

There is no Mac to keep a signing identity in a keychain. The release job runs on
one of GitHub's Macs, which is wiped after every job, so each run rebuilds the
identity from two secrets in the `testflight` environment: the App Store Connect
API key, and one RSA private key that belongs to the team's Apple Distribution
certificate. This script is every part of that which talks to Apple:

  preflight   Read only. Says which of the owner's Apple steps are done: the key
              works and can sign, the app record and both App IDs exist, both
              App IDs carry App Groups, and an internal TestFlight group gets
              every build. Runs on Linux, before any Mac minute is spent.
  signing     Finds the Apple Distribution certificate that belongs to the
              stored private key, or creates it from a signing request the
              first time; finds or creates an App Store profile for the app and
              for the widget; installs both into a throwaway keychain and
              Xcode's profile folder; and writes the names the archive and the
              export need to an env file. macOS only.
  archive     Read only, without credentials: verifies and reports the archived
              app and extensions' version, build number and bundle identifiers.
  testers     After the upload: waits, bounded, for Apple to finish processing
              the build, and makes sure the internal group can install it.
  installs    Read only: each internal tester's TestFlight state (invited,
              accepted, installed) and the newest build there.
              ios-testers.yml runs it.
  setup       Registers each target's App ID, turns on the capabilities its
              entitlements need, finds or makes each App Store profile on Linux
              with no keychain, and reads every part back. Apple's API cannot
              assign an App Group, so a profile without it is reported with the
              portal step. ios-capabilities.yml runs it.

The API key is used, never shown. No key, token or team id is printed: the team
id goes only into the env file, and the workflow masks it before reading that.

Environment:
  APP_STORE_CONNECT_KEY_ID      the key id
  APP_STORE_CONNECT_ISSUER_ID   the issuer id
  APP_STORE_CONNECT_KEY_PATH    a path to the .p8 file
  SIGNING_KEY_PATH              signing only: a path to the certificate's RSA key

Needs Python 3.12 and openssl on PATH, and `security` for signing.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

API = "https://api.appstoreconnect.apple.com"

# Mirrors apps/ios/project.yml; tests/test_app_store_connect.py holds them equal.
APP_BUNDLE = "com.siqstack.stewardai"
WIDGET_BUNDLE = "com.siqstack.stewardai.widgets"
NOTIFICATIONS_BUNDLE = "com.siqstack.stewardai.notifications"
SHARE_BUNDLE = "com.siqstack.stewardai.share"
APP_GROUP = "group.com.siqstack.stewardai"
PROJECT = Path(__file__).resolve().parents[2] / "apps" / "ios" / "project.yml"
# PRODUCT_NAME of each signed target, as the archive's xcconfig keys its profile.
# A release signs the ones project.yml declares, so a target can be set up at Apple
# before the change that adds it lands.
TARGETS = {
    "HouseholdAssistant": APP_BUNDLE,
    "HouseholdAssistantWidgets": WIDGET_BUNDLE,
    "HouseholdAssistantNotifications": NOTIFICATIONS_BUNDLE,
    "HouseholdAssistantShare": SHARE_BUNDLE,
}
# The variable that carries each target's profile name to build-ios.sh and
# deploy-testflight.sh.
PROFILE_VARIABLES = {
    "HouseholdAssistant": "HA_APP_PROFILE",
    "HouseholdAssistantWidgets": "HA_WIDGET_PROFILE",
    "HouseholdAssistantNotifications": "HA_NOTIFICATIONS_PROFILE",
    "HouseholdAssistantShare": "HA_SHARE_PROFILE",
}
# The name each App ID gets when `setup` registers it.
APP_ID_NAMES = {
    APP_BUNDLE: "Steward AI",
    WIDGET_BUNDLE: "Steward AI Widgets",
    NOTIFICATIONS_BUNDLE: "Steward AI Notifications",
    SHARE_BUNDLE: "Steward AI Share",
}

# Apple refuses a token that lives longer than 20 minutes.
TOKEN_LIFETIME = timedelta(minutes=19)
# A certificate or profile this close to expiry is replaced rather than used.
EXPIRY_MARGIN = timedelta(days=2)
CERTIFICATE_SUBJECT = "/CN=Steward AI release"
# Xcode 16 and later read installed profiles from here.
PROFILES_DIR = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"

Json = dict[str, Any]
Runner = Callable[..., subprocess.CompletedProcess[bytes]]
Send = Callable[[str, str, Json | None, str], tuple[int, Json]]


class AppleError(Exception):
    """A plain-words failure that names what to do about it."""


@dataclass(frozen=True)
class Key:
    key_id: str
    issuer_id: str
    path: Path

    @classmethod
    def from_environment(cls) -> Key:
        values = {}
        for name in (
            "APP_STORE_CONNECT_KEY_ID",
            "APP_STORE_CONNECT_ISSUER_ID",
            "APP_STORE_CONNECT_KEY_PATH",
        ):
            value = os.environ.get(name, "").strip()
            if not value:
                raise AppleError(f"{name} is not set. See docs/testflight.md.")
            values[name] = value
        path = Path(values["APP_STORE_CONNECT_KEY_PATH"])
        if not path.is_file():
            raise AppleError("APP_STORE_CONNECT_KEY_PATH does not point at a file.")
        return cls(values["APP_STORE_CONNECT_KEY_ID"], values["APP_STORE_CONNECT_ISSUER_ID"], path)


def run_openssl(run: Runner, *arguments: str, data: bytes = b"") -> bytes:
    completed = run(["openssl", *arguments], input=data, capture_output=True, check=False)
    if completed.returncode != 0:
        # openssl's stderr names files and formats, never key material.
        raise AppleError(f"openssl {arguments[0]} failed: {completed.stderr.decode().strip()}")
    return completed.stdout


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_signature_to_raw(der: bytes) -> bytes:
    """openssl writes an ECDSA signature as DER; a JWT carries r and s as 64 raw bytes."""
    if len(der) < 8 or der[0] != 0x30:
        raise AppleError("openssl did not return an ECDSA signature")
    index = 2
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise AppleError("openssl did not return an ECDSA signature")
        length = der[index + 1]
        value = der[index + 2 : index + 2 + length].lstrip(b"\x00")
        if len(value) > 32:
            raise AppleError("the App Store Connect key is not a P-256 key")
        parts.append(value.rjust(32, b"\x00"))
        index += 2 + length
    return parts[0] + parts[1]


def make_token(key: Key, now: datetime, run: Runner) -> str:
    header = {"alg": "ES256", "kid": key.key_id, "typ": "JWT"}
    claims = {
        "iss": key.issuer_id,
        "iat": int(now.timestamp()),
        "exp": int((now + TOKEN_LIFETIME).timestamp()),
        "aud": "appstoreconnect-v1",
    }
    signing_input = ".".join(
        b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, claims)
    )
    der = run_openssl(run, "dgst", "-sha256", "-sign", str(key.path), data=signing_input.encode())
    return f"{signing_input}.{b64url(der_signature_to_raw(der))}"


def send_with_urllib(method: str, url: str, body: Json | None, token: str) -> tuple[int, Json]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return error.code, {}


class Api:
    """Each request carries a token minted for it: the wait for testers outlives any one token."""

    def __init__(self, token: Callable[[], str], send: Send = send_with_urllib) -> None:
        self._token = token
        self._send = send

    def request(self, method: str, path: str, body: Json | None = None) -> tuple[int, Json]:
        url = path if path.startswith("https://") else f"{API}{path}"
        status, payload = self._send(method, url, body, self._token())
        if status == 401:
            raise AppleError(
                "Apple refused the API key. The key id, the issuer id and the .p8 must come "
                "from the same key, and the key must not be revoked. See docs/testflight.md."
            )
        return status, payload

    def must(self, method: str, path: str, body: Json | None = None, doing: str = "") -> Json:
        status, payload = self.request(method, path, body)
        if status == 403:
            raise AppleError(
                f"the API key's role cannot {doing or 'do this'}. "
                "The release key needs Admin access. See docs/testflight.md."
            )
        if status >= 300:
            raise AppleError(f"Apple answered {status} while trying to {doing}: {detail(payload)}")
        return payload

    def all(self, path: str, params: dict[str, str], doing: str) -> list[Json]:
        url: str | None = f"{path}?{urllib.parse.urlencode(params)}" if params else path
        found: list[Json] = []
        while url:
            payload = self.must("GET", url, doing=doing)
            found.extend(payload.get("data", []))
            url = payload.get("links", {}).get("next")
        return found


def detail(payload: Json) -> str:
    errors = payload.get("errors") or [{}]
    first = errors[0]
    return str(first.get("detail") or first.get("title") or "no detail given")


def expires(attributes: Json) -> datetime:
    return datetime.fromisoformat(str(attributes["expirationDate"]))


def profile_plist(content: bytes) -> Json:
    """A .mobileprovision is a signed envelope around a plain XML plist."""
    start = content.find(b"<?xml")
    end = content.find(b"</plist>")
    if start < 0 or end < 0:
        raise AppleError("Apple returned a profile with no plist inside")
    parsed: Json = plistlib.loads(content[start : end + len(b"</plist>")])
    return parsed


# ---------------------------------------------------------------------- preflight


@dataclass(frozen=True)
class Check:
    name: str
    is_done: bool
    detail: str


def find_bundle(api: Api, identifier: str) -> Json | None:
    for bundle in api.all(
        "/v1/bundleIds",
        {"filter[identifier]": identifier, "filter[platform]": "IOS", "limit": "200"},
        doing="read App IDs",
    ):
        if bundle["attributes"]["identifier"] == identifier:
            return bundle
    return None


def preflight(api: Api, targets: dict[str, str]) -> list[Check]:
    checks: list[Check] = []
    apps = api.all("/v1/apps", {"filter[bundleId]": APP_BUNDLE, "limit": "200"}, doing="read apps")
    checks.append(Check("API key", True, "Apple accepted it"))
    app = next((a for a in apps if a["attributes"]["bundleId"] == APP_BUNDLE), None)
    checks.append(
        Check(
            "App Store Connect app",
            app is not None,
            f"{app['attributes']['name']}" if app else f"no app with bundle id {APP_BUNDLE} yet",
        )
    )

    status, _ = api.request("GET", "/v1/certificates?limit=1")
    is_admin = status < 300
    checks.append(
        Check(
            "key can sign",
            is_admin,
            "it can make certificates and profiles"
            if is_admin
            else "its role is not Admin, so it cannot make certificates or profiles",
        )
    )

    if is_admin:
        for identifier in targets.values():
            bundle = find_bundle(api, identifier)
            checks.append(
                Check(
                    f"App ID {identifier}",
                    bundle is not None,
                    "registered" if bundle else "not registered yet",
                )
            )
            if bundle is None:
                continue
            capabilities = api.all(
                f"/v1/bundleIds/{bundle['id']}/bundleIdCapabilities",
                {},
                doing="read App ID capabilities",
            )
            has_groups = any(
                c["attributes"].get("capabilityType") == "APP_GROUPS" for c in capabilities
            )
            checks.append(
                Check(
                    f"App Groups on {identifier}",
                    has_groups,
                    f"on, and {APP_GROUP} must be assigned to it"
                    if has_groups
                    else f"off. Turn it on and assign {APP_GROUP}",
                )
            )

    if app is not None:
        groups = [
            g
            for g in api.all(
                f"/v1/apps/{app['id']}/betaGroups", {"limit": "200"}, doing="read TestFlight groups"
            )
            if g["attributes"].get("isInternalGroup")
        ]
        automatic = [g for g in groups if g["attributes"].get("hasAccessToAllBuilds")]
        if not groups:
            checks.append(Check("TestFlight group", False, "no internal group yet"))
        elif not automatic:
            names = ", ".join(str(g["attributes"]["name"]) for g in groups)
            checks.append(
                Check("TestFlight group", False, f"{names} does not get every build automatically")
            )
        else:
            group = automatic[0]
            testers = api.all(
                f"/v1/betaGroups/{group['id']}/betaTesters",
                {"limit": "200"},
                doing="read TestFlight testers",
            )
            checks.append(
                Check(
                    "TestFlight group",
                    len(testers) > 0,
                    f"{group['attributes']['name']} gets every build, {len(testers)} tester(s)",
                )
            )
    return checks


# ------------------------------------------------------------------------ signing


@dataclass(frozen=True)
class Profile:
    target: str
    bundle: str
    name: str
    uuid: str
    team: str
    content: bytes
    expires: datetime
    entitlements: Json


def certificate_pem(der: bytes) -> bytes:
    """Apple sends a certificate as DER. As PEM it is text, which every openssl reads on stdin."""
    body = base64.b64encode(der)
    lines = [body[index : index + 64] for index in range(0, len(body), 64)]
    return b"\n".join([b"-----BEGIN CERTIFICATE-----", *lines, b"-----END CERTIFICATE-----", b""])


def public_key(run: Runner, pem: bytes, *, is_certificate: bool) -> bytes:
    if is_certificate:
        return run_openssl(run, "x509", "-noout", "-pubkey", data=pem)
    return run_openssl(run, "pkey", "-pubout", data=pem)


def distribution_certificate(
    api: Api, signing_key: Path, now: datetime, run: Runner
) -> tuple[Json, bytes]:
    """The team's Apple Distribution certificate for this key, made the first time."""
    ours = public_key(run, signing_key.read_bytes(), is_certificate=False)
    for certificate in api.all(
        "/v1/certificates",
        {"filter[certificateType]": "DISTRIBUTION", "limit": "200"},
        doing="read certificates",
    ):
        attributes = certificate["attributes"]
        if expires(attributes) - now < EXPIRY_MARGIN:
            continue
        der = base64.b64decode(attributes["certificateContent"])
        if public_key(run, certificate_pem(der), is_certificate=True) == ours:
            return certificate, der

    request = run_openssl(
        run, "req", "-new", "-key", str(signing_key), "-subj", CERTIFICATE_SUBJECT
    )
    status, payload = api.request(
        "POST",
        "/v1/certificates",
        {
            "data": {
                "type": "certificates",
                "attributes": {"certificateType": "DISTRIBUTION", "csrContent": request.decode()},
            }
        },
    )
    if status == 409:
        raise AppleError(
            "Apple will not make another Apple Distribution certificate: the team has its "
            f"maximum. Revoke an unused one at developer.apple.com. Apple said: {detail(payload)}"
        )
    if status == 403:
        raise AppleError(
            "the API key's role cannot make certificates. The release key needs Admin access."
        )
    if status >= 300:
        raise AppleError(f"Apple answered {status} to a new certificate: {detail(payload)}")
    created: Json = payload["data"]
    return created, base64.b64decode(created["attributes"]["certificateContent"])


def app_store_profile(
    api: Api, target: str, bundle_identifier: str, certificate_id: str, now: datetime
) -> Profile:
    bundle = find_bundle(api, bundle_identifier)
    if bundle is None:
        raise AppleError(
            f"the App ID {bundle_identifier} is not registered. Register it at "
            "developer.apple.com, Identifiers. See docs/apple-signing.md."
        )
    candidates = api.all(
        f"/v1/bundleIds/{bundle['id']}/profiles", {"limit": "200"}, doing="read profiles"
    )
    for candidate in candidates:
        attributes = candidate["attributes"]
        if (
            attributes.get("profileType") != "IOS_APP_STORE"
            or attributes.get("profileState") != "ACTIVE"
            or expires(attributes) - now < EXPIRY_MARGIN
        ):
            continue
        certificates = api.all(
            f"/v1/profiles/{candidate['id']}/certificates",
            {"limit": "200"},
            doing="read a profile's certificates",
        )
        if any(c["id"] == certificate_id for c in certificates):
            return checked_profile(target, bundle_identifier, attributes)

    payload = api.must(
        "POST",
        "/v1/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": f"Steward AI {target} App Store {now:%Y-%m-%d %H%M}",
                    "profileType": "IOS_APP_STORE",
                },
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                    "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
                },
            }
        },
        doing="make a profile",
    )
    return checked_profile(target, bundle_identifier, payload["data"]["attributes"])


def checked_profile(target: str, bundle_identifier: str, attributes: Json) -> Profile:
    content = base64.b64decode(attributes["profileContent"])
    plist = profile_plist(content)
    groups = plist.get("Entitlements", {}).get("com.apple.security.application-groups", [])
    if APP_GROUP not in groups:
        raise AppleError(
            f"the profile for {bundle_identifier} does not carry the App Group {APP_GROUP}. "
            "At developer.apple.com, Identifiers, turn on App Groups for that App ID and "
            "assign the group, then run the release again."
        )
    return Profile(
        target=target,
        bundle=bundle_identifier,
        name=str(plist["Name"]),
        uuid=str(plist["UUID"]),
        team=str(plist["TeamIdentifier"][0]),
        content=content,
        expires=expires(attributes),
        entitlements=plist.get("Entitlements", {}),
    )


def install_identity(signing_key: Path, certificate_der: bytes, out: Path, run: Runner) -> Path:
    """A throwaway keychain holding the one identity the archive and the export sign with."""
    keychain = out / "signing.keychain-db"
    keychain_password = secrets.token_urlsafe(24)
    bundle_password = secrets.token_urlsafe(24)
    certificate_file = out / "distribution.pem"
    certificate_file.write_bytes(certificate_pem(certificate_der))
    identity = out / "identity.p12"
    # /usr/bin/openssl is LibreSSL on macOS, whose PKCS#12 `security` can always read.
    # A Homebrew OpenSSL 3 earlier on PATH writes one it may refuse.
    steps: list[list[str]] = [
        ["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(signing_key),
         "-in", str(certificate_file), "-out", str(identity),
         "-passout", f"pass:{bundle_password}"],
        ["security", "create-keychain", "-p", keychain_password, str(keychain)],
        ["security", "set-keychain-settings", "-lut", "21600", str(keychain)],
        ["security", "unlock-keychain", "-p", keychain_password, str(keychain)],
        ["security", "import", str(identity), "-k", str(keychain), "-P", bundle_password,
         "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"],
        ["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
         "-s", "-k", keychain_password, str(keychain)],
    ]  # fmt: skip
    for step in steps:
        completed = run(step, capture_output=True, check=False)
        if completed.returncode != 0:
            raise AppleError(f"{step[0]} {step[1]} failed: {completed.stderr.decode().strip()}")
    identity.unlink()

    listed = run(["security", "list-keychains", "-d", "user"], capture_output=True, check=True)
    existing = [line.strip().strip('"') for line in listed.stdout.decode().splitlines()]
    run(
        ["security", "list-keychains", "-d", "user", "-s", str(keychain), *existing],
        capture_output=True,
        check=True,
    )
    found = run(
        ["security", "find-identity", "-v", "-p", "codesigning", str(keychain)],
        capture_output=True,
        check=True,
    )
    if b"Apple Distribution" not in found.stdout:
        raise AppleError(
            "the keychain holds no valid Apple Distribution identity. The runner may be "
            "missing Apple's WWDR G3 intermediate certificate."
        )
    return keychain


def targets_in(project: Path) -> dict[str, str]:
    """The signed targets whose bundle identifier the project declares."""
    text = project.read_text(encoding="utf-8")
    return {
        target: bundle
        for target, bundle in TARGETS.items()
        if re.search(rf"^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*{re.escape(bundle)}\s*$", text, re.M)
    }


def marketing_version_in(project: Path) -> str:
    versions = list(
        re.finditer(
            r'^\s*MARKETING_VERSION:\s*"(\d+\.\d+\.\d+)"\s*$',
            project.read_text(encoding="utf-8"),
            re.M,
        )
    )
    if len(versions) != 1:
        raise AppleError("project.yml must declare one quoted MARKETING_VERSION")
    return versions[0].group(1)


def verify_archive(archive: Path, build_number: str) -> list[dict[str, str]]:
    version = marketing_version_in(PROJECT)
    application = archive / "Products" / "Applications" / "HouseholdAssistant.app"
    report = []
    for name, identifier in targets_in(PROJECT).items():
        product = (
            application
            if name == "HouseholdAssistant"
            else (application / "PlugIns" / f"{name}.appex")
        )
        path = product / "Info.plist"
        contents = path.read_bytes()
        properties = plistlib.loads(contents)
        expected = {
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build_number,
        }
        actual = {field: properties.get(field) for field in expected}
        if actual != expected:
            raise AppleError(f"archive metadata mismatch for {name}: {actual}, expected {expected}")
        report.append(
            {
                "bundle": identifier,
                "version": version,
                "build": build_number,
                "plist": str(path.relative_to(archive)),
                "plist_sha256": hashlib.sha256(contents).hexdigest(),
            }
        )
    return report


def signing(
    api: Api,
    signing_key: Path,
    out: Path,
    profiles_dir: Path,
    now: datetime,
    run: Runner,
    targets: dict[str, str],
) -> list[str]:
    out.mkdir(parents=True, exist_ok=True)
    certificate, der = distribution_certificate(api, signing_key, now, run)
    profiles = [
        app_store_profile(api, target, bundle, certificate["id"], now)
        for target, bundle in targets.items()
    ]
    teams = {profile.team for profile in profiles}
    if len(teams) != 1:
        raise AppleError("the profiles belong to different teams")

    profiles_dir.mkdir(parents=True, exist_ok=True)
    for profile in profiles:
        (profiles_dir / f"{profile.uuid}.mobileprovision").write_bytes(profile.content)
    keychain = install_identity(signing_key, der, out, run)

    (out / "signing.env").write_text(
        f"DEVELOPMENT_TEAM={teams.pop()}\n"
        + "".join(f"{PROFILE_VARIABLES[p.target]}={p.name}\n" for p in profiles)
        + f"HA_KEYCHAIN={keychain}\n",
        encoding="utf-8",
    )
    attributes = certificate["attributes"]
    return [
        f"certificate  {attributes.get('name', 'Apple Distribution')}, "
        f"until {expires(attributes):%Y-%m-%d}",
        *(f"profile      {p.name} for {p.bundle}, until {p.expires:%Y-%m-%d}" for p in profiles),
    ]


# ------------------------------------------------------------------- capabilities

# The capabilities each App ID needs for the entitlements its target declares in
# apps/ios/project.yml, that the API can turn on.
CAPABILITIES = {
    APP_BUNDLE: ["APP_GROUPS", "APPLE_ID_AUTH", "PUSH_NOTIFICATIONS"],
    WIDGET_BUNDLE: ["APP_GROUPS"],
    NOTIFICATIONS_BUNDLE: ["APP_GROUPS"],
    SHARE_BUNDLE: ["APP_GROUPS"],
}
# The entitlement each capability grants, which the tests hold to project.yml.
CAPABILITY_ENTITLEMENTS = {
    "APP_GROUPS": "com.apple.security.application-groups",
    "APPLE_ID_AUTH": "com.apple.developer.applesignin",
    "PUSH_NOTIFICATIONS": "aps-environment",
}
# Entitlements only the portal can grant, by the name its Identifiers screen shows.
# On 15 October 2026 the API answered 409 to USERNOTIFICATIONS_COMMUNICATION, the
# type fastlane's web session uses for Communication Notifications, and its answer
# listed every type it accepts, without USERNOTIFICATIONS_TIMESENSITIVE either.
# `setup` checks the profile for each one and reports the tick it needs.
PORTAL_ENTITLEMENTS = {
    APP_BUNDLE: {
        "com.apple.developer.usernotifications.communication": "Communication Notifications",
        "com.apple.developer.usernotifications.time-sensitive": "Time Sensitive Notifications",
    },
}
# The settings Apple wants with a capability. Sign in with Apple makes this app
# the primary one for its consent screen. The others take none.
CAPABILITY_SETTINGS: dict[str, list[Json]] = {
    "APPLE_ID_AUTH": [
        {"key": "APPLE_ID_AUTH_APP_CONSENT", "options": [{"key": "PRIMARY_APP_CONSENT"}]}
    ],
}
# Entitlements every App Store profile carries, some holding the team id, and so
# not worth reading back.
PLAIN_ENTITLEMENTS = {
    "application-identifier",
    "beta-reports-active",
    "com.apple.developer.team-identifier",
    "get-task-allow",
    "keychain-access-groups",
}


def capability_types(api: Api, bundle: Json) -> set[str]:
    return {
        str(c["attributes"].get("capabilityType"))
        for c in api.all(
            f"/v1/bundleIds/{bundle['id']}/bundleIdCapabilities",
            {},
            doing="read App ID capabilities",
        )
    }


def capability(api: Api, bundle_identifier: str, capability_type: str) -> str:
    """Turn one capability on for an App ID, once, and read it back."""
    bundle = find_bundle(api, bundle_identifier)
    if bundle is None:
        raise AppleError(f"the App ID {bundle_identifier} is not registered")
    if capability_type in capability_types(api, bundle):
        return f"{capability_type} was already on for {bundle_identifier}"
    api.must(
        "POST",
        "/v1/bundleIdCapabilities",
        {
            "data": {
                "type": "bundleIdCapabilities",
                "attributes": {
                    "capabilityType": capability_type,
                    "settings": CAPABILITY_SETTINGS.get(capability_type, []),
                },
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}}},
            }
        },
        doing=f"turn on {capability_type}",
    )
    if capability_type not in capability_types(api, bundle):
        raise AppleError(f"Apple accepted {capability_type} but does not list it on the App ID")
    return f"{capability_type} is now on for {bundle_identifier}"


def register(api: Api, identifier: str) -> str:
    """Register an App ID once, and read it back."""
    if find_bundle(api, identifier) is not None:
        return f"App ID {identifier} was already registered"
    api.must(
        "POST",
        "/v1/bundleIds",
        {
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": identifier,
                    "name": APP_ID_NAMES[identifier],
                    "platform": "IOS",
                },
            }
        },
        doing=f"register the App ID {identifier}",
    )
    if find_bundle(api, identifier) is None:
        raise AppleError(f"Apple accepted the App ID {identifier} but does not list it")
    return f"App ID {identifier} is now registered"


def setup(api: Api, signing_key: Path, now: datetime, run: Runner) -> list[str]:
    """Bring the account to what every target needs, and read each part back.

    Registers each App ID, turns on the capabilities its entitlements need, then
    finds or makes each App Store profile. A capability change makes Apple
    invalidate the profiles it touches, so this makes fresh ones. What only the
    portal can do, assigning the App Group and the capabilities in
    PORTAL_ENTITLEMENTS, is read from each profile and reported with its screen,
    and everything else still goes ahead.
    """
    lines = []
    for bundle in TARGETS.values():
        lines.append(f"done   {register(api, bundle)}")
        for kind in CAPABILITIES[bundle]:
            try:
                lines.append(f"done   {capability(api, bundle, kind)}")
            except AppleError as error:
                lines.append(f"TO DO  {error}")
    certificate, _ = distribution_certificate(api, signing_key, now, run)
    for target, bundle in TARGETS.items():
        try:
            profile = app_store_profile(api, target, bundle, certificate["id"], now)
        except AppleError as error:
            lines.append(f"TO DO  {error}")
            continue
        carries = sorted(set(profile.entitlements) - PLAIN_ENTITLEMENTS)
        lines.append(
            f"done   profile {profile.name} for {bundle}, until {profile.expires:%Y-%m-%d}, "
            f"carries {', '.join(carries) or 'nothing more'}"
        )
        for entitlement, label in PORTAL_ENTITLEMENTS.get(bundle, {}).items():
            if entitlement not in profile.entitlements:
                lines.append(
                    f"TO DO  {label} is off for {bundle}. At developer.apple.com, "
                    f"Certificates, IDs and Profiles, Identifiers, open {bundle}, tick "
                    f"{label}, then Save and Confirm. The next setup makes a fresh profile."
                )
    return lines


# ------------------------------------------------------------------------ testers


def testers(api: Api, build_number: str, wait: timedelta, sleep: Callable[[float], None]) -> str:
    """Wait for Apple to process the build, then make sure the internal group gets it."""
    apps = api.all("/v1/apps", {"filter[bundleId]": APP_BUNDLE}, doing="read apps")
    app = next((a for a in apps if a["attributes"]["bundleId"] == APP_BUNDLE), None)
    if app is None:
        raise AppleError(f"no App Store Connect app with bundle id {APP_BUNDLE}")
    deadline = time.monotonic() + wait.total_seconds()
    while True:
        builds = api.all(
            "/v1/builds",
            {"filter[app]": app["id"], "filter[version]": build_number, "limit": "10"},
            doing="read builds",
        )
        if builds and (len(builds) != 1 or builds[0]["attributes"].get("version") != build_number):
            raise AppleError(f"Apple did not return one exact build {build_number}")
        state = builds[0]["attributes"].get("processingState") if builds else "NOT_SEEN"
        if state == "VALID":
            break
        if state in ("FAILED", "INVALID"):
            raise AppleError(
                f"Apple marked build {build_number} {state}. The account holder gets an email "
                "that says why."
            )
        if time.monotonic() >= deadline:
            raise AppleError(
                f"build {build_number} was still {state} after {wait}. It may still finish. "
                "Look in App Store Connect, TestFlight."
            )
        sleep(30)

    build = builds[0]
    version = marketing_version_in(PROJECT)
    processed = (
        api.must(
            "GET",
            f"/v1/builds/{build['id']}/preReleaseVersion",
            doing="read the processed marketing version",
        ).get("data")
        or {}
    )
    attributes = processed.get("attributes") or {}
    if attributes.get("version") != version or attributes.get("platform") != "IOS":
        raise AppleError(
            f"build {build_number} processed version {attributes.get('version')} "
            f"on {attributes.get('platform')}, expected {version} on IOS"
        )
    groups = [
        g
        for g in api.all(
            f"/v1/apps/{app['id']}/betaGroups", {"limit": "200"}, doing="read TestFlight groups"
        )
        if g["attributes"].get("isInternalGroup")
    ]
    if not groups:
        raise AppleError("there is no internal TestFlight group to give the build to")
    for group in groups:
        if group["attributes"].get("hasAccessToAllBuilds"):
            continue
        api.must(
            "POST",
            f"/v1/betaGroups/{group['id']}/relationships/builds",
            {"data": [{"type": "builds", "id": build["id"]}]},
            doing="give the build to a TestFlight group",
        )
    names = ", ".join(str(g["attributes"]["name"]) for g in groups)
    return f"version {version}, build {build_number} is ready in TestFlight for {names}"


def installs(api: Api) -> list[str]:
    """Read only: each internal tester's TestFlight state, and the newest build there.

    Apple reports whether a tester has installed the app, not which build: on
    15 October 2026 it returned no `appDevices` for any tester, even asked by name.
    Testers are named by first name alone, so the run's log holds no email address.
    """
    apps = api.all("/v1/apps", {"filter[bundleId]": APP_BUNDLE}, doing="read apps")
    app = next((a for a in apps if a["attributes"]["bundleId"] == APP_BUNDLE), None)
    if app is None:
        raise AppleError(f"no App Store Connect app with bundle id {APP_BUNDLE}")
    query = urllib.parse.urlencode(
        {"filter[app]": app["id"], "sort": "-uploadedDate", "limit": "1"}
    )
    newest = api.must("GET", f"/v1/builds?{query}", doing="read builds").get("data", [])
    lines: list[str] = []
    seen = 0
    installed = 0
    for group in api.all(
        f"/v1/apps/{app['id']}/betaGroups", {"limit": "200"}, doing="read TestFlight groups"
    ):
        if not group["attributes"].get("isInternalGroup"):
            continue
        for tester in api.all(
            f"/v1/betaGroups/{group['id']}/betaTesters",
            {"fields[betaTesters]": "firstName,state", "limit": "200"},
            doing="read TestFlight testers",
        ):
            attributes = tester["attributes"]
            state = str(attributes.get("state", "UNKNOWN"))
            seen += 1
            installed += state == "INSTALLED"
            name = attributes.get("firstName") or "a tester"
            lines.append(f"{group['attributes']['name']}: {name} is {state}")
    build = newest[0]["attributes"]["version"] if newest else "none yet"
    lines.append(
        f"{installed} of {seen} tester(s) have installed the app from TestFlight. "
        f"The newest build there is {build}."
    )
    return lines


# --------------------------------------------------------------------------- main


def main(
    argv: Sequence[str] | None = None,
    *,
    send: Send = send_with_urllib,
    run: Runner = subprocess.run,
    now: Callable[[], datetime] = lambda: datetime.now(UTC),
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("preflight", help="read only: which Apple steps are done")
    archive = commands.add_parser("archive", help="read only: verify archived release metadata")
    archive.add_argument("--path", type=Path, required=True)
    archive.add_argument("--build-number", required=True)
    sign = commands.add_parser("signing", help="certificate, profiles and keychain for a release")
    sign.add_argument("--out", type=Path, required=True, help="a private directory for the files")
    sign.add_argument("--profiles-dir", type=Path, default=PROFILES_DIR)
    tester = commands.add_parser("testers", help="wait for processing, then hand to testers")
    tester.add_argument("--build-number", required=True)
    tester.add_argument("--wait-minutes", type=int, default=30)
    commands.add_parser("installs", help="read only: who has installed the app from TestFlight")
    commands.add_parser(
        "setup", help="register the App IDs, turn on their capabilities, make the profiles"
    )
    arguments = parser.parse_args(argv)

    try:
        if arguments.command == "archive":
            print(json.dumps(verify_archive(arguments.path, arguments.build_number), indent=2))
            return 0
        key = Key.from_environment()
        api = Api(lambda: make_token(key, now(), run), send)
        if arguments.command == "preflight":
            checks = preflight(api, targets_in(PROJECT))
            for check in checks:
                print(f"{'done' if check.is_done else 'TO DO':<6} {check.name:<44} {check.detail}")
            return 0 if all(check.is_done for check in checks) else 1
        if arguments.command == "signing":
            signing_key = Path(os.environ.get("SIGNING_KEY_PATH", ""))
            if not signing_key.is_file():
                raise AppleError("SIGNING_KEY_PATH does not point at a file.")
            for line in signing(
                api,
                signing_key,
                arguments.out,
                arguments.profiles_dir,
                now(),
                run,
                targets_in(PROJECT),
            ):
                print(line)
            return 0
        if arguments.command == "installs":
            for line in installs(api):
                print(line)
            return 0
        if arguments.command == "setup":
            signing_key = Path(os.environ.get("SIGNING_KEY_PATH", ""))
            if not signing_key.is_file():
                raise AppleError("SIGNING_KEY_PATH does not point at a file.")
            lines = setup(api, signing_key, now(), run)
            for line in lines:
                print(line)
            return 0 if not any(line.startswith("TO DO") for line in lines) else 1
        print(
            testers(api, arguments.build_number, timedelta(minutes=arguments.wait_minutes), sleep)
        )
        return 0
    except AppleError as error:
        print(f"error  {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
