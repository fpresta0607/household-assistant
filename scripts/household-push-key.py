#!/usr/bin/env python3
"""The household's own key for the app publisher's push relay, made once on its box.

A household whose box does not hold the app's Apple push key notifies its phones through
the publisher's push relay (docs/deploy/push-relay.md), and signs each notification with an
Ed25519 key of its own. This makes that key, once, as root on the household's box, and
puts it in each gateway's root-only env file as HOUSEHOLD_PUSH_RELAY_KEY, the same key in
both, so either gateway can notify the household's phones. It never prints the private
half and never replaces a key a gateway already has. It prints the public half, the one
line the household sends the publisher, who lets the household in with the relay's
admin.mjs. Run it again and it only prints that line again.

    python3 scripts/household-push-key.py

The household file must name the relay first (`pushRelay` in
/etc/household-assistant/household.json), and the gateways' env files must be there,
which scripts/openclaw-install.sh makes. A gateway reads its env file when its container is
made, so they are made again afterwards, by scripts/openclaw-install.sh, before the key
takes effect. Python's standard library has no Ed25519, so openssl makes the key.
"""

from __future__ import annotations

import argparse
import base64
import os
import subprocess
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

import household_file

VARIABLE = "HOUSEHOLD_PUSH_RELAY_KEY"
# An Ed25519 SubjectPublicKeyInfo: this algorithm header, then the 32 bytes of the key.
ED25519_SPKI_HEADER = bytes.fromhex("302a300506032b6570032100")
Runner = Callable[..., subprocess.CompletedProcess[Any]]


class PushKeyRefused(RuntimeError):
    """Something on the box this will not decide for anyone."""


def kept_key(env_file: Path) -> str | None:
    """The key a gateway's env file holds, escaped as it is kept, or None."""
    found = None
    for line in env_file.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{VARIABLE}="):
            if found is not None:
                raise PushKeyRefused(f"{env_file} names {VARIABLE} twice")
            found = line.split("=", 1)[1]
            if not found:
                raise PushKeyRefused(f"{env_file} names {VARIABLE} with nothing in it")
    return found


def _made_key(run: Runner) -> str:
    made = run(["openssl", "genpkey", "-algorithm", "ed25519"], capture_output=True, check=True)
    pem = bytes(made.stdout).decode("ascii").strip()
    if not pem.startswith("-----BEGIN PRIVATE KEY-----"):
        raise PushKeyRefused("openssl did not make an Ed25519 key")
    # An env file holds one line per variable, so the line breaks are kept as \n, which the
    # household-app plugin turns back, as it does for the Apple key.
    return pem.replace("\n", "\\n")


def public_key(kept: str, run: Runner) -> str:
    """The public half of a kept key, as the base64 of its SubjectPublicKeyInfo."""
    pem = kept.replace("\\n", "\n") + "\n"
    out = run(
        ["openssl", "pkey", "-pubout", "-outform", "DER"],
        input=pem.encode("ascii"),
        capture_output=True,
        check=True,
    )
    der = bytes(out.stdout)
    if len(der) != len(ED25519_SPKI_HEADER) + 32 or not der.startswith(ED25519_SPKI_HEADER):
        raise PushKeyRefused(f"the {VARIABLE} the gateways hold is not an Ed25519 key")
    return base64.b64encode(der).decode("ascii")


def _add_line(env_file: Path, value: str) -> None:
    """Appends the key, written whole beside the file and renamed over it, owner-only."""
    text = env_file.read_text(encoding="utf-8")
    if text and not text.endswith("\n"):
        text += "\n"
    text += f"{VARIABLE}={value}\n"
    temporary = env_file.with_name(f".{env_file.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, env_file)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def install_key(env_files: Sequence[Path], run: Runner = subprocess.run) -> tuple[str, list[Path]]:
    """The household's public key, and the env files it was written into just now."""
    for env_file in env_files:
        if not env_file.is_file():
            raise PushKeyRefused(
                f"{env_file} is not there yet: scripts/openclaw-install.sh makes each "
                "gateway's env file"
            )
    kept = {env_file: kept_key(env_file) for env_file in env_files}
    distinct = {value for value in kept.values() if value is not None}
    if len(distinct) > 1:
        raise PushKeyRefused(
            f"the gateways' env files hold different {VARIABLE}s; keep the one the publisher "
            "has and take the other out by hand"
        )
    value = next(iter(distinct)) if distinct else _made_key(run)
    public = public_key(value, run)
    written = [env_file for env_file, held in kept.items() if held is None]
    for env_file in written:
        _add_line(env_file, value)
    return public, written


def main(
    argv: Sequence[str] | None = None,
    *,
    run: Runner = subprocess.run,
    is_root: Callable[[], bool] = lambda: os.geteuid() == 0,
) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.parse_args(argv)
    if not is_root():
        print("run as root: the gateways' env files are root's", file=sys.stderr)
        return 1
    household = household_file.load_household(household_file.HOUSEHOLD_FILE)
    relay = household.push_relay
    if relay is None:
        print(
            f"{household_file.HOUSEHOLD_FILE} names no pushRelay; add the relay's address and "
            "the household's name there first (docs/deploy/push-relay.md)",
            file=sys.stderr,
        )
        return 1
    try:
        public, written = install_key([member.env_file for member in household.members], run)
    except (PushKeyRefused, subprocess.CalledProcessError) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    if written:
        print(f"The household's push relay key is now in {', '.join(map(str, written))}.")
    else:
        print("Both gateways already hold the household's push relay key.")
    print()
    print("Send the app's publisher this line. It is the key's public half, safe to send any way:")
    print()
    print(f"  household {relay.household} key {public}")
    print()
    if written:
        print("Then make the gateways again so they read it: scripts/openclaw-install.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
