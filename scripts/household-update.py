#!/usr/bin/env python3
"""Keeps a household's box on the newest release its publisher signed.

Every day household-update.timer runs `household-update.py run`, which:

1. fetches the publisher's release tags into a bare mirror, /opt/household-assistant/repo.git;
2. picks the newest tag newer than the release in use whose signature verifies against
   /etc/household-assistant/allowed_signers, a file only the box holds, and checks out the
   commit that signed tag names into /opt/household-assistant/releases/<tag>;
3. under the rollout lock, runs the nightly backup from the release in use and keeps a copy
   of the compose file and of each gateway's openclaw.json;
4. converges the box with the new release's scripts/household-converge.sh and, when that
   passes, points /opt/household-assistant/current at the new release;
5. when it fails, puts the copies back, converges the box again with the release it was
   on, and never tries the failed tag again.

It never installs an older release than the one in use, and nothing in the repository can
change whom it trusts: the signers file is put on the box once, by `install`.
docs/deploy/updates.md is the runbook: how the publisher signs a release, how a box is set
up for it, how to pause it and how to roll back by hand.

    python3 scripts/household-update.py install --remote <url> --signers <file>
    python3 /opt/household-assistant/update/household-update.py run [--dry-run]
    python3 /opt/household-assistant/update/household-update.py status

The copy under /opt/household-assistant/update is the one the timer runs. `install` puts it
there from a checkout, and every release that converges replaces it with its own.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import household_file

APP_DIR = Path("/opt/household-assistant")
SIGNERS = Path("/etc/household-assistant/allowed_signers")
# Held for the whole of an update, and by hand for a rollout by hand
# (`flock /run/household-assistant/rollout.lock <command>`), so the two never overlap.
LOCK = Path("/run/household-assistant/rollout.lock")
UNITS = Path("/etc/systemd/system")
# A release is an annotated tag named for the day it was cut, and a number when a day has
# more than one: v2026.10.24, v2026.10.24.2.
RELEASE_TAG = re.compile(r"v(\d{4})\.(\d{2})\.(\d{2})(?:\.([1-9]\d{0,2}))?")
# The newest releases kept on disk, besides the one in use and the one before it.
KEEP = 3
CONVERGE = "scripts/household-converge.sh"
BACKUP = "scripts/household-backup.sh"
UNIT_NAMES = ("household-update.service", "household-update.timer")
# What each release directory says it holds, written once it is checked out.
MARKER = ".household-release.json"
# The exit status when another rollout holds the lock. The service counts it a success:
# the box is busy, not broken, and the next day's run tries again.
BUSY = 75
# One allowed_signers line: principals, optional options, then the key's type and data.
SIGNER_KEY = re.compile(
    r"(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com"
    r"|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]{40,}"
)
# Git told nothing by root's own or the system's git config, so nothing there decides how
# a signature is checked. The mirror's own config, its remote and any deploy key, still
# counts. Every setting the check depends on is passed with the command.
GIT_ENVIRONMENT = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_TERMINAL_PROMPT": "0",
}
GIT_TIMEOUT_SECONDS = 600
# Only an SSH signature from a principal in the signers file counts: a PGP or X.509
# signature has no program to check it, and an SSH key the file does not name is only
# "undefined" trust, below the minimum.
VERIFY = (
    "-c",
    "gpg.format=ssh",
    "-c",
    "gpg.ssh.program=ssh-keygen",
    "-c",
    "gpg.minTrustLevel=fully",
    "-c",
    "gpg.program=false",
    "-c",
    "gpg.x509.program=false",
)
GOOD_SIGNATURE = 'Good "git" signature for '
# Set for a release's backup and converge, which run under the lock this updater holds:
# a script that takes the rollout lock itself when run by hand must not wait on it then.
LOCK_HELD = "HOUSEHOLD_ROLLOUT_LOCKED"


class UpdateError(RuntimeError):
    """Something that stops this run, said in a sentence for the journal."""


class Refused(UpdateError):
    """A tag that is not a release the publisher signed."""


@dataclass(frozen=True, slots=True)
class Box:
    """Where on the box everything is. The tests point each at a throwaway tree."""

    app: Path = APP_DIR
    state_root: Path = household_file.STATE_ROOT
    signers: Path = SIGNERS
    lock: Path = LOCK
    units: Path = UNITS
    household_file: Path = field(default_factory=lambda: household_file.HOUSEHOLD_FILE)
    systemctl: tuple[str, ...] = ("systemctl",)

    @property
    def mirror(self) -> Path:
        return self.app / "repo.git"

    @property
    def releases(self) -> Path:
        return self.app / "releases"

    @property
    def current(self) -> Path:
        return self.app / "current"

    @property
    def compose(self) -> Path:
        return self.app / "docker-compose.yml"

    @property
    def updater(self) -> Path:
        return self.app / "update"

    @property
    def record_file(self) -> Path:
        return self.state_root / "update" / "state.json"

    @property
    def snapshots(self) -> Path:
        return self.state_root / "update" / "snapshot"


@dataclass(frozen=True, slots=True)
class Release:
    tag: str
    commit: str


def log(message: str) -> None:
    print(message, flush=True)


def version(tag: str) -> tuple[int, int, int, int] | None:
    """The order releases go in, or None for a tag that is not a release's."""
    match = RELEASE_TAG.fullmatch(tag)
    if match is None:
        return None
    year, month, day, number = match.groups()
    return (int(year), int(month), int(day), int(number or 0))


