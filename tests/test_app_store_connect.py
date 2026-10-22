"""scripts/macos/app-store-connect.py against a fake App Store Connect.

The release job runs this on a GitHub Mac with the owner's real key, so these tests
check everything that can be checked without Apple: the token's signature with a
real P-256 key and real openssl, the read-only preflight, finding or making the
distribution certificate and the two App Store profiles, the throwaway keychain's
commands, and the wait for testers. The fake API answers the way Apple's documents
say it does; the first real release is what proves Apple agrees.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import sys
import urllib.parse
from collections.abc import Callable, Sequence
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml

from tests.capabilities import POSIX_BASH, needs_posix_bash

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "macos" / "app-store-connect.py"
NOW = datetime(2026, 10, 14, 20, 0, tzinfo=UTC)
LATER = "2027-10-14T00:00:00.000+00:00"
SOON = "2026-10-15T00:00:00.000+00:00"

needs_openssl = pytest.mark.skipif(
    shutil.which("openssl") is None, reason="needs openssl, which CI on Linux has"
)


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("app_store_connect", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["app_store_connect"] = module
    spec.loader.exec_module(module)
    return module


asc = load()


Payload = dict[str, Any]


def openssl_run(
    command: Sequence[str], *, input: bytes = b"", capture_output: bool = True, check: bool = False
) -> subprocess.CompletedProcess[bytes]:
    # Git for Windows' openssl would read "/CN=..." as a path and rewrite it.
    env = {**os.environ, "MSYS2_ARG_CONV_EXCL": "*"}
    return subprocess.run(command, input=input, capture_output=capture_output, check=check, env=env)


def openssl(*arguments: str) -> bytes:
    completed = openssl_run(["openssl", *arguments], capture_output=True, check=True)
    return completed.stdout


# ------------------------------------------------------------------ the project


TWO = {
    "HouseholdAssistant": "com.siqstack.stewardai",
    "HouseholdAssistantWidgets": "com.siqstack.stewardai.widgets",
}


def test_every_signed_target_in_the_project_is_known_with_the_capabilities_it_needs() -> None:
    """The script may know a target before the change that adds it lands, never after."""
    spec = yaml.safe_load(asc.PROJECT.read_text(encoding="utf-8"))
    signed = {
        name: target
        for name, target in spec["targets"].items()
        if target["type"] in ("application", "app-extension")
    }
    assert signed, "the project declares no app or extension"
    assert asc.targets_in(asc.PROJECT) == {
        name: target["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"]
        for name, target in signed.items()
    }
    for name, target in signed.items():
        settings = target["settings"]["base"]
        bundle = asc.TARGETS[name]
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == bundle
        assert settings["PRODUCT_NAME"] == name
        entitlements = target["entitlements"]["properties"]
        assert entitlements["com.apple.security.application-groups"] == [asc.APP_GROUP]
        granted = {asc.CAPABILITY_ENTITLEMENTS[kind] for kind in asc.CAPABILITIES[bundle]}
        granted |= set(asc.PORTAL_ENTITLEMENTS.get(bundle, {}))
        assert set(entitlements) <= granted, (
            f"{name} needs a capability the script does not turn on"
        )


def test_a_release_signs_only_the_targets_the_project_declares(tmp_path: Path) -> None:
    project = tmp_path / "project.yml"
    project.write_text(
        "targets:\n"
        "  HouseholdAssistant:\n"
        "    settings:\n"
        "      base:\n"
        "        PRODUCT_BUNDLE_IDENTIFIER: com.siqstack.stewardai\n"
        "  HouseholdAssistantWidgets:\n"
        "    settings:\n"
        "      base:\n"
        "        PRODUCT_BUNDLE_IDENTIFIER: com.siqstack.stewardai.widgets\n"
        "  HouseholdAssistantTests:\n"
        "    settings:\n"
        "      base:\n"
        "        PRODUCT_BUNDLE_IDENTIFIER: com.siqstack.stewardai.tests\n",
        encoding="utf-8",
    )

    assert asc.targets_in(project) == TWO


# ---------------------------------------------------------------------- tokens


def der(r: bytes, s: bytes) -> bytes:
    body = bytes([0x02, len(r)]) + r + bytes([0x02, len(s)]) + s
    return bytes([0x30, len(body)]) + body


@pytest.mark.parametrize(
    ("r", "s"),
    [
        (b"\x01" * 32, b"\x02" * 32),
        (b"\x00" + b"\x80" * 32, b"\x7f" * 32),
        (b"\x05" * 31, b"\x06" * 30),
    ],
)
def test_a_der_signature_becomes_64_raw_bytes(r: bytes, s: bytes) -> None:
    raw = asc.der_signature_to_raw(der(r, s))

    assert len(raw) == 64
    assert raw[:32] == r.lstrip(b"\x00").rjust(32, b"\x00")
    assert raw[32:] == s.lstrip(b"\x00").rjust(32, b"\x00")


def test_something_that_is_not_a_signature_is_refused() -> None:
    with pytest.raises(asc.AppleError):
        asc.der_signature_to_raw(b"not a signature")


@pytest.fixture
def apple_key(tmp_path: Path) -> Path:
    path = tmp_path / "AuthKey_TEST.p8"
    openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(path))
    return path


def minimal(integer: bytes) -> bytes:
    """DER's shortest form of a positive integer, which openssl insists on."""
    stripped = integer.lstrip(b"\x00") or b"\x00"
    return b"\x00" + stripped if stripped[0] & 0x80 else stripped


