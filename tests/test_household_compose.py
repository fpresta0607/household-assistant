"""A household's compose file, written from its household file.

Every household but the first runs the compose file scripts/household-compose.py writes,
so what keeps the first household's gateways private and apart has to hold in it too:
the same image, hardening and loopback ports, and each gateway mounting only the other's
family-room share, read-only.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from household_file import load_household  # noqa: E402

PINNED = ROOT / "deploy" / "openclaw" / "docker-compose.yml"
EXAMPLE = ROOT / "deploy" / "household.example.json"
NEW_EXAMPLE = ROOT / "deploy" / "household.new.example.json"
SAME = (
    *("image", "environment", "ports", "cap_drop", "security_opt", "init", "command"),
    *("healthcheck", "logging", "restart", "container_name", "env_file"),
)


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "household_compose", ROOT / "scripts" / "household-compose.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


household_compose = load_script()


def written(path: Path) -> dict[str, Any]:
    text = household_compose.rendered(load_household(path), household_compose.pinned_image())
    loaded: dict[str, Any] = yaml.safe_load(text)
    return loaded


def test_the_first_households_gateways_come_out_as_the_repository_holds_them() -> None:
    pinned = yaml.safe_load(PINNED.read_text(encoding="utf-8"))["services"]
    services = written(EXAMPLE)["services"]

    assert sorted(services) == ["openclaw-denise", "openclaw-gateway"]
    for name, service in services.items():
        held = pinned[name]
        for key in SAME:
            assert service[key] == held[key], (name, key)
        # Gia's mailbox is the one mount only the first household's box has.
        assert set(service["volumes"]) <= set(held["volumes"]), name
        assert (
            service["deploy"]["resources"]["limits"]["memory"]
            == held["deploy"]["resources"]["limits"]["memory"]
        )


def test_a_new_household_gets_a_gateway_for_each_member_on_its_own_clock() -> None:
    compose = written(NEW_EXAMPLE)
    services = compose["services"]

    assert sorted(services) == ["openclaw-ada", "openclaw-rex"]
    ada, rex = services["openclaw-ada"], services["openclaw-rex"]
    assert ada["ports"] == ["127.0.0.1:18789:18789"]
    assert rex["ports"] == ["127.0.0.1:18790:18789"]
    assert ada["env_file"] == ["/etc/household-assistant/openclaw-ada.env"]
    assert ada["environment"]["TZ"] == "America/New_York"
    assert "/var/lib/household-assistant/codex-ada:/home/node/.codex" in ada["volumes"]
    assert ada["deploy"]["resources"]["limits"]["memory"] == "1536M"
    assert compose["networks"]["household"]["ipam"]["config"] == [
        {"subnet": household_compose.GATEWAY_SUBNET, "gateway": household_compose.GATEWAY_BRIDGE}
    ]


@pytest.mark.parametrize("example", [EXAMPLE, NEW_EXAMPLE])
def test_each_gateway_mounts_only_the_others_share_read_only(example: Path) -> None:
    household = load_household(example)
    services = written(example)["services"]
    first, second = household.members

    for member, peer in ((first, second), (second, first)):
        mounts = [volume.split(":") for volume in services[member.container]["volumes"]]
        of_peer = [m for m in mounts if Path(m[0]).is_relative_to(peer.state_dir)]
        assert of_peer == [
            [str(peer.state_dir / "household-app" / "share"), "/opt/household-peer", "ro"]
        ]
        assert ["/opt/household-assistant/plugins", "/opt/household-plugins", "ro"] in mounts


def test_the_image_is_the_one_the_first_household_pins(tmp_path: Path) -> None:
    assert household_compose.pinned_image().startswith("openclaw/openclaw:")
    two = tmp_path / "compose.yml"
    two.write_text(
        "services:\n"
        "  a:\n    image: openclaw/openclaw:1@sha256:" + "a" * 64 + "\n"
        "  b:\n    image: openclaw/openclaw:2@sha256:" + "b" * 64 + "\n",
        encoding="utf-8",
    )
    with pytest.raises(household_compose.ComposeError, match="exactly one"):
        household_compose.pinned_image(two)


def test_a_file_without_members_is_refused(tmp_path: Path) -> None:
    data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    del data["members"]
    path = tmp_path / "household.json"
    path.write_text(json.dumps(data), encoding="utf-8")

    assert household_compose.main(["--household", str(path)]) == 2


def test_the_file_reads_back_as_what_was_meant() -> None:
    household = load_household(NEW_EXAMPLE)
    image = household_compose.pinned_image()
    text = household_compose.rendered(household, image)

    assert yaml.safe_load(text) == household_compose.compose(household, image)
    assert '\n  openclaw-ada:\n    image: "openclaw/openclaw:' in text
    assert '\n          memory: "1536M"\n' in text


def test_check_says_whether_the_box_runs_the_households_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert household_compose.main(["--household", str(NEW_EXAMPLE)]) == 0
    text = capsys.readouterr().out
    deployed = tmp_path / "docker-compose.yml"
    deployed.write_text(text, encoding="utf-8")

    assert household_compose.main(["--household", str(NEW_EXAMPLE), "--check", str(deployed)]) == 0
    deployed.write_text(text.replace("1536M", "4096M"), encoding="utf-8")
    assert household_compose.main(["--household", str(NEW_EXAMPLE), "--check", str(deployed)]) == 1
