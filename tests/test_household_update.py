"""household-update.py, run for real against a throwaway box and a publisher's repository.

The releases are real git tags signed with real SSH keys, checked by git and ssh-keygen
exactly as on the box. Each release's converge and backup are stand-ins that say what
they did, and fail when the release or the test tells them to.
"""

from __future__ import annotations

import configparser
import fcntl
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, Protocol

import pytest

from tests.capabilities import needs_posix_bash, needs_ssh_keygen, needs_symlinks

ROOT = Path(__file__).resolve().parents[1]
NEW_EXAMPLE = ROOT / "deploy" / "household.new.example.json"
UNITS = ROOT / "deploy" / "update"
GIT_ENVIRONMENT = {
    **os.environ,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_AUTHOR_NAME": "Publisher",
    "GIT_AUTHOR_EMAIL": "publisher@example.com",
    "GIT_COMMITTER_NAME": "Publisher",
    "GIT_COMMITTER_EMAIL": "publisher@example.com",
}

CONVERGE = """#!/usr/bin/env bash
set -euo pipefail
echo "converge $(cat RELEASE)${HOUSEHOLD_ROLLOUT_LOCKED:+ under the lock}" >> "${UPDATE_TEST_LOG}"
if [[ -f fail ]]; then
  echo "broken by $(cat RELEASE)" > "${UPDATE_TEST_COMPOSE}"
  for config in ${UPDATE_TEST_CONFIGS}; do echo broken > "${config}"; done
  exit 3
fi
"""
BACKUP = """#!/usr/bin/env bash
echo "backup $(cat RELEASE)" >> "${UPDATE_TEST_LOG}"
exit "${UPDATE_TEST_BACKUP_STATUS:-0}"
"""

pytestmark = [needs_posix_bash, needs_symlinks]


def updater() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "household_update", ROOT / "scripts" / "household-update.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # Its dataclasses look their module up by name as they are made.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


update = updater()


class Box(Protocol):
    """What the tests read of the updater's Box, which they cannot import by its name."""

    @property
    def app(self) -> Path: ...
    @property
    def state_root(self) -> Path: ...
    @property
    def signers(self) -> Path: ...
    @property
    def lock(self) -> Path: ...
    @property
    def units(self) -> Path: ...
    @property
    def mirror(self) -> Path: ...
    @property
    def releases(self) -> Path: ...
    @property
    def current(self) -> Path: ...
    @property
    def compose(self) -> Path: ...
    @property
    def updater(self) -> Path: ...
    @property
    def record_file(self) -> Path: ...
    @property
    def snapshots(self) -> Path: ...