def unpadded(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


@needs_openssl
def test_the_token_is_signed_by_the_key_and_says_who_it_is(apple_key: Path, tmp_path: Path) -> None:
    # Arrange
    key = asc.Key("KEYID", "issuer-uuid", apple_key)

    # Act
    token = asc.make_token(key, NOW, openssl_run)

    # Assert: the claims Apple reads, and a signature openssl itself accepts.
    header, claims, signature = token.split(".")
    assert json.loads(unpadded(header)) == {"alg": "ES256", "kid": "KEYID", "typ": "JWT"}
    decoded = json.loads(unpadded(claims))
    assert decoded["iss"] == "issuer-uuid"
    assert decoded["aud"] == "appstoreconnect-v1"
    assert decoded["exp"] - decoded["iat"] <= 20 * 60
    raw = unpadded(signature)
    signature_file = tmp_path / "signature.der"
    signature_file.write_bytes(der(minimal(raw[:32]), minimal(raw[32:])))
    public = tmp_path / "public.pem"
    public.write_bytes(openssl("pkey", "-in", str(apple_key), "-pubout"))
    verified = openssl_run(
        ["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(signature_file)],
        input=f"{header}.{claims}".encode(),
        capture_output=True,
        check=False,
    )
    assert b"Verified OK" in verified.stdout


# ------------------------------------------------------------------- the fake API


Handler = Callable[[str, str, dict[str, str], Payload | None], tuple[int, Payload]]


class FakeApple:
    """Routes each request to a handler by method and path, and records it."""

    def __init__(self) -> None:
        self.routes: dict[tuple[str, str], Handler] = {}
        self.calls: list[tuple[str, str, Payload | None]] = []

    def on(self, method: str, path: str, handler: Handler) -> None:
        self.routes[(method, path)] = handler

    def answer(self, method: str, path: str, status: int, payload: Payload) -> None:
        self.on(method, path, lambda *_: (status, payload))

    def send(self, method: str, url: str, body: Payload | None, token: str) -> tuple[int, Payload]:
        assert token == "token"
        parsed = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(parsed.query))
        self.calls.append((method, parsed.path, body))
        handler = self.routes.get((method, parsed.path))
        if handler is None:
            return 404, {"errors": [{"detail": f"no route {method} {parsed.path}"}]}
        return handler(method, parsed.path, query, body)

    def api(self) -> object:
        api: object = asc.Api(lambda: "token", self.send)
        return api


def page(*items: dict[str, Any]) -> dict[str, Any]:
    return {"data": list(items), "links": {}}


def bundle(identifier: str, number: str) -> dict[str, Any]:
    return {"id": number, "attributes": {"identifier": identifier}}


def bundles_by_identifier(
    _method: str, _path: str, query: dict[str, str], _body: Payload | None
) -> tuple[int, Payload]:
    identifier = query["filter[identifier]"]
    # Apple's filter matches by prefix, so the app's lookup also finds the widget.
    known = [bundle(asc.APP_BUNDLE, "B1"), bundle(asc.WIDGET_BUNDLE, "B2")]
    return 200, page(*(b for b in known if b["attributes"]["identifier"].startswith(identifier)))


def capabilities(
    _method: str, _path: str, query: dict[str, str], _body: Payload | None
) -> tuple[int, Payload]:
    # Apple answered the first real preflight, on 14 October 2026, with this 400.
    if "limit" in query:
        detail = "The parameter 'limit' can not be used with this request"
        return 400, {"errors": [{"detail": detail}]}
    return 200, page({"attributes": {"capabilityType": "APP_GROUPS"}})


def everything_done(apple: FakeApple) -> None:
    app = {"id": "A1", "attributes": {"bundleId": asc.APP_BUNDLE, "name": "Steward AI"}}
    apple.answer("GET", "/v1/apps", 200, page(app))
    apple.answer("GET", "/v1/certificates", 200, page())
    apple.on("GET", "/v1/bundleIds", bundles_by_identifier)
    for number in ("B1", "B2"):
        apple.on("GET", f"/v1/bundleIds/{number}/bundleIdCapabilities", capabilities)
    family = {
        "id": "G1",
        "attributes": {"name": "Family", "isInternalGroup": True, "hasAccessToAllBuilds": True},
    }
    apple.answer("GET", "/v1/apps/A1/betaGroups", 200, page(family))
    apple.answer("GET", "/v1/betaGroups/G1/betaTesters", 200, page({"id": "T1"}, {"id": "T2"}))


# ------------------------------------------------------------------- preflight


def test_preflight_reports_every_step_done() -> None:
    apple = FakeApple()
    everything_done(apple)

    checks = asc.preflight(apple.api(), TWO)

    assert all(check.is_done for check in checks), checks
    assert [check.name for check in checks] == [
        "API key",
        "App Store Connect app",
        "key can sign",
        f"App ID {asc.APP_BUNDLE}",
        f"App Groups on {asc.APP_BUNDLE}",
        f"App ID {asc.WIDGET_BUNDLE}",
        f"App Groups on {asc.WIDGET_BUNDLE}",
        "TestFlight group",
    ]
    assert checks[-1].detail == "Family gets every build, 2 tester(s)"


def test_preflight_names_a_key_that_is_not_admin_and_reads_nothing_it_cannot() -> None:
    apple = FakeApple()
    everything_done(apple)
    apple.answer("GET", "/v1/certificates", 403, {"errors": [{"detail": "forbidden"}]})

    checks = asc.preflight(apple.api(), TWO)

    by_name = {check.name: check for check in checks}
    assert not by_name["key can sign"].is_done
    assert "not Admin" in by_name["key can sign"].detail
    assert not any(path.startswith("/v1/bundleIds") for _, path, _ in apple.calls)


def test_preflight_names_the_missing_app_record_and_group() -> None:
    apple = FakeApple()
    everything_done(apple)
    apple.answer("GET", "/v1/apps", 200, page())

    checks = asc.preflight(apple.api(), TWO)

    by_name = {check.name: check for check in checks}
    assert not by_name["App Store Connect app"].is_done
    assert "TestFlight group" not in by_name


def test_preflight_wants_a_group_that_gets_every_build() -> None:
    apple = FakeApple()
    everything_done(apple)
    by_hand = {
        "id": "G1",
        "attributes": {"name": "Family", "isInternalGroup": True, "hasAccessToAllBuilds": False},
    }
    apple.answer("GET", "/v1/apps/A1/betaGroups", 200, page(by_hand))

    checks = asc.preflight(apple.api(), TWO)

    assert checks[-1].is_done is False
    assert "does not get every build automatically" in checks[-1].detail


def test_a_refused_key_says_what_to_check() -> None:
    apple = FakeApple()
    apple.answer("GET", "/v1/apps", 401, {})

    with pytest.raises(asc.AppleError, match="same key"):
        asc.preflight(apple.api(), TWO)


# --------------------------------------------------------------------- signing


@pytest.fixture
def distribution_key(tmp_path: Path) -> Path:
    path = tmp_path / "distribution-key.pem"
    openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(path))
    return path


