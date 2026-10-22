"""scripts/home-install.py against temporary directories and a fake host, never the box."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
from pathlib import Path
from types import ModuleType

import pytest
import yaml

from tests.capabilities import needs_getuid, needs_nofollow_open

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "eyJhbGciOiJIUzI1NiJ9.assistants-token-body.signature"
WHEEL = b"a pip wheel"


def installer() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "home_install", ROOT / "scripts" / "home-install.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeHost:
    """Records system commands and answers `id` for the key holder's user."""

    def __init__(self, *, has_user: bool = False, state: str = "active") -> None:
        self.has_user = has_user
        self.state = state
        self.commands: list[list[str]] = []

    def __call__(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        self.commands.append(command)
        if command[:2] in (["id", "-u"], ["id", "-g"]):
            ids = f"{os.getuid() if command[1] == '-u' else os.getgid()}\n"
            return subprocess.CompletedProcess(command, 0 if self.has_user else 1, ids, "")
        if command[0] == "useradd":
            self.has_user = True
        if command[:2] == ["systemctl", "is-active"]:
            return subprocess.CompletedProcess(command, 0, f"{self.state}\n", "")
        return subprocess.CompletedProcess(command, 0, "", "")


THERMOSTAT = "climate.thermostat"
SPOTIFY = "media_player.spotify_household"


def config(module: ModuleType) -> dict[str, object]:
    result: dict[str, object] = module.config_for(
        "100.64.0.20", 49153, "Living Room", THERMOSTAT, SPOTIFY
    )
    return result


@pytest.mark.parametrize(
    ("address", "port", "name", "thermostat", "spotify"),
    [
        ("192.168.1.20", 49153, "Living Room", THERMOSTAT, SPOTIFY),
        ("the-tv.local", 49153, "Living Room", THERMOSTAT, SPOTIFY),
        ("100.64.0.20", 0, "Living Room", THERMOSTAT, SPOTIFY),
        ("100.64.0.20", 70000, "Living Room", THERMOSTAT, SPOTIFY),
        ("100.64.0.20", 49153, "", THERMOSTAT, SPOTIFY),
        ("100.64.0.20", 49153, "Living\nRoom", THERMOSTAT, SPOTIFY),
        ("100.64.0.20", 49153, "Living Room", "", SPOTIFY),
        ("100.64.0.20", 49153, "Living Room", "media_player.thermostat", SPOTIFY),
        ("100.64.0.20", 49153, "Living Room", THERMOSTAT, "climate.spotify"),
        ("100.64.0.20", 49153, "Living Room", THERMOSTAT, "media_player.Spotify Room"),
    ],
)
def test_a_tv_off_the_tailnet_a_bad_name_or_a_bad_entity_is_refused(
    address: str, port: int, name: str, thermostat: str, spotify: str
) -> None:
    with pytest.raises(ValueError):
        installer().config_for(address, port, name, thermostat, spotify)


def test_the_config_is_the_one_the_key_holder_reads() -> None:
    module = installer()
    assert config(module) == {
        "hass": "http://127.0.0.1:8123",
        "entities": {
            "thermostat": "climate.thermostat",
            "spotify": "media_player.spotify_household",
            "tv_spotify_name": "Living Room",
        },
        "tv": {"address": "100.64.0.20", "port": 49153},
    }


@pytest.mark.parametrize(
    "text", ["", "   \n", "two\nlines-of-token-text-here", "short", "a b " * 10]
)
def test_anything_but_one_token_on_stdin_is_refused(text: str) -> None:
    with pytest.raises(ValueError):
        installer().read_token(text)


def test_the_token_is_read_without_its_newline() -> None:
    assert installer().read_token(TOKEN + "\n") == TOKEN


def test_home_assistant_install_keeps_configuration_and_is_repeatable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "chown", lambda path, uid, gid: None, raising=False)
    monkeypatch.setattr(module.os, "fchmod", lambda descriptor, mode: None, raising=False)
    if not hasattr(module.os, "O_NOFOLLOW"):
        monkeypatch.setattr(module.os, "O_NOFOLLOW", 0, raising=False)
    configuration = tmp_path / "configuration.yaml"
    configuration.write_text("default_config:\nscript: !include scripts.yaml\n", encoding="utf-8")

    module.install_home_assistant(tmp_path)
    first = configuration.read_bytes()
    module.install_home_assistant(tmp_path)

    assert configuration.read_bytes() == first
    parsed = yaml.compose(configuration.read_text(encoding="utf-8"))
    assert isinstance(parsed, yaml.MappingNode)
    assert [key.value for key, _ in parsed.value] == ["default_config", "script", "household_home"]
    component = tmp_path / "custom_components/household_home"
    assert json.loads((component / "manifest.json").read_text())["dependencies"] == ["spotify"]
    assert (component / "__init__.py").read_bytes() == (
        ROOT / "deploy/homeassistant/custom_components/household_home/__init__.py"
    ).read_bytes()


def installed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    token: str | None = TOKEN,
    host: FakeHost | None = None,
) -> tuple[ModuleType, FakeHost, str]:
    module = installer()
    monkeypatch.setattr(module, "PIP_SHA256", hashlib.sha256(WHEEL).hexdigest())
    monkeypatch.setattr(module.os, "chown", lambda path, uid, gid: None)
    host = host or FakeHost()
    (tmp_path / "gateways" / "openclaw").mkdir(parents=True, exist_ok=True)
    (tmp_path / "units").mkdir(exist_ok=True)
    state = module.install(
        "corey",
        config(module),
        token,
        code_root=tmp_path / "code",
        state_root=tmp_path / "state",
        gateway_root=tmp_path / "gateways",
        units=tmp_path / "units",
        run=host,
        fetch=lambda url: WHEEL,
    )
    return module, host, state