class Publisher:
    """The publisher's repository and signing keys, and a key nobody trusts."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.source = root / "repository"
        self.source.mkdir(parents=True)
        for name in ("publisher", "stranger"):
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", root / name],
                stdin=subprocess.DEVNULL,
                check=True,
            )
        self.signers = root / "allowed_signers"
        public = (root / "publisher.pub").read_text(encoding="utf-8")
        self.signers.write_text(
            f'publisher@example.com namespaces="git" {public}', encoding="utf-8"
        )
        self.git("init", "--quiet", "--initial-branch=main")

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.source,
            env=GIT_ENVIRONMENT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout

    def release(
        self, tag: str, *, key: str | None = "publisher", fail: bool = False, bare: bool = False
    ) -> str:
        """A commit that is release `tag`, tagged as asked. Returns the commit."""
        scripts = self.source / "scripts"
        scripts.mkdir(exist_ok=True)
        (scripts / "household-converge.sh").write_text(CONVERGE, encoding="utf-8")
        (scripts / "household-backup.sh").write_text(BACKUP, encoding="utf-8")
        for name in ("household-update.py", "household_file.py"):
            shutil.copy(ROOT / "scripts" / name, scripts / name)
        shutil.copytree(UNITS, self.source / "deploy" / "update", dirs_exist_ok=True)
        (self.source / "RELEASE").write_text(tag, encoding="utf-8")
        (self.source / "fail").unlink(missing_ok=True)
        if fail:
            (self.source / "fail").write_text("", encoding="utf-8")
        self.git("add", "--all")
        self.git("commit", "--quiet", "--allow-empty", "-m", f"release {tag}")
        if bare:
            self.git("tag", tag)
        elif key is None:
            self.git("tag", "-a", tag, "-m", tag)
        else:
            self.git(
                "-c",
                "gpg.format=ssh",
                "-c",
                "gpg.ssh.program=ssh-keygen",
                "-c",
                f"user.signingkey={self.root / key}",
                "tag",
                "-s",
                tag,
                "-m",
                tag,
            )
        return self.git("rev-parse", "HEAD").strip()


@pytest.fixture
def publisher(tmp_path: Path) -> Publisher:
    return Publisher(tmp_path / "publisher-side")


@pytest.fixture
def box(tmp_path: Path, publisher: Publisher, monkeypatch: pytest.MonkeyPatch) -> Box:
    """A box set up for updates from `publisher`, with nothing installed yet."""
    root = tmp_path / "box"
    calls = tmp_path / "systemctl.log"
    systemctl = tmp_path / "systemctl"
    systemctl.write_text(f'#!/usr/bin/env bash\necho "$*" >> "{calls}"\n', encoding="utf-8")
    systemctl.chmod(0o755)
    the_box: Box = update.Box(
        app=root / "opt",
        state_root=root / "var",
        signers=root / "etc" / "allowed_signers",
        lock=root / "run" / "rollout.lock",
        units=root / "units",
        household_file=NEW_EXAMPLE,
        systemctl=(str(systemctl),),
    )
    log = tmp_path / "scripts.log"
    log.touch()
    configs = [
        the_box.state_root / state / "openclaw.json" for state in ("openclaw-ada", "openclaw-rex")
    ]
    monkeypatch.setenv("UPDATE_TEST_LOG", str(log))
    monkeypatch.setenv("UPDATE_TEST_COMPOSE", str(the_box.compose))
    monkeypatch.setenv("UPDATE_TEST_CONFIGS", " ".join(str(config) for config in configs))
    assert update.install(the_box, remote=str(publisher.source), signers=publisher.signers) == 0
    return the_box


def ran(tmp_path: Path) -> list[str]:
    return (tmp_path / "scripts.log").read_text(encoding="utf-8").splitlines()


def record(box: Box) -> dict[str, Any]:
    found: dict[str, Any] = json.loads(box.record_file.read_text(encoding="utf-8"))
    return found


def in_use(box: Box) -> str:
    return os.readlink(box.current)


@needs_ssh_keygen
def test_the_newest_signed_release_is_checked_out_converged_and_put_in_use(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.01")
    commit = publisher.release("v2026.10.02")

    assert update.run(box) == 0

    assert in_use(box) == "releases/v2026.10.02"
    assert ran(tmp_path) == ["converge v2026.10.02 under the lock"]
    release = box.releases / "v2026.10.02"
    assert json.loads((release / update.MARKER).read_text()) == {
        "tag": "v2026.10.02",
        "commit": commit,
    }
    assert (release / "RELEASE").read_text() == "v2026.10.02"
    assert record(box)["current"] == "v2026.10.02"
    assert record(box)["previous"] is None


@needs_ssh_keygen
def test_a_release_not_signed_by_an_allowed_signer_is_refused(
    tmp_path: Path, publisher: Publisher, box: Box, capsys: pytest.CaptureFixture[str]
) -> None:
    publisher.release("v2026.10.01")
    assert update.run(box) == 0
    publisher.release("v2026.10.02", key="stranger")
    publisher.release("v2026.10.03", key=None)
    publisher.release("v2026.10.04", bare=True)

    assert update.run(box) == 0

    assert in_use(box) == "releases/v2026.10.01"
    assert ran(tmp_path) == ["converge v2026.10.01 under the lock"]
    said = capsys.readouterr().out
    assert "v2026.10.02 was refused: its signature is not from a signer" in said
    assert "v2026.10.03 was refused: it is not signed with an SSH key" in said
    assert "v2026.10.04 was refused: it is a bare name" in said


@needs_ssh_keygen
def test_an_older_signed_release_pushed_again_under_a_newer_name_is_refused(
    tmp_path: Path, publisher: Publisher, box: Box, capsys: pytest.CaptureFixture[str]
) -> None:
    publisher.release("v2026.10.01")
    assert update.run(box) == 0
    old = publisher.git("rev-parse", "refs/tags/v2026.10.01").strip()
    publisher.git("update-ref", "refs/tags/v2026.10.09", old)

    assert update.run(box) == 0

    assert in_use(box) == "releases/v2026.10.01"
    assert "the signed tag inside it is 'v2026.10.01', a different release" in (
        capsys.readouterr().out
    )


@needs_ssh_keygen
def test_with_no_signer_on_the_box_nothing_is_trusted(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.01")
    box.signers.unlink()

    assert update.run(box) == 1

    assert not box.current.exists()
    assert ran(tmp_path) == []


@needs_ssh_keygen
def test_an_older_release_is_never_installed(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.02")
    assert update.run(box) == 0
    publisher.release("v2026.10.01")

    assert update.run(box) == 0

    assert in_use(box) == "releases/v2026.10.02"
    assert ran(tmp_path) == ["converge v2026.10.02 under the lock"]


@needs_ssh_keygen
def test_a_failed_backup_changes_nothing(
    tmp_path: Path, publisher: Publisher, box: Box, monkeypatch: pytest.MonkeyPatch
) -> None:
    publisher.release("v2026.10.01")
    assert update.run(box) == 0
    publisher.release("v2026.10.02")
    monkeypatch.setenv("UPDATE_TEST_BACKUP_STATUS", "1")

    assert update.run(box) == 1

    assert in_use(box) == "releases/v2026.10.01"
    assert ran(tmp_path) == ["converge v2026.10.01 under the lock", "backup v2026.10.01"]
    assert "the backup failed" in str(record(box)["lastError"])
    assert "failed" not in record(box)


@needs_ssh_keygen
def test_a_release_that_fails_is_rolled_back_with_its_files_put_back(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.01")
    assert update.run(box) == 0
    box.compose.write_text("services: {}\n", encoding="utf-8")
    configs = []
    for state in ("openclaw-ada", "openclaw-rex"):
        config = box.state_root / state / "openclaw.json"
        config.parent.mkdir(parents=True)
        config.write_text(f'{{"gateway": "{state}"}}\n', encoding="utf-8")
        config.chmod(0o600)
        configs.append(config)
    publisher.release("v2026.10.02", fail=True)

    assert update.run(box) == 1

    assert ran(tmp_path) == [
        "converge v2026.10.01 under the lock",
        "backup v2026.10.01",
        "converge v2026.10.02 under the lock",
        "converge v2026.10.01 under the lock",
    ]
    assert in_use(box) == "releases/v2026.10.01"
    assert box.compose.read_text() == "services: {}\n"
    for config, state in zip(configs, ("openclaw-ada", "openclaw-rex"), strict=True):
        assert config.read_text() == f'{{"gateway": "{state}"}}\n'
        assert config.stat().st_mode & 0o777 == 0o600
    assert record(box)["failed"] == ["v2026.10.02"]
    assert record(box)["lastAttempt"]["result"] == "failed, rolled back"


@needs_ssh_keygen
def test_a_failed_release_is_not_tried_again_but_a_newer_one_is(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.01")
    assert update.run(box) == 0
    publisher.release("v2026.10.02", fail=True)
    assert update.run(box) == 1
    before = ran(tmp_path)

    assert update.run(box) == 0
    assert ran(tmp_path) == before

    publisher.release("v2026.10.02.2")
    assert update.run(box) == 0
    assert in_use(box) == "releases/v2026.10.02.2"
    assert record(box)["previous"] == "v2026.10.01"


@needs_ssh_keygen
def test_a_first_release_that_fails_leaves_nothing_in_use(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.01", fail=True)

    assert update.run(box) == 1

    assert not box.current.exists()
    assert ran(tmp_path) == ["converge v2026.10.01 under the lock"]
    assert record(box)["lastAttempt"]["result"] == "failed, nothing to roll back to"


@needs_ssh_keygen
def test_old_releases_are_removed_but_the_newest_three_stay(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    for day in range(1, 7):
        publisher.release(f"v2026.10.0{day}")
        assert update.run(box) == 0

    kept = sorted(path.name for path in box.releases.iterdir())
    assert kept == ["v2026.10.04", "v2026.10.05", "v2026.10.06"]
    assert record(box)["previous"] == "v2026.10.05"


@needs_ssh_keygen
def test_a_rollout_in_progress_holds_the_update_off(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.01")
    box.lock.parent.mkdir(parents=True, exist_ok=True)
    with open(box.lock, "w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)

        assert update.run(box) == update.BUSY

    assert not box.current.exists()
    assert ran(tmp_path) == []


@needs_ssh_keygen
def test_a_dry_run_says_what_it_would_install_and_installs_nothing(
    tmp_path: Path, publisher: Publisher, box: Box, capsys: pytest.CaptureFixture[str]
) -> None:
    commit = publisher.release("v2026.10.01")

    assert update.run(box, dry_run=True) == 0

    assert f"v2026.10.01 ({commit}) would be installed over nothing" in capsys.readouterr().out
    assert not box.current.exists()
    assert not box.releases.exists()
    assert ran(tmp_path) == []


@needs_ssh_keygen
def test_a_converged_release_replaces_the_updater_the_timer_runs(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.01")
    marked = (ROOT / "scripts" / "household-update.py").read_text() + "\n# the next version\n"
    (publisher.source / "scripts").mkdir(exist_ok=True)
    publisher.release("v2026.10.02")
    (publisher.source / "scripts" / "household-update.py").write_text(marked)
    publisher.git("add", "--all")
    publisher.git("commit", "--quiet", "-m", "the updater changes")
    publisher.git(
        "-c",
        "gpg.format=ssh",
        "-c",
        "gpg.ssh.program=ssh-keygen",
        "-c",
        f"user.signingkey={publisher.root / 'publisher'}",
        "tag",
        "-s",
        "v2026.10.03",
        "-m",
        "v2026.10.03",
    )

    assert update.run(box) == 0

    copy = box.updater / "household-update.py"
    assert copy.read_text() == marked
    assert copy.stat().st_mode & 0o777 == 0o755


@needs_ssh_keygen
def test_a_symlink_in_place_of_a_gateway_config_is_never_followed(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    publisher.release("v2026.10.01")
    assert update.run(box) == 0
    secret = tmp_path / "root-only"
    secret.write_text("a root secret", encoding="utf-8")
    config = box.state_root / "openclaw-ada" / "openclaw.json"
    config.parent.mkdir(parents=True)
    config.symlink_to(secret)
    publisher.release("v2026.10.02", fail=True)

    assert update.run(box) == 1

    snapshots = box.snapshots
    assert all("a root secret" not in path.read_text() for path in snapshots.iterdir())
    assert config.read_text() != "a root secret"


@needs_ssh_keygen
def test_install_puts_the_signers_mirror_updater_and_timer_in_place(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    assert box.signers.read_text() == publisher.signers.read_text()
    remote = subprocess.run(
        ["git", f"--git-dir={box.mirror}", "remote", "get-url", "origin"],
        env=GIT_ENVIRONMENT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    assert remote == str(publisher.source)
    assert (box.updater / "household-update.py").is_file()
    assert (box.updater / "household_file.py").is_file()
    for unit in update.UNIT_NAMES:
        assert (box.units / unit).read_text() == (UNITS / unit).read_text()
    assert (tmp_path / "systemctl.log").read_text().splitlines() == [
        "daemon-reload",
        "enable --now household-update.timer",
    ]


@needs_ssh_keygen
def test_install_refuses_signers_that_trust_nothing_or_others_without_being_told(
    tmp_path: Path, publisher: Publisher, box: Box
) -> None:
    empty = tmp_path / "empty_signers"
    empty.write_text("# nobody yet\n", encoding="utf-8")
    other = tmp_path / "other_signers"
    stranger = (publisher.root / "stranger.pub").read_text(encoding="utf-8")
    other.write_text(f"stranger@example.com {stranger}", encoding="utf-8")

    assert update.install(box, remote=str(publisher.source), signers=empty) == 1
    assert update.install(box, remote=str(publisher.source), signers=other) == 1
    assert box.signers.read_text() == publisher.signers.read_text()

    assert (
        update.install(box, remote=str(publisher.source), signers=other, replace_signers=True) == 0
    )
    assert box.signers.read_text() == other.read_text()


def test_status_reads_the_record_without_touching_the_box(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    the_box = update.Box(app=tmp_path / "opt", state_root=tmp_path / "var")
    the_box.record_file.parent.mkdir(parents=True)
    the_box.record_file.write_text(
        json.dumps(
            {
                "current": "v2026.10.01",
                "failed": ["v2026.10.02"],
                "lastAttempt": {
                    "tag": "v2026.10.02",
                    "at": "then",
                    "result": "failed, rolled back",
                },
            }
        )
    )

    assert update.main(["status"], box=the_box) == 0

    said = capsys.readouterr().out
    assert "in use: v2026.10.01" in said
    assert "last attempt: v2026.10.02 at then: failed, rolled back" in said
    assert "never tried again: v2026.10.02" in said
    assert sorted(path.name for path in tmp_path.rglob("*")) == ["state.json", "update", "var"]


@pytest.mark.parametrize(
    ("tag", "expected"),
    [
        ("v2026.10.24", (2026, 10, 24, 0)),
        ("v2026.10.24.2", (2026, 10, 24, 2)),
        ("v2026.10.24.0", None),
        ("2026.10.24", None),
        ("v2026.10.24-rc1", None),
        ("v1.2.3", None),
    ],
)
def test_only_release_tags_name_releases(tag: str, expected: object) -> None:
    assert update.version(tag) == expected


def test_the_timer_runs_the_installed_updater_nightly_and_a_busy_box_is_no_failure() -> None:
    service = configparser.ConfigParser(interpolation=None, strict=False)
    service.read(UNITS / "household-update.service")
    timer = configparser.ConfigParser(interpolation=None, strict=False)
    timer.read(UNITS / "household-update.timer")

    assert service["Service"]["Type"] == "oneshot"
    assert service["Service"]["ExecStart"] == (
        "/usr/bin/python3 /opt/household-assistant/update/household-update.py run"
    )
    assert service["Service"]["SuccessExitStatus"] == str(update.BUSY)
    assert timer["Timer"]["Persistent"] == "true"
    assert timer["Timer"]["RandomizedDelaySec"]
    assert timer["Timer"]["Unit"] == "household-update.service"
    assert update.Box().updater == Path("/opt/household-assistant/update")