def certificate_for(key: Path, tmp_path: Path) -> bytes:
    """A certificate for this key, standing in for the one Apple issues."""
    out = tmp_path / "issued.der"
    openssl(
        "req", "-new", "-x509", "-key", str(key), "-subj", "/CN=Apple Distribution: Test",
        "-days", "365", "-outform", "DER", "-out", str(out),
    )  # fmt: skip
    return out.read_bytes()


def profile_content(name: str, uuid: str, groups: list[str]) -> str:
    plist = plistlib.dumps(
        {
            "Name": name,
            "UUID": uuid,
            "TeamIdentifier": ["TeamTest01"],
            "Entitlements": {"com.apple.security.application-groups": groups},
        }
    )
    return base64.b64encode(b"\x30\x80signed envelope" + plist + b"\x00signature").decode()


def a_profile(number: str, name: str, *, groups: list[str] | None = None) -> dict[str, Any]:
    return {
        "id": number,
        "attributes": {
            "profileType": "IOS_APP_STORE",
            "profileState": "ACTIVE",
            "expirationDate": LATER,
            "profileContent": profile_content(
                name, f"uuid-{number}", [asc.APP_GROUP] if groups is None else groups
            ),
        },
    }


class FakeSecurity:
    """Stands in for macOS `security` and LibreSSL; passes real openssl through."""

    def __init__(self) -> None:
        self.commands: list[list[str]] = []

    def __call__(
        self, command: Sequence[str], *, input: bytes = b"", **_: object
    ) -> subprocess.CompletedProcess[bytes]:
        command = list(command)
        if command[0] == "openssl":
            return openssl_run(command, input=input)
        self.commands.append(command)
        out = b""
        if command[:2] == ["/usr/bin/openssl", "pkcs12"]:
            Path(command[command.index("-out") + 1]).write_bytes(b"p12")
        if command[:2] == ["security", "list-keychains"] and "-s" not in command:
            out = b'    "/Users/runner/Library/Keychains/login.keychain-db"\n'
        if command[:2] == ["security", "find-identity"]:
            out = b'  1) ABC "Apple Distribution: Test (TeamTest01)"\n'
        return subprocess.CompletedProcess(command, 0, out, b"")


def signing_apple(certificate_der: bytes) -> FakeApple:
    apple = FakeApple()
    apple.answer(
        "GET",
        "/v1/certificates",
        200,
        page(
            {"id": "C0", "attributes": {"expirationDate": SOON, "certificateContent": "eA=="}},
            {
                "id": "C1",
                "attributes": {
                    "name": "Apple Distribution",
                    "expirationDate": LATER,
                    "certificateContent": base64.b64encode(certificate_der).decode(),
                },
            },
        ),
    )
    apple.on("GET", "/v1/bundleIds", bundles_by_identifier)
    apple.answer("GET", "/v1/bundleIds/B1/profiles", 200, page(a_profile("P1", "app profile")))
    apple.answer("GET", "/v1/bundleIds/B2/profiles", 200, page(a_profile("P2", "widget profile")))
    for number in ("P1", "P2"):
        apple.answer("GET", f"/v1/profiles/{number}/certificates", 200, page({"id": "C1"}))
    return apple


@needs_openssl
def test_signing_uses_the_certificate_and_profiles_that_already_exist(
    distribution_key: Path, tmp_path: Path
) -> None:
    # Arrange
    apple = signing_apple(certificate_for(distribution_key, tmp_path))
    security = FakeSecurity()
    out = tmp_path / "signing"
    profiles = tmp_path / "profiles"

    # Act
    said = asc.signing(apple.api(), distribution_key, out, profiles, NOW, security, TWO)

    # Assert: nothing was made, both profiles are installed, and the env file has the names.
    assert not any(method == "POST" for method, _, _ in apple.calls)
    assert sorted(p.name for p in profiles.iterdir()) == [
        "uuid-P1.mobileprovision",
        "uuid-P2.mobileprovision",
    ]
    env = (out / "signing.env").read_text(encoding="utf-8").splitlines()
    assert env[:3] == [
        "DEVELOPMENT_TEAM=TeamTest01",
        "HA_APP_PROFILE=app profile",
        "HA_WIDGET_PROFILE=widget profile",
    ]
    assert env[3] == f"HA_KEYCHAIN={out / 'signing.keychain-db'}"
    assert not any("TeamTest01" in line for line in said)
    assert not (out / "identity.p12").exists()


@needs_openssl
def test_the_keychain_is_made_imported_unlocked_and_searched(
    distribution_key: Path, tmp_path: Path
) -> None:
    security = FakeSecurity()
    apple = signing_apple(certificate_for(distribution_key, tmp_path))

    asc.signing(apple.api(), distribution_key, tmp_path / "s", tmp_path / "p", NOW, security, TWO)

    verbs = [" ".join(command[:2]) for command in security.commands]
    assert verbs == [
        "/usr/bin/openssl pkcs12",
        "security create-keychain",
        "security set-keychain-settings",
        "security unlock-keychain",
        "security import",
        "security set-key-partition-list",
        "security list-keychains",
        "security list-keychains",
        "security find-identity",
    ]
    search = security.commands[7]
    assert search[search.index("-s") + 1 :] == [
        str(tmp_path / "s" / "signing.keychain-db"),
        "/Users/runner/Library/Keychains/login.keychain-db",
    ]


