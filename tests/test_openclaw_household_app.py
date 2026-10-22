"""openclaw-household-app.py: the app's channel, named in one gateway's config at a time.

The first config below is the shape both gateways had on 14 October 2026, read from the
box with no secrets in it. The apply tests replace `docker exec` with a runner that
applies the patch to the file the way `openclaw config patch` does, answers
`devices list` with the gateway's paired devices, and keeps scheduled jobs the way
`automations add --declaration-key` converges them.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from tests.capabilities import needs_nofollow_open

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-household-app.py"

FINANCE = ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]
FRANCO_PHONE = "A" * 42 + "Q"
FRANCO_IPAD = "B" * 42 + "Q"
GIA_PHONE = "C" * 42 + "Q"
THE_FAM = "-5100000001"
# Google's iOS OAuth client for com.siqstack.stewardai, which Franco made on 15 October.
GOOGLE_CLIENT_ID = "123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com"
# The Fam's tool allowlist on both gateways since PocketPiggies, 13 October 2026.
THE_FAMS_TOOLS = [
    "web_search",
    "web_fetch",
    "speak",
    "family_history",
    "picture",
    "video",
]


def load(path: Path, name: str) -> ModuleType:
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def app() -> ModuleType:
    return load(SCRIPT, "openclaw_household_app")


def as_on_the_box(persona: str = "corey") -> dict[str, Any]:
    pocket = f"/opt/household-plugins/pocket-piggies-{persona}"
    return {
        "commands": {"ownerAllowFrom": ["telegram:7100000001"]},
        "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
        "channels": {
            "telegram": {
                "groups": {
                    THE_FAM: {
                        "requireMention": True,
                        "allowFrom": ["7100000001", "7100000002"],
                        "tools": {"allow": list(THE_FAMS_TOOLS)},
                    }
                }
            }
        },
        "agents": {
            "entries": {
                "main": {"identity": {"name": persona.capitalize(), "emoji": "🦉", "theme": "warm"}}
            }
        },
        "plugins": {
            "load": {
                "paths": [
                    "/opt/household-plugins/household-family-room",
                    "/opt/household-plugins/household-openrouter-video",
                    "/opt/household-plugins/household-speech",
                    pocket,
                    "/opt/household-plugins/household-memory",
                ]
            },
            "entries": {"household-speech": {"enabled": True}},
        },
    }


def paired(*devices: tuple[str, str, str]) -> dict[str, Any]:
    """`devices list --json` with (clientId, role, publicKey) rows."""
    return {
        "paired": [
            {
                "deviceId": f"device-{index}",
                "clientId": client,
                "role": role,
                "publicKey": key,
                "displayName": "Steward AI on iPhone",
                "approvedAtMs": 1792018800000,
            }
            for index, (client, role, key) in enumerate(devices)
        ],
        "pending": [],
    }


def test_the_patch_names_the_plugin_and_the_room_and_keeps_every_list(app: ModuleType) -> None:
    config = as_on_the_box()
    patch = app.household_patch(
        config,
        app.GATEWAYS[0],
        app.GATEWAYS[1],
        owner_keys=[FRANCO_PHONE],
        peer_keys=[GIA_PHONE],
        peer_identity={"name": "Denise", "emoji": "🌸"},
    )
    result = app.patched(config, patch)

    assert result["plugins"]["load"]["paths"] == [
        *config["plugins"]["load"]["paths"],
        "/opt/household-plugins/household-app",
    ]
    assert result["plugins"]["entries"]["household-app"] == {
        "enabled": True,
        "hooks": {"allowConversationAccess": True},
    }
    assert result["plugins"]["entries"]["household-speech"] == {"enabled": True}
    assert result["channels"]["household"] == {
        "enabled": True,
        "owner": {"id": "franco", "name": "Franco", "deviceKeys": [FRANCO_PHONE]},
        "assistant": {"id": "corey", "name": "Corey", "emoji": "🦉"},
        "peer": {
            "person": {"id": "gia", "name": "Gia", "deviceKeys": [GIA_PHONE]},
            "assistant": {"id": "denise", "name": "Denise"},
        },
        "phoneUrl": "wss://household.example.ts.net:18789",
        "approver": "franco",
        "talkDailyCharacters": 20000,
        "googleClientId": GOOGLE_CLIENT_ID,
        "familyTools": THE_FAMS_TOOLS,
    }
    assert result["commands"]["ownerAllowFrom"] == ["telegram:7100000001", "household:franco"]
    assert result["channels"]["telegram"] == {**config["channels"]["telegram"], "enabled": False}
    assert result["tools"] == {
        "alsoAllow": [
            "household_location",
            "household_cart",
            "household_brief",
            "household_today",
            "household_home",
            "household_react",
            "household_note",
            "household_send",
            "household_digest",
        ]
    }


def test_the_family_room_gets_the_tools_the_fam_has_on_this_gateway(app: ModuleType) -> None:
    config = as_on_the_box()
    config["channels"]["telegram"]["groups"][THE_FAM]["tools"]["allow"] = ["web_search", "speak"]
    patch = app.household_patch(
        config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    assert patch["channels"]["household"]["familyTools"] == ["web_search", "speak"]
    assert app.problems(app.patched(config, patch), app.GATEWAYS[0]) == []


def test_the_fam_is_the_group_openclaw_family_group_py_names(app: ModuleType) -> None:
    family = load(ROOT / "scripts" / "openclaw-family-group.py", "openclaw_family_group")
    assert app.FAMILY_GROUP == family.FAMILY_GROUP == THE_FAM


def _the_fam(config: dict[str, Any]) -> dict[str, Any]:
    group: dict[str, Any] = config["channels"]["telegram"]["groups"][THE_FAM]
    return group


@pytest.mark.parametrize(
    "remove",
    [
        lambda c: c["channels"].pop("telegram"),
        lambda c: c["channels"]["telegram"]["groups"].pop(THE_FAM),
        lambda c: _the_fam(c).pop("tools"),
        lambda c: _the_fam(c)["tools"].update({"allow": []}),
        lambda c: _the_fam(c)["tools"].update({"deny": ["speak"]}),
        lambda c: _the_fam(c)["tools"].update({"allow": "web_search"}),
        lambda c: _the_fam(c)["tools"].update({"allow": ["web_search", 7]}),
    ],
    ids=[
        "no telegram channel",
        "no entry for The Fam",
        "no tools",
        "an empty allowlist",
        "a deny beside the allowlist",
        "an allowlist that is not a list",
        "a name that is not a string",
    ],
)
def test_with_no_allowlist_for_the_fam_the_room_gets_none_and_check_says_so(
    app: ModuleType, remove: Callable[[dict[str, Any]], object]
) -> None:
    config = as_on_the_box()
    # A room that had a list keeps none once The Fam has none: there is one source.
    config["channels"]["household"] = {"familyTools": THE_FAMS_TOOLS}
    remove(config)
    patch = app.household_patch(
        config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    result = app.patched(config, patch)

    assert app.family_tools(config) is None
    assert "familyTools" not in result["channels"]["household"]
    assert f"The Fam ({THE_FAM}) has no tool allowlist" in "; ".join(
        app.problems(result, app.GATEWAYS[0])
    )


def test_a_room_whose_tools_are_not_the_fams_is_reported(app: ModuleType) -> None:
    config = as_on_the_box()
    patch = app.household_patch(
        config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    done = app.patched(config, patch)
    done["channels"]["household"]["familyTools"] = [*THE_FAMS_TOOLS, "exec"]
    assert app.problems(done, app.GATEWAYS[0]) == ["the family room's tools are not The Fam's"]
    del done["channels"]["household"]["familyTools"]
    assert app.problems(done, app.GATEWAYS[0]) == ["the family room's tools are not The Fam's"]


def test_the_location_tool_goes_before_the_finance_tools_so_the_guard_finds_nothing(
    app: ModuleType,
) -> None:
    installer = load(ROOT / "scripts" / "pocket-piggies-install.py", "pocket_piggies_install")
    config = as_on_the_box()
    config["channels"] = {
        "telegram": {
            "dmPolicy": "allowlist",
            "allowFrom": ["7100000001"],
            "groupPolicy": "allowlist",
        }
    }
    config["tools"] = {"alsoAllow": ["speak", "family_history"]}
    guarded = installer.configured(config, "corey", "7100000001")

    result = app.patched(guarded, app.plugin_patch(guarded))

    assert result["tools"]["alsoAllow"] == [
        "speak",
        "family_history",
        "household_location",
        "household_cart",
        "household_brief",
        "household_today",
        "household_home",
        "household_react",
        "household_note",
        "household_send",
        "household_digest",
        *FINANCE,
    ]
    assert installer.configured(result, "corey", "7100000001") == result


def test_a_gateway_without_the_apps_tools_is_told_so(app: ModuleType) -> None:
    config = as_on_the_box()
    done = app.patched(
        config,
        app.household_patch(
            config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
        ),
    )
    done["tools"]["alsoAllow"] = []
    assert app.problems(done, app.GATEWAYS[0]) == [
        "the assistant is not handed household_location",
        "the assistant is not handed household_cart",
        "the assistant is not handed household_brief",
        "the assistant is not handed household_today",
        "the assistant is not handed household_home",
        "the assistant is not handed household_react",
        "the assistant is not handed household_note",
        "the assistant is not handed household_send",
        "the assistant is not handed household_digest",
    ]


def test_a_gateway_that_has_the_location_tool_gets_the_cart_and_the_brief_beside_it(
    app: ModuleType,
) -> None:
    config = as_on_the_box()
    config["tools"] = {"alsoAllow": ["speak", "household_location"]}

    result = app.patched(config, app.plugin_patch(config))

    assert result["tools"]["alsoAllow"] == [
        "speak",
        "household_location",
        "household_cart",
        "household_brief",
        "household_today",
        "household_home",
        "household_react",
        "household_note",
        "household_send",
        "household_digest",
    ]


def test_a_gateway_that_already_follows_it_needs_nothing(app: ModuleType) -> None:
    config = as_on_the_box()
    patch = app.household_patch(
        config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    done = app.patched(config, patch)
    again = app.household_patch(
        done, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    assert app.patched(done, again) == done
    assert app.problems(done, app.GATEWAYS[0]) == []


def done_on_the_box(app: ModuleType) -> dict[str, Any]:
    config = as_on_the_box()
    done: dict[str, Any] = app.patched(
        config,
        app.household_patch(
            config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
        ),
    )
    return done


def test_a_talk_ceiling_a_person_set_stays(app: ModuleType) -> None:
    done = done_on_the_box(app)
    done["channels"]["household"]["talkDailyCharacters"] = 5000
    again = app.household_patch(
        done, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    assert app.patched(done, again)["channels"]["household"]["talkDailyCharacters"] == 5000
    assert app.problems(done, app.GATEWAYS[0]) == []


@pytest.mark.parametrize("ceiling", [None, "20000", -1, True])
def test_a_room_without_a_talk_ceiling_is_reported_and_given_one(
    app: ModuleType, ceiling: object
) -> None:
    done = done_on_the_box(app)
    if ceiling is None:
        del done["channels"]["household"]["talkDailyCharacters"]
    else:
        done["channels"]["household"]["talkDailyCharacters"] = ceiling
    assert app.problems(done, app.GATEWAYS[0]) == ["Talk has no daily ceiling"]
    again = app.household_patch(
        done, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    assert app.patched(done, again)["channels"]["household"]["talkDailyCharacters"] == 20000


@pytest.mark.parametrize("client", [None, "", "1-other.apps.googleusercontent.com"])
def test_a_room_without_the_apps_google_client_is_reported_and_given_it(
    app: ModuleType, client: object
) -> None:
    done = done_on_the_box(app)
    if client is None:
        del done["channels"]["household"]["googleClientId"]
    else:
        done["channels"]["household"]["googleClientId"] = client
    assert app.problems(done, app.GATEWAYS[0]) == [
        "Connect Google in the app is not set up on this gateway"
    ]
    again = app.household_patch(
        done, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    assert app.patched(done, again)["channels"]["household"]["googleClientId"] == GOOGLE_CLIENT_ID


def test_the_example_google_client_is_the_one_the_app_builds_with(app: ModuleType) -> None:
    """The placeholders stay one client: the household file's and the app's xcconfig's."""
    xcconfig = (ROOT / "apps" / "ios" / "Household.xcconfig").read_text(encoding="utf-8")
    found = re.search(r"^GOOGLE_IOS_CLIENT_ID = (\S+)$", xcconfig, re.MULTILINE)
    assert found is not None
    assert f"{found.group(1)}.apps.googleusercontent.com" == app.GOOGLE_CLIENT_ID


