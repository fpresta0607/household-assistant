"""household-converge.sh brings a household's box to a checkout and proves it.

Each case runs the real script from a scratch copy of scripts/ whose every step is a stub
that records how it was called, against a scratch household file, env files and state,
with `tailscale` and `systemctl` stubbed on PATH. What is asserted is the order of the
steps, what each is handed, and that a failed step or gateway fails the pass, which is the
verdict household-update.py rolls a release back on.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from tests.capabilities import needs_posix_bash

pytestmark = needs_posix_bash

ROOT = Path(__file__).resolve().parent.parent
NEW_EXAMPLE = ROOT / "deploy" / "household.new.example.json"
STEPS = (
    "openclaw-install.sh",
    "household-app-install.sh",
    "openclaw-verify.sh",
    "household-backup.sh",
    "household-restore-drill.sh",
    "household-backup-lib.sh",
)
PY_STEPS = (
    "scripture-build.py",
    "openclaw-openrouter.py",
    "openclaw-memory.py",
    "openclaw-household-app.py",
    "openclaw-scripture.py",
    "openclaw-speech.py",
    "openclaw-pictures.py",
    "openclaw-tailnet.py",
)


def executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def box(tmp_path: Path, *, keys: bool = True, failing: str = "") -> dict[str, str]:
    scripts = tmp_path / "release" / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy(ROOT / "scripts" / "household-converge.sh", scripts)
    shutil.copy(ROOT / "scripts" / "household_file.py", scripts)
    log = tmp_path / "log"
    record = f'echo "$(basename "$0") $* CT=${{CT:-}} WORLD=${{WORLD_PORTS-unset}}" >> "{log}"\n'
    for name in STEPS:
        # The verifier fails Rex's gateway alone; any other step fails outright.
        fail = ""
        if failing == name:
            fail = 'if [ "${CT:-openclaw-rex}" = "openclaw-rex" ]; then exit 1; fi\n'
        executable(scripts / name, f"#!/bin/sh\n{record}{fail}")
    for name in PY_STEPS:
        fail = "raise SystemExit(1)\n" if failing == name else ""
        executable(
            scripts / name,
            "import os, sys\n"
            f"open({str(log)!r}, 'a').write(os.path.basename(sys.argv[0]) + ' ' + "
            "' '.join(sys.argv[1:]) + '\\n')\n" + fail,
        )
    deploy = tmp_path / "release" / "deploy" / "backup"
    deploy.mkdir(parents=True)
    for unit in ("household-backup.service", "household-backup.timer"):
        (deploy / unit).write_text("", encoding="utf-8")
    shim = tmp_path / "bin"
    shim.mkdir()
    for name in ("tailscale", "systemctl"):
        executable(shim / name, f'#!/bin/sh\necho "{name} $*" >> "{log}"\n')

    env_root = tmp_path / "etc"
    env_root.mkdir()
    for state in ("openclaw-ada", "openclaw-rex"):
        (env_root / f"{state}.env").write_text(
            "OPENCLAW_GATEWAY_TOKEN=x\n" + ("OPENROUTER_API_KEY=sk-or-test\n" if keys else ""),
            encoding="utf-8",
        )
    return {
        **os.environ,
        "PATH": f"{shim}{os.pathsep}{os.environ['PATH']}",
        "HOUSEHOLD_FILE": NEW_EXAMPLE.as_posix(),
        "HOUSEHOLD_ENV_ROOT": env_root.as_posix(),
        "HOUSEHOLD_STATE_ROOT": (tmp_path / "state").as_posix(),
        "HOUSEHOLD_BACKUP_DIR": (tmp_path / "backup").as_posix(),
        "HOUSEHOLD_UNITS": (tmp_path / "units").as_posix(),
    }


def converge(tmp_path: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    bash = shutil.which("bash")
    assert bash is not None
    return subprocess.run(
        [bash, (tmp_path / "release" / "scripts" / "household-converge.sh").as_posix()],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def logged(tmp_path: Path) -> list[str]:
    log = tmp_path / "log"
    return log.read_text(encoding="utf-8").splitlines() if log.exists() else []


def test_a_pass_runs_every_step_in_order_and_verifies_each_gateway(tmp_path: Path) -> None:
    result = converge(tmp_path, box(tmp_path))

    assert result.returncode == 0, result.stdout + result.stderr
    assert "HOUSEHOLD CONVERGED" in result.stdout
    steps = [line.split(" CT=")[0].strip() for line in logged(tmp_path)]
    env_file = f"{tmp_path}/etc/openclaw-ada.env"
    assert steps[:4] == [
        "openclaw-install.sh",
        f"scripture-build.py --embed --env-file {env_file}",
        "openclaw-openrouter.py apply",
        "household-app-install.sh",
    ]
    for persona in ("ada", "rex"):
        for script in PY_STEPS[2:]:
            assert f"{script} apply --gateway {persona}" in steps
    assert "tailscale serve --bg --https=18789 http://127.0.0.1:18789" in steps
    assert "tailscale serve --bg --https=18790 http://127.0.0.1:18790" in steps
    assert "systemctl enable --now household-backup.timer" in steps
    verified = [line for line in logged(tmp_path) if line.startswith("openclaw-verify.sh")]
    assert verified == [
        "openclaw-verify.sh  CT=openclaw-ada WORLD=",
        "openclaw-verify.sh  CT=openclaw-rex WORLD=",
    ]
    assert (tmp_path / "backup" / "household_file.py").is_file()


def test_a_built_bible_is_not_built_again(tmp_path: Path) -> None:
    env = box(tmp_path)
    bible = tmp_path / "state" / "scripture" / "bible.sqlite"
    bible.parent.mkdir(parents=True)
    bible.write_bytes(b"SQLite format 3\0")

    assert converge(tmp_path, env).returncode == 0
    assert not any(line.startswith("scripture-build.py") for line in logged(tmp_path))


@pytest.mark.parametrize("failing", ["openclaw-install.sh", "openclaw-household-app.py"])
def test_a_step_that_fails_stops_the_pass(tmp_path: Path, failing: str) -> None:
    result = converge(tmp_path, box(tmp_path, failing=failing))

    assert result.returncode != 0
    assert "HOUSEHOLD CONVERGED" not in result.stdout
    assert not any(line.startswith("openclaw-verify.sh") for line in logged(tmp_path))


def test_a_gateway_that_does_not_verify_fails_the_pass(tmp_path: Path) -> None:
    result = converge(tmp_path, box(tmp_path, failing="openclaw-verify.sh"))

    assert result.returncode == 1
    assert "the box did not verify" in result.stderr
    # Both gateways are still checked, so the log names every one that failed.
    assert len([line for line in logged(tmp_path) if line.startswith("openclaw-verify.sh")]) == 2


def test_a_gateway_without_an_openrouter_key_stops_it_before_anything_changes(
    tmp_path: Path,
) -> None:
    result = converge(tmp_path, box(tmp_path, keys=False))

    assert result.returncode == 1
    assert "no OpenRouter key" in result.stderr
    assert logged(tmp_path) == []


def test_the_first_households_box_is_left_to_its_rollouts_by_hand(tmp_path: Path) -> None:
    env = box(tmp_path)
    data = json.loads(NEW_EXAMPLE.read_text(encoding="utf-8"))
    del data["members"]
    legacy = tmp_path / "household.json"
    legacy.write_text(json.dumps(data), encoding="utf-8")
    env["HOUSEHOLD_FILE"] = legacy.as_posix()

    result = converge(tmp_path, env)

    assert result.returncode == 2
    assert "first household's" in result.stderr
    assert logged(tmp_path) == []


@pytest.mark.parametrize(
    "script",
    [
        "scripts/new-household.sh",
        "scripts/household-converge.sh",
        "scripts/openclaw-install.sh",
        "scripts/openclaw-verify.sh",
        "scripts/household-backup.sh",
        "scripts/household-restore-drill.sh",
        "scripts/install-household-plugins.sh",
    ],
)
def test_a_script_a_new_households_box_runs_by_its_path_is_executable_in_git(script: str) -> None:
    git = shutil.which("git")
    if git is None:
        pytest.skip("git is not installed")
    listed = subprocess.run(
        [git, "ls-files", "--stage", "--", script],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if listed.returncode != 0 or not listed.stdout.strip():
        pytest.skip("not a git checkout")
    assert listed.stdout.split()[0] == "100755", script


@pytest.mark.parametrize("script", ["scripts/new-household.sh", "scripts/household-converge.sh"])
def test_the_scripts_parse(script: str) -> None:
    bash = shutil.which("bash")
    assert bash is not None
    parsed = subprocess.run(
        [bash, "-n", (ROOT / script).as_posix()], capture_output=True, text=True, check=False
    )
    assert parsed.returncode == 0, parsed.stderr