@needs_openssl
def test_signing_makes_the_certificate_and_profiles_the_first_time(
    distribution_key: Path, tmp_path: Path
) -> None:
    # Arrange: no certificate for this key, and no profile at all.
    issued = certificate_for(distribution_key, tmp_path)
    apple = signing_apple(issued)
    apple.answer("GET", "/v1/certificates", 200, page())
    apple.answer("GET", "/v1/bundleIds/B1/profiles", 200, page())
    apple.answer("GET", "/v1/bundleIds/B2/profiles", 200, page())
    requests: list[str] = []

    def issue(_m: str, _p: str, _q: dict[str, str], body: Payload | None) -> tuple[int, Payload]:
        assert body is not None
        requests.append(body["data"]["attributes"]["csrContent"])
        content = base64.b64encode(issued).decode()
        made = {"id": "C9", "attributes": {"expirationDate": LATER, "certificateContent": content}}
        return 201, {"data": made}

    made: list[Payload] = []

    def make_profile(
        _m: str, _p: str, _q: dict[str, str], body: Payload | None
    ) -> tuple[int, Payload]:
        assert body is not None
        made.append(body)
        number = f"N{len(made)}"
        return 201, {"data": a_profile(number, body["data"]["attributes"]["name"])}

    apple.on("POST", "/v1/certificates", issue)
    apple.on("POST", "/v1/profiles", make_profile)

    # Act
    asc.signing(
        apple.api(), distribution_key, tmp_path / "s", tmp_path / "p", NOW, FakeSecurity(), TWO
    )

    # Assert: one signing request for this key, one profile per App ID, both on the new certificate.
    assert len(requests) == 1 and "BEGIN CERTIFICATE REQUEST" in requests[0]
    assert [b["data"]["relationships"]["bundleId"]["data"]["id"] for b in made] == ["B1", "B2"]
    assert all(
        b["data"]["relationships"]["certificates"]["data"] == [{"type": "certificates", "id": "C9"}]
        for b in made
    )
    assert all(b["data"]["attributes"]["profileType"] == "IOS_APP_STORE" for b in made)


@needs_openssl
def test_a_full_certificate_allowance_says_what_to_revoke(
    distribution_key: Path, tmp_path: Path
) -> None:
    apple = FakeApple()
    apple.answer("GET", "/v1/certificates", 200, page())
    apple.answer("POST", "/v1/certificates", 409, {"errors": [{"detail": "limit reached"}]})

    with pytest.raises(asc.AppleError, match="Revoke an unused one"):
        asc.distribution_certificate(apple.api(), distribution_key, NOW, openssl_run)


def test_a_profile_without_the_app_group_names_the_fix() -> None:
    attributes = a_profile("P1", "app profile", groups=[])["attributes"]

    with pytest.raises(asc.AppleError, match="turn on App Groups"):
        asc.checked_profile("HouseholdAssistant", asc.APP_BUNDLE, attributes)


def test_an_unregistered_app_id_names_the_fix() -> None:
    apple = FakeApple()
    apple.answer("GET", "/v1/bundleIds", 200, page())

    with pytest.raises(asc.AppleError, match="is not registered"):
        asc.app_store_profile(apple.api(), "HouseholdAssistant", asc.APP_BUNDLE, "C1", NOW)


# --------------------------------------------------------------------- testers


def apple_for_testers(states: list[str], *, automatic: bool) -> FakeApple:
    apple = FakeApple()
    app = {"id": "A1", "attributes": {"bundleId": asc.APP_BUNDLE, "name": "Steward AI"}}
    apple.answer("GET", "/v1/apps", 200, page(app))
    remaining = iter(states)
    apple.on(
        "GET",
        "/v1/builds",
        lambda *_: (
            200,
            page(
                {"id": "BUILD", "attributes": {"version": "42", "processingState": next(remaining)}}
            ),
        ),
    )
    version = yaml.safe_load(asc.PROJECT.read_text(encoding="utf-8"))["settings"]["base"][
        "MARKETING_VERSION"
    ]
    apple.answer(
        "GET",
        "/v1/builds/BUILD/preReleaseVersion",
        200,
        {"data": {"attributes": {"version": version, "platform": "IOS"}}},
    )
    family = {
        "id": "G1",
        "attributes": {
            "name": "Family",
            "isInternalGroup": True,
            "hasAccessToAllBuilds": automatic,
        },
    }
    apple.answer("GET", "/v1/apps/A1/betaGroups", 200, page(family))
    apple.answer("POST", "/v1/betaGroups/G1/relationships/builds", 204, {})
    return apple


def test_testers_wait_for_processing_then_report_the_group() -> None:
    apple = apple_for_testers(["PROCESSING", "PROCESSING", "VALID"], automatic=True)
    slept: list[float] = []

    said = asc.testers(apple.api(), "42", timedelta(minutes=30), slept.append)

    version = asc.marketing_version_in(asc.PROJECT)
    assert said == f"version {version}, build 42 is ready in TestFlight for Family"
    assert slept == [30, 30]
    assert not any(method == "POST" for method, _, _ in apple.calls)


def test_testers_hand_the_build_to_a_group_that_does_not_get_every_build() -> None:
    apple = apple_for_testers(["VALID"], automatic=False)

    asc.testers(apple.api(), "42", timedelta(minutes=30), lambda _: None)

    posts = [(path, body) for method, path, body in apple.calls if method == "POST"]
    assert posts == [
        ("/v1/betaGroups/G1/relationships/builds", {"data": [{"type": "builds", "id": "BUILD"}]})
    ]