def order(tag: str) -> tuple[int, int, int, int]:
    """A sort key for release tags; anything else sorts first."""
    return version(tag) or (0, 0, 0, 0)


def now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


# --- git ---------------------------------------------------------------------


def git(
    box: Box, *arguments: str, check: bool = True, environment: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        ["git", f"--git-dir={box.mirror}", *arguments],
        capture_output=True,
        text=True,
        env={**os.environ, **GIT_ENVIRONMENT, **(environment or {})},
        timeout=GIT_TIMEOUT_SECONDS,
        check=False,
    )
    if check and completed.returncode != 0:
        said = completed.stderr.strip() or completed.stdout.strip()
        command = next(argument for argument in arguments if not argument.startswith("-"))
        raise UpdateError(f"git {command} failed: {said}")
    return completed


def fetch(box: Box) -> None:
    """The publisher's release tags, as they are now. A tag gone there goes here too."""
    git(box, "fetch", "--quiet", "--no-tags", "--prune", "origin", "+refs/tags/v*:refs/tags/v*")


def release_tags(box: Box) -> list[str]:
    """Every release tag the mirror has, newest first."""
    names = git(box, "for-each-ref", "--format=%(refname:strip=2)", "refs/tags/").stdout.split()
    ordered = [(found, name) for name in names if (found := version(name)) is not None]
    return [name for _, name in sorted(ordered, reverse=True)]


def verified(box: Box, tag: str) -> Release:
    """The commit `tag` names, when it is a release the publisher signed.

    What is checked is the tag object itself: that it names a commit, that the name inside
    it is the tag's own, so an old signed release cannot be pushed again under a newer
    name, and that its SSH signature is from a principal in the signers file.
    """
    found = git(box, "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}", check=False)
    tag_object = found.stdout.strip()
    if found.returncode != 0 or not tag_object:
        raise Refused("it is not in the mirror")
    if git(box, "cat-file", "-t", tag_object).stdout.strip() != "tag":
        raise Refused("it is a bare name, not an annotated, signed tag")
    content = git(box, "cat-file", "tag", tag_object).stdout
    header: dict[str, str] = {}
    for line in content.split("\n\n", 1)[0].splitlines():
        key, _, value = line.partition(" ")
        header.setdefault(key, value)
    if header.get("type") != "commit":
        raise Refused("it does not name a commit")
    if header.get("tag") != tag:
        raise Refused(f"the signed tag inside it is {header.get('tag')!r}, a different release")
    if "-----BEGIN SSH SIGNATURE-----" not in content:
        raise Refused("it is not signed with an SSH key")
    checked = git(
        box,
        *VERIFY,
        "-c",
        f"gpg.ssh.allowedSignersFile={box.signers}",
        "verify-tag",
        "--raw",
        tag_object,
        check=False,
    )
    if checked.returncode != 0 or GOOD_SIGNATURE not in checked.stderr:
        raise Refused("its signature is not from a signer in the signers file")
    commit = header.get("object", "")
    if git(box, "cat-file", "-t", commit, check=False).stdout.strip() != "commit":
        raise Refused("the commit it names is not in the mirror")
    return Release(tag=tag, commit=commit)


