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
    "household-push-key.py",
    "scripture-build.py",
    "openclaw-openrouter.py",
    "openclaw-memory.py",
    "openclaw-household-app.py",
    "openclaw-scripture.py",
    "openclaw-speech.py",
    "openclaw-pictures.py",
    "openclaw-box.py",
)


def executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def box(
    tmp_path: Path, *, keys: bool = True, failing: str = "", certificates: bool = True
) -> dict[str, str]:
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
    executable(shim / "systemctl", f'#!/bin/sh\necho "systemctl $*" >> "{log}"\n')
    # What `tailscale status --json` says of the box's certificates, which serve needs.
    domains = '["box.tail1234.ts.net"]' if certificates else "null"
    executable(
        shim / "tailscale",
        "#!/bin/sh\n"
        f'if [ "$*" = "status --json" ]; then echo \'{{"CertDomains": {domains}}}\'; exit 0; fi\n'
        f'echo "tailscale $*" >> "{log}"\n',
    )

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
    assert steps[:5] == [
        "household-push-key.py",
        "openclaw-install.sh",
        f"scripture-build.py --embed --env-file {env_file}",
        "openclaw-openrouter.py apply",
        "household-app-install.sh",
    ]
    for persona in ("ada", "rex"):
        for script in PY_STEPS[3:]:
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
    # The first household's file, which names no members and so no approver of its own.
    del data["members"]
    del data["approver"]
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


def test_a_household_without_a_push_relay_makes_no_key(tmp_path: Path) -> None:
    env = box(tmp_path)
    data = json.loads(NEW_EXAMPLE.read_text(encoding="utf-8"))
    del data["pushRelay"]
    household = tmp_path / "household.json"
    household.write_text(json.dumps(data), encoding="utf-8")
    env["HOUSEHOLD_FILE"] = household.as_posix()

    assert converge(tmp_path, env).returncode == 0
    assert not any(line.startswith("household-push-key.py") for line in logged(tmp_path))


def test_a_tailnet_without_https_certificates_stops_it_before_serve_waits(tmp_path: Path) -> None:
    result = converge(tmp_path, box(tmp_path, certificates=False))

    assert result.returncode == 1
    assert "HTTPS Certificates" in result.stderr
    assert not any(line.startswith("tailscale serve") for line in logged(tmp_path))


def test_a_household_file_that_cannot_be_read_changes_nothing(tmp_path: Path) -> None:
    env = box(tmp_path)
    broken = tmp_path / "household.json"
    broken.write_text("{not json", encoding="utf-8")
    env["HOUSEHOLD_FILE"] = broken.as_posix()

    result = converge(tmp_path, env)

    assert result.returncode == 1
    assert "cannot be read" in result.stderr
    assert "first household" not in result.stderr
    assert logged(tmp_path) == []


def test_each_gateway_gets_a_token_and_a_keyring_password_of_its_own(tmp_path: Path) -> None:
    """Without GOG_KEYRING_PASSWORD no connector can be signed in to from the app
    (household-app's sealed-file.js), and one shared between the gateways would hand each
    assistant the key to the other person's sign-ins. The install's own section runs here,
    against scratch env files, one already holding a token and an OpenRouter key."""
    bash = shutil.which("bash")
    assert bash is not None
    script = (ROOT / "scripts" / "openclaw-install.sh").read_text(encoding="utf-8")
    section = script[script.index("# --- gateway token") : script.index("# --- image")]
    first, second = tmp_path / "openclaw-ada.env", tmp_path / "openclaw-rex.env"
    first.write_text("OPENROUTER_API_KEY=sk-or-x\nOPENCLAW_GATEWAY_TOKEN=kept\n", encoding="utf-8")
    members = "\n".join(
        f"p\t{name}\tc\ts\t1\t/s\t{path}\t/x\t/y\t/z"
        for name, path in (("ada", first), ("rex", second))
    )
    subprocess.run(
        [bash, "-c", f"set -euo pipefail\nmembers=$'{members}'\n{section}"],
        capture_output=True,
        text=True,
        check=True,
    )

    def values(path: Path) -> dict[str, str]:
        lines = path.read_text(encoding="utf-8").splitlines()
        return dict(line.split("=", 1) for line in lines)

    ada, rex = values(first), values(second)
    assert ada["OPENCLAW_GATEWAY_TOKEN"] == "kept" and ada["OPENROUTER_API_KEY"] == "sk-or-x"
    assert len(ada["GOG_KEYRING_PASSWORD"]) == 64 and len(rex["OPENCLAW_GATEWAY_TOKEN"]) == 64
    assert ada["GOG_KEYRING_PASSWORD"] != rex["GOG_KEYRING_PASSWORD"]
    assert stat.S_IMODE(first.stat().st_mode) == 0o600
    # A second run changes nothing.
    before = first.read_text(encoding="utf-8")
    subprocess.run(
        [bash, "-c", f"set -euo pipefail\nmembers=$'{members}'\n{section}"],
        capture_output=True,
        text=True,
        check=True,
    )
    assert first.read_text(encoding="utf-8") == before
