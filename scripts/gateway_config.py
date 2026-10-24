"""Reading and patching the two OpenClaw gateways' config from the host, as root.

Shared by openclaw-family-group.py, openclaw-openrouter.py and openclaw-speech.py, which
import it from the directory they run in, so copy the whole scripts/ directory to the box
together.

Every gateway setting the household depends on lives only on the box, in each
gateway's openclaw.json. These helpers read that file without trusting the directory
it sits in, and change it only through `openclaw config patch` inside the container,
which validates the change and lets the gateway hot-reload it.
"""

from __future__ import annotations

import copy
import json
import os
import stat
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

STATE_ROOT = Path("/var/lib/household-assistant")


@dataclass(frozen=True, slots=True)
class Gateway:
    """One assistant's gateway: its persona, its container, its state, its person."""

    persona: str
    container: str
    state: Path
    person: str

    @property
    def config_path(self) -> Path:
        return self.state / "openclaw.json"


GATEWAYS = (
    Gateway("corey", "openclaw-gateway", STATE_ROOT / "openclaw", "franco"),
    Gateway("denise", "openclaw-denise", STATE_ROOT / "openclaw-denise", "gia"),
)

# The household's own identifiers live on the box, in a root-only file the repository
# does not hold. deploy/household.example.json shows its shape, and HOUSEHOLD_FILE
# points the test suite at its own.
HOUSEHOLD_FILE = Path(os.environ.get("HOUSEHOLD_FILE", "/etc/household-assistant/household.json"))


@dataclass(frozen=True, slots=True)
class Household:
    """Where the phones reach the gateways, the app's Google client, the calendar the
    planner reads and the Bible edition the household reads. The Telegram group and
    accounts a file written before Telegram was retired still names are not read."""

    gateway_host: str
    google_client_id: str
    shared_calendar: str
    shared_calendar_apple_id: str
    bible_version: str


def _text(section: dict[str, Any], key: str, path: Path) -> str:
    value = section.get(key)
    if not isinstance(value, str) or not value:
        raise UnsupportedConfig(f"{path} has no {key}")
    return value


def load_household(path: Path = HOUSEHOLD_FILE) -> Household:
    loaded = json.loads(path.read_bytes())
    if not isinstance(loaded, dict):
        raise UnsupportedConfig(f"{path} is not a JSON object")
    calendar = loaded.get("sharedCalendar")
    if not isinstance(calendar, dict):
        raise UnsupportedConfig(f"{path} has no sharedCalendar")
    return Household(
        gateway_host=_text(loaded, "gatewayHost", path),
        google_client_id=_text(loaded, "googleClientId", path),
        shared_calendar=_text(calendar, "name", path),
        shared_calendar_apple_id=_text(calendar, "appleId", path),
        bible_version=_text(loaded, "bibleVersion", path),
    )


# family_history, pictures and finance answer only in the family room or a person's own
# thread, which they tell apart by session key. OpenClaw's default puts every DM in one
# shared main session, so they need DMs kept per sender and groups per group.
ISOLATED_DM_SCOPES = ("per-channel-peer", "per-account-channel-peer")

# How long one `docker exec` into a gateway may take. A probe or a config write
# answers in a few seconds; this only stops a wedged gateway from hanging the script.
GATEWAY_TIMEOUT_SECONDS = 120

Runner = Callable[..., "subprocess.CompletedProcess[str]"]


class UnsupportedConfig(ValueError):
    """A config shape a script does not evaluate, rather than guess at."""


def gateway_for(container: str, state: Path) -> Gateway | None:
    """The known gateway running in `container`, read from `state` instead of its default."""
    known = next((gateway for gateway in GATEWAYS if gateway.container == container), None)
    if known is None:
        return None
    return Gateway(known.persona, container, state, known.person)