@pytest.mark.parametrize("state", ["FAILED", "INVALID"])
def test_a_build_apple_rejects_says_where_the_reason_is(state: str) -> None:
    apple = apple_for_testers([state], automatic=True)

    with pytest.raises(asc.AppleError, match="gets an email"):
        asc.testers(apple.api(), "42", timedelta(minutes=30), lambda _: None)


def test_the_wait_for_processing_is_bounded() -> None:
    apple = apple_for_testers(["PROCESSING"], automatic=True)

    with pytest.raises(asc.AppleError, match="was still PROCESSING"):
        asc.testers(apple.api(), "42", timedelta(0), lambda _: None)


@pytest.mark.parametrize(
    "attributes",
    [
        {"version": "9.9.9", "platform": "IOS"},
        {"platform": "IOS"},
        {"version": "0.1.1", "platform": "MAC_OS"},
    ],
)
def test_testers_refuse_the_wrong_or_missing_processed_version_before_distribution(
    attributes: dict[str, str],
) -> None:
    apple = apple_for_testers(["VALID"], automatic=False)
    apple.answer(
        "GET", "/v1/builds/BUILD/preReleaseVersion", 200, {"data": {"attributes": attributes}}
    )

    with pytest.raises(asc.AppleError, match="processed version"):
        asc.testers(apple.api(), "42", timedelta(minutes=30), lambda _: None)

    assert not any(method == "POST" for method, _, _ in apple.calls)


@pytest.mark.parametrize(
    "builds",
    [
        [{"id": "WRONG", "attributes": {"version": "41", "processingState": "VALID"}}],
        [
            {"id": identifier, "attributes": {"version": "42", "processingState": "VALID"}}
            for identifier in ("ONE", "TWO")
        ],
    ],
)
def test_testers_refuse_mismatched_or_ambiguous_builds(builds: list[Payload]) -> None:
    apple = apple_for_testers(["VALID"], automatic=False)
    apple.answer("GET", "/v1/builds", 200, page(*builds))

    with pytest.raises(asc.AppleError, match="one exact build"):
        asc.testers(apple.api(), "42", timedelta(minutes=30), lambda _: None)

    assert not any(method == "POST" for method, _, _ in apple.calls)


def test_testers_report_the_processed_marketing_version() -> None:
    apple = apple_for_testers(["VALID"], automatic=True)
    version = yaml.safe_load(asc.PROJECT.read_text(encoding="utf-8"))["settings"]["base"][
        "MARKETING_VERSION"
    ]

    said = asc.testers(apple.api(), "42", timedelta(minutes=30), lambda _: None)

    assert f"version {version}, build 42" in said


@pytest.fixture
def release_archive(tmp_path: Path) -> Path:
    archive = tmp_path / "HouseholdAssistant.xcarchive"
    application = archive / "Products" / "Applications" / "HouseholdAssistant.app"
    version = yaml.safe_load(asc.PROJECT.read_text(encoding="utf-8"))["settings"]["base"][
        "MARKETING_VERSION"
    ]
    for name, identifier in asc.targets_in(asc.PROJECT).items():
        product = (
            application
            if name == "HouseholdAssistant"
            else (application / "PlugIns" / f"{name}.appex")
        )
        product.mkdir(parents=True)
        (product / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": identifier,
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": "14",
                }
            )
        )
    return archive


def test_archive_command_reports_every_signed_bundle_without_apple_credentials(
    release_archive: Path,
) -> None:
    completed = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "archive",
            "--path",
            str(release_archive),
            "--build-number",
            "14",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
        env={
            name: value
            for name, value in os.environ.items()
            if not name.startswith("APP_STORE_CONNECT_")
        },
    )

    assert completed.returncode == 0, completed.stderr
    report = json.loads(completed.stdout)
    assert {row["bundle"] for row in report} == set(asc.targets_in(asc.PROJECT).values())
    assert all(row["build"] == "14" and len(row["plist_sha256"]) == 64 for row in report)


@pytest.mark.parametrize(
    "setting",
    [
        "",
        'MARKETING_VERSION: "0.1.1"\nMARKETING_VERSION: "0.1.0"\n',
    ],
)
def test_release_refuses_missing_or_ambiguous_project_version(
    tmp_path: Path,
    setting: str,
) -> None:
    project = tmp_path / "project.yml"
    project.write_text(setting, encoding="utf-8")

    with pytest.raises(asc.AppleError, match="one quoted MARKETING_VERSION"):
        asc.marketing_version_in(project)


@pytest.mark.parametrize(
    ("target", "field", "value"),
    [
        ("HouseholdAssistant", "CFBundleShortVersionString", "9.9.9"),
        ("HouseholdAssistantWidgets", "CFBundleShortVersionString", "9.9.9"),
        ("HouseholdAssistantShare", "CFBundleVersion", "13"),
        ("HouseholdAssistantNotifications", "CFBundleIdentifier", "wrong.bundle"),
    ],
)
def test_archive_command_rejects_mismatched_app_or_extension_metadata(
    release_archive: Path,
    target: str,
    field: str,
    value: str,
) -> None:
    application = release_archive / "Products" / "Applications" / "HouseholdAssistant.app"
    product = (
        application
        if target == "HouseholdAssistant"
        else (application / "PlugIns" / f"{target}.appex")
    )
    path = product / "Info.plist"
    properties = plistlib.loads(path.read_bytes())
    properties[field] = value
    path.write_bytes(plistlib.dumps(properties))

    completed = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "archive",
            "--path",
            str(release_archive),
            "--build-number",
            "14",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )

    assert completed.returncode == 1
    assert "archive metadata mismatch" in completed.stderr


