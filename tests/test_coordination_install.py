"""The deployment artefacts, run and parsed rather than read for the right words.

The install script must never write the box's `docker-compose.yml` or either env
file, and must never reach a container: those are changed deliberately, on their own,
and never as a side effect of a feature landing. So the script is run for real here,
against a throwaway tree, with `docker` and `systemctl` on PATH as recorders, and
what it actually touched is what is asserted.

The compose file must put both gateways on Central. That one is not cosmetic. With
`TZ=UTC` Corey wrote a seven o'clock concert onto the shared calendar at breakfast
time and had to correct itself in the group, in front of both of them.
"""

from __future__ import annotations

import configparser
import importlib.util
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest
import yaml

from household.coordination import TURN_CAP
from household.family_room import DELIVERY_TIMEOUT_SECONDS as FAMILY_ROOM_DELIVERY_SECONDS
from household.openclaw import DELIVERY_ACK_SECONDS, TRANSPORT_TIMEOUT_SECONDS
from tests.capabilities import needs_posix_bash

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "scripts" / "coordination-install.sh"
COMPOSE = ROOT / "deploy" / "openclaw" / "docker-compose.yml"
UNIT = ROOT / "deploy" / "coordination" / "household-coordination@.service"
TICK_TIMER = ROOT / "deploy" / "coordination" / "household-coordination@tick.timer"
PLAN_TIMER = ROOT / "deploy" / "coordination" / "household-coordination@plan.timer"

SHARED_CONFIGURATION = (
    Path("/opt/household-assistant/docker-compose.yml"),
    Path("/etc/household-assistant/openclaw.env"),
    Path("/etc/household-assistant/openclaw-denise.env"),
)

RECORDED = ("docker", "systemctl", "chown")
# Everything the script writes with, recorded rather than run, for the cases that must
# install nothing at all. A regression in the guard then shows up as a recorded line
# here rather than as an `rm -rf` under /opt/household-assistant on somebody's box.
RECORDED_INSTEAD_OF_RUN = ("install", "cp", "rm", "chown", "systemctl")


def bash_or_skip() -> str:
    bash = shutil.which("bash")
    if bash is None:
        pytest.skip("no bash on this machine")
    return bash


def recorders(tmp_path: Path, commands: tuple[str, ...]) -> tuple[Path, Path]:
    """Stubs on PATH that write down their arguments instead of doing anything."""
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


