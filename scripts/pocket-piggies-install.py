#!/usr/bin/env python3
"""Install PocketPiggies into ONE existing OpenClaw gateway and start its key holder.

The gateway gets the plugin, the three read-only finance tools for its owner's private
chat, owner-only private messages and a family-group tool allowlist. The key holder,
a host service under its own user, holds the client credential and the owner's grant.
Client provisioning is separate and follows restart and verification; it prints only
a non-secret registration digest, and owner consent creates the grant.

`--guard` is what household-pocketpiggies-guard runs as root whenever a gateway's
config changes: the gateway's own uid can rewrite that config, so the policy is put
back from outside it, and finance is stopped where it cannot be.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import time
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

PLUGIN_ID = "pocket-piggies"
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "deploy" / "openclaw" / "plugins" / PLUGIN_ID
PLUGINS_ROOT = Path("/opt/household-assistant/plugins")
# A gateway config is a few kilobytes, a couple of hundred values and eight levels deep.
# These bounds keep what root parses, copies and rewrites small whatever the gateway writes.
MAX_CONFIG_BYTES = 256 * 1024
MAX_CONFIG_NODES = 20_000
MAX_CONFIG_DEPTH = 32
PLUGIN_PATH = re.compile(r"/opt/household-plugins/(?!\.\.?$)[A-Za-z0-9._-]+")
GUARD_RETRY_SECONDS = 1.0
GUARD_RUNTIME = Path("/run/household-pocketpiggies-guard")
# More repairs than this in the window means something keeps rewriting the config, or
# OpenClaw and the guard disagree; either way finance stops instead of looping.
MAX_REPAIRS = 20
REPAIR_WINDOW_SECONDS = 60
KEY_HOLDER_CODE = Path("/opt/household-assistant/pocketpiggies")
KEY_HOLDER_STATE = Path("/var/lib/household-pocketpiggies")
SYSTEMD_UNITS = Path("/etc/systemd/system")
UNIT = "household-pocketpiggies@.service"
SOCKET_DIRECTORY = "pocketpiggies"
BOT_NAMES = {"corey": "Corey_the_man_bot", "denise": "Denise_the_woman_bot"}
# Whose own thread in the Steward AI app may read finance, by household person id: the
# owner of that gateway's app channel. Both gateways, by the household's decision of
# 15 October, so finance is not lost when Telegram is turned off.
APP_OWNERS = {"corey": "franco", "denise": "gia"}
GATEWAYS = {
    "corey": ("openclaw", "openclaw-gateway"),
    "denise": ("openclaw-denise", "openclaw-denise"),
}
FINANCE_TOOLS = ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]
# Must equal SAFE_GROUP_TOOLS in the plugin, which refuses finance when a group has more.
GROUP_TOOLS = [
    "web_search",
    "web_fetch",
    "speak",
    "family_history",
    # Only a picture or a short video through OpenRouter, sent to the chat it was asked in,
    # under each person's daily limit (household-pictures).
    "picture",
    "video",
    # Read-only, and it answers in a family group only while that person shares their
    # location with the family from the app.
    "household_location",
    # Only the household's shared shopping cart, in the app's family room, with no orders.
    "household_cart",
    # Only the thermostat, the music and the living room TV, through the home key holder,
    # and only in the app.
    "household_home",
    # Only a tapback on a person's message, in the app's family room.
    "household_react",
    # Only the household note both assistants keep, which both people read, in the app.
    "household_note",
    # Only the Bible and the household's kept sermons, read in the gateway (household-scripture).
    "scripture",
]
GUARD_UNITS = [
    "household-pocketpiggies-guard.service",
    "household-pocketpiggies-guard.path",
    "household-pocketpiggies-guard.timer",
]
GATEWAY_STATE_ROOT = Path("/var/lib/household-assistant")
Runner = Callable[..., subprocess.CompletedProcess[str]]


def key_holder_user(persona: str) -> str:
    return f"household-pp-{persona}"


def configured(
    original: dict[str, Any], persona: str, telegram_id: str, *, is_enabled: bool = True
) -> dict[str, Any]:
    """Keep the owner's tools and keep everyone else's turns away from finance."""
    if persona not in GATEWAYS or not re.fullmatch(r"[1-9][0-9]*", telegram_id):
        raise ValueError("use corey or denise and a positive numeric Telegram user id")
    owners = original.get("commands", {}).get("ownerAllowFrom", [])
    if f"telegram:{telegram_id}" not in owners:
        raise ValueError("the Telegram id must match the gateway's existing trusted owner")
    result = copy.deepcopy(original)
    session = result.setdefault("session", {})
    if session.get("scope") == "global":
        raise ValueError("global session scope must be removed before enabling private finance")
    for binding in result.get("bindings", []):
        if binding.get("session", {}).get("groupScope") == "main":
            raise ValueError(
                "a group binding joins the private main session; fix that binding first"
            )
    # The owner's finance transcript is never the family group's or another sender's.
    session["dmScope"] = "per-channel-peer"
    session["groupScope"] = "per-group"
    telegram = result.get("channels", {}).get("telegram")
    if not isinstance(telegram, dict):
        raise ValueError("the gateway has no Telegram channel")
    if "accounts" in telegram or "direct" in telegram:
        raise ValueError("per-account or per-chat Telegram settings need a reviewed finance policy")
    # Only the owner reaches a full-tool private turn; every group the bot admits runs
    # with tools that can neither read gateway files nor reach the key holder.
    telegram["dmPolicy"] = "allowlist"
    telegram["allowFrom"] = [telegram_id]
    if telegram.get("groupPolicy") != "disabled":
        telegram["groupPolicy"] = "allowlist"
    groups = telegram.get("groups", {})
    for group in groups.values():
        if not isinstance(group, dict) or "toolsBySender" in group or "topics" in group:
            raise ValueError(
                "a group with per-sender or per-topic settings needs a reviewed policy"
            )
        group["tools"] = {"allow": list(GROUP_TOOLS)}
    plugins = result.setdefault("plugins", {})
    if is_enabled and plugins.get("enabled") is False:
        raise ValueError("plugins are explicitly disabled; enable plugins before installing")
    if is_enabled and PLUGIN_ID in plugins.get("deny", []):
        raise ValueError("PocketPiggies is explicitly denied")
    if "allow" in plugins:
        if is_enabled and PLUGIN_ID not in plugins["allow"]:
            plugins["allow"].append(PLUGIN_ID)
        elif not is_enabled:
            plugins["allow"] = [name for name in plugins["allow"] if name != PLUGIN_ID]
    # Only the keys this policy owns are set, so whatever OpenClaw keeps beside them stays.
    entry = plugins.setdefault("entries", {}).setdefault(PLUGIN_ID, {})
    entry["enabled"] = is_enabled
    if is_enabled:
        entry["config"] = {"ownerTelegramId": telegram_id, "accountLabel": persona}
        if persona in APP_OWNERS:
            entry["config"]["ownerHouseholdPersonId"] = APP_OWNERS[persona]
    else:
        entry.pop("config", None)
    paths = plugins.setdefault("load", {}).setdefault("paths", [])
    # Plugin code runs inside the gateway and can offer tools under any name, including
    # one on the group allowlist, so it may come only from the root-owned read-only mount.
    if any(not isinstance(path, str) or not PLUGIN_PATH.fullmatch(path) for path in paths):
        raise ValueError("a plugin loads from outside /opt/household-plugins")
    plugin_path = f"/opt/household-plugins/{PLUGIN_ID}-{persona}"
    if is_enabled and plugin_path not in paths:
        paths.append(plugin_path)
    elif not is_enabled:
        plugins["load"]["paths"] = [path for path in paths if path != plugin_path]
    tools = result.setdefault("tools", {})
    if "allow" in tools:
        raise ValueError("an explicit tools.allow replaces the owner's tools; remove it first")
    # Under a tool profile, plugin tools reach the model only through alsoAllow.
    kept = [name for name in tools.get("alsoAllow", []) if name not in FINANCE_TOOLS]
    tools["alsoAllow"] = [*kept, *FINANCE_TOOLS] if is_enabled else kept
    return result


def _open_state(state: Path) -> int:
    """The gateway's state directory, which the gateway's own uid can rewrite under root.

    Everything root does inside it goes through this descriptor, never through a path
    that a swapped symlink could redirect.
    """
    try:
        return os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        raise ValueError("the existing gateway state directory is required") from error


def _read_config(state_descriptor: int) -> tuple[dict[str, Any], os.stat_result]:
    try:
        descriptor = os.open(
            "openclaw.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=state_descriptor
        )
    except OSError as error:
        raise ValueError("a regular openclaw.json file is required") from error
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.fstat(state_descriptor).st_uid
        ):
            raise ValueError("openclaw.json must be the gateway's own regular, unlinked file")
        raw = stream.read(MAX_CONFIG_BYTES + 1)
    if len(raw) > MAX_CONFIG_BYTES:
        raise ValueError("openclaw.json is larger than any gateway config")
    original = json.loads(raw)
    _check_shape(original)
    if not isinstance(original, dict):
        raise ValueError("openclaw.json is not a JSON object")
    return original, metadata


def _check_shape(config: object) -> None:
    """Refuse a config too deep or too large to copy and rewrite cheaply, without recursing."""
    pending: list[tuple[object, int]] = [(config, 0)]
    nodes = 0
    while pending:
        value, depth = pending.pop()
        nodes += 1
        if nodes > MAX_CONFIG_NODES or depth > MAX_CONFIG_DEPTH:
            raise ValueError("openclaw.json is deeper or larger than any gateway config")
        if isinstance(value, dict):
            pending.extend((child, depth + 1) for child in value.values())
        elif isinstance(value, list):
            pending.extend((child, depth + 1) for child in value)


def _write_config(state_descriptor: int, updated: dict[str, Any], uid: int, gid: int) -> None:
    serialized = json.dumps(updated, indent=2) + "\n"
    if len(serialized.encode("utf-8")) > MAX_CONFIG_BYTES:
        raise ValueError("the repaired openclaw.json would be larger than any gateway config")
    temporary = f".pocket-piggies-{secrets.token_hex(16)}"
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=state_descriptor,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(serialized)
            output.flush()
            os.fsync(output.fileno())
            os.fchown(output.fileno(), uid, gid)
            os.fchmod(output.fileno(), 0o600)
        os.replace(
            temporary, "openclaw.json", src_dir_fd=state_descriptor, dst_dir_fd=state_descriptor
        )
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=state_descriptor)


def install_into(
    state: Path,
    persona: str,
    telegram_id: str,
    plugins_root: Path = PLUGINS_ROOT,
    *,
    is_enabled: bool = True,
) -> Path:
    """Back up the config and any installed plugin, then write the plugin and the policy."""
    state_descriptor = _open_state(state)
    try:
        return _install_into(state_descriptor, persona, telegram_id, plugins_root, is_enabled)
    finally:
        os.close(state_descriptor)


def _install_into(
    state_descriptor: int, persona: str, telegram_id: str, plugins_root: Path, is_enabled: bool
) -> Path:
    original, metadata = _read_config(state_descriptor)
    updated = configured(original, persona, telegram_id, is_enabled=is_enabled)
    destination = plugins_root / f"{PLUGIN_ID}-{persona}"
    if plugins_root.is_symlink() or not plugins_root.is_dir() or destination.is_symlink():
        raise ValueError("refusing a symlinked plugin installation directory")
    if plugins_root.stat().st_uid != os.geteuid() or plugins_root.stat().st_mode & 0o022:
        raise ValueError("the existing plugin mount must be root-owned and not writable by others")
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    backup_root = plugins_root.parent / "pocket-piggies-backups"
    if backup_root.is_symlink():
        raise ValueError("refusing a symlinked backup directory")
    backup_root.mkdir(mode=0o700, exist_ok=True)
    backup_root.chmod(0o700)
    backup_directory = backup_root / f"{persona}-{stamp}"
    backup_directory.mkdir(mode=0o700)
    backup = backup_directory / "openclaw.json"
    with backup.open("x", encoding="utf-8") as output:
        backup.chmod(0o600)
        output.write(json.dumps(original, indent=2) + "\n")
    os.chown(backup, metadata.st_uid, metadata.st_gid)
    if destination.exists():
        if not destination.is_dir() or any(path.is_symlink() for path in destination.rglob("*")):
            raise ValueError("the existing plugin must contain only regular installed files")
        shutil.copytree(destination, backup_directory / "plugin")
    if is_enabled:
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir()
        for source in SOURCE.iterdir():
            if source.is_file() and source.suffix in {".json", ".mjs"}:
                target = destination / source.name
                shutil.copyfile(source, target)
                target.chmod(0o644)
                os.chown(target, 0, 0)
        destination.chmod(0o755)
        os.chown(destination, 0, 0)
    _write_config(state_descriptor, updated, metadata.st_uid, metadata.st_gid)
    return backup


def _copy_root_owned(source: Path, target: Path) -> None:
    shutil.copyfile(source, target)
    target.chmod(0o644)
    os.chown(target, 0, 0)


def _replace_root_owned(source: Path, target: Path, mode: int) -> None:
    _write_root_owned(target, source.read_bytes(), mode)


def _write_root_owned(target: Path, content: bytes, mode: int) -> None:
    """Swap `target` in whole: a reader sees the old file or the new one, never a partial."""
    staged = target.with_name(f".{target.name}.{secrets.token_hex(8)}.new")
    descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
        # The directory is root's alone, so naming the staged file here is safe.
        os.chown(staged, 0, 0)
        os.replace(staged, target)
    finally:
        staged.unlink(missing_ok=True)


def install_key_holder(
    state: Path,
    persona: str,
    telegram_id: str,
    *,
    code_root: Path = KEY_HOLDER_CODE,
    units: Path = SYSTEMD_UNITS,
    run: Runner = subprocess.run,
) -> None:
    """The key holder's user, code, unit and socket directory, then start it.

    The socket directory sits in the gateway's own state, owned by the key holder and
    setgid to the gateway's group: the gateway can connect, and cannot plant, rename or
    remove anything inside it. The other gateway does not mount this state at all.
    """
    if not re.fullmatch(r"[1-9][0-9]*", telegram_id) or persona not in GATEWAYS:
        raise ValueError("use corey or denise and a positive numeric Telegram user id")
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
    uid = int(run(["id", "-u", user], capture_output=True, text=True, check=True).stdout)

    if code_root.is_symlink() or (code_root.exists() and code_root.stat().st_uid != os.geteuid()):
        raise ValueError("the key holder's code directory must be a real root-owned directory")
    code_root.mkdir(mode=0o755, exist_ok=True)
    code_root.chmod(0o755)
    os.chown(code_root, 0, 0)
    # The key holder's package is replaced whole; the key holder restarts below.
    package_root = code_root / "household"
    if package_root.exists():
        shutil.rmtree(package_root)
    package = package_root / "pocketpiggies"
    package.mkdir(parents=True)
    for directory in (package_root, package):
        directory.chmod(0o755)
        os.chown(directory, 0, 0)
    _copy_root_owned(ROOT / "household" / "__init__.py", package_root / "__init__.py")
    for module in sorted((ROOT / "household" / "pocketpiggies").glob("*.py")):
        _copy_root_owned(module, package / module.name)
    # The guard runs this installer from here at any moment, so each script is swapped in
    # with one rename: a run sees the old file or the new one, never none.
    for name in ("pocketpiggies-keyholder.py", "pocket-piggies-install.py"):
        _replace_root_owned(ROOT / "scripts" / name, code_root / name, 0o755)

    for name in (UNIT, *GUARD_UNITS):
        _replace_root_owned(ROOT / "deploy" / "pocketpiggies" / name, units / name, 0o644)
    drop_in = units / f"household-pocketpiggies@{persona}.service.d"
    drop_in.mkdir(mode=0o755, exist_ok=True)
    _write_root_owned(
        drop_in / "gateway.conf",
        (
            "# Written by scripts/pocket-piggies-install.py for this owner and gateway.\n"
            "[Service]\n"
            f"Environment=POCKETPIGGIES_OWNER_TELEGRAM_ID={telegram_id}\n"
            f"BindPaths={state / 'pocketpiggies'}:/run/household-pocketpiggies\n"
        ).encode(),
        0o644,
    )

    _prepare_socket_directory(state, uid)

    for command in (
        ["systemctl", "daemon-reload"],
        ["systemctl", "enable", "--now", *GUARD_UNITS[1:]],
        ["systemctl", "enable", f"household-pocketpiggies@{persona}.service"],
        # Restart rather than start, so a reinstall runs the code just copied.
        ["systemctl", "restart", f"household-pocketpiggies@{persona}.service"],
    ):
        run(command, check=True, capture_output=True, text=True, timeout=60)
    for other in GATEWAYS:
        if installed_owner(units, other) is not None:
            holder_state = run(
                ["systemctl", "is-active", f"household-pocketpiggies@{other}.service"],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            ).stdout.strip()
            if holder_state != "active":
                print(f"warning: household-pocketpiggies@{other} is {holder_state or 'unknown'}")


def _prepare_socket_directory(state: Path, uid: int) -> None:
    """Create or reuse the socket directory without following anything the gateway planted.

    Only a directory this run just created (root's) or an earlier install left (the key
    holder's) is accepted; one the gateway made, a file or a symlink is refused.
    """
    state_descriptor = _open_state(state)
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
            raise ValueError(
                "refusing an unexpected file at the key holder's socket directory"
            ) from error
        try:
            if os.fstat(descriptor).st_uid not in (0, uid):
                raise ValueError("refusing a socket directory the key holder did not create")
            os.fchown(descriptor, uid, os.fstat(state_descriptor).st_gid)
            os.fchmod(descriptor, 0o2750)
        finally:
            os.close(descriptor)
    finally:
        os.close(state_descriptor)


def installed_owner(units: Path, persona: str) -> str | None:
    """The owner the installer pinned for this persona, or None where finance is not installed."""
    drop_in = units / f"household-pocketpiggies@{persona}.service.d" / "gateway.conf"
    if drop_in.is_symlink() or not drop_in.is_file():
        return None
    try:
        text = drop_in.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    match = re.search(
        r"^Environment=POCKETPIGGIES_OWNER_TELEGRAM_ID=([1-9][0-9]*)$", text, re.MULTILINE
    )
    if match is None:
        raise ValueError(f"the {persona} drop-in names no owner")
    return match.group(1)


def guard(
    *,
    units: Path = SYSTEMD_UNITS,
    state_root: Path = GATEWAY_STATE_ROOT,
    run: Runner = subprocess.run,
    log: Callable[[str], None] = print,
    sleep: Callable[[float], None] = time.sleep,
    runtime: Path = GUARD_RUNTIME,
    clock: Callable[[], float] = time.time,
) -> None:
    """Put each installed gateway's finance policy back, or stop its finance.

    A drifted key, such as exec handed back to the family group or private messages
    opened to another sender, is rewritten to what the installer set. A config the
    installer cannot make safe, or one that keeps drifting back, stops that gateway's
    key holder instead. A failure of the guard itself, including a stop systemd did not
    carry out, is caught by the unit, which then stops every key holder.
    """
    is_stopped = True
    for persona, (state_name, _) in GATEWAYS.items():
        try:
            owner = installed_owner(units, persona)
        except (ValueError, OSError) as error:
            is_stopped = _stop(persona, run, log, str(error)) and is_stopped
            continue
        if owner is None:
            continue
        try:
            repaired = _guard_one(state_root / state_name, persona, owner, log)
        except Exception as first:
            # Anything the gateway's config can make go wrong, a bad type, deep nesting or a
            # write racing ours, must fail closed for this gateway only and never stop the
            # guard from reaching the other one. One retry rides out a write in progress.
            sleep(GUARD_RETRY_SECONDS)
            try:
                repaired = _guard_one(state_root / state_name, persona, owner, log)
            except Exception as error:
                is_stopped = (
                    _stop(
                        persona,
                        run,
                        log,
                        f"the gateway config cannot be made safe: "
                        f"{type(error).__name__}: {error} (first attempt: {type(first).__name__})",
                    )
                    and is_stopped
                )
                continue
        if not repaired:
            continue
        try:
            is_looping = _repairs_in_window(runtime, persona, clock()) > MAX_REPAIRS
        except OSError as error:
            is_stopped = (
                _stop(persona, run, log, f"its repairs cannot be counted: {type(error).__name__}")
                and is_stopped
            )
            continue
        if is_looping:
            is_stopped = _stop(persona, run, log, "its config keeps drifting back") and is_stopped
    if not is_stopped:
        # The unit treats a failed run as a reason to stop every key holder.
        raise SystemExit(1)


def _stop(persona: str, run: Runner, log: Callable[[str], None], reason: str) -> bool:
    """Stop this gateway's key holder; False, logged, when systemd did not."""
    try:
        is_stopped = (
            run(
                ["systemctl", "stop", f"household-pocketpiggies@{persona}.service"],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            ).returncode
            == 0
        )
    except (OSError, subprocess.SubprocessError) as error:
        log(f"{persona}: stopping PocketPiggies failed: {type(error).__name__}")
        return False
    if not is_stopped:
        log(f"{persona}: stopping PocketPiggies failed: systemctl refused")
        return False
    log(f"{persona}: PocketPiggies stopped; {reason}")
    return True


def _repairs_in_window(runtime: Path, persona: str, now: float) -> int:
    """Record one repair and count those in the window, across the guard's runs."""
    record = runtime / f"repairs-{persona}.json"
    try:
        stored = json.loads(record.read_bytes()[:65536])
    except (OSError, ValueError):
        stored = []
    recent = [
        moment
        for moment in (stored if isinstance(stored, list) else [])
        if isinstance(moment, int | float) and now - REPAIR_WINDOW_SECONDS < moment <= now
    ][-MAX_REPAIRS:]
    recent.append(now)
    runtime.mkdir(mode=0o700, exist_ok=True)
    record.write_text(json.dumps(recent), encoding="utf-8")
    return len(recent)


def _guard_one(state: Path, persona: str, owner: str, log: Callable[[str], None]) -> bool:
    """Put the policy back if it drifted; True when it had to."""
    state_descriptor = _open_state(state)
    try:
        original, metadata = _read_config(state_descriptor)
        expected = configured(original, persona, owner)
        if expected == original:
            return False
        _write_config(state_descriptor, expected, metadata.st_uid, metadata.st_gid)
        changed = sorted(key for key in expected if expected.get(key) != original.get(key))
        log(f"{persona}: put back the PocketPiggies policy in {', '.join(changed)}")
        return True
    finally:
        os.close(state_descriptor)


def doctor_failures(output: str) -> list[str]:
    """What `plugins doctor --json` says is wrong with this plugin, one line each.

    Doctor exits 1 whenever any plugin has a diagnostic, and on the box every plugin
    loaded from a local path has one: "OpenClaw can't verify where this plugin came
    from". That says nothing about whether it loaded, so it is not a failure, and nor is
    anything about another plugin, which is that plugin's installer's to judge.
    """
    decoder = json.JSONDecoder()
    start = output.find("{")
    report = None
    while start != -1 and report is None:
        try:
            found, _ = decoder.raw_decode(output, start)
        except json.JSONDecodeError:
            start = output.find("{", start + 1)
            continue
        if isinstance(found, dict) and "diagnostics" in found:
            report = found
        else:
            start = output.find("{", start + 1)
    if report is None:
        return ["plugins doctor printed no JSON report"]
    failures = []
    for error in report.get("pluginErrors") or []:
        if isinstance(error, dict) and error.get("pluginId") == PLUGIN_ID:
            failures.append(f"{PLUGIN_ID}: {error.get('error') or error.get('message') or error}")
    for diagnostic in report.get("diagnostics") or []:
        if not isinstance(diagnostic, dict) or diagnostic.get("pluginId") != PLUGIN_ID:
            continue
        message = str(diagnostic.get("message", ""))
        if "can't verify where this plugin came from" not in message:
            failures.append(f"{PLUGIN_ID}: {message}")
    return failures


def provision_client(state_root: Path, persona: str, telegram_id: str) -> dict[str, str]:
    """Generate once in the key holder's state; never rotate an existing client."""
    directory = state_root / persona
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("start the key holder first; its state directory does not exist")
    metadata = directory.stat()
    if metadata.st_mode & 0o777 != 0o700:
        raise ValueError("the key holder's state directory is not private")
    path = directory / "connection.json"
    if path.is_symlink():
        raise ValueError("refusing a symlinked credential file")
    if path.exists():
        stored_metadata = path.stat()
        if (
            not path.is_file()
            or stored_metadata.st_nlink != 1
            or stored_metadata.st_mode & 0o777 != 0o600
        ):
            raise ValueError("existing credential storage is not private and regular")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            stored = json.loads(stream.read(MAX_CONFIG_BYTES))
        if stored.get("version") != 1 or stored.get("ownerTelegramId") != telegram_id:
            raise ValueError("existing credentials belong to a different owner or format")
        credential = stored.get("clientCredential")
        if not isinstance(credential, str) or not re.fullmatch(
            r"ppc_[A-Za-z0-9_-]{43}", credential
        ):
            raise ValueError("existing client credential is invalid; no credential was replaced")
    else:
        credential = "ppc_" + secrets.token_urlsafe(32)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchown(output.fileno(), metadata.st_uid, metadata.st_gid)
            json.dump(
                {
                    "version": 1,
                    "ownerTelegramId": telegram_id,
                    "clientCredential": credential,
                    "pending": None,
                    "grant": None,
                },
                output,
            )
            output.flush()
            os.fsync(output.fileno())
    return {
        "clientId": persona,
        "credentialSha256": hashlib.sha256(credential.encode()).hexdigest(),
        "telegramUserId": telegram_id,
        "botUsername": BOT_NAMES[persona],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("persona", nargs="?", choices=GATEWAYS)
    parser.add_argument("--telegram-id", help="the account owner's numeric Telegram id")
    parser.add_argument(
        "--restart", action="store_true", help="restart only this gateway after install or rollback"
    )
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument(
        "--provision-client",
        action="store_true",
        help="after verified activation, generate the key holder's client and print its digest",
    )
    operation.add_argument(
        "--rollback",
        action="store_true",
        help="stop the key holder and disable finance, keeping the owner-only and group policy",
    )
    operation.add_argument(
        "--guard",
        action="store_true",
        help="put every installed gateway's finance policy back (run by the guard unit)",
    )
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("run as root on the household VPS")
    if args.guard:
        guard()
        return
    if args.persona is None or args.telegram_id is None:
        parser.error("name the persona and --telegram-id")
    state_name, container = GATEWAYS[args.persona]
    state = GATEWAY_STATE_ROOT / state_name
    unit = f"household-pocketpiggies@{args.persona}.service"
    try:
        if args.provision_client:
            state_descriptor = _open_state(state)
            try:
                original, _ = _read_config(state_descriptor)
            finally:
                os.close(state_descriptor)
            expected = configured(original, args.persona, args.telegram_id)
            if any(
                original.get(key) != expected.get(key)
                for key in ("tools", "channels", "session", "plugins")
            ):
                raise ValueError("install and verify the finance policy before provisioning")
            for check, expected_state in (
                (
                    ["docker", "inspect", "--format", "{{.State.Health.Status}}", container],
                    "healthy",
                ),
                (["systemctl", "is-active", unit], "active"),
            ):
                answer = subprocess.run(
                    check, capture_output=True, text=True, check=False, timeout=20
                )
                if answer.stdout.strip() != expected_state:
                    raise ValueError(f"verify {check[-1]} is {expected_state} before provisioning")
            print(json.dumps(provision_client(KEY_HOLDER_STATE, args.persona, args.telegram_id)))
            return
        if args.rollback:
            # Finance stops here: without its key holder the gateway holds no credential.
            # A unit an interrupted install never wrote is already stopped.
            subprocess.run(
                ["systemctl", "disable", "--now", unit],
                check=False,
                capture_output=True,
                text=True,
                timeout=90,
            )
            state_now = subprocess.run(
                ["systemctl", "is-active", unit],
                check=False,
                capture_output=True,
                text=True,
                timeout=90,
            ).stdout.strip()
            if state_now not in ("inactive", "failed", "unknown"):
                raise ValueError(f"{unit} is still {state_now}; finance was not stopped")
            # Without its drop-in the guard no longer puts finance back for this gateway.
            drop_in = SYSTEMD_UNITS / f"{unit}.d"
            if drop_in.is_dir() and not drop_in.is_symlink():
                shutil.rmtree(drop_in)
        backup = install_into(state, args.persona, args.telegram_id, is_enabled=not args.rollback)
        if not args.rollback:
            install_key_holder(state, args.persona, args.telegram_id)
    except (ValueError, OSError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Installation refused: {error}\n")
    action = "Disabled" if args.rollback else "Installed"
    print(f"{action} PocketPiggies for {args.persona}; previous config: {backup}")
    if not args.rollback:
        # Accept this reviewed, local read-only plugin using the supported CLI.
        subprocess.run(
            [
                "docker",
                "exec",
                container,
                "node",
                "dist/index.js",
                "plugins",
                "enable",
                PLUGIN_ID,
                "--accept-capabilities",
            ],
            check=True,
            capture_output=True,
            timeout=90,
        )
    if args.restart:
        subprocess.run(["docker", "restart", container], check=True, timeout=90)
        doctor = subprocess.run(
            ["docker", "exec", container, "node", "dist/index.js", "plugins", "doctor", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=90,
        )
        failures = doctor_failures(doctor.stdout)
        if failures:
            raise SystemExit("plugins doctor reports: " + "; ".join(failures))
    else:
        print(f"Activate with: docker restart {container}")
    if args.rollback:
        print("Finance is disabled; the owner-only and family-group tool policy stays in place.")
        print(
            "The grant stays valid at PocketPiggies until revoked: ask the owner to disconnect "
            "in PocketPiggies settings, or reinstall and use /pocketpiggies disconnect."
        )
    else:
        print("Verify the plugin, the key holder and the group tool policy before provisioning.")


if __name__ == "__main__":
    main()