@needs_posix_bash
@pytest.mark.parametrize("verification_status", [0, 1])
def test_release_never_uploads_when_archive_verification_fails(
    tmp_path: Path,
    verification_status: int,
) -> None:
    workflow = yaml.safe_load((ROOT / ".github/workflows/ios-release.yml").read_text("utf-8"))
    step = next(
        step
        for step in workflow["jobs"]["testflight"]["steps"]
        if step.get("name") == "upload to TestFlight"
    )
    commands = tmp_path / "commands"
    commands.mkdir()
    python = commands / "python"
    python.write_text(f"#!/bin/sh\necho '[]'\nexit {verification_status}\n", encoding="utf-8")
    python.chmod(0o755)
    deployment = tmp_path / "scripts/macos/deploy-testflight.sh"
    deployment.parent.mkdir(parents=True)
    deployment.write_text("#!/bin/sh\ntouch uploaded\n", encoding="utf-8")
    deployment.chmod(0o755)
    (tmp_path / "apps/ios/build").mkdir(parents=True)
    assert POSIX_BASH is not None
    shell = [POSIX_BASH, "--noprofile", "--norc", "-e"]
    if step.get("shell") == "bash":
        shell += ["-o", "pipefail"]

    completed = subprocess.run(
        [*shell, "-c", step["run"]],
        cwd=tmp_path,
        capture_output=True,
        check=False,
        env={
            **os.environ,
            "PATH": f"{commands}{os.pathsep}{os.environ['PATH']}",
            "HA_BUILD_NUMBER": "14",
        },
    )

    assert completed.returncode == verification_status, completed.stderr
    assert (tmp_path / "uploaded").exists() == (verification_status == 0)


# ------------------------------------------------------------------------ main


