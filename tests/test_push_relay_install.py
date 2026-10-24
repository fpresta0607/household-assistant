"""push-relay-install.sh, run for real against a throwaway tree, and the relay's unit.

The installer puts the relay's code where its unit runs it, in the repository's own
layout, makes its settings without ever writing the Apple key, and starts the relay only
once the key is in the env file. The unit keeps the relay from writing anything of the
publisher's box.
"""

from __future__ import annotations

import configparser
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.capabilities import needs_posix_bash

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "scripts" / "push-relay-install.sh"
UNIT = ROOT / "deploy" / "push-relay" / "push-relay.service"

pytestmark = needs_posix_bash


def run_install(
    tmp_path: Path, *, node: str | None = None, env_text: str | None = None
) -> tuple[subprocess.CompletedProcess[str], Path, dict[str, Path]]:
    bash = shutil.which("bash")
    assert bash is not None
    stubs = tmp_path / "stubs"
    stubs.mkdir(exist_ok=True)
    log = tmp_path / "invocations.log"
    stub = stubs / "systemctl"
    stub.write_text(
        f'#!/usr/bin/env bash\nprintf "systemctl %s\\n" "$*" >> "{log.as_posix()}"\n',
        encoding="utf-8",
    )
    stub.chmod(0o755)
    paths = {
        "PUSH_RELAY_CODE": tmp_path / "opt" / "push-relay" / "release",
        "PUSH_RELAY_ETC": tmp_path / "etc" / "push-relay",
        "PUSH_RELAY_UNITS": tmp_path / "etc" / "systemd" / "system",
    }
    if env_text is not None:
        paths["PUSH_RELAY_ETC"].mkdir(parents=True, exist_ok=True)
        (paths["PUSH_RELAY_ETC"] / "push-relay.env").write_text(env_text, encoding="utf-8")
    real_node = node if node is not None else shutil.which("node")
    if real_node is None:
        pytest.skip("node is not installed")
    environment = {
        "PATH": f"{stubs}:/usr/bin:/bin",
        "PUSH_RELAY_NODE": real_node,
        **{name: str(path) for name, path in paths.items()},
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


def node_major() -> int:
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is not installed")
    found = subprocess.run(
        [node, "-p", "process.versions.node.split('.')[0]"],
        capture_output=True,
        text=True,
        check=True,
    )
    return int(found.stdout.strip())


def test_it_installs_the_code_and_settings_and_waits_for_the_key(tmp_path: Path) -> None:
    if node_major() < 22:
        pytest.skip("the relay wants node 22 or newer")
    completed, log, paths = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr

    code = paths["PUSH_RELAY_CODE"]
    for name in ("relay.mjs", "server.mjs", "admin.mjs"):
        assert (code / "deploy" / "push-relay" / name).read_bytes() == (
            ROOT / "deploy" / "push-relay" / name
        ).read_bytes()
    apple = code / "deploy" / "openclaw" / "plugins" / "household-app" / "apple-push.js"
    assert apple.read_bytes() == (ROOT / apple.relative_to(code)).read_bytes()
    etc = paths["PUSH_RELAY_ETC"]
    assert (etc / "push-relay.env").stat().st_mode & 0o777 == 0o600
    assert (etc / "households.json").read_text(encoding="utf-8") == '{\n  "households": {}\n}\n'
    assert (etc / "households.json").stat().st_mode & 0o777 == 0o644
    assert (paths["PUSH_RELAY_UNITS"] / "push-relay.service").read_bytes() == UNIT.read_bytes()
    assert log.read_text(encoding="utf-8").splitlines() == ["systemctl daemon-reload"]
    assert "not started" in completed.stdout


def test_with_the_key_in_place_it_starts_the_relay_and_keeps_the_settings(
    tmp_path: Path,
) -> None:
    if node_major() < 22:
        pytest.skip("the relay wants node 22 or newer")
    # The marker in two parts, so the repository's check for a committed key block passes.
    settings = (
        "APNS_KEY_ID=K\nAPNS_PRIVATE_KEY=-----BEGIN " + "PRIVATE KEY-----\\nMIGT\\n-----END\n"
    )
    completed, log, paths = run_install(tmp_path, env_text=settings)
    assert completed.returncode == 0, completed.stderr

    assert (paths["PUSH_RELAY_ETC"] / "push-relay.env").read_text(encoding="utf-8") == settings
    assert log.read_text(encoding="utf-8").splitlines() == [
        "systemctl daemon-reload",
        "systemctl enable push-relay.service",
        "systemctl restart push-relay.service",
    ]


def test_the_relays_code_runs_where_it_is_installed(tmp_path: Path) -> None:
    """The import of apple-push.js resolves in the installed tree, as in the repository."""
    if node_major() < 22:
        pytest.skip("the relay wants node 22 or newer")
    completed, _, paths = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr
    node = shutil.which("node")
    assert node is not None
    server = paths["PUSH_RELAY_CODE"] / "deploy" / "push-relay" / "server.mjs"
    loaded = subprocess.run(
        [
            node,
            "--input-type=module",
            "--eval",
            "const m = await import(process.argv[1]); console.log(typeof m.createRelayServer);",
            server.as_uri(),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert loaded.returncode == 0, loaded.stderr
    assert loaded.stdout.strip() == "function"


def test_an_old_node_is_refused_before_anything_is_written(tmp_path: Path) -> None:
    old = tmp_path / "old-node"
    old.write_text("#!/usr/bin/env bash\necho 18\n", encoding="utf-8")
    old.chmod(0o755)
    completed, _, paths = run_install(tmp_path, node=str(old))
    assert completed.returncode == 1
    assert "Node 22 or newer" in completed.stderr
    assert not paths["PUSH_RELAY_CODE"].exists()


@pytest.mark.parametrize("root", ["", "relative/path", "/", "/opt"])
def test_a_root_it_could_not_safely_replace_is_refused(tmp_path: Path, root: str) -> None:
    bash = shutil.which("bash")
    assert bash is not None
    completed = subprocess.run(
        [bash, str(INSTALL)],
        env={"PATH": "/usr/bin:/bin", "PUSH_RELAY_CODE": root},
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert completed.returncode == 2
    assert "refusing to install" in completed.stderr


def test_the_unit_runs_the_relay_as_nobody_with_nothing_it_may_write() -> None:
    unit = configparser.ConfigParser(strict=False, interpolation=None)
    unit.optionxform = str  # type: ignore[assignment,method-assign]
    unit.read_string(UNIT.read_text(encoding="utf-8"))
    service = unit["Service"]
    server = "/opt/push-relay/release/deploy/push-relay/server.mjs"
    assert service["ExecStart"] == f"/usr/bin/node {server}"
    assert service["EnvironmentFile"] == "/etc/push-relay/push-relay.env"
    for key, value in {
        "DynamicUser": "yes",
        "NoNewPrivileges": "yes",
        "ProtectSystem": "strict",
        "ProtectHome": "yes",
        "PrivateTmp": "yes",
        "CapabilityBoundingSet": "",
    }.items():
        assert service[key] == value, key
    assert unit["Install"]["WantedBy"] == "multi-user.target"
