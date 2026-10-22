"""scripts/home-keyholder.py: the key holder's start, from its own state directory."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "home-keyholder.py"
CONFIG = {
    "hass": "http://127.0.0.1:8123",
    "entities": {
        "thermostat": "climate.thermostat",
        "spotify": "media_player.spotify_household",
        "tv_spotify_name": "Living Room",
    },
    "tv": {"address": "100.64.0.20", "port": 49153},
}


@pytest.fixture
def entry() -> ModuleType:
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    spec = importlib.util.spec_from_file_location("home_keyholder", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["home_keyholder"] = module
    spec.loader.exec_module(module)
    return module


def state(tmp_path: Path, config: object = CONFIG) -> Path:
    (tmp_path / "config.json").write_text(json.dumps(config), encoding="utf-8")
    (tmp_path / "token").write_text("eyJ.token.body\n", encoding="utf-8")
    (tmp_path / "apple-tv-credentials").write_text("pairing\n", encoding="utf-8")
    return tmp_path


def test_the_house_is_built_from_the_state_directory(entry: ModuleType, tmp_path: Path) -> None:
    home = entry.build_home(state(tmp_path))
    assert home.entities.thermostat == "climate.thermostat"
    assert home.entities.tv_spotify_name == "Living Room"
    assert home.hass.base == "http://127.0.0.1:8123"
    assert home.hass.token == "eyJ.token.body"
    assert home.apple_tv.address == "100.64.0.20"
    assert home.apple_tv.port == 49153
    assert home.apple_tv.credentials == "pairing"


@pytest.mark.parametrize(
    ("why", "config"),
    [
        (
            "Home Assistant is not on loopback",
            {**CONFIG, "hass": "http://homeassistant.example:8123"},
        ),
        ("an entity is missing", {**CONFIG, "entities": {"thermostat": "climate.x"}}),
        (
            "the TV port is not a port",
            {**CONFIG, "tv": {"address": "100.64.0.20", "port": "49153"}},
        ),
    ],
)
def test_a_config_that_is_wrong_stops_the_start(
    entry: ModuleType, tmp_path: Path, why: str, config: object
) -> None:
    with pytest.raises(ValueError):
        entry.build_home(state(tmp_path, config))


def test_a_missing_token_stops_the_start_without_saying_more(
    entry: ModuleType, tmp_path: Path
) -> None:
    (state(tmp_path) / "token").unlink()
    with pytest.raises(ValueError, match="token"):
        entry.build_home(tmp_path)


def test_the_house_starts_before_the_tv_is_paired(entry: ModuleType, tmp_path: Path) -> None:
    (state(tmp_path) / "apple-tv-credentials").unlink()
    home = entry.build_home(tmp_path)
    assert home.apple_tv.credentials is None
    assert home.hass.token == "eyJ.token.body"
