"""A new household's gateways get what the first household's were given by hand."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-box.py"
sys.path.insert(0, str(SCRIPT.parent))

from gateway_config import Gateway  # noqa: E402

BRIDGE = "172.31.240.1"
ORIGIN = "https://household.example.ts.net:18789"


@pytest.fixture(scope="module")
def box() -> ModuleType:
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("openclaw_box", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def gateway_in(box: ModuleType, tmp_path: Path, config: dict[str, Any]) -> Gateway:
    state = tmp_path / "openclaw"
    state.mkdir()
    (state / "openclaw.json").write_text(json.dumps(config), encoding="utf-8")
    gateway: Gateway = box.Gateway("corey", "openclaw-gateway", state, "franco")
    return gateway


class Recorder:
    def __init__(self) -> None:
        self.patches: list[tuple[dict[str, Any], bool]] = []

    def __call__(
        self, command: list[str], *, input: str, **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        dry = "--dry-run" in command
        self.patches.append((json.loads(input), dry))
        out = '{"ok": true}' if dry else ""
        return subprocess.CompletedProcess(command, 0, out, "")


def test_a_fresh_gateway_is_told_the_bridge_and_its_own_address(
    box: ModuleType, tmp_path: Path
) -> None:
    gateway = gateway_in(box, tmp_path, {"gateway": {"controlUi": {"allowedOrigins": ["x"]}}})

    assert box.box_patch(box.read_config(gateway), gateway) == {
        "gateway": {"trustedProxies": [BRIDGE], "controlUi": {"allowedOrigins": ["x", ORIGIN]}},
        "agents": {"defaults": {"heartbeat": {"every": "0m"}}},
    }


def test_a_gateway_that_takes_its_traffic_needs_nothing(box: ModuleType, tmp_path: Path) -> None:
    config = {
        "gateway": {"trustedProxies": [BRIDGE], "controlUi": {"allowedOrigins": [ORIGIN]}},
        "agents": {"defaults": {"heartbeat": {"every": "0m"}}},
    }
    gateway = gateway_in(box, tmp_path, config)

    assert box.box_patch(config, gateway) == {}
    assert box.problems(config, gateway) == []


def test_a_heartbeat_left_on_is_turned_off_and_nothing_else_is_touched(
    box: ModuleType, tmp_path: Path
) -> None:
    config = {
        "gateway": {"trustedProxies": [BRIDGE], "controlUi": {"allowedOrigins": [ORIGIN]}},
        "agents": {"defaults": {"heartbeat": {"every": "30m", "target": "last"}}},
    }
    gateway = gateway_in(box, tmp_path, config)

    assert box.problems(config, gateway) == ["the recurring heartbeat is on"]
    assert box.box_patch(config, gateway) == {
        "agents": {"defaults": {"heartbeat": {"every": "0m"}}}
    }


def test_apply_validates_saves_and_writes(box: ModuleType, tmp_path: Path) -> None:
    gateway = gateway_in(box, tmp_path, {})
    run = Recorder()

    assert box.apply([gateway], run=run, dry_run=False) == 0
    assert [dry for _, dry in run.patches] == [True, False]
    assert run.patches[1][0]["gateway"]["trustedProxies"] == [BRIDGE]
    assert list(gateway.state.glob("openclaw.json.pre-box-*"))


def test_a_dry_run_writes_nothing(box: ModuleType, tmp_path: Path) -> None:
    gateway = gateway_in(box, tmp_path, {})
    run = Recorder()

    assert box.apply([gateway], run=run, dry_run=True) == 0
    assert [dry for _, dry in run.patches] == [True]
    assert not list(gateway.state.glob("openclaw.json.pre-box-*"))


def test_the_first_households_box_is_left_as_it_was_set_by_hand(
    box: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data = json.loads((ROOT / "deploy" / "household.example.json").read_text(encoding="utf-8"))
    del data["members"]
    legacy = tmp_path / "household.json"
    legacy.write_text(json.dumps(data), encoding="utf-8")
    real = box.load_household
    monkeypatch.setattr(box, "load_household", lambda: real(legacy))
    gateway = gateway_in(box, tmp_path, {})
    run = Recorder()

    assert box.apply([gateway], run=run, dry_run=False) == 1
    assert run.patches == []
    assert box.check([gateway]) == 0


def test_each_gateway_trusts_the_host_address_of_its_own_network(box: ModuleType) -> None:
    corey, denise = box.GATEWAYS
    assert box.bridge(corey) == "172.31.240.1"
    assert box.bridge(denise) == "172.31.240.17"
