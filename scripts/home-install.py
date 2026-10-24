#!/usr/bin/env python3
"""Install the home key holder for ONE gateway, or pair the key holders with the living room TV.

As root on the box, from a checkout of main:

    python3 scripts/home-install.py install corey --tv-address <tailnet address> \\
        --tv-port <Companion port> --tv-spotify-name "<the TV in Spotify>" \\
        --thermostat-entity <climate entity> --spotify-entity <media_player entity> --token-stdin
    /opt/household-assistant/home/venv/bin/python scripts/home-install.py pair \\
        --tv-address <tailnet address> --tv-port <Companion port>

`install` puts in place the key holder's user, its code and hash-locked venv, its unit and
drop-in, the socket directory in the gateway's own state, and config.json in the key
holder's state, with the Home Assistant token read from stdin the first time, then
restarts household-home@<persona> and reads it back. Run again, it replaces the code and
config and keeps the token. The key holder runs before the TV is paired, and until then
its TV steps answer that the TV is not paired.

`pair` asks the TV for a code, waits for it in /run/household-home-pair/pin, and writes the
pairing into every installed key holder's state, then restarts those. Nothing secret is
printed.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import hashlib
import ipaddress
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
from collections.abc import Callable
from pathlib import Path

from household_file import load_household

ROOT = Path(__file__).resolve().parents[1]
CODE = Path("/opt/household-assistant/home")
STATE_ROOT = Path("/var/lib/household-home")
GATEWAY_STATE_ROOT = Path("/var/lib/household-assistant")
SYSTEMD_UNITS = Path("/etc/systemd/system")
UNIT = "household-home@.service"
# Each assistant's gateway state directory, from the household file's members.
GATEWAYS = {member.assistant: member.state for member in load_household().members}
SOCKET_DIRECTORY = "home"
PAIR_DIRECTORY = Path("/run/household-home-pair")
HOME_ASSISTANT_STATE = GATEWAY_STATE_ROOT / "homeassistant"
PIN_WAIT_SECONDS = 1800
HASS = "http://127.0.0.1:8123"
# Home Assistant entity ids, which name the household's own rooms and accounts, so each
# install is given them and they live only in the key holder's config.json.
THERMOSTAT_ENTITY = re.compile(r"climate\.[a-z0-9_]{1,64}")
SPOTIFY_ENTITY = re.compile(r"media_player\.[a-z0-9_]{1,64}")
TAILNET = ipaddress.ip_network("100.64.0.0/10")
TOKEN = re.compile(r"[A-Za-z0-9._-]{20,2048}")
# The box's python3 has no ensurepip, so pip runs from its wheel, checked by hash.
PIP_WHEEL = (
    "https://files.pythonhosted.org/packages/f3/6e/"
    "1736e5b4ae2b778ef2f81c47d797de9f891d4d8acb047a24ca37a60294dd/pip-26.2.1-py3-none-any.whl"
)
PIP_SHA256 = "71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e"
Runner = Callable[..., subprocess.CompletedProcess[str]]
Fetch = Callable[[str], bytes]


def key_holder_user(persona: str) -> str:
    return f"household-home-{persona}"


def check_tv(address: str, port: int) -> None:
    try:
        is_tailnet = ipaddress.ip_address(address) in TAILNET
    except ValueError:
        is_tailnet = False
    if not is_tailnet:
        raise ValueError("the TV's address must be its tailnet address")
    if not 0 < port < 65536:
        raise ValueError("the TV's Companion port must be a port")


def config_for(
    address: str, port: int, spotify_name: str, thermostat: str, spotify: str
) -> dict[str, object]:
    check_tv(address, port)
    if not THERMOSTAT_ENTITY.fullmatch(thermostat):
        raise ValueError("the thermostat must be a Home Assistant climate entity id")
    if not SPOTIFY_ENTITY.fullmatch(spotify):
        raise ValueError("Spotify must be a Home Assistant media_player entity id")
    if not 0 < len(spotify_name) <= 64 or not spotify_name.isprintable():
        raise ValueError("the TV's name in Spotify must be one short line")
    return {
        "hass": HASS,
        "entities": {"thermostat": thermostat, "spotify": spotify, "tv_spotify_name": spotify_name},
        "tv": {"address": address, "port": port},
    }


def read_token(text: str) -> str:
    token = text.strip()
    if not TOKEN.fullmatch(token):
        raise ValueError("the token on stdin must be one Home Assistant long-lived token")
    return token


def _fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as answer:
        content: bytes = answer.read()
        return content


def _copy_root_owned(source: Path, target: Path, mode: int = 0o644) -> None:
    shutil.copyfile(source, target)
    target.chmod(mode)
    os.chown(target, 0, 0)


def install_code(code_root: Path, *, run: Runner, fetch: Fetch = _fetch) -> None:
    """The key holder's package, entry, lock and venv, all root's, the venv from the lock."""
    if code_root.is_symlink() or (code_root.exists() and code_root.stat().st_uid != os.geteuid()):
        raise ValueError("the key holder's code directory must be a real root-owned directory")
    wheel = fetch(PIP_WHEEL)
    if hashlib.sha256(wheel).hexdigest() != PIP_SHA256:
        raise ValueError("the pip wheel does not match its pinned hash")
    code_root.mkdir(mode=0o755, exist_ok=True)
    code_root.chmod(0o755)
    os.chown(code_root, 0, 0)
    package_root = code_root / "household"
    if package_root.exists():
        shutil.rmtree(package_root)
    package = package_root / "home"
    package.mkdir(parents=True)
    for directory in (package_root, package):
        directory.chmod(0o755)
        os.chown(directory, 0, 0)
    _copy_root_owned(ROOT / "household" / "__init__.py", package_root / "__init__.py")
    for module in sorted((ROOT / "household" / "home").glob("*.py")):
        _copy_root_owned(module, package / module.name)
    _copy_root_owned(ROOT / "scripts" / "home-keyholder.py", code_root / "home-keyholder.py", 0o755)
    requirements = code_root / "requirements.txt"
    _copy_root_owned(ROOT / "deploy" / "home" / "requirements.txt", requirements)

    venv = code_root / "venv"
    if not (venv / "bin" / "python").exists():
        run(
            ["python3", "-m", "venv", "--without-pip", str(venv)],
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        )
    with tempfile.TemporaryDirectory(dir=code_root) as staging:
        wheel_path = Path(staging) / PIP_WHEEL.rsplit("/", 1)[1]
        wheel_path.write_bytes(wheel)
        run(
            [
                str(venv / "bin" / "python"),
                f"{wheel_path}/pip",
                "install",
                "--no-cache-dir",
                "--disable-pip-version-check",
                "--require-hashes",
                "--only-binary",
                ":all:",
                "--no-deps",
                "-r",
                str(requirements),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=600,
        )


def _write_root_owned(target: Path, content: bytes, mode: int) -> None:
    """Swap `target` in whole: systemd sees the old file or the new one, never a partial."""
    staged = target.with_name(f".{target.name}.{secrets.token_hex(8)}.new")
    descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
        os.chown(staged, 0, 0)
        os.replace(staged, target)
    finally:
        staged.unlink(missing_ok=True)


def install_units(persona: str, gateway_state: Path, units: Path) -> None:
    _write_root_owned(units / UNIT, (ROOT / "deploy" / "home" / UNIT).read_bytes(), 0o644)
    drop_in = units / f"household-home@{persona}.service.d"
    drop_in.mkdir(mode=0o755, exist_ok=True)
    _write_root_owned(
        drop_in / "gateway.conf",
        (
            "# Written by scripts/home-install.py for this gateway.\n"
            "[Service]\n"
            f"BindPaths={gateway_state / SOCKET_DIRECTORY}:/run/household-home\n"
        ).encode(),
        0o644,
    )


def install_home_assistant(directory: Path = HOME_ASSISTANT_STATE) -> None:
    configuration = directory / "configuration.yaml"
    content = configuration.read_text(encoding="utf-8")
    component = directory / "custom_components" / "household_home"
    component.mkdir(parents=True, exist_ok=True)
    source = ROOT / "deploy" / "homeassistant" / "custom_components" / "household_home"
    for name in ("__init__.py", "manifest.json"):
        _write_root_owned(component / name, (source / name).read_bytes(), 0o644)
    if not re.search(r"(?m)^household_home:", content):
        _write_root_owned(
            configuration,
            (content.rstrip() + "\n\nhousehold_home:\n").encode(),
            stat.S_IMODE(configuration.stat().st_mode),
        )


def _open_directory(path: Path, message: str) -> int:
    try:
        return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        raise ValueError(message) from error


def prepare_socket_directory(gateway_state: Path, uid: int) -> None:
    """The socket directory in the gateway's state, the key holder's and setgid to the gateway.

    The gateway's own uid can rewrite its state, so everything here goes through
    descriptors, and a directory the gateway made, a file or a symlink is refused.
    """
    state_descriptor = _open_directory(gateway_state, "the gateway's state directory is required")
    try:
        with contextlib.suppress(FileExistsError):
            os.mkdir(SOCKET_DIRECTORY, 0o700, dir_fd=state_descriptor)
        try:
            descriptor = os.open(
                SOCKET_DIRECTORY,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=state_descriptor,
            )
        except OSError as error:
            raise ValueError("refusing an unexpected file at the socket directory") from error
        try:
            if os.fstat(descriptor).st_uid not in (0, uid):
                raise ValueError("refusing a socket directory the key holder did not create")
            os.fchown(descriptor, uid, os.fstat(state_descriptor).st_gid)
            os.fchmod(descriptor, 0o2750)
        finally:
            os.close(descriptor)
    finally:
        os.close(state_descriptor)


def _open_key_holder_state(state_root: Path, persona: str, uid: int, gid: int) -> int:
    """The key holder's own state directory, made here or left by an earlier install."""
    if state_root.is_symlink():
        raise ValueError("refusing a symlinked key holder state root")
    state_root.mkdir(mode=0o755, exist_ok=True)
    os.chown(state_root, 0, 0)
    root_descriptor = _open_directory(state_root, "the key holder state root is required")
    try:
        with contextlib.suppress(FileExistsError):
            os.mkdir(persona, 0o700, dir_fd=root_descriptor)
        try:
            descriptor = os.open(
                persona, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_descriptor
            )
        except OSError as error:
            raise ValueError("refusing an unexpected file at the key holder's state") from error
    finally:
        os.close(root_descriptor)
    if os.fstat(descriptor).st_uid not in (0, uid):
        os.close(descriptor)
        raise ValueError("refusing a key holder state directory someone else made")
    os.fchown(descriptor, uid, gid)
    os.fchmod(descriptor, 0o700)
    return descriptor