def record_install_rejecting_numeric_ownership(stubs: Path, log: Path, bash: str) -> None:
    install = subprocess.run(
        [bash, "-c", "command -v install"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    stub = stubs / "install"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        f'printf "install %s\\n" "$*" >> "{log.as_posix()}"\n'
        'for argument in "$@"; do\n'
        '  case "$argument" in\n'
        '    -o|-g) echo "install: invalid user: 1000" >&2; exit 1 ;;\n'
        "  esac\n"
        "done\n"
        f'exec "{install}" "$@"\n',
        encoding="utf-8",
    )
    stub.chmod(0o755)


def environment_for(stubs: Path, *, target: str, state: str, units: str) -> dict[str, str]:
    """All three roots, always set explicitly: no case here may fall back to the box."""
    environment = dict(os.environ)
    environment["PATH"] = os.pathsep.join([stubs.as_posix(), environment["PATH"]])
    environment["COORDINATION_TARGET"] = target
    environment["COORDINATION_STATE"] = state
    environment["COORDINATION_UNITS"] = units
    return environment


@pytest.fixture
def installed(tmp_path: Path) -> tuple[Path, Path]:
    """Run the real script against a throwaway tree. Returns its roots and its log."""
    bash = bash_or_skip()
    probe = (tmp_path / "probe").as_posix()
    if subprocess.run([bash, "-c", f'install -d -m 0700 "{probe}"'], check=False).returncode:
        pytest.skip("this filesystem carries no POSIX modes, so the install script cannot run")

    stubs, log = recorders(tmp_path, RECORDED)
    record_install_rejecting_numeric_ownership(stubs, log, bash)
    root = tmp_path / "box"
    environment = environment_for(
        stubs,
        target=(root / "opt/coordination").as_posix(),
        state=(root / "var").as_posix(),
        units=(root / "units").as_posix(),
    )
    calendar_reader = root / "var/openclaw/workspace/skills/apple-cal-anywhere/scripts/applecal.py"
    calendar_reader.parent.mkdir(parents=True)
    calendar_reader.write_text("#!/usr/bin/env python3\n", encoding="utf-8")

    subprocess.run([bash, INSTALL.as_posix()], check=True, env=environment, cwd=tmp_path)
    return root, log


@needs_posix_bash
def test_the_install_script_lands_the_code_the_skill_and_the_units(
    installed: tuple[Path, Path],
) -> None:
    root, log = installed

    assert (root / "opt/coordination/coordination-daemon.py").is_file()
    assert (root / "opt/coordination/gateway_config.py").is_file()
    assert (root / "opt/coordination/household/coordination.py").is_file()
    assert (root / "opt/coordination/calendar/applecal.py").read_text(encoding="utf-8") == (
        "#!/usr/bin/env python3\n"
    )
    invocations = log.read_text(encoding="utf-8").splitlines()
    calendar_chown = (
        "chown root:root "
        f"{(root / 'opt/coordination/calendar').as_posix()} "
        f"{(root / 'opt/coordination/calendar/applecal.py').as_posix()}"
    )
    assert calendar_chown in invocations
    assert (root / "var/coordination").is_dir()
    for workspace in ("openclaw", "openclaw-denise"):
        skill = root / "var" / workspace / "workspace" / "skills" / "coordinate"
        outbox = root / "var" / workspace / "workspace" / "coordination-outbox"
        assert (skill / "SKILL.md").is_file()
        assert (skill / "coordinate.py").is_file()
        assert outbox.is_dir()
        assert (skill.stat().st_mode & 0o777) == 0o755
        assert ((skill / "SKILL.md").stat().st_mode & 0o777) == 0o644
        assert ((skill / "coordinate.py").stat().st_mode & 0o777) == 0o755
        assert (outbox.stat().st_mode & 0o777) == 0o755
        assert [
            "chown",
            "1000:1000",
            skill.as_posix(),
            (skill / "SKILL.md").as_posix(),
            (skill / "coordinate.py").as_posix(),
            outbox.as_posix(),
        ] in [shlex.split(line) for line in invocations]
    for unit in ("@.service", "@tick.timer", "@plan.timer"):
        assert (root / "units" / f"household-coordination{unit}").is_file()


@needs_posix_bash
def test_the_install_script_writes_nothing_outside_its_own_roots(
    installed: tuple[Path, Path],
) -> None:
    root, _ = installed

    stray = [path for path in SHARED_CONFIGURATION if path.exists()]
    assert stray == []
    assert sorted(child.name for child in root.iterdir()) == ["opt", "units", "var"]


@needs_posix_bash
def test_the_install_script_touches_no_container(installed: tuple[Path, Path]) -> None:
    """Nothing it runs reaches docker at all, so no evening can end because of it."""
    _, log = installed

    invocations = log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    assert [line for line in invocations if line.startswith("docker")] == []
    assert [line for line in invocations if line.startswith("systemctl")] != []


@needs_posix_bash
def test_the_install_script_enables_only_the_tick_timer(
    installed: tuple[Path, Path],
) -> None:
    """Guard that the first proactive planner run goes to the CFO, not the family group.

    The plan timer stays disabled at install, and this assertion is what holds it.
    """
    _, log = installed

    invocations = log.read_text(encoding="utf-8").splitlines()
    enabled = [line for line in invocations if line.startswith("systemctl enable")]

    assert enabled == ["systemctl enable --now household-coordination@tick.timer"]


@pytest.mark.parametrize("root", ["", "relative/coordination", "~/coordination"])
@needs_posix_bash
def test_a_root_that_is_not_an_absolute_path_installs_nothing(root: str, tmp_path: Path) -> None:
    """`rm -rf` runs under these, so a stray value in the operator's shell must stop it.

    The empty one is the case that matters most: a default substituting on empty as
    well as on unset would turn a blank root into the real production path.
    """
    bash = bash_or_skip()
    stubs, log = recorders(tmp_path, RECORDED_INSTEAD_OF_RUN)
    environment = environment_for(
        stubs,
        target=root,
        state=(tmp_path / "var").as_posix(),
        units=(tmp_path / "units").as_posix(),
    )

    refused = subprocess.run(
        [bash, INSTALL.as_posix()],
        check=False,
        capture_output=True,
        text=True,
        cwd=tmp_path,
        env=environment,
    )

    assert refused.returncode == 2
    # Named, because a refusal for some other reason would let the empty case pass
    # while the empty root itself had quietly become /opt/household-assistant.
    assert f"refusing to install: '{root}' is not an absolute path" in refused.stderr
    assert not log.exists()
    assert not (tmp_path / "var").exists()
    assert not (tmp_path / "units").exists()


def test_both_gateways_run_on_the_household_clock() -> None:
    services = yaml.safe_load(COMPOSE.read_text(encoding="utf-8"))["services"]

    assert services["openclaw-gateway"]["environment"]["TZ"] == "America/Chicago"
    assert services["openclaw-denise"]["environment"]["TZ"] == "America/Chicago"


@pytest.mark.parametrize(
    ("service", "state"),
    [
        ("openclaw-gateway", "/var/lib/household-assistant/openclaw"),
        ("openclaw-denise", "/var/lib/household-assistant/openclaw-denise"),
    ],
)
def test_each_gateway_keeps_its_own_google_sign_ins_under_its_own_state(
    service: str, state: str
) -> None:
    """Gia's Google account sits in Denise's state, never beside Franco's in Corey's."""
    gateway = yaml.safe_load(COMPOSE.read_text(encoding="utf-8"))["services"][service]

    assert gateway["environment"]["GOG_HOME"] == "/home/node/.openclaw/gog"
    assert gateway["environment"]["GOG_KEYRING_BACKEND"] == "file"
    assert f"{state}:/home/node/.openclaw" in gateway["volumes"]


def test_the_unit_outlives_the_work_it_supervises() -> None:
    """The comment beside TimeoutStartSec is arithmetic, so it is checked as arithmetic.

    Type=oneshot means TimeoutStartSec covers the whole ExecStart, and both instances
    of the template share it, so it has to clear the slower one. A plan run waits on
    the calendar read, the research turn, the group post and the delivery ack in
    series. At 900 it did not clear them, and systemd killed the weekly run and marked
    the unit failed. Changing any one of those four should turn this red rather than
    quietly reintroducing that.
    """
    daemon = load_daemon()
    plan_worst_case = (
        daemon.CALENDAR_TIMEOUT_SECONDS
        + daemon.RESEARCH_TIMEOUT_SECONDS
        + TRANSPORT_TIMEOUT_SECONDS
        + DELIVERY_ACK_SECONDS
    )
    tick_worst_case = (
        len(daemon.ASSISTANTS) * TURN_CAP * (TRANSPORT_TIMEOUT_SECONDS + DELIVERY_ACK_SECONDS)
        + len(daemon.ASSISTANTS) * (len(daemon.ASSISTANTS) - 1) * FAMILY_ROOM_DELIVERY_SECONDS
    )
    unit = configparser.ConfigParser(interpolation=None, strict=False)
    unit.read(UNIT, encoding="utf-8")
    declared = unit.getint("Service", "TimeoutStartSec")

    assert declared >= plan_worst_case
    assert declared > tick_worst_case


def test_instances_have_only_timer_activation_paths() -> None:
    service = configparser.ConfigParser(interpolation=None, strict=False)
    service.read(UNIT, encoding="utf-8")

    assert not service.has_section("Install")
    for timer_path in (TICK_TIMER, PLAN_TIMER):
        timer = configparser.ConfigParser(interpolation=None, strict=False)
        timer.read(timer_path, encoding="utf-8")
        assert timer.get("Install", "WantedBy") == "timers.target"


def test_the_planner_skips_a_missed_week() -> None:
    timer = configparser.ConfigParser(interpolation=None, strict=False)
    timer.read(PLAN_TIMER, encoding="utf-8")

    assert timer.getboolean("Timer", "Persistent", fallback=False) is False


def test_coordination_yields_to_the_primary_host_workload() -> None:
    service = configparser.ConfigParser(interpolation=None, strict=False)
    service.read(UNIT, encoding="utf-8")

    assert service.getint("Service", "Nice") == 10


def load_daemon() -> ModuleType:
    if str(ROOT / "scripts") not in sys.path:
        sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location(
        "coordination_daemon_for_timeouts", ROOT / "scripts" / "coordination-daemon.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("dangerous", ["/", "/tmp/..", "//"])
@needs_posix_bash
def test_the_installer_refuses_a_root_that_resolves_to_the_filesystem_root(
    tmp_path: Path, dangerous: str
) -> None:
    """A leading slash is not a guard, and this script runs `rm -rf` under these roots.

    With `COORDINATION_TARGET=/` the old check passed and the script would have run
    `rm -rf //household` and then scanned the whole filesystem deleting `__pycache__`.
    The refusal has to name the value it refused, because the override exists so tests
    can redirect the roots and that is exactly how a wrong one arrives.
    """
    bash = bash_or_skip()
    stubs, _ = recorders(tmp_path, RECORDED)
    # The guard loop runs before the script writes anything, and the target is checked
    # first, so the other two roots only have to get past the guard. They are named
    # rather than built from tmp_path because a Windows tmp_path is not an absolute
    # POSIX path, which would refuse on the wrong root and pass this test for the
    # wrong reason.
    environment = environment_for(
        stubs,
        target=dangerous,
        state="/var/lib/household-assistant-guard-test",
        units="/etc/systemd/household-assistant-guard-test",
    )

    completed = subprocess.run(
        [bash, INSTALL.as_posix()],
        check=False,
        env=environment,
        cwd=tmp_path,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 2
    assert dangerous in completed.stderr
    assert "refusing to install" in completed.stderr