@needs_nofollow_open
@needs_getuid
def test_install_puts_everything_in_place_and_reads_the_unit_back(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _, host, state = installed(tmp_path, monkeypatch)

    assert state == "active"
    code = tmp_path / "code"
    assert sorted(path.name for path in (code / "household" / "home").iterdir()) == [
        "__init__.py",
        "actions.py",
        "apple_tv.py",
        "hass.py",
        "server.py",
    ]
    assert (code / "home-keyholder.py").stat().st_mode & 0o777 == 0o755
    assert (code / "requirements.txt").read_bytes() == (
        ROOT / "deploy" / "home" / "requirements.txt"
    ).read_bytes()
    assert (
        (tmp_path / "units" / "household-home@.service").read_text().startswith("# One assistant")
    )
    drop_in = (tmp_path / "units" / "household-home@corey.service.d" / "gateway.conf").read_text()
    assert (
        f"BindPaths={tmp_path / 'gateways' / 'openclaw' / 'home'}:/run/household-home\n" in drop_in
    )
    sockets = tmp_path / "gateways" / "openclaw" / "home"
    assert sockets.stat().st_mode & 0o7777 == 0o2750
    holder = tmp_path / "state" / "corey"
    assert holder.stat().st_mode & 0o777 == 0o700
    assert json.loads((holder / "config.json").read_text()) == config(installer())
    assert (holder / "token").read_text() == TOKEN + "\n"
    assert all((holder / name).stat().st_mode & 0o777 == 0o600 for name in ("config.json", "token"))
    assert not (holder / "apple-tv-credentials").exists()

    assert [command[0] for command in host.commands if command[0] == "useradd"] == ["useradd"]
    assert host.commands[-1] == ["systemctl", "is-active", "household-home@corey.service"]
    systemctl = [command for command in host.commands if command[0] == "systemctl"]
    assert systemctl[:3] == [
        ["systemctl", "daemon-reload"],
        ["systemctl", "enable", "household-home@corey.service"],
        ["systemctl", "restart", "household-home@corey.service"],
    ]
    pip = next(command for command in host.commands if "install" in command)
    assert pip[0] == str(code / "venv" / "bin" / "python")
    assert pip[1].endswith("pip-26.2.1-py3-none-any.whl/pip")
    assert {"--require-hashes", "--no-deps", ":all:"} <= set(pip)
    assert ["python3", "-m", "venv", "--without-pip", str(code / "venv")] in host.commands


@needs_nofollow_open
@needs_getuid
def test_a_reinstall_keeps_the_token_and_the_first_install_needs_one(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    with pytest.raises(ValueError, match="token"):
        installed(tmp_path, monkeypatch, token=None)
    assert not (tmp_path / "code").exists()

    installed(tmp_path, monkeypatch)
    _, host, _ = installed(tmp_path, monkeypatch, token=None, host=FakeHost(has_user=True))

    assert (tmp_path / "state" / "corey" / "token").read_text() == TOKEN + "\n"
    assert not [command for command in host.commands if command[0] == "useradd"]


@needs_nofollow_open
@needs_getuid
def test_a_pip_wheel_that_does_not_match_its_hash_installs_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "chown", lambda path, uid, gid: None)
    host = FakeHost()
    with pytest.raises(ValueError, match="hash"):
        module.install_code(tmp_path / "code", run=host, fetch=lambda url: b"something else")
    assert not (tmp_path / "code").exists()
    assert host.commands == []


@needs_nofollow_open
@needs_getuid
@pytest.mark.parametrize("planted", ["symlink", "file"])
def test_a_socket_directory_the_gateway_planted_is_refused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, planted: str
) -> None:
    gateway = tmp_path / "gateways" / "openclaw"
    gateway.mkdir(parents=True)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    if planted == "symlink":
        (gateway / "home").symlink_to(elsewhere, target_is_directory=True)
    else:
        (gateway / "home").write_text("not a directory")
    with pytest.raises(ValueError):
        installed(tmp_path, monkeypatch)
    assert elsewhere.stat().st_mode & 0o7777 != 0o2750


def test_each_gateway_binds_only_its_own_state() -> None:
    module = installer()
    assert module.GATEWAYS == {"corey": "openclaw", "denise": "openclaw-denise"}


def test_the_pin_is_read_once_and_only_as_four_digits(tmp_path: Path) -> None:
    module = installer()
    (tmp_path / "pin").write_text("4821\n")
    assert module.wait_for_pin(tmp_path, seconds=1, wait=lambda seconds: None) == "4821"
    assert not (tmp_path / "pin").exists()
    (tmp_path / "pin").write_text("48; rm -rf /")
    assert module.wait_for_pin(tmp_path, seconds=1, wait=lambda seconds: None) is None


def test_no_pin_in_time_is_no_pairing(tmp_path: Path) -> None:
    waited: list[float] = []
    assert installer().wait_for_pin(tmp_path, seconds=3, wait=waited.append) is None
    assert waited == [1, 1, 1]


@needs_nofollow_open
@needs_getuid
def test_the_pairing_goes_to_each_installed_key_holder_and_restarts_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module, _, _ = installed(tmp_path, monkeypatch)
    host = FakeHost(has_user=True)

    saved = module.save_pairing("the-pairing", state_root=tmp_path / "state", run=host)

    assert saved == ["corey"]
    pairing = tmp_path / "state" / "corey" / "apple-tv-credentials"
    assert pairing.read_text() == "the-pairing\n"
    assert pairing.stat().st_mode & 0o777 == 0o600
    assert ["systemctl", "restart", "household-home@corey.service"] in host.commands
    assert not (tmp_path / "state" / "denise").exists()