def _write_owned(directory: int, name: str, content: str, uid: int, gid: int) -> None:
    temporary = f".{name}.{secrets.token_hex(8)}.new"
    descriptor = os.open(
        temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
            os.fchown(output.fileno(), uid, gid)
            os.fchmod(output.fileno(), 0o600)
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=directory)


def _has_file(directory: int, name: str) -> bool:
    try:
        return stat.S_ISREG(os.stat(name, dir_fd=directory, follow_symlinks=False).st_mode)
    except FileNotFoundError:
        return False


def _ids(user: str, run: Runner) -> tuple[int, int]:
    uid = run(["id", "-u", user], capture_output=True, text=True, check=True).stdout
    gid = run(["id", "-g", user], capture_output=True, text=True, check=True).stdout
    return int(uid), int(gid)


def install(
    persona: str,
    config: dict[str, object],
    token: str | None,
    *,
    code_root: Path = CODE,
    state_root: Path = STATE_ROOT,
    gateway_root: Path = GATEWAY_STATE_ROOT,
    units: Path = SYSTEMD_UNITS,
    run: Runner = subprocess.run,
    fetch: Fetch = _fetch,
) -> str:
    """Everything one gateway's key holder needs, then restart it and read its state back."""
    if persona not in GATEWAYS:
        raise ValueError(f"use one of the household's assistants: {', '.join(GATEWAYS)}")
    user = key_holder_user(persona)
    if run(["id", "-u", user], capture_output=True, text=True, check=False).returncode != 0:
        run(
            [
                "useradd",
                "--system",
                "--user-group",
                "--no-create-home",
                "--home-dir",
                "/nonexistent",
                "--shell",
                "/usr/sbin/nologin",
                user,
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    uid, gid = _ids(user, run)

    state = _open_key_holder_state(state_root, persona, uid, gid)
    try:
        if token is None and not _has_file(state, "token"):
            raise ValueError("the first install needs the token, with --token-stdin")
        install_code(code_root, run=run, fetch=fetch)
        gateway_state = gateway_root / GATEWAYS[persona]
        install_units(persona, gateway_state, units)
        prepare_socket_directory(gateway_state, uid)
        _write_owned(state, "config.json", json.dumps(config, indent=2) + "\n", uid, gid)
        if token is not None:
            _write_owned(state, "token", token + "\n", uid, gid)
    finally:
        os.close(state)

    service = f"household-home@{persona}.service"
    for command in (
        ["systemctl", "daemon-reload"],
        ["systemctl", "enable", service],
        # Restart rather than start, so a reinstall runs the code and config just written.
        ["systemctl", "restart", service],
    ):
        run(command, check=True, capture_output=True, text=True, timeout=60)
    return run(
        ["systemctl", "is-active", service], check=False, capture_output=True, text=True, timeout=60
    ).stdout.strip()


def wait_for_pin(
    directory: Path, *, seconds: int = PIN_WAIT_SECONDS, wait: Callable[[float], None] = time.sleep
) -> str | None:
    """The four digits the TV shows, once they are written to `directory`/pin."""
    pin_file = directory / "pin"
    for _ in range(seconds):
        try:
            text = pin_file.read_text(encoding="utf-8")
        except FileNotFoundError:
            wait(1)
            continue
        pin_file.unlink()
        pin = text.strip()
        return pin if re.fullmatch(r"[0-9]{4}", pin) else None
    return None


async def pyatv_pair(address: str, port: int, read_pin: Callable[[], str | None]) -> str | None:
    """Companion pairing with the TV: its pairing, or None when no code came or it refused."""
    import pyatv
    from pyatv import conf
    from pyatv.const import Protocol as Service

    config = conf.AppleTV(address, "Living room")
    config.add_service(conf.ManualService("living-room", Service.Companion, port, {}))
    pairing = await pyatv.pair(config, Service.Companion, asyncio.get_running_loop())
    try:
        await pairing.begin()
        print("pair: the TV shows a code now", flush=True)
        pin = await asyncio.to_thread(read_pin)
        if pin is None:
            return None
        pairing.pin(int(pin))
        await pairing.finish()
        credentials = pairing.service.credentials if pairing.has_paired else None
        return credentials if isinstance(credentials, str) and credentials else None
    finally:
        await pairing.close()


def save_pairing(
    credentials: str, *, state_root: Path = STATE_ROOT, run: Runner = subprocess.run
) -> list[str]:
    """Write the pairing into each installed key holder's state and restart it."""
    saved = []
    for persona in GATEWAYS:
        if not (state_root / persona).is_dir():
            continue
        uid, gid = _ids(key_holder_user(persona), run)
        state = _open_key_holder_state(state_root, persona, uid, gid)
        try:
            _write_owned(state, "apple-tv-credentials", credentials + "\n", uid, gid)
        finally:
            os.close(state)
        run(
            ["systemctl", "restart", f"household-home@{persona}.service"],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        saved.append(persona)
    return saved


def _pair_directory(directory: Path) -> None:
    if directory.is_symlink():
        raise ValueError("refusing a symlinked pairing directory")
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    with contextlib.suppress(FileNotFoundError):
        (directory / "pin").unlink()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("install-ha", help="install the Home Assistant Spotify refresh action")
    install_command = commands.add_parser("install", help="install one gateway's key holder")
    install_command.add_argument("persona", choices=sorted(GATEWAYS))
    install_command.add_argument("--token-stdin", action="store_true")
    pair_command = commands.add_parser("pair", help="pair the key holders with the TV")
    for command in (install_command, pair_command):
        command.add_argument("--tv-address", required=True)
        command.add_argument("--tv-port", required=True, type=int)
    install_command.add_argument("--tv-spotify-name", required=True)
    install_command.add_argument("--thermostat-entity", required=True)
    install_command.add_argument("--spotify-entity", required=True)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "install-ha":
            install_home_assistant()
            print("Home Assistant refresh action installed. Restart Home Assistant to load it.")
            return 0
        if arguments.command == "install":
            config = config_for(
                arguments.tv_address,
                arguments.tv_port,
                arguments.tv_spotify_name,
                arguments.thermostat_entity,
                arguments.spotify_entity,
            )
            token = read_token(sys.stdin.read()) if arguments.token_stdin else None
            state = install(arguments.persona, config, token)
            print(f"household-home@{arguments.persona} is {state or 'unknown'}")
            return 0 if state == "active" else 1
        check_tv(arguments.tv_address, arguments.tv_port)
        _pair_directory(PAIR_DIRECTORY)
        credentials = asyncio.run(
            pyatv_pair(
                arguments.tv_address, arguments.tv_port, lambda: wait_for_pin(PAIR_DIRECTORY)
            )
        )
    except ValueError as error:
        parser.error(str(error))
    if credentials is None:
        print("pair: not paired, either no code came or the TV refused it")
        return 1
    saved = save_pairing(credentials)
    print(f"pair: paired, and restarted {', '.join(saved) or 'no installed key holder'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