@pytest.mark.parametrize(
    "hooks",
    [
        {},
        {"allowConversationAccess": False},
        {"allowConversationAccess": True, "allowPromptInjection": False},
    ],
)
def test_a_plugin_whose_turn_hook_is_not_allowed_is_reported(
    app: ModuleType, hooks: dict[str, bool]
) -> None:
    done = done_on_the_box(app)
    done["plugins"]["entries"]["household-app"]["hooks"] = hooks
    assert app.problems(done, app.GATEWAYS[0]) == [
        "the assistant's name and manner from Settings do not reach its turns"
    ]


def test_denise_is_given_her_own_side_of_the_room(app: ModuleType) -> None:
    config = as_on_the_box("denise")
    patch = app.household_patch(
        config,
        app.GATEWAYS[1],
        app.GATEWAYS[0],
        owner_keys=[GIA_PHONE],
        peer_keys=[FRANCO_PHONE],
        peer_identity={"name": "Corey"},
    )
    room = app.patched(config, patch)["channels"]["household"]
    assert room["owner"] == {"id": "gia", "name": "Gia", "deviceKeys": [GIA_PHONE]}
    assert room["peer"]["person"] == {
        "id": "franco",
        "name": "Franco",
        "deviceKeys": [FRANCO_PHONE],
    }
    assert room["peer"]["assistant"] == {"id": "corey", "name": "Corey"}
    assert room["phoneUrl"] == "wss://household.example.ts.net:18790"
    assert room["approver"] == "franco"


