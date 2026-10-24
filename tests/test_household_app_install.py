"""household-app-install.sh, run for real against a throwaway tree.

It must put the relay, the plugin and the units in place and start the relay, and
nothing else: no container, no compose file, no env file and no gateway config. Naming
the plugin in a gateway's config is openclaw-household-app.py's job, one gateway at a
time, so installing never changes what either gateway does.
"""

from __future__ import annotations

import configparser
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.capabilities import needs_posix_bash

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "scripts" / "household-app-install.sh"
UNITS = ROOT / "deploy" / "household-app"

pytestmark = needs_posix_bash


def recorders(tmp_path: Path, commands: tuple[str, ...]) -> tuple[Path, Path]:
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    log = tmp_path / "invocations.log"
    for command in commands:
        stub = stubs / command
        stub.write_text(
            f'#!/usr/bin/env bash\nprintf "{command} %s\\n" "$*" >> "{log.as_posix()}"\n',
            encoding="utf-8",
        )
        stub.chmod(0o755)
    return stubs, log


def run_install(
    tmp_path: Path, **roots: str
) -> tuple[subprocess.CompletedProcess[str], Path, dict[str, Path]]:
    bash = shutil.which("bash")
    assert bash is not None
    stubs, log = recorders(tmp_path, ("docker", "systemctl", "chown"))
    paths = {
        "HOUSEHOLD_APP_TARGET": tmp_path / "opt" / "household-assistant" / "app-relay",
        "HOUSEHOLD_APP_PLUGINS": tmp_path / "opt" / "household-assistant" / "plugins",
        "HOUSEHOLD_APP_STATE": tmp_path / "var" / "lib" / "household-assistant",
        "HOUSEHOLD_APP_UNITS": tmp_path / "etc" / "systemd" / "system",
    }
    environment = {
        "PATH": f"{stubs}:/usr/bin:/bin",
        **{name: str(path) for name, path in paths.items()},
        **roots,
    }
    completed = subprocess.run(
        [bash, str(INSTALL)],
        env=environment,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    return completed, log, paths


def test_it_installs_the_spend_job_the_plugin_and_the_units_and_starts_them(
    tmp_path: Path,
) -> None:
    completed, log, paths = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr

    target = paths["HOUSEHOLD_APP_TARGET"]
    assert (target / "household-spend.py").read_bytes() == (
        ROOT / "scripts" / "household-spend.py"
    ).read_bytes()
    assert (target / "gateway_config.py").exists()
    plugin = paths["HOUSEHOLD_APP_PLUGINS"] / "household-app"
    for name in (
        "index.js",
        "cards.js",
        "room.js",
        "store.js",
        "media.js",
        "push.js",
        "signature.js",
        "share.js",
        "peer-link.js",
        "spend.js",
        "spend-in.mjs",
        "openclaw.plugin.json",
    ):
        assert (plugin / name).exists(), name
    for unit in ("household-spend.service", "household-spend.timer"):
        assert (paths["HOUSEHOLD_APP_UNITS"] / unit).read_bytes() == (UNITS / unit).read_bytes()
    assert (paths["HOUSEHOLD_APP_STATE"] / "coordination").is_dir()

    calls = log.read_text(encoding="utf-8").splitlines()
    assert "systemctl daemon-reload" in calls
    assert "systemctl enable --now household-spend.timer" in calls
    assert not [call for call in calls if call.startswith("docker")], (
        "installing never reaches a container"
    )


def test_it_leaves_the_other_household_plugins_alone(tmp_path: Path) -> None:
    plugins = tmp_path / "opt" / "household-assistant" / "plugins"
    (plugins / "pocket-piggies-corey").mkdir(parents=True)
    (plugins / "pocket-piggies-corey" / "index.mjs").write_text("kept", encoding="utf-8")
    (plugins / "household-speech").mkdir()
    (plugins / "household-speech" / "index.js").write_text("the deployed version", encoding="utf-8")
    completed, _, _ = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr
    assert (plugins / "pocket-piggies-corey" / "index.mjs").read_text(encoding="utf-8") == "kept"
    assert (plugins / "household-speech" / "index.js").read_text(
        encoding="utf-8"
    ) == "the deployed version"


def test_it_replaces_an_older_copy_of_its_own_plugin_whole(tmp_path: Path) -> None:
    plugins = tmp_path / "opt" / "household-assistant" / "plugins"
    (plugins / "household-app").mkdir(parents=True)
    (plugins / "household-app" / "dropped.js").write_text("from an older version", encoding="utf-8")
    completed, _, _ = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr
    assert not (plugins / "household-app" / "dropped.js").exists()


@pytest.mark.parametrize("root", ["relative/path", "/", "//", "/tmp/.."])
def test_it_refuses_a_root_it_could_not_safely_replace_under(tmp_path: Path, root: str) -> None:
    completed, log, _ = run_install(tmp_path, HOUSEHOLD_APP_PLUGINS=root)
    assert completed.returncode == 2
    assert not log.exists() or "systemctl" not in log.read_text(encoding="utf-8")


def test_the_host_relay_that_the_share_replaced_is_taken_away(tmp_path: Path) -> None:
    """Until the gateways read each other's share, a host relay carried the family room."""
    units = tmp_path / "etc" / "systemd" / "system"
    units.mkdir(parents=True)
    for unit in (
        "household-app-relay.service",
        "household-app-relay.path",
        "household-app-relay.timer",
    ):
        (units / unit).write_text("[Unit]\n", encoding="utf-8")
    target = tmp_path / "opt" / "household-assistant" / "app-relay"
    target.mkdir(parents=True)
    (target / "household-app-relay.py").write_text("old", encoding="utf-8")

    completed, log, paths = run_install(tmp_path)

    assert completed.returncode == 0, completed.stderr
    assert sorted(path.name for path in paths["HOUSEHOLD_APP_UNITS"].iterdir()) == [
        "household-spend.service",
        "household-spend.timer",
    ]
    assert not (paths["HOUSEHOLD_APP_TARGET"] / "household-app-relay.py").exists()
    calls = log.read_text(encoding="utf-8").splitlines()
    assert calls.index(
        "systemctl disable --now household-app-relay.path household-app-relay.timer"
        " household-app-relay.service"
    ) < calls.index("systemctl daemon-reload")


def test_the_spend_job_runs_the_installed_script_every_ten_minutes_on_the_clock() -> None:
    service = configparser.ConfigParser(strict=False, interpolation=None)
    service.read(UNITS / "household-spend.service", encoding="utf-8")
    assert service["Service"]["ExecStart"] == (
        "/usr/bin/python3 /opt/household-assistant/app-relay/household-spend.py tick"
    )
    assert service["Service"]["Type"] == "oneshot"
    timer = configparser.ConfigParser(strict=False, interpolation=None)
    timer.read(UNITS / "household-spend.timer", encoding="utf-8")
    assert timer["Timer"]["OnCalendar"] == "*:0/10"
    assert timer["Timer"]["Unit"] == "household-spend.service"