def check_out(box: Box, release: Release) -> Path:
    """The release's files, exactly the commit its signed tag names, in their own folder."""
    target = box.releases / release.tag
    if marker(target) == {"tag": release.tag, "commit": release.commit}:
        return target
    box.releases.mkdir(parents=True, exist_ok=True, mode=0o755)
    partial = box.releases / f".{release.tag}.partial"
    index = box.releases / f".{release.tag}.index"
    for leftover in (partial, target):
        if leftover.is_dir() and not leftover.is_symlink():
            shutil.rmtree(leftover)
    index.unlink(missing_ok=True)
    partial.mkdir(mode=0o755)
    through_index = {"GIT_INDEX_FILE": str(index)}
    git(box, "read-tree", release.commit, environment=through_index)
    git(
        box,
        f"--work-tree={partial}",
        "checkout-index",
        "--all",
        "--force",
        environment=through_index,
    )
    index.unlink()
    (partial / MARKER).write_text(
        json.dumps({"tag": release.tag, "commit": release.commit}) + "\n", encoding="utf-8"
    )
    os.rename(partial, target)
    return target


def marker(directory: Path) -> dict[str, Any] | None:
    try:
        found = json.loads((directory / MARKER).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return found if isinstance(found, dict) else None


# --- the record of what this box runs ----------------------------------------


def load_record(box: Box) -> dict[str, Any]:
    try:
        found = json.loads(box.record_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except ValueError as error:
        raise UpdateError(f"{box.record_file} is not readable JSON: {error}") from error
    return found if isinstance(found, dict) else {}


def save_record(box: Box, record: dict[str, Any]) -> None:
    box.record_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = box.record_file.with_name(f".{box.record_file.name}.{os.getpid()}")
    temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, box.record_file)


def in_use(box: Box, record: dict[str, Any]) -> str | None:
    """The release the box runs: the one `current` points at, or else the one recorded."""
    if box.current.is_symlink():
        name = Path(os.readlink(box.current)).name
        if version(name) is not None and (box.releases / name).is_dir():
            return name
    recorded = record.get("current")
    return recorded if isinstance(recorded, str) and version(recorded) is not None else None


def choose(box: Box, record: dict[str, Any], current: str | None) -> Release | None:
    """The newest signed release newer than `current` that has not failed here."""
    floor = version(current) if current else None
    failed = set(record.get("failed") or [])
    for tag in release_tags(box):
        found = version(tag)
        if floor is not None and found is not None and found <= floor:
            break
        if tag in failed:
            log(f"{tag} failed on this box before, so it is not tried again.")
            continue
        try:
            return verified(box, tag)
        except Refused as reason:
            log(f"{tag} was refused: {reason}.")
    return None


# --- what an update changes, kept and put back ---------------------------------


def snapshot_targets(box: Box) -> list[Path]:
    """The compose file and each gateway's config, which a release's converge rewrites."""
    members = household_file.load_household(box.household_file).members
    return [box.compose, *(box.state_root / member.state / "openclaw.json" for member in members)]


def read_regular(path: Path) -> tuple[bytes, os.stat_result] | None:
    """A file's bytes and status, or None when it is missing or not a plain file. The
    gateways' configs sit in folders their assistants write, so a link in a config's place
    is never followed: a root process copying it back would hand the assistant its target."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as error:
        log(f"{path} was not kept: {error.strerror}.")
        return None
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode):
            log(f"{path} is not a plain file, so it was not kept.")
            return None
        chunks = []
        while chunk := os.read(descriptor, 1 << 20):
            chunks.append(chunk)
        return b"".join(chunks), status
    finally:
        os.close(descriptor)


def take_snapshots(box: Box) -> list[dict[str, Any]]:
    if box.snapshots.exists():
        shutil.rmtree(box.snapshots)
    box.snapshots.mkdir(parents=True, mode=0o700)
    kept = []
    for number, target in enumerate(snapshot_targets(box)):
        read = read_regular(target)
        if read is None:
            continue
        content, status = read
        copy = box.snapshots / str(number)
        copy.write_bytes(content)
        copy.chmod(0o600)
        kept.append(
            {
                "path": str(target),
                "copy": copy.name,
                "mode": stat.S_IMODE(status.st_mode),
                "uid": status.st_uid,
                "gid": status.st_gid,
            }
        )
    (box.snapshots / "kept.json").write_text(json.dumps(kept, indent=2) + "\n", encoding="utf-8")
    return kept


def restore(box: Box, kept: list[dict[str, Any]]) -> None:
    """Each kept file back where it was, with its owner and mode, replaced whole. A file
    the failed release made where there was none before is left: removing a gateway's
    first config would take the gateway down with it."""
    for entry in kept:
        target = Path(entry["path"])
        content = (box.snapshots / entry["copy"]).read_bytes()
        temporary = target.with_name(f".{target.name}.restore-{os.getpid()}")
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, entry["mode"]
        )
        try:
            os.write(descriptor, content)
            if os.geteuid() == 0:
                os.fchown(descriptor, entry["uid"], entry["gid"])
            os.fchmod(descriptor, entry["mode"])
        finally:
            os.close(descriptor)
        os.replace(temporary, target)
        log(f"{target} is back as it was before the update.")


# --- running a release's own scripts -------------------------------------------


def run_script(release_dir: Path, script: str) -> int:
    path = release_dir / script
    if not path.is_file():
        log(f"{release_dir.name} has no {script}.")
        return 127
    under_lock = {**os.environ, LOCK_HELD: "1"}
    return subprocess.run(
        ["bash", str(path)], cwd=release_dir, env=under_lock, check=False
    ).returncode


def back_up(current_dir: Path | None) -> None:
    if current_dir is None:
        log("No release is in use yet, so there is nothing to back up.")
        return
    log(f"Backing up the box with {current_dir.name}'s backup.")
    status = run_script(current_dir, BACKUP)
    if status != 0:
        raise UpdateError(f"the backup failed with status {status}, so nothing was changed")


def swap_current(box: Box, release_dir: Path) -> None:
    """`current` pointed at the release in one step, so it never points at nothing."""
    temporary = box.app / f".current.{os.getpid()}"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(Path("releases") / release_dir.name)
    os.replace(temporary, box.current)


def refresh_updater(box: Box, release_dir: Path) -> None:
    """This updater and its units, as the release that just converged ships them. A new
    updater that cannot even start is not put in place, so the next day's run still can."""
    scripts = release_dir / "scripts"
    new = scripts / "household-update.py"
    started = subprocess.run(
        [sys.executable, str(new), "--help"], capture_output=True, text=True, check=False
    )
    if started.returncode != 0:
        log(f"{release_dir.name}'s updater does not start, so the one in place stays.")
        return
    box.updater.mkdir(parents=True, exist_ok=True, mode=0o755)
    for name, mode in (("household-update.py", 0o755), ("household_file.py", 0o644)):
        install_file(scripts / name, box.updater / name, mode)
    units = release_dir / "deploy" / "update"
    if all((units / unit).is_file() for unit in UNIT_NAMES):
        changed = False
        for unit in UNIT_NAMES:
            changed |= install_file(units / unit, box.units / unit, 0o644)
        if changed:
            systemctl(box, "daemon-reload")


def install_file(source: Path, target: Path, mode: int) -> bool:
    """`source` copied over `target` in one step. True when it changed anything."""
    content = source.read_bytes()
    if target.is_file() and not target.is_symlink() and target.read_bytes() == content:
        target.chmod(mode)
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".{target.name}.{os.getpid()}")
    temporary.write_bytes(content)
    temporary.chmod(mode)
    os.replace(temporary, target)
    return True