def test_an_allow_list_is_merged_and_a_missing_one_is_not_created(app: ModuleType) -> None:
    config = as_on_the_box()
    assert (
        "allow"
        not in app.household_patch(
            config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
        )["plugins"]
    )
    config["plugins"]["allow"] = ["household-speech"]
    patch = app.household_patch(
        config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    assert patch["plugins"]["allow"] == ["household-speech", "household-app"]


@pytest.mark.parametrize(
    ("change", "said"),
    [
        (lambda c: c["plugins"].update({"enabled": False}), "plugins are switched off"),
        (lambda c: c["plugins"].update({"deny": ["household-app"]}), "plugins.deny blocks"),
        (lambda c: c["session"].update({"dmScope": "main"}), "one shared main session"),
        (lambda c: c["session"].update({"groupScope": "main"}), "one shared main session"),
    ],
)
def test_a_decision_someone_made_on_purpose_is_reported_and_not_undone(
    app: ModuleType, change: Callable[[dict[str, Any]], object], said: str
) -> None:
    config = as_on_the_box()
    change(config)
    with pytest.raises(app.UnsupportedConfig, match=said):
        app.refusals(config)


def test_the_owner_entry_is_added_once(app: ModuleType) -> None:
    config = as_on_the_box()
    config["commands"]["ownerAllowFrom"].append("household:franco")
    patch = app.household_patch(
        config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    assert "commands" not in patch


def test_a_gateway_with_no_owner_list_gets_one_for_this_channel_only(app: ModuleType) -> None:
    config = as_on_the_box()
    del config["commands"]
    patch = app.household_patch(
        config, app.GATEWAYS[0], app.GATEWAYS[1], owner_keys=[], peer_keys=[], peer_identity={}
    )
    assert patch["commands"] == {"ownerAllowFrom": ["household:franco"]}


def test_only_the_apps_paired_operator_phones_are_pinned(app: ModuleType) -> None:
    devices = paired(
        ("openclaw-ios", "operator", FRANCO_PHONE),
        ("openclaw-ios", "operator", FRANCO_IPAD),
        ("openclaw-tui", "operator", "D" * 42 + "Q"),
        ("openclaw-ios", "node", "E" * 42 + "Q"),
        ("openclaw-ios", "operator", "not a key"),
    )
    assert app.phone_keys(devices) == [FRANCO_PHONE, FRANCO_IPAD]


def test_what_is_pinned_is_described_without_the_keys(app: ModuleType) -> None:
    devices = paired(("openclaw-ios", "operator", FRANCO_PHONE))
    lines = app.describe_phones(devices)
    assert lines == ["device-0 Steward AI on iPhone, approved 2026-10-14"]
    assert FRANCO_PHONE not in "".join(lines)


def test_the_assistants_name_and_emoji_come_from_its_identity(app: ModuleType) -> None:
    assert app.assistant_identity(as_on_the_box(), "corey") == {"name": "Corey", "emoji": "🦉"}
    config = as_on_the_box()
    del config["agents"]
    assert app.assistant_identity(config, "corey") == {"name": "Corey"}


def _flag(command: list[str], name: str) -> str | None:
    return command[command.index(name) + 1] if name in command else None


class FakeGateways:
    """`docker exec` for both gateways.

    A config patch writes the state file, `devices list` answers from a dict, and each
    gateway's scheduler keeps its jobs: `automations add` with a declaration key creates
    the job, or brings the one with that key to what it was given but its name, and leaves
    whether it is on alone, as 2026.9.4's cron.add does, and `cron edit --name` renames one.
    """

    def __init__(
        self, app: ModuleType, gateways: tuple[Any, ...], devices: dict[str, dict[str, Any]]
    ) -> None:
        self.app = app
        self.gateways = gateways
        self.devices = devices
        self.patched: list[str] = []
        self.refuse: set[str] = set()
        self.writes: list[list[str]] = []
        self.jobs: dict[str, list[dict[str, Any]]] = {gateway.persona: [] for gateway in gateways}
        self.added: list[str] = []
        self.renamed: list[str] = []

    def scheduler(self, persona: str, command: list[str]) -> subprocess.CompletedProcess[str]:
        jobs = self.jobs[persona]
        if "list" in command:
            listed = jobs if "--all" in command else [job for job in jobs if job["enabled"]]
            # The CLI can print a line before its JSON.
            return subprocess.CompletedProcess(
                command, 0, "Automations\n" + json.dumps({"jobs": listed}), ""
            )
        key = _flag(command, "--declaration-key")
        spec: dict[str, Any] = {
            "name": _flag(command, "--name"),
            "agentId": _flag(command, "--agent"),
            "schedule": {"kind": "cron", "expr": _flag(command, "--cron")},
            "sessionTarget": _flag(command, "--session"),
            "wakeMode": "now",
            "payload": {"kind": "agentTurn", "message": _flag(command, "--message")},
            "delivery": {"mode": "none" if "--no-deliver" in command else "announce"},
        }
        if _flag(command, "--tz") is not None:
            spec["schedule"]["tz"] = _flag(command, "--tz")
        existing = next((job for job in jobs if key and job.get("declarationKey") == key), None)
        if existing is None:
            jobs.append(
                {"id": f"job-{len(jobs) + 1}", "declarationKey": key, "enabled": True, **spec}
            )
        else:
            existing.update({part: value for part, value in spec.items() if part != "name"})
        self.added.append(persona)
        return subprocess.CompletedProcess(
            command, 0, json.dumps({"created": existing is None}), ""
        )

    def __call__(self, command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        container = command[command.index("exec") + (2 if command[2] == "-i" else 1)]
        gateway = next(g for g in self.gateways if g.container == container)
        if "devices" in command:
            return subprocess.CompletedProcess(
                command, 0, json.dumps(self.devices[gateway.persona]), ""
            )
        if "automations" in command:
            return self.scheduler(gateway.persona, command)
        if "cron" in command and "edit" in command:
            job_id = command[command.index("edit") + 1]
            job = next(job for job in self.jobs[gateway.persona] if job["id"] == job_id)
            job["name"] = _flag(command, "--name")
            self.renamed.append(gateway.persona)
            return subprocess.CompletedProcess(command, 0, "{}", "")
        if "patch" in command:
            if container in self.refuse:
                return subprocess.CompletedProcess(command, 1, "", "invalid config")
            config = json.loads(gateway.config_path.read_text(encoding="utf-8"))
            patch = json.loads(str(options["input"]))
            paths = config.get("plugins", {}).get("load", {}).get("paths", [])
            if "channels" in patch and self.app.PLUGIN_PATH not in paths:
                # 2026.9.4 validates a channel against the plugins it has already loaded.
                return subprocess.CompletedProcess(
                    command, 1, "", "channels.household: unknown channel id: household"
                )
            if "--dry-run" in command:
                return subprocess.CompletedProcess(command, 0, '{"ok": true}', "")
            gateway.config_path.write_text(
                json.dumps(self.app.patched(config, patch)), encoding="utf-8"
            )
            self.writes.append(sorted(patch))
            self.patched.append(gateway.persona)
            return subprocess.CompletedProcess(command, 0, "", "")
        return subprocess.CompletedProcess(command, 0, "{}", "")


@pytest.fixture
def box(
    app: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[FakeGateways, tuple[Any, ...]]:
    installed = tmp_path / "plugins" / "household-app" / "openclaw.plugin.json"
    installed.parent.mkdir(parents=True)
    installed.write_text("{}", encoding="utf-8")
    monkeypatch.setattr(app, "PLUGIN_ON_HOST", installed)
    gateways = (
        app.Gateway("corey", "openclaw-gateway", tmp_path / "openclaw", "franco"),
        app.Gateway("denise", "openclaw-denise", tmp_path / "openclaw-denise", "gia"),
    )
    for gateway in gateways:
        gateway.state.mkdir()
        gateway.config_path.write_text(json.dumps(as_on_the_box(gateway.persona)), encoding="utf-8")
    devices = {
        "corey": paired(("openclaw-ios", "operator", FRANCO_PHONE)),
        "denise": paired(("openclaw-ios", "operator", GIA_PHONE)),
    }
    monkeypatch.setattr(app, "GATEWAYS", gateways)
    return FakeGateways(app, gateways, devices), gateways


@needs_nofollow_open
def test_apply_writes_only_the_gateway_it_is_told_and_backs_it_up_first(
    app: ModuleType, box: tuple[FakeGateways, tuple[Any, ...]]
) -> None:
    fake, gateways = box
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert set(fake.patched) == {"corey"}, "Denise's config is never written"
    corey = json.loads(gateways[0].config_path.read_text(encoding="utf-8"))
    assert corey["channels"]["household"]["owner"]["deviceKeys"] == [FRANCO_PHONE]
    assert corey["channels"]["household"]["peer"]["person"]["deviceKeys"] == [GIA_PHONE]
    assert corey["channels"]["household"]["familyTools"] == THE_FAMS_TOOLS
    assert list(gateways[0].state.glob("openclaw.json.pre-household-app-*"))
    assert json.loads(gateways[1].config_path.read_text(encoding="utf-8")) == as_on_the_box(
        "denise"
    )


@needs_nofollow_open
def test_apply_warns_when_the_fam_has_no_allowlist_and_leaves_the_room_without_tools(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake, gateways = box
    config = json.loads(gateways[0].config_path.read_text(encoding="utf-8"))
    del _the_fam(config)["tools"]
    gateways[0].config_path.write_text(json.dumps(config), encoding="utf-8")

    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    said = capsys.readouterr().out
    assert f"warning: The Fam ({THE_FAM}) has no tool allowlist here" in said
    assert "verdict: ok" not in said
    room = json.loads(gateways[0].config_path.read_text(encoding="utf-8"))["channels"]["household"]
    assert "familyTools" not in room


@needs_nofollow_open
def test_apply_loads_the_plugin_before_it_names_the_channel(
    app: ModuleType, box: tuple[FakeGateways, tuple[Any, ...]]
) -> None:
    fake, gateways = box
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert fake.writes == [["plugins", "tools"], ["channels", "commands"]]
    assert len(list(gateways[0].state.glob("openclaw.json.pre-household-app-*"))) == 1


@needs_nofollow_open
def test_a_gateway_that_has_the_plugin_gets_only_the_channel(
    app: ModuleType, box: tuple[FakeGateways, tuple[Any, ...]]
) -> None:
    fake, gateways = box
    config = json.loads(gateways[0].config_path.read_text(encoding="utf-8"))
    gateways[0].config_path.write_text(
        json.dumps(app.patched(config, app.plugin_patch(config))), encoding="utf-8"
    )
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert fake.writes == [["channels", "commands"]]


@needs_nofollow_open
def test_apply_needs_a_gateway_named(
    app: ModuleType, box: tuple[FakeGateways, tuple[Any, ...]]
) -> None:
    fake, _ = box
    with pytest.raises(SystemExit):
        app.main(["apply"], run=fake)


@needs_nofollow_open
def test_a_dry_run_validates_and_writes_nothing(
    app: ModuleType, box: tuple[FakeGateways, tuple[Any, ...]]
) -> None:
    fake, gateways = box
    assert app.main(["apply", "--gateway", "corey", "--dry-run"], run=fake) == 0
    assert fake.patched == []
    assert json.loads(gateways[0].config_path.read_text(encoding="utf-8")) == as_on_the_box("corey")


@needs_nofollow_open
def test_a_refused_patch_writes_nothing(
    app: ModuleType, box: tuple[FakeGateways, tuple[Any, ...]]
) -> None:
    fake, gateways = box
    fake.refuse.add("openclaw-gateway")
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 1
    assert json.loads(gateways[0].config_path.read_text(encoding="utf-8")) == as_on_the_box("corey")


@needs_nofollow_open
def test_apply_refuses_until_the_plugin_is_installed(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    fake, _ = box
    monkeypatch.setattr(app, "PLUGIN_ON_HOST", tmp_path / "nowhere" / "openclaw.plugin.json")
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 1
    assert fake.patched == []


@needs_nofollow_open
def test_check_and_verdict_read_each_gateway(
    app: ModuleType, box: tuple[FakeGateways, tuple[Any, ...]], capsys: pytest.CaptureFixture[str]
) -> None:
    fake, gateways = box
    assert (
        app.main(
            ["verdict", "--container", "openclaw-gateway", "--state", str(gateways[0].state)],
            run=fake,
        )
        == 0
    )
    assert "the household-app plugin is not loaded" in capsys.readouterr().out
    app.main(["apply", "--gateway", "corey"], run=fake)
    capsys.readouterr()
    app.main(
        ["verdict", "--container", "openclaw-gateway", "--state", str(gateways[0].state)], run=fake
    )
    assert capsys.readouterr().out.strip() == "ok"


def test_the_today_card_runs_quietly_morning_and_evening(app: ModuleType) -> None:
    command = app.TODAY_JOB_COMMAND
    assert command[:2] == ["automations", "add"]
    assert _flag(command, "--declaration-key") == "household-app:daily-brief"
    assert _flag(command, "--cron") == "45 4,16 * * *", (
        "ready before the first morning opening at 5 AM, and for tonight"
    )
    assert _flag(command, "--name") == "Today card"
    assert "--tz" not in command, "the gateway's own time zone, the day the plugin keeps"
    assert _flag(command, "--agent") == "main"
    assert _flag(command, "--session") == "isolated"
    assert "--no-deliver" in command
    assert not {"--announce", "--channel", "--to", "--webhook"} & set(command)
    prompt = _flag(command, "--message")
    assert prompt is not None
    for asked in (
        "calendar",
        "reminders",
        "household_today",
        "tomorrow",
        "scripture skill",
        "share with you in Steward",
        "another person's plans only",
        "Send nothing",
    ):
        assert asked in prompt
    assert ";" not in prompt


@needs_nofollow_open
def test_apply_adds_the_today_card_once_and_check_sees_it(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake, _ = box
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert fake.added == ["corey"]
    [job] = fake.jobs["corey"]
    assert job["declarationKey"] == "household-app:daily-brief"
    assert job["schedule"] == {"kind": "cron", "expr": "45 4,16 * * *"}
    assert job["delivery"] == {"mode": "none"}
    assert fake.jobs["denise"] == [], "Denise's scheduler is never written"
    capsys.readouterr()

    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert capsys.readouterr().out.strip() == "corey: nothing to write"
    assert fake.added == ["corey"], "apply again changes nothing"

    app.main(["check"], run=fake)
    said = capsys.readouterr().out
    corey, denise = said.split("denise (")
    assert "Today card  ok" in corey
    assert "Today card  missing" in denise


@needs_nofollow_open
def test_check_reads_the_channel_openclaw_fills_in_as_no_change(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake, _ = box
    app.main(["apply", "--gateway", "corey"], run=fake)
    fake.jobs["corey"][0]["delivery"]["channel"] = "last"
    capsys.readouterr()

    app.main(["check"], run=fake)
    corey, _ = capsys.readouterr().out.split("denise (")
    assert "Today card  ok" in corey
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert fake.added == ["corey"], "apply leaves a job OpenClaw stored that way alone"


@needs_nofollow_open
@pytest.mark.parametrize(
    ("change", "said"),
    [
        (lambda job: job["schedule"].update({"expr": "0 7 * * *"}), "changed: schedule"),
        (lambda job: job["schedule"].update({"tz": "UTC"}), "changed: schedule"),
        (lambda job: job.update({"delivery": {"mode": "announce"}}), "changed: delivery"),
        (
            lambda job: job["delivery"].update({"channel": "telegram", "to": "7100000001"}),
            "changed: delivery",
        ),
        (lambda job: job["payload"].update({"message": "Say hello."}), "changed: prompt"),
        (lambda job: job.update({"sessionTarget": "main"}), "changed: session"),
        (lambda job: job.update({"agentId": "ops"}), "changed: agent"),
    ],
)
def test_check_reports_a_changed_job_and_apply_puts_it_back(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
    change: Callable[[dict[str, Any]], object],
    said: str,
) -> None:
    fake, gateways = box
    for gateway in gateways:
        app.main(["apply", "--gateway", gateway.persona], run=fake)
    change(fake.jobs["corey"][0])
    capsys.readouterr()

    assert app.main(["check"], run=fake) == 1
    assert f"Today card  {said}" in capsys.readouterr().out

    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert len(fake.jobs["corey"]) == 1
    capsys.readouterr()
    assert app.main(["check"], run=fake) == 0
    assert "Today card  changed" not in capsys.readouterr().out


@needs_nofollow_open
def test_a_job_someone_switched_off_is_reported_and_left_off(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake, _ = box
    app.main(["apply", "--gateway", "corey"], run=fake)
    fake.jobs["corey"][0]["enabled"] = False
    capsys.readouterr()

    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert fake.added == ["corey"]
    assert "Today card switched off, left as it is" in capsys.readouterr().out
    assert fake.jobs["corey"][0]["enabled"] is False
    app.main(["check"], run=fake)
    assert "Today card  switched off" in capsys.readouterr().out


@needs_nofollow_open
def test_a_dry_run_shows_the_today_card_and_adds_nothing(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake, _ = box
    assert app.main(["apply", "--gateway", "corey", "--dry-run"], run=fake) == 0
    said = capsys.readouterr().out
    assert "Today card missing, apply writes it at 45 4,16 * * * in the gateway's time zone" in said
    assert "dry run: nothing written." in said
    assert fake.added == []
    assert fake.jobs["corey"] == []


@needs_nofollow_open
def test_a_job_written_when_the_config_already_follows_writes_no_config(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake, gateways = box
    app.main(["apply", "--gateway", "corey"], run=fake)
    fake.jobs["corey"].clear()
    backups = set(gateways[0].state.glob("openclaw.json.pre-household-app-*"))
    fake.writes.clear()
    capsys.readouterr()

    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert fake.writes == []
    assert set(gateways[0].state.glob("openclaw.json.pre-household-app-*")) == backups
    assert len(fake.jobs["corey"]) == 1
    assert "corey: the Today card's job written" in capsys.readouterr().out


@needs_nofollow_open
def test_the_morning_briefs_job_becomes_the_today_cards(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake, _ = box
    app.main(["apply", "--gateway", "corey"], run=fake)
    [job] = fake.jobs["corey"]
    job.update({"name": "Daily brief"})
    job["schedule"].update({"expr": "30 6 * * *"})
    job["payload"].update({"message": "Write today's brief for the Steward AI app."})
    capsys.readouterr()

    assert app.main(["check"], run=fake) == 1
    assert "Today card  changed: name, schedule, prompt" in capsys.readouterr().out
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0

    [card] = fake.jobs["corey"]
    assert card["declarationKey"] == "household-app:daily-brief"
    assert card["name"] == "Today card", "the add keeps the old name, so apply renames the job"
    assert card["schedule"]["expr"] == "45 4,16 * * *"
    assert fake.renamed == ["corey"]
    capsys.readouterr()

    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    assert capsys.readouterr().out.strip() == "corey: nothing to write"
    assert fake.renamed == ["corey"], "a job that is the card's already is not renamed again"


@needs_nofollow_open
def test_a_job_whose_name_alone_is_the_briefs_is_renamed(
    app: ModuleType,
    box: tuple[FakeGateways, tuple[Any, ...]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake, gateways = box
    for gateway in gateways:
        app.main(["apply", "--gateway", gateway.persona], run=fake)
    fake.jobs["corey"][0]["name"] = "Daily brief"
    capsys.readouterr()

    assert app.main(["check"], run=fake) == 1
    assert "Today card  changed: name" in capsys.readouterr().out
    assert app.main(["apply", "--gateway", "corey"], run=fake) == 0
    capsys.readouterr()

    assert app.main(["check"], run=fake) == 0
    assert "Today card  ok" in capsys.readouterr().out


def test_the_household_app_test_files_run_in_ci() -> None:
    listed = (ROOT / "tests" / "test_household_plugins.py").read_text(encoding="utf-8")
    for name in (ROOT / "tests" / "js").glob("household_app_*.test.mjs"):
        assert name.name in listed, f"{name.name} is not run by tests/test_household_plugins.py"
