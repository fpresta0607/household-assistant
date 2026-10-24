"""household-push-key.py: the household's own key for the publisher's push relay.

Made with the real openssl into throwaway env files, as on the box: once, the same in
both gateways' env files, owner-only, never printed, and never replacing a key a gateway
already has.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "household-push-key.py"
NEW_EXAMPLE = ROOT / "deploy" / "household.new.example.json"
ED25519_HEADER = bytes.fromhex("302a300506032b6570032100")

pytestmark = pytest.mark.skipif(
    shutil.which("openssl") is None or os.name != "posix",
    reason="needs openssl and POSIX file modes, as the box has; CI on Linux runs it",
)


@pytest.fixture(scope="module")
def keys() -> ModuleType:
    spec = importlib.util.spec_from_file_location("household_push_key", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["household_push_key"] = module
    spec.loader.exec_module(module)
    return module


def env_files(tmp_path: Path, *contents: str) -> list[Path]:
    files = []
    for index, content in enumerate(contents):
        path = tmp_path / f"openclaw-{index}.env"
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600)
        files.append(path)
    return files


def held(path: Path) -> list[str]:
    return [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.startswith("HOUSEHOLD_PUSH_RELAY_KEY=")
    ]


def test_one_key_is_made_and_written_into_both_env_files_owner_only(
    keys: ModuleType, tmp_path: Path
) -> None:
    files = env_files(tmp_path, "OPENCLAW_GATEWAY_TOKEN=one\n", "OPENCLAW_GATEWAY_TOKEN=two")

    public, written = keys.install_key(files)

    assert written == files
    first, second = (held(path) for path in files)
    assert first == second and len(first) == 1
    assert first[0].startswith("HOUSEHOLD_PUSH_RELAY_KEY=-----BEGIN PRIVATE KEY-----\\n")
    assert "\n" not in first[0]
    assert files[0].read_text(encoding="utf-8").startswith("OPENCLAW_GATEWAY_TOKEN=one\n")
    assert files[1].read_text(encoding="utf-8").startswith("OPENCLAW_GATEWAY_TOKEN=two\n")
    for path in files:
        assert path.stat().st_mode & 0o777 == 0o600
    der = base64.b64decode(public)
    assert len(der) == 44 and der.startswith(ED25519_HEADER)
    assert not list(tmp_path.glob(".*.tmp"))


def test_the_public_half_is_the_key_the_gateways_hold(keys: ModuleType, tmp_path: Path) -> None:
    files = env_files(tmp_path, "", "")
    public, _ = keys.install_key(files)
    pem = held(files[0])[0].split("=", 1)[1].replace("\\n", "\n") + "\n"
    derived = subprocess.run(
        ["openssl", "pkey", "-pubout", "-outform", "DER"],
        input=pem.encode("ascii"),
        capture_output=True,
        check=True,
    ).stdout
    assert base64.b64encode(derived).decode("ascii") == public


def test_a_key_a_gateway_has_is_kept_and_given_to_the_other(
    keys: ModuleType, tmp_path: Path
) -> None:
    first = env_files(tmp_path, "", "")
    public, _ = keys.install_key(first[:1])
    kept = held(first[0])

    again, written = keys.install_key(first)

    assert again == public
    assert written == [first[1]]
    assert held(first[0]) == held(first[1]) == kept


def test_running_it_again_changes_nothing(keys: ModuleType, tmp_path: Path) -> None:
    files = env_files(tmp_path, "", "")
    public, _ = keys.install_key(files)
    before = [path.read_bytes() for path in files]

    assert keys.install_key(files) == (public, [])
    assert [path.read_bytes() for path in files] == before


def test_two_different_keys_are_refused_and_neither_is_changed(
    keys: ModuleType, tmp_path: Path
) -> None:
    one, two = env_files(tmp_path, "", "")
    keys.install_key([one])
    keys.install_key([two])
    before = [one.read_bytes(), two.read_bytes()]

    with pytest.raises(keys.PushKeyRefused, match="different"):
        keys.install_key([one, two])
    assert [one.read_bytes(), two.read_bytes()] == before


@pytest.mark.parametrize(
    ("content", "message"),
    [
        ("HOUSEHOLD_PUSH_RELAY_KEY=\n", "nothing in it"),
        ("HOUSEHOLD_PUSH_RELAY_KEY=a\nHOUSEHOLD_PUSH_RELAY_KEY=b\n", "twice"),
        ("HOUSEHOLD_PUSH_RELAY_KEY=not-a-key\n", None),
    ],
)
def test_a_key_line_that_is_not_one_key_is_refused(
    keys: ModuleType, tmp_path: Path, content: str, message: str | None
) -> None:
    (path,) = env_files(tmp_path, content)
    with pytest.raises((keys.PushKeyRefused, subprocess.CalledProcessError), match=message):
        keys.install_key([path])
    assert path.read_text(encoding="utf-8") == content


def test_a_gateway_without_its_env_file_yet_is_refused(keys: ModuleType, tmp_path: Path) -> None:
    with pytest.raises(keys.PushKeyRefused, match=r"openclaw-install\.sh"):
        keys.install_key([tmp_path / "openclaw-ada.env"])


def as_box(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, data: dict[str, Any]) -> list[Path]:
    import household_file

    household = tmp_path / "household.json"
    household.write_text(json.dumps(data), encoding="utf-8")
    monkeypatch.setattr(household_file, "HOUSEHOLD_FILE", household)
    monkeypatch.setattr(household_file, "ENV_ROOT", tmp_path)
    files = [tmp_path / "openclaw-ada.env", tmp_path / "openclaw-rex.env"]
    for path in files:
        path.write_text("OPENCLAW_GATEWAY_TOKEN=x\n", encoding="utf-8")
        path.chmod(0o600)
    return files


def test_it_prints_the_line_for_the_publisher_and_never_the_private_key(
    keys: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    files = as_box(monkeypatch, tmp_path, json.loads(NEW_EXAMPLE.read_text(encoding="utf-8")))

    assert keys.main([], is_root=lambda: True) == 0

    out = capsys.readouterr()
    assert "PRIVATE" not in out.out + out.err
    line = next(line.strip() for line in out.out.splitlines() if "household marina-steve" in line)
    assert line.startswith("household marina-steve key MCowBQYDK2VwAyEA")
    assert "scripts/openclaw-install.sh" in out.out
    assert held(files[0]) == held(files[1])

    assert keys.main([], is_root=lambda: True) == 0
    again = capsys.readouterr().out
    assert line in again
    assert "already hold" in again
    assert "openclaw-install.sh" not in again


def test_it_needs_root_and_a_relay_in_the_household_file(
    keys: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    data = json.loads(NEW_EXAMPLE.read_text(encoding="utf-8"))
    files = as_box(monkeypatch, tmp_path, data)
    assert keys.main([], is_root=lambda: False) == 1
    assert "run as root" in capsys.readouterr().err

    del data["pushRelay"]
    as_box(monkeypatch, tmp_path, data)
    assert keys.main([], is_root=lambda: True) == 1
    assert "names no pushRelay" in capsys.readouterr().err
    assert held(files[0]) == []
