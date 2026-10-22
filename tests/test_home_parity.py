"""Corey and Denise get the same home controls from every script that gives a gateway its tools.

PocketPiggies' installer writes The Fam's tool allowlist, the household-app policy hands the
plugin's tools to the owner's own thread and copies The Fam's list into the family room,
and home-install.py gives each gateway a key holder of its own. Both gateways are built here
the way those scripts build them on the box, from the same config, so a home tool, a
family-room tool or a key holder one assistant has and the other lacks fails here. The
plugin's side, the same tool and the same key holder calls for both owners, is in
tests/js/household_app_home.test.mjs.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
HOME_TOOL = "household_home"
THE_FAM = "-5100000001"
TELEGRAM_OWNER = "123456"


def load(name: str, path: Path) -> ModuleType:
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def scripts() -> dict[str, ModuleType]:
    return {
        "app": load("openclaw_household_app", SCRIPTS / "openclaw-household-app.py"),
        "pocket": load("pocket_piggies_install", SCRIPTS / "pocket-piggies-install.py"),
        "home": load("home_install", SCRIPTS / "home-install.py"),
        "gateways": load("gateway_config", SCRIPTS / "gateway_config.py"),
    }


def on_the_box() -> dict[str, Any]:
    """Either gateway before the household's scripts, with no secrets in it."""
    return {
        "commands": {"ownerAllowFrom": [f"telegram:{TELEGRAM_OWNER}"]},
        "channels": {
            "telegram": {
                "groupPolicy": "allowlist",
                "groups": {THE_FAM: {"requireMention": True, "allowFrom": [TELEGRAM_OWNER]}},
            }
        },
        "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
        "tools": {"profile": "coding", "alsoAllow": ["speak", "family_history"]},
        "plugins": {"entries": {"household-speech": {"enabled": True}}},
    }


def tools_of(scripts: dict[str, ModuleType], persona: str) -> dict[str, list[str]]:
    """The tools each kind of turn gets on one gateway once the scripts have run."""
    app, pocket, patched = scripts["app"], scripts["pocket"], scripts["gateways"].patched
    gateways = scripts["gateways"].GATEWAYS
    gateway = next(each for each in gateways if each.persona == persona)
    peer = next(each for each in gateways if each.persona != persona)
    config = pocket.configured(on_the_box(), persona, TELEGRAM_OWNER)
    config = patched(config, app.plugin_patch(config))
    config = patched(
        config,
        app.channel_patch(config, gateway, peer, owner_keys=[], peer_keys=[], peer_identity={}),
    )
    assert app.problems(config, gateway) == []
    return {
        "owner's own thread": config["tools"]["alsoAllow"],
        "The Fam": config["channels"]["telegram"]["groups"][THE_FAM]["tools"]["allow"],
        "family room": config["channels"]["household"]["familyTools"],
    }


def test_corey_and_denise_hand_every_kind_of_turn_the_same_tools(
    scripts: dict[str, ModuleType],
) -> None:
    corey = tools_of(scripts, "corey")
    denise = tools_of(scripts, "denise")
    assert denise == corey
    assert all(HOME_TOOL in tools for tools in corey.values())


def test_every_gateway_has_a_key_holder_bound_to_its_own_state(
    scripts: dict[str, ModuleType],
) -> None:
    gateways = scripts["gateways"].GATEWAYS
    key_holders = scripts["home"].GATEWAYS
    assert set(key_holders) == {gateway.persona for gateway in gateways}
    for gateway in gateways:
        assert key_holders[gateway.persona] == gateway.state.name