def read_config_bytes(gateway: Gateway) -> bytes:
    """The config file's bytes, refusing anything but a regular file.

    The state directory belongs to the assistant (uid 1000) and this runs as root, so
    the file is opened without following a symlink and checked before it is read. A
    FIFO would otherwise hang the read, hence O_NONBLOCK.
    """
    descriptor = os.open(gateway.config_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise UnsupportedConfig(f"{gateway.config_path} is not a regular file")
        return stream.read()


def read_config(gateway: Gateway) -> dict[str, Any]:
    loaded = json.loads(read_config_bytes(gateway))
    if not isinstance(loaded, dict):
        raise UnsupportedConfig(f"{gateway.config_path} is not a JSON object")
    return loaded


def patched(config: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    """What `openclaw config patch` writes: objects merge, lists and scalars replace,
    and null deletes."""
    result = copy.deepcopy(config)
    for key, value in patch.items():
        current = result.get(key)
        if value is None:
            result.pop(key, None)
        elif isinstance(value, dict) and isinstance(current, dict):
            result[key] = patched(current, value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def session_patch(config: dict[str, Any]) -> dict[str, Any]:
    """What keeps DMs per sender and groups per group, for scopes the config does not set.

    A scope a person set is theirs to change, so a shared one is reported, not replaced.
    """
    session = config.get("session")
    session = session if isinstance(session, dict) else {}
    scopes: dict[str, str] = {}
    if "dmScope" not in session:
        scopes["dmScope"] = "per-channel-peer"
    if "groupScope" not in session:
        scopes["groupScope"] = "per-group"
    return {"session": scopes} if scopes else {}


def sessions_kept_apart(config: dict[str, Any]) -> bool:
    session = config.get("session")
    session = session if isinstance(session, dict) else {}
    return session.get("dmScope") in ISOLATED_DM_SCOPES and session.get("groupScope") == "per-group"


def first_json_object(output: str, key: str) -> dict[str, Any] | None:
    """The first JSON object in a CLI's stdout that carries `key`.

    The gateway CLI can print a banner before its JSON, so neither end of its stdout
    is a safe anchor. Same approach as `first_json_value` in household/openclaw.py,
    which these scripts cannot import: they run from a bare copy of scripts/.
    """
    decoder = json.JSONDecoder()
    start = output.find("{")
    while start != -1:
        try:
            found, end = decoder.raw_decode(output, start)
        except json.JSONDecodeError:
            start = output.find("{", start + 1)
            continue
        if isinstance(found, dict) and key in found:
            return found
        start = output.find("{", end)
    return None


def gateway_cli(gateway: Gateway, *arguments: str, stdin: bool = False) -> list[str]:
    attach = ["-i"] if stdin else []
    return ["docker", "exec", *attach, gateway.container, "node", "dist/index.js", *arguments]


def ask_gateway(gateway: Gateway, run: Runner, *arguments: str) -> subprocess.CompletedProcess[str]:
    """A read-only CLI call inside the container, without attaching a terminal."""
    return run(
        gateway_cli(gateway, *arguments),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=GATEWAY_TIMEOUT_SECONDS,
        check=False,
    )


def backup(gateway: Gateway, label: str, stamp: str) -> Path:
    """A byte-for-byte copy beside the live config, owned like it, mode 0600.

    O_EXCL refuses a name that already exists, a planted symlink included.
    """
    content = read_config_bytes(gateway)
    owner = os.stat(gateway.config_path, follow_symlinks=False)
    target = gateway.state / f"openclaw.json.pre-{label}-{stamp}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    with os.fdopen(os.open(target, flags, 0o600), "wb") as stream:
        stream.write(content)
    os.chown(target, owner.st_uid, owner.st_gid, follow_symlinks=False)
    return target


def config_patch(gateway: Gateway, patch: dict[str, Any], run: Runner, *, dry_run: bool) -> None:
    """`openclaw config patch --stdin` inside the container; raises unless it succeeds."""
    arguments = ["config", "patch", "--stdin"] + (["--dry-run", "--json"] if dry_run else [])
    completed = run(
        gateway_cli(gateway, *arguments, stdin=True),
        input=json.dumps(patch),
        capture_output=True,
        text=True,
        timeout=GATEWAY_TIMEOUT_SECONDS,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()[-600:]
        raise RuntimeError(f"{gateway.container} refused the patch: {detail}")
    if dry_run:
        result = first_json_object(completed.stdout, "ok")
        if result is None or result.get("ok") is not True:
            raise RuntimeError(
                f"{gateway.container} did not validate the patch: {completed.stdout}"
            )


def field(label: str, text: str) -> None:
    print(f"  {label:<12} {text}")