def test_main_refuses_without_the_key_and_prints_no_value(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    for name in (
        "APP_STORE_CONNECT_KEY_ID",
        "APP_STORE_CONNECT_ISSUER_ID",
        "APP_STORE_CONNECT_KEY_PATH",
    ):
        monkeypatch.delenv(name, raising=False)

    status = asc.main(["preflight"])

    assert status == 1
    assert "APP_STORE_CONNECT_KEY_ID is not set" in capsys.readouterr().err


@needs_openssl
def test_main_preflight_exits_nonzero_while_a_step_is_to_do(
    apple_key: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("APP_STORE_CONNECT_KEY_ID", "KEYID")
    monkeypatch.setenv("APP_STORE_CONNECT_ISSUER_ID", "issuer-uuid")
    monkeypatch.setenv("APP_STORE_CONNECT_KEY_PATH", str(apple_key))
    apple = FakeApple()
    everything_done(apple)
    apple.answer("GET", "/v1/apps/A1/betaGroups", 200, page())

    def send(method: str, url: str, body: Payload | None, token: str) -> tuple[int, Payload]:
        assert token.count(".") == 2
        return apple.send(method, url, body, "token")

    status = asc.main(["preflight"], send=send, run=openssl_run, now=lambda: NOW)

    out = capsys.readouterr().out
    assert status == 1
    assert "TO DO  TestFlight group" in out
    assert "done   App Store Connect app" in out


@needs_openssl
def test_a_long_wait_for_testers_never_sends_an_expired_token(
    apple_key: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Apple's tokens live 20 minutes at most, and the wait for processing is allowed 30."""
    # Arrange: a clock that moves ten minutes on every poll.
    monkeypatch.setenv("APP_STORE_CONNECT_KEY_ID", "KEYID")
    monkeypatch.setenv("APP_STORE_CONNECT_ISSUER_ID", "issuer-uuid")
    monkeypatch.setenv("APP_STORE_CONNECT_KEY_PATH", str(apple_key))
    clock = [NOW]

    def advance(_: float) -> None:
        clock[0] += timedelta(minutes=10)

    apple = apple_for_testers(["PROCESSING", "PROCESSING", "PROCESSING", "VALID"], automatic=True)
    expiries: list[int] = []

    def send(method: str, url: str, body: Payload | None, token: str) -> tuple[int, Payload]:
        claims = json.loads(unpadded(token.split(".")[1]))
        expiries.append(claims["exp"])
        assert claims["exp"] > clock[0].timestamp(), "a token sent after it expired"
        return apple.send(method, url, body, "token")

    # Act
    status = asc.main(
        ["testers", "--build-number", "42", "--wait-minutes", "60"],
        send=send,
        run=openssl_run,
        now=lambda: clock[0],
        sleep=advance,
    )

    # Assert
    assert status == 0
    assert len(set(expiries)) > 1


def test_an_app_that_runs_on_ipad_lists_every_orientation_apple_requires() -> None:
    """App Store Connect refused the first upload, on 15 October 2026, with error 90474."""
    spec = yaml.safe_load((ROOT / "apps" / "ios" / "project.yml").read_text(encoding="utf-8"))
    app = spec["targets"]["HouseholdAssistant"]
    families = str(app["settings"]["base"]["TARGETED_DEVICE_FAMILY"]).split(",")
    if "2" not in families:
        return
    orientations = app["info"]["properties"]["UISupportedInterfaceOrientations~ipad"]
    assert set(orientations) == {
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    }


def test_installs_counts_testers_by_their_state_and_names_the_newest_build() -> None:
    # Arrange: one tester who installed, one still invited, as Apple read on 15 October 2026.
    apple = FakeApple()
    app = {"id": "A1", "attributes": {"bundleId": asc.APP_BUNDLE, "name": "Steward AI"}}
    apple.answer("GET", "/v1/apps", 200, page(app))
    builds: list[dict[str, str]] = []

    def newest(
        _method: str, _path: str, query: dict[str, str], _body: Payload | None
    ) -> tuple[int, Payload]:
        builds.append(query)
        return 200, page({"id": "BUILD", "attributes": {"version": "9"}})

    apple.on("GET", "/v1/builds", newest)
    family = {"id": "G1", "attributes": {"name": "Family", "isInternalGroup": True}}
    outside = {"id": "G2", "attributes": {"name": "Friends", "isInternalGroup": False}}
    apple.answer("GET", "/v1/apps/A1/betaGroups", 200, page(family, outside))
    installed = {"firstName": "Franco", "email": "someone@example.com", "state": "INSTALLED"}
    invited = {"firstName": "Gia", "email": "else@example.com", "state": "INVITED"}
    apple.answer(
        "GET",
        "/v1/betaGroups/G1/betaTesters",
        200,
        page({"id": "T1", "attributes": installed}, {"id": "T2", "attributes": invited}),
    )

    # Act
    lines = asc.installs(apple.api())

    # Assert: first names only, no email, external groups skipped, the newest build asked for.
    assert lines == [
        "Family: Franco is INSTALLED",
        "Family: Gia is INVITED",
        "1 of 2 tester(s) have installed the app from TestFlight. The newest build there is 9.",
    ]
    assert not any("@" in line for line in lines)
    assert not any(path.startswith("/v1/betaGroups/G2") for _, path, _ in apple.calls)
    assert builds == [{"filter[app]": "A1", "sort": "-uploadedDate", "limit": "1"}]


def apple_with_capabilities(present: list[str]) -> tuple[FakeApple, list[Payload]]:
    apple = FakeApple()
    apple.on("GET", "/v1/bundleIds", bundles_by_identifier)
    types = list(present)
    posted: list[Payload] = []

    def listed(_m: str, _p: str, _q: dict[str, str], _b: Payload | None) -> tuple[int, Payload]:
        return 200, page(*({"attributes": {"capabilityType": kind}} for kind in types))

    def turn_on(_m: str, _p: str, _q: dict[str, str], body: Payload | None) -> tuple[int, Payload]:
        assert body is not None
        posted.append(body)
        types.append(body["data"]["attributes"]["capabilityType"])
        return 201, {"data": {"id": "CAP"}}

    apple.on("GET", "/v1/bundleIds/B1/bundleIdCapabilities", listed)
    apple.on("POST", "/v1/bundleIdCapabilities", turn_on)
    return apple, posted


def test_sign_in_with_apple_is_turned_on_as_the_primary_app() -> None:
    apple, posted = apple_with_capabilities(["APP_GROUPS"])

    said = asc.capability(apple.api(), asc.APP_BUNDLE, "APPLE_ID_AUTH")

    assert said == f"APPLE_ID_AUTH is now on for {asc.APP_BUNDLE}"
    assert posted == [
        {
            "data": {
                "type": "bundleIdCapabilities",
                "attributes": {
                    "capabilityType": "APPLE_ID_AUTH",
                    "settings": [
                        {
                            "key": "APPLE_ID_AUTH_APP_CONSENT",
                            "options": [{"key": "PRIMARY_APP_CONSENT"}],
                        }
                    ],
                },
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": "B1"}}},
            }
        }
    ]


def test_a_capability_already_on_is_left_alone() -> None:
    apple, posted = apple_with_capabilities(["APP_GROUPS", "APPLE_ID_AUTH"])

    said = asc.capability(apple.api(), asc.APP_BUNDLE, "APPLE_ID_AUTH")

    assert said == f"APPLE_ID_AUTH was already on for {asc.APP_BUNDLE}"
    assert posted == []


def setup_apple(
    certificate_der: bytes, *, refuse: str = "", has_portal_ticks: bool = True
) -> tuple[FakeApple, list[str], list[Payload]]:
    """App and widget set up, the notification extension not yet registered.

    `refuse` names a capability type the API answers 409 to, as it did to
    USERNOTIFICATIONS_COMMUNICATION, and `has_portal_ticks` says whether the
    owner has ticked Communication and Time Sensitive Notifications in the portal.
    """
    apple = signing_apple(certificate_der)
    known = [bundle(asc.APP_BUNDLE, "B1"), bundle(asc.WIDGET_BUNDLE, "B2")]
    capabilities: dict[str, list[str]] = {"B1": ["APP_GROUPS"], "B2": ["APP_GROUPS"]}
    registered: list[str] = []
    turned_on: list[Payload] = []

    def bundles(_m: str, _p: str, query: dict[str, str], _b: Payload | None) -> tuple[int, Payload]:
        prefix = query["filter[identifier]"]
        return 200, page(*(b for b in known if b["attributes"]["identifier"].startswith(prefix)))

    def register(_m: str, _p: str, _q: dict[str, str], body: Payload | None) -> tuple[int, Payload]:
        assert body is not None
        identifier = body["data"]["attributes"]["identifier"]
        registered.append(identifier)
        number = f"B{len(known) + 1}"
        known.append(bundle(identifier, number))
        capabilities[number] = []
        return 201, {"data": known[-1]}

    def listed(_m: str, path: str, _q: dict[str, str], _b: Payload | None) -> tuple[int, Payload]:
        kinds = capabilities[path.split("/")[3]]
        return 200, page(*({"attributes": {"capabilityType": kind}} for kind in kinds))

    def turn_on(_m: str, _p: str, _q: dict[str, str], body: Payload | None) -> tuple[int, Payload]:
        assert body is not None
        kind = body["data"]["attributes"]["capabilityType"]
        if kind == refuse:
            detail = f"'{kind}' is not a valid value for the attribute 'capabilityType'."
            return 409, {"errors": [{"detail": detail}]}
        turned_on.append(body)
        owner = body["data"]["relationships"]["bundleId"]["data"]["id"]
        capabilities[owner].append(kind)
        return 201, {"data": {"id": "CAP"}}

    apple.on("GET", "/v1/bundleIds", bundles)
    apple.on("POST", "/v1/bundleIds", register)
    for number in ("B1", "B2", "B3", "B4"):
        apple.on("GET", f"/v1/bundleIds/{number}/bundleIdCapabilities", listed)
    apple.on("POST", "/v1/bundleIdCapabilities", turn_on)
    # The capability change made Apple invalidate the app's profile, and the new
    # App ID has none yet, so both are made. The widget's still stands.
    apple.answer("GET", "/v1/bundleIds/B1/profiles", 200, page())
    apple.answer("GET", "/v1/bundleIds/B3/profiles", 200, page())
    apple.answer("GET", "/v1/bundleIds/B4/profiles", 200, page())

    def make_profile(
        _m: str, _p: str, _q: dict[str, str], body: Payload | None
    ) -> tuple[int, Payload]:
        assert body is not None
        name = body["data"]["attributes"]["name"]
        owner = body["data"]["relationships"]["bundleId"]["data"]["id"]
        entitlements: Payload = {
            "application-identifier": "TeamTest01.com.siqstack.stewardai",
            "com.apple.developer.team-identifier": "TeamTest01",
            # Apple's API cannot assign the App Group, so the new App ID's profile lacks it.
            "com.apple.security.application-groups": []
            if owner in ("B3", "B4")
            else [asc.APP_GROUP],
        }
        if owner == "B1":
            entitlements["com.apple.developer.applesignin"] = ["Default"]
            entitlements["aps-environment"] = "production"
            if has_portal_ticks:
                entitlements["com.apple.developer.usernotifications.communication"] = True
                entitlements["com.apple.developer.usernotifications.time-sensitive"] = True
        content = plistlib.dumps(
            {"Name": name, "UUID": f"uuid-{owner}", "TeamIdentifier": ["TeamTest01"],
             "Entitlements": entitlements}
        )  # fmt: skip
        made = {
            "profileType": "IOS_APP_STORE",
            "profileState": "ACTIVE",
            "expirationDate": LATER,
            "profileContent": base64.b64encode(b"\x30\x80" + content).decode(),
        }
        return 201, {"data": {"id": f"P-{owner}", "attributes": made}}

    apple.on("POST", "/v1/profiles", make_profile)
    return apple, registered, turned_on


@needs_openssl
def test_setup_registers_the_extension_turns_on_capabilities_and_reads_profiles_back(
    distribution_key: Path, tmp_path: Path
) -> None:
    # Arrange
    apple, registered, turned_on = setup_apple(certificate_for(distribution_key, tmp_path))

    # Act
    lines = asc.setup(apple.api(), distribution_key, NOW, openssl_run)

    # Assert: the new App ID registered, each missing capability turned on once.
    assert registered == [asc.NOTIFICATIONS_BUNDLE, asc.SHARE_BUNDLE]
    kinds = [
        (
            b["data"]["relationships"]["bundleId"]["data"]["id"],
            b["data"]["attributes"]["capabilityType"],
        )
        for b in turned_on
    ]
    assert kinds == [
        ("B1", "APPLE_ID_AUTH"),
        ("B1", "PUSH_NOTIFICATIONS"),
        ("B3", "APP_GROUPS"),
        ("B4", "APP_GROUPS"),
    ]
    app = next(line for line in lines if f"for {asc.APP_BUNDLE}," in line)
    for entitlement in (
        "aps-environment",
        "com.apple.developer.applesignin",
        "com.apple.developer.usernotifications.communication",
        "com.apple.security.application-groups",
    ):
        assert entitlement in app
    assert any(line.startswith("done   profile") and asc.WIDGET_BUNDLE in line for line in lines)
    # The extension's profile lacks the group, and the line says how to assign it.
    missing = [line for line in lines if line.startswith("TO DO")]
    assert len(missing) == 2
    assert asc.NOTIFICATIONS_BUNDLE in missing[0] and asc.SHARE_BUNDLE in missing[1]
    assert all("assign the group" in line for line in missing)
    assert not any("TeamTest01" in line for line in lines)


@needs_openssl
def test_setup_run_again_changes_nothing_it_already_did(
    distribution_key: Path, tmp_path: Path
) -> None:
    apple, registered, turned_on = setup_apple(certificate_for(distribution_key, tmp_path))
    asc.setup(apple.api(), distribution_key, NOW, openssl_run)
    registered.clear()
    turned_on.clear()

    lines = asc.setup(apple.api(), distribution_key, NOW, openssl_run)

    assert registered == []
    assert turned_on == []
    assert not any("is now" in line for line in lines)
    assert sum("was already" in line for line in lines) == 4 + 6


@needs_openssl
def test_setup_reports_a_capability_the_api_refuses_and_goes_on(
    distribution_key: Path, tmp_path: Path
) -> None:
    """On 15 October 2026 one 409 stopped setup before it reached the new App ID."""
    apple, registered, _ = setup_apple(
        certificate_for(distribution_key, tmp_path), refuse="PUSH_NOTIFICATIONS"
    )

    lines = asc.setup(apple.api(), distribution_key, NOW, openssl_run)

    refused = [line for line in lines if line.startswith("TO DO") and "PUSH_NOTIFICATIONS" in line]
    assert len(refused) == 1
    assert registered == [asc.NOTIFICATIONS_BUNDLE, asc.SHARE_BUNDLE]
    assert any(line.startswith("done   profile") and asc.WIDGET_BUNDLE in line for line in lines)


@needs_openssl
@pytest.mark.parametrize("label", ["Communication Notifications", "Time Sensitive Notifications"])
def test_setup_names_each_portal_tick_a_profile_still_lacks(
    distribution_key: Path, tmp_path: Path, label: str
) -> None:
    apple, _, _ = setup_apple(certificate_for(distribution_key, tmp_path), has_portal_ticks=False)

    lines = asc.setup(apple.api(), distribution_key, NOW, openssl_run)

    tick = [line for line in lines if f"{label} is off" in line]
    assert len(tick) == 1
    assert tick[0].startswith("TO DO")
    assert f"open {asc.APP_BUNDLE}, tick {label}" in tick[0]