def systemctl(box: Box, *arguments: str) -> None:
    subprocess.run([*box.systemctl, *arguments], check=False)


def prune(box: Box, record: dict[str, Any]) -> None:
    """Releases beyond the newest KEEP go, except the one in use and the one before it."""
    if not box.releases.is_dir():
        return
    names = [path.name for path in box.releases.iterdir() if path.is_dir()]
    releases = sorted((name for name in names if version(name)), key=order, reverse=True)
    keep = set(releases[:KEEP]) | {record.get("current"), record.get("previous")}
    for name in names:
        if name in keep:
            continue
        if version(name) is not None or name.endswith(".partial"):
            shutil.rmtree(box.releases / name)
            log(f"Removed the old release {name}.")


@contextmanager
def rollout_lock(box: Box) -> Iterator[bool]:
    box.lock.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    descriptor = os.open(box.lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        os.close(descriptor)


def signers_ready(box: Box) -> bool:
    try:
        text = box.signers.read_text(encoding="utf-8")
    except OSError:
        return False
    return any(SIGNER_KEY.search(line) for line in text.splitlines())


# --- the commands ------------------------------------------------------------


def run(box: Box, *, dry_run: bool = False) -> int:
    os.umask(0o022)
    if not signers_ready(box):
        log(f"There is no signer in {box.signers}, so no release can be trusted and none is.")
        return 1
    if not box.mirror.is_dir():
        log(f"There is no mirror at {box.mirror}; run household-update.py install first.")
        return 1
    with rollout_lock(box) as held:
        if not held:
            log(f"Another rollout holds {box.lock}, so this run leaves the box alone.")
            return BUSY
        record = load_record(box)
        record["lastChecked"] = now()
        try:
            fetch(box)
        except UpdateError as error:
            record["lastError"] = str(error)
            save_record(box, record)
            log(f"The publisher's releases could not be fetched: {error}.")
            return 1
        current = in_use(box, record)
        release = choose(box, record, current)
        if release is None:
            log(f"{current or 'Nothing'} is the newest signed release; nothing to do.")
            if not dry_run:
                save_record(box, record)
            return 0
        if dry_run:
            log(f"{release.tag} ({release.commit}) would be installed over {current or 'nothing'}.")
            return 0
        return update(box, record, current, release)


def update(box: Box, record: dict[str, Any], current: str | None, release: Release) -> int:
    log(f"Installing {release.tag} ({release.commit}) over {current or 'nothing'}.")
    attempt: dict[str, Any] = {"tag": release.tag, "commit": release.commit, "at": now()}
    record["lastAttempt"] = attempt
    current_dir = box.releases / current if current else None
    try:
        release_dir = check_out(box, release)
        back_up(current_dir)
        kept = take_snapshots(box)
    except (UpdateError, OSError, ValueError) as error:
        attempt["result"] = "not started"
        record["lastError"] = f"{release.tag}: {error}"
        save_record(box, record)
        log(f"{release.tag} was not installed: {error}.")
        return 1

    log(f"Converging the box to {release.tag}.")
    status = run_script(release_dir, CONVERGE)
    if status == 0:
        swap_current(box, release_dir)
        record.update(current=release.tag, previous=current, lastError=None)
        attempt["result"] = "installed"
        save_record(box, record)
        log(f"{release.tag} is installed and every gateway passed its checks.")
        try:
            refresh_updater(box, release_dir)
            prune(box, record)
        except OSError as error:
            log(f"{release.tag} is in use, but tidying up after it failed: {error}.")
        return 0

    log(f"{release.tag} did not converge (status {status}); putting the box back.")
    try:
        restore(box, kept)
    except OSError as error:
        log(f"The kept files could not all be put back ({error}); converging back anyway.")
    record["failed"] = sorted({*(record.get("failed") or []), release.tag}, key=order)
    record["lastError"] = f"{release.tag} did not converge (status {status})"
    if current_dir is None:
        attempt["result"] = "failed, nothing to roll back to"
        save_record(box, record)
        log("No release was in use before, so there is nothing to converge back to.")
        return 1
    back = run_script(current_dir, CONVERGE)
    if back == 0:
        attempt["result"] = "failed, rolled back"
        log(f"The box is back on {current}.")
    else:
        attempt["result"] = "failed, rollback failed"
        record["lastError"] += f"; converging back to {current} failed too (status {back})"
        log(f"Converging back to {current} failed too (status {back}); the box needs a person.")
    save_record(box, record)
    return 1


def status(box: Box) -> int:
    record = load_record(box)
    current = in_use(box, record)
    log(f"in use: {current or 'nothing yet'}")
    log(f"before it: {record.get('previous') or 'nothing'}")
    log(f"last checked: {record.get('lastChecked') or 'never'}")
    attempt = record.get("lastAttempt")
    if isinstance(attempt, dict):
        log(f"last attempt: {attempt.get('tag')} at {attempt.get('at')}: {attempt.get('result')}")
    if record.get("failed"):
        log(f"never tried again: {', '.join(record['failed'])}")
    if record.get("lastError"):
        log(f"last error: {record['lastError']}")
    log(f"signers: {box.signers}{'' if signers_ready(box) else ' (missing or empty)'}")
    return 0


def install(
    box: Box,
    *,
    remote: str,
    signers: Path,
    deploy_key: Path | None = None,
    replace_signers: bool = False,
    checkout: Path | None = None,
) -> int:
    """The signers file, the mirror, this updater and its timer, put on the box once.

    It installs no release: `run` does that, the first time from nothing, so the box only
    ever runs what the publisher signed.
    """
    checkout = checkout or Path(__file__).resolve().parent.parent
    if shutil.which("ssh-keygen") is None:
        log("ssh-keygen is missing, so no signature could be checked; install openssh-client.")
        return 1
    try:
        wanted = signers.read_text(encoding="utf-8")
    except OSError as error:
        log(f"{signers} cannot be read: {error.strerror}.")
        return 1
    if not any(SIGNER_KEY.search(line) for line in wanted.splitlines()):
        log(f"{signers} names no signer's public key, so it would trust nothing.")
        return 1
    if box.signers.exists() and box.signers.read_text(encoding="utf-8") != wanted:
        if not replace_signers:
            log(f"{box.signers} already trusts other signers; --replace-signers changes whom.")
            return 1
        log(f"{box.signers} now trusts the signers in {signers}.")
    box.signers.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    install_file(signers, box.signers, 0o644)

    if not box.mirror.is_dir():
        box.mirror.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        subprocess.run(
            ["git", "init", "--quiet", "--bare", str(box.mirror)],
            env={**os.environ, **GIT_ENVIRONMENT},
            check=True,
        )
    if git(box, "remote", "get-url", "origin", check=False).returncode == 0:
        git(box, "remote", "set-url", "origin", remote)
    else:
        git(box, "remote", "add", "origin", remote)
    if deploy_key is not None:
        git(
            box,
            "config",
            "core.sshCommand",
            f"ssh -i {deploy_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new",
        )

    box.updater.mkdir(parents=True, exist_ok=True, mode=0o755)
    install_file(
        checkout / "scripts" / "household-update.py", box.updater / "household-update.py", 0o755
    )
    install_file(
        checkout / "scripts" / "household_file.py", box.updater / "household_file.py", 0o644
    )
    for unit in UNIT_NAMES:
        install_file(checkout / "deploy" / "update" / unit, box.units / unit, 0o644)
    systemctl(box, "daemon-reload")
    systemctl(box, "enable", "--now", "household-update.timer")
    log(f"Updates are set up from {remote}; the first run installs the newest signed release:")
    log(f"  python3 {box.updater / 'household-update.py'} run")
    return 0


def main(argv: Sequence[str] | None = None, *, box: Box | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    runner = commands.add_parser("run", help="install the newest signed release, if newer")
    runner.add_argument("--dry-run", action="store_true", help="say what it would install")
    commands.add_parser("status", help="what the box runs and how the last update went")
    installer = commands.add_parser("install", help="set the box up to update itself")
    installer.add_argument("--remote", required=True, help="the publisher's repository")
    installer.add_argument("--signers", required=True, type=Path, help="an allowed_signers file")
    installer.add_argument("--deploy-key", type=Path, help="a read-only key for a private remote")
    installer.add_argument(
        "--replace-signers", action="store_true", help="trust these signers instead"
    )
    arguments = parser.parse_args(argv)
    box = box or Box()
    try:
        if arguments.command == "status":
            return status(box)
        if os.geteuid() != 0 and box == Box():
            log("Run it as root.")
            return 1
        if arguments.command == "install":
            return install(
                box,
                remote=arguments.remote,
                signers=arguments.signers,
                deploy_key=arguments.deploy_key,
                replace_signers=arguments.replace_signers,
            )
        return run(box, dry_run=arguments.dry_run)
    except UpdateError as error:
        log(f"Stopped: {error}.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
