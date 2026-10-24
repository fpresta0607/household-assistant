"""Exercise the PocketPiggies installer against temporary gateway state, never the VPS."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
# The owner as the app names them, and the Telegram chat their grant was made under before
# Telegram was retired.
OWNER = "franco"
TELEGRAM_ID = "123456"
GROUP_TOOLS = [
    "web_search",
    "web_fetch",
    "family_history",
    "picture",
    "video",
    "household_location",
    "household_cart",
    "household_home",
    "household_react",
    "household_note",
    "scripture",
]
FINANCE_TOOLS = ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]


def installer() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "pocket_install", ROOT / "scripts" / "pocket-piggies-install.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def as_on_the_box(profile: str = "coding") -> dict[str, Any]:
    """Corey's gateway with the app as its channel and the retired Telegram switched off."""
    return {
        "commands": {"ownerAllowFrom": [f"telegram:{TELEGRAM_ID}", f"household:{OWNER}"]},
        "channels": {
            "household": {
                "enabled": True,
                "owner": {"id": OWNER, "name": "Franco"},
                "peer": {"person": {"id": "gia", "name": "Gia"}},
                "familyTools": ["web_search", "family_history"],
            },
            "telegram": {
                "enabled": False,
                "botToken": {"source": "env", "id": "EXISTING"},
                "groupPolicy": "allowlist",
            },
        },
        "models": {"default": "existing-model"},
        "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
        "tools": {
            "profile": profile,
            "alsoAllow": ["household_note", "family_history"],
            "deny": ["codex", "memory-wiki", "onepassword"],
        },
        "plugins": {"entries": {"household-app": {"enabled": True}}},
    }


@pytest.mark.parametrize("profile", ["coding", "full"])
def test_the_owner_keeps_every_tool_and_everyone_else_is_kept_from_finance(profile: str) -> None:
    original = as_on_the_box(profile)

    installed = installer().configured(original, "corey", OWNER)

    tools = installed["tools"]
    assert tools["profile"] == profile
    assert tools["deny"] == original["tools"]["deny"]
    assert tools["alsoAllow"] == ["household_note", "family_history", *FINANCE_TOOLS]
    assert "allow" not in tools and "sessions" not in tools
    assert installed["channels"]["household"] == {
        **original["channels"]["household"],
        "familyTools": GROUP_TOOLS,
    }
    assert installed["channels"]["telegram"] == original["channels"]["telegram"]
    assert installed["models"] == original["models"]
    assert installed["commands"] == original["commands"]
    assert installed["plugins"]["entries"]["pocket-piggies"] == {
        "enabled": True,
        "config": {"ownerHouseholdPersonId": OWNER, "accountLabel": "corey"},
    }
    assert installed["plugins"]["load"]["paths"] == ["/opt/household-plugins/pocket-piggies-corey"]
    assert installer().configured(installed, "corey", OWNER) == installed
    assert original["channels"]["household"]["familyTools"] == ["web_search", "family_history"]


def test_every_other_chat_channel_is_switched_off() -> None:
    """The app is the household's only channel: another one would admit senders this policy
    never reviewed into a turn with every tool."""
    original = as_on_the_box()
    original["channels"]["telegram"]["enabled"] = True
    original["channels"]["whatsapp"] = {"dmPolicy": "allowlist", "allowFrom": ["+15550100"]}
    original["channels"]["defaults"] = {"groupPolicy": "allowlist"}

    installed = installer().configured(original, "corey", OWNER)

    assert installed["channels"]["telegram"]["enabled"] is False
    assert installed["channels"]["whatsapp"] == {
        "dmPolicy": "allowlist",
        "allowFrom": ["+15550100"],
        "enabled": False,
    }
    assert installed["channels"]["defaults"] == {"groupPolicy": "allowlist"}
    assert (
        "enabled" not in installed["channels"]["household"]
        or installed["channels"]["household"]["enabled"]
    )


def test_a_gateway_with_no_app_channel_yet_keeps_finance_to_nobody_but_the_owner() -> None:
    original = as_on_the_box()
    del original["channels"]["household"]

    installed = installer().configured(original, "corey", OWNER)

    assert "household" not in installed["channels"]
    assert installed["channels"]["telegram"]["enabled"] is False


def test_the_group_allowlist_is_the_one_the_plugin_accepts() -> None:
    source = (ROOT / "deploy/openclaw/plugins/pocket-piggies/index.mjs").read_text()
    match = re.search(r"SAFE_GROUP_TOOLS = \[([^\]]*)\]", source)
    assert match is not None
    assert re.findall(r'"([a-z_]+)"', match.group(1)) == installer().GROUP_TOOLS == GROUP_TOOLS


@pytest.mark.parametrize(
    "change",
    [
        {"session": {"scope": "global"}},
        {"plugins": {"enabled": False}},
        {"plugins": {"deny": ["pocket-piggies"]}},
        {"bindings": [{"session": {"groupScope": "main"}}]},
        {"tools": {"allow": ["web_search"]}},
        {"channels": []},
        {"channels": {"household": {"owner": {"id": "gia"}}}},
        {"channels": {"household": "on"}},
        {"channels": {"signal": True}},
    ],
)
def test_routing_the_installer_cannot_make_safe_is_refused(change: dict[str, Any]) -> None:
    original = {**as_on_the_box(), **change}
    with pytest.raises(ValueError):
        installer().configured(original, "corey", OWNER)


@pytest.mark.parametrize("value", ["Franco", "123456", "", "household:franco", "franco\n"])
def test_installer_requires_a_household_person_id(value: str) -> None:
    original = as_on_the_box()
    original["commands"]["ownerAllowFrom"].append(f"household:{value}")
    with pytest.raises(ValueError):
        installer().configured(original, "corey", value)


@pytest.mark.parametrize(
    "owners", [[], ["*"], [f"telegram:{TELEGRAM_ID}"], ["household:gia"], [OWNER]]
)
def test_install_refuses_an_owner_other_than_the_gateways_app_owner(owners: list[str]) -> None:
    original = {**as_on_the_box(), "commands": {"ownerAllowFrom": owners}}
    with pytest.raises(ValueError, match="owner"):
        installer().configured(original, "corey", OWNER)


@pytest.mark.parametrize("persona", ["corey", "denise"])
def test_rollback_disables_finance_and_keeps_the_channel_and_family_room_policy(
    persona: str,
) -> None:
    module = installer()
    installed = module.configured(as_on_the_box(), persona, OWNER)

    rolled_back = module.configured(installed, persona, OWNER, is_enabled=False)

    assert rolled_back["tools"]["alsoAllow"] == ["household_note", "family_history"]
    assert rolled_back["plugins"]["entries"]["pocket-piggies"] == {"enabled": False}
    assert rolled_back["plugins"]["load"]["paths"] == []
    assert rolled_back["channels"] == installed["channels"]
    assert rolled_back["session"] == installed["session"]
    assert module.configured(rolled_back, persona, OWNER, is_enabled=False) == rolled_back


posix = pytest.mark.skipif(os.name != "posix", reason="the VPS install needs POSIX modes")


@posix
def test_one_gateway_install_preserves_its_peer_and_writes_a_recoverable_backup(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "chown", lambda *_: None)
    corey = tmp_path / "openclaw"
    denise = tmp_path / "openclaw-denise"
    for state in (corey, denise):
        state.mkdir()
        (state / "openclaw.json").write_text(json.dumps(as_on_the_box()), encoding="utf-8")
    peer_before = (denise / "openclaw.json").read_bytes()
    plugins_root = tmp_path / "plugins"
    plugins_root.mkdir(mode=0o755)
    peer_plugin = plugins_root / "pocket-piggies-denise"
    peer_plugin.mkdir()
    (peer_plugin / "unchanged").write_text("original")
    stale = plugins_root / "pocket-piggies-corey"
    stale.mkdir()
    (stale / "server.mjs").write_text("an earlier release")

    backup = module.install_into(corey, "corey", OWNER, plugins_root)

    assert json.loads(backup.read_text()) == as_on_the_box()
    assert backup.stat().st_mode & 0o777 == 0o600
    assert (backup.parent / "plugin" / "server.mjs").read_text() == "an earlier release"
    assert (corey / "openclaw.json").stat().st_mode & 0o777 == 0o600
    assert (denise / "openclaw.json").read_bytes() == peer_before
    assert (peer_plugin / "unchanged").read_text() == "original"
    assert sorted(path.name for path in stale.iterdir()) == [
        "client.mjs",
        "index.mjs",
        "openclaw.plugin.json",
        "package.json",
        "tools.mjs",
    ]
    assert not any("ppc_" in path.read_text() for path in stale.iterdir())


@posix
def test_symlinked_config_is_refused(tmp_path: Path) -> None:
    actual = tmp_path / "actual.json"
    actual.write_text("{}", encoding="utf-8")
    state = tmp_path / "state"
    state.mkdir()
    os.symlink(actual, state / "openclaw.json")
    with pytest.raises(ValueError, match="regular"):
        installer().install_into(state, "corey", OWNER)
    assert actual.read_text() == "{}"


class FakeHost:
    """Records system commands and answers `id -u` for the key holder's user."""

    def __init__(self, *, has_user: bool, uid: int | None = None) -> None:
        self.has_user = has_user
        self.uid = os.getuid() if uid is None else uid
        self.commands: list[list[str]] = []

    def __call__(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        self.commands.append(command)
        if command[:2] == ["id", "-u"]:
            code = 0 if self.has_user else 1
            return subprocess.CompletedProcess(command, code, f"{self.uid}\n", "")
        if command[0] == "useradd":
            self.has_user = True
        return subprocess.CompletedProcess(command, 0, "", "")


@posix
@pytest.mark.parametrize("has_user", [False, True])
def test_the_key_holder_gets_its_own_user_root_owned_code_and_a_private_socket_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, has_user: bool
) -> None:
    module = installer()
    owners: dict[str, tuple[int, int]] = {}
    monkeypatch.setattr(
        module.os, "chown", lambda path, uid, gid: owners.update({str(path): (uid, gid)})
    )
    state = tmp_path / "openclaw"
    state.mkdir()
    units = tmp_path / "units"
    units.mkdir()
    code = tmp_path / "code"
    host = FakeHost(has_user=has_user)

    module.install_key_holder(state, "corey", OWNER, code_root=code, units=units, run=host)

    assert (code / "pocketpiggies-keyholder.py").is_file()
    assert (code / "pocket-piggies-install.py").is_file()
    assert sorted(path.name for path in (code / "household" / "pocketpiggies").iterdir()) == [
        "__init__.py",
        "api.py",
        "binding.py",
        "errors.py",
        "link.py",
        "reads.py",
        "server.py",
        "store.py",
    ]
    # The scripts are chowned as their staged copy, then renamed into place.
    assert all(
        owners.get(str(path), _staged_owner(owners, path)) == (0, 0) for path in code.rglob("*")
    )
    assert code.stat().st_mode & 0o777 == 0o755
    assert (units / "household-pocketpiggies@.service").read_text().startswith("# One assistant")
    for name in ("service", "path", "timer"):
        assert (units / f"household-pocketpiggies-guard.{name}").is_file()
    drop_in = (units / "household-pocketpiggies@corey.service.d" / "gateway.conf").read_text()
    assert f"Environment=POCKETPIGGIES_OWNER={OWNER}\n" in drop_in
    # A household person's client, never corey, which PocketPiggies keeps for Telegram.
    assert (
        f"Environment=POCKETPIGGIES_CLIENT_ID={module.default_client_id('corey', None)}\n"
        in drop_in
    )
    assert "TELEGRAM" not in drop_in
    assert f"BindPaths={state / 'pocketpiggies'}:/run/household-pocketpiggies\n" in drop_in
    sockets = state / "pocketpiggies"
    assert sockets.stat().st_mode & 0o7777 == 0o2750
    assert (sockets.stat().st_uid, sockets.stat().st_gid) == (os.getuid(), state.stat().st_gid)
    useradd = [command for command in host.commands if command[0] == "useradd"]
    assert (useradd[0][-1] == "household-pp-corey") if not has_user else useradd == []
    systemctl = [command for command in host.commands if command[0] == "systemctl"]
    assert systemctl == [
        ["systemctl", "daemon-reload"],
        [
            "systemctl",
            "enable",
            "--now",
            "household-pocketpiggies-guard.path",
            "household-pocketpiggies-guard.timer",
        ],
        ["systemctl", "enable", "household-pocketpiggies@corey.service"],
        ["systemctl", "restart", "household-pocketpiggies@corey.service"],
        ["systemctl", "is-active", "household-pocketpiggies@corey.service"],
    ]


def _staged_owner(owners: dict[str, tuple[int, int]], path: Path) -> tuple[int, int] | None:
    """A file swapped into place was chowned as its uniquely named staged copy."""
    for name, owner in owners.items():
        staged = Path(name)
        if (
            staged.parent == path.parent
            and staged.name.startswith(f".{path.name}.")
            and staged.name.endswith(".new")
        ):
            return owner
    return None


@posix
def test_the_guards_own_script_is_swapped_in_with_one_rename(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "chown", lambda *_: None)
    real_replace = os.replace
    replaced: list[tuple[str, str]] = []

    def recording(source: Path, target: Path) -> None:
        replaced.append((Path(source).name, Path(target).name))
        real_replace(source, target)

    monkeypatch.setattr(module.os, "replace", recording)
    state = tmp_path / "openclaw"
    state.mkdir()
    code = tmp_path / "code"
    host = FakeHost(has_user=True)
    for _ in range(2):
        module.install_key_holder(state, "corey", OWNER, code_root=code, units=tmp_path, run=host)

    # On a reinstall the scripts were never absent: each was renamed over the last one.
    for name in ("pocket-piggies-install.py", "pocketpiggies-keyholder.py"):
        swaps = [
            source
            for source, target in replaced
            if target == name and source.startswith(f".{name}.") and source.endswith(".new")
        ]
        assert len(swaps) == 2 and len(set(swaps)) == 2
    assert not list(code.glob(".*.new"))
    assert (code / "pocket-piggies-install.py").stat().st_mode & 0o777 == 0o755


@posix
@pytest.mark.parametrize("planted", ["file", "symlink"])
def test_the_key_holder_refuses_a_planted_socket_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, planted: str
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "chown", lambda *_: None)
    state = tmp_path / "openclaw"
    state.mkdir()
    target = tmp_path / "elsewhere"
    target.mkdir()
    if planted == "file":
        (state / "pocketpiggies").write_text("planted")
    else:
        (state / "pocketpiggies").symlink_to(target, target_is_directory=True)
    host = FakeHost(has_user=True)
    with pytest.raises(ValueError, match="socket directory"):
        module.install_key_holder(
            state, "corey", OWNER, code_root=tmp_path / "code", units=tmp_path, run=host
        )
    assert ["systemctl", "daemon-reload"] not in host.commands
    assert target.stat().st_mode & 0o7777 != 0o2750


@posix
def test_the_key_holder_refuses_a_socket_directory_someone_else_made(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "chown", lambda *_: None)
    state = tmp_path / "openclaw"
    (state / "pocketpiggies").mkdir(parents=True)
    host = FakeHost(has_user=True, uid=os.getuid() + 1)
    with pytest.raises(ValueError, match="did not create"):
        module.install_key_holder(
            state, "corey", OWNER, code_root=tmp_path / "code", units=tmp_path, run=host
        )
    assert ["systemctl", "daemon-reload"] not in host.commands


@posix
def test_client_provisioning_writes_only_into_the_key_holder_state_and_never_rotates(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "fchown", lambda *_: None)
    with pytest.raises(ValueError, match="start the key holder"):
        module.provision_client(tmp_path, "corey", OWNER)
    directory = tmp_path / "corey"
    directory.mkdir(mode=0o700)

    registration = module.provision_client(tmp_path, "corey", OWNER)

    path = directory / "connection.json"
    original = path.read_bytes()
    stored = json.loads(original)
    assert stored["clientCredential"].startswith("ppc_") and len(stored["clientCredential"]) == 47
    assert stored["grant"] is None and stored["pending"] is None
    assert stored["owner"] == OWNER and "ownerTelegramId" not in stored
    assert registration == {
        "clientId": module.default_client_id("corey", None),
        "credentialSha256": registration["credentialSha256"],
        "subjectType": "household_person",
        "subject": OWNER,
        "redirectUri": "steward://pocketpiggies/linked",
    }
    assert stored["clientCredential"] not in json.dumps(registration)
    assert path.stat().st_mode & 0o777 == 0o600
    assert module.provision_client(tmp_path, "corey", OWNER) == registration
    assert path.read_bytes() == original
    with pytest.raises(ValueError, match="different owner"):
        module.provision_client(tmp_path, "corey", "gia")
    with pytest.raises(ValueError, match="different owner"):
        module.provision_client(tmp_path, "corey", OWNER, telegram_id=TELEGRAM_ID)
    path.unlink()
    os.symlink(tmp_path / "missing", path)
    with pytest.raises(ValueError, match="symlinked"):
        module.provision_client(tmp_path, "corey", OWNER)


def test_a_grant_made_on_telegram_keeps_its_binding_in_the_drop_in() -> None:
    """Franco's and Gia's grants were made under their Telegram chats, which PocketPiggies
    still checks, so their key holders keep speaking for them."""
    module = installer()
    state = Path("/var/lib/household-assistant/openclaw")

    franco = module.drop_in(state, OWNER, "corey", TELEGRAM_ID).decode()
    marina = module.drop_in(state, "marina", "hh-7f3a", None).decode()

    assert franco.splitlines()[2:] == [
        f"Environment=POCKETPIGGIES_OWNER={OWNER}",
        "Environment=POCKETPIGGIES_CLIENT_ID=corey",
        f"Environment=POCKETPIGGIES_TELEGRAM_ID={TELEGRAM_ID}",
        f"BindPaths={state / 'pocketpiggies'}:/run/household-pocketpiggies",
    ]
    assert "TELEGRAM" not in marina and "POCKETPIGGIES_CLIENT_ID=hh-7f3a" in marina


@posix
def test_a_telegram_binding_is_refused_for_a_client_it_was_never_made_with(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "chown", lambda *_: None)
    host = FakeHost(has_user=True)
    for owner, telegram_id, client in [
        (OWNER, TELEGRAM_ID, "hh-7f3a"),
        (OWNER, "telegram:123", None),
        ("Franco", None, None),
    ]:
        with pytest.raises(ValueError):
            module.install_key_holder(
                tmp_path,
                "corey",
                owner,
                telegram_id=telegram_id,
                client_id=client,
                code_root=tmp_path / "code",
                units=tmp_path,
                run=host,
            )
    assert host.commands == []


@posix
def test_provisioning_a_telegram_bound_key_holder_keeps_the_file_it_had(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "fchown", lambda *_: None)
    (tmp_path / "corey").mkdir(mode=0o700)

    registration = module.provision_client(tmp_path, "corey", OWNER, telegram_id=TELEGRAM_ID)

    stored = json.loads((tmp_path / "corey" / "connection.json").read_text())
    assert stored["ownerTelegramId"] == TELEGRAM_ID and "owner" not in stored
    assert registration["telegramUserId"] == TELEGRAM_ID
    assert registration["botUsername"] == "Corey_the_man_bot"


def installed(tmp_path: Path, persona: str = "corey", owner: str = OWNER) -> tuple[Path, Path]:
    """A gateway state with the installed config and its drop-in, as the guard finds them."""
    module = installer()
    state_root = tmp_path / "state"
    state = state_root / module.GATEWAYS[persona][0]
    state.mkdir(parents=True)
    config = module.configured(as_on_the_box(), persona, owner)
    (state / "openclaw.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    units = tmp_path / "units"
    drop_in = units / f"household-pocketpiggies@{persona}.service.d"
    drop_in.mkdir(parents=True)
    (drop_in / "gateway.conf").write_text(
        f"[Service]\nEnvironment=POCKETPIGGIES_OWNER={owner}\n"
        f"Environment=POCKETPIGGIES_CLIENT_ID={persona}\n"
        f"Environment=POCKETPIGGIES_TELEGRAM_ID={TELEGRAM_ID}\n",
        encoding="utf-8",
    )
    return state_root, units


@posix
@pytest.mark.parametrize(
    "drift",
    [
        lambda config: config["channels"]["household"].update(familyTools=["exec", "read"]),
        lambda config: config["channels"]["household"].pop("familyTools"),
        lambda config: config["channels"]["telegram"].update(enabled=True),
        lambda config: config["channels"]["telegram"].pop("enabled"),
        lambda config: config["session"].update(dmScope="main"),
        lambda config: config["plugins"]["entries"]["pocket-piggies"]["config"].update(
            ownerHouseholdPersonId="gia"
        ),
    ],
)
def test_the_guard_puts_back_a_drifted_policy(
    tmp_path: Path, drift: Callable[[dict[str, Any]], object]
) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    expected = json.loads(config_path.read_text())
    drifted = json.loads(config_path.read_text())
    drift(drifted)
    config_path.write_text(json.dumps(drifted), encoding="utf-8")
    config_path.chmod(0o600)
    host = FakeHost(has_user=True)
    lines: list[str] = []

    module.guard(
        runtime=tmp_path / "runtime",
        sleep=lambda _: None,
        units=units,
        state_root=state_root,
        run=host,
        log=lines.append,
    )

    assert json.loads(config_path.read_text()) == expected
    assert config_path.stat().st_mode & 0o777 == 0o600
    assert len(lines) == 1 and lines[0].startswith("corey: put back the PocketPiggies policy")
    assert host.commands == []


@posix
def test_the_guard_leaves_an_intact_config_and_an_uninstalled_gateway_alone(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    before = config_path.read_bytes()
    denise = state_root / "openclaw-denise"
    denise.mkdir()
    (denise / "openclaw.json").write_text(json.dumps(as_on_the_box()), encoding="utf-8")
    denise_before = (denise / "openclaw.json").read_bytes()
    host = FakeHost(has_user=True)
    lines: list[str] = []

    module.guard(
        runtime=tmp_path / "runtime",
        sleep=lambda _: None,
        units=units,
        state_root=state_root,
        run=host,
        log=lines.append,
    )

    assert config_path.read_bytes() == before
    assert (denise / "openclaw.json").read_bytes() == denise_before
    assert lines == [] and host.commands == []


@posix
@pytest.mark.parametrize(
    "unsafe",
    [
        lambda config: config["channels"]["household"].update(owner={"id": "gia"}),
        lambda config: config["channels"].update(signal=True),
        lambda config: config["tools"].update(allow=["exec"]),
        lambda config: config.update(bindings=[{"session": {"groupScope": "main"}}]),
    ],
)
def test_the_guard_stops_finance_when_the_config_cannot_be_made_safe(
    tmp_path: Path, unsafe: Callable[[dict[str, Any]], object]
) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    drifted = json.loads(config_path.read_text())
    unsafe(drifted)
    config_path.write_text(json.dumps(drifted), encoding="utf-8")
    written = config_path.read_bytes()
    host = FakeHost(has_user=True)
    lines: list[str] = []

    module.guard(
        runtime=tmp_path / "runtime",
        sleep=lambda _: None,
        units=units,
        state_root=state_root,
        run=host,
        log=lines.append,
    )

    assert host.commands == [["systemctl", "stop", "household-pocketpiggies@corey.service"]]
    assert config_path.read_bytes() == written
    assert lines[0].startswith("corey: PocketPiggies stopped")


@posix
def test_the_guard_stops_finance_when_the_config_is_missing_or_a_symlink(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    elsewhere = tmp_path / "elsewhere.json"
    config_path.rename(elsewhere)
    config_path.symlink_to(elsewhere)
    host = FakeHost(has_user=True)

    module.guard(
        runtime=tmp_path / "runtime",
        sleep=lambda _: None,
        units=units,
        state_root=state_root,
        run=host,
        log=lambda line: None,
    )

    assert host.commands == [["systemctl", "stop", "household-pocketpiggies@corey.service"]]


def test_neither_gateway_mounts_the_other_ones_key_holder_socket() -> None:
    compose = yaml.safe_load((ROOT / "deploy/openclaw/docker-compose.yml").read_text())
    sockets = {
        "openclaw-gateway": "/var/lib/household-assistant/openclaw/pocketpiggies",
        "openclaw-denise": "/var/lib/household-assistant/openclaw-denise/pocketpiggies",
    }
    for service, definition in compose["services"].items():
        for volume in definition.get("volumes", []):
            source = Path(volume.split(":", 1)[0])
            for owner, socket_directory in sockets.items():
                if Path(socket_directory).is_relative_to(source):
                    assert service == owner, f"{service} mounts {owner}'s key holder via {source}"


@pytest.mark.parametrize("has_failure", [False, True])
def test_rollback_stops_the_key_holder_first_and_touches_only_this_gateway(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, has_failure: bool
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "geteuid", lambda: 0, raising=False)
    monkeypatch.setattr(module, "SYSTEMD_UNITS", tmp_path)
    drop_in = tmp_path / "household-pocketpiggies@denise.service.d"
    drop_in.mkdir()
    (drop_in / "gateway.conf").write_text("[Service]\n", encoding="utf-8")
    peer_drop_in = tmp_path / "household-pocketpiggies@corey.service.d"
    peer_drop_in.mkdir()
    monkeypatch.setattr(
        sys, "argv", ["installer", "denise", "--owner", OWNER, "--rollback", "--restart"]
    )
    actions: list[object] = []

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        assert kwargs.get("timeout") == 90
        actions.append(command)
        if command[-3:] == ["plugins", "doctor", "--json"]:
            # Doctor exits 1 whenever any plugin has a diagnostic, provenance included.
            return subprocess.CompletedProcess(command, 1, doctor_report(PROVENANCE_ONLY), "")
        stdout = "inactive\n" if command[1:2] == ["is-active"] else ""
        return subprocess.CompletedProcess(command, 0, stdout, "")

    def install(state: Path, persona: str, owner: str, *, is_enabled: bool = True) -> Path:
        assert state == Path("/var/lib/household-assistant/openclaw-denise")
        assert persona == "denise" and owner == OWNER and not is_enabled
        # The guard must already have lost this gateway, or it would put finance back.
        assert not drop_in.exists() and peer_drop_in.exists()
        actions.append("disable finance")
        if has_failure:
            raise OSError("config write failed")
        return Path("/backup/openclaw.json")

    monkeypatch.setattr(module.subprocess, "run", run)
    monkeypatch.setattr(module, "install_into", install)
    monkeypatch.setattr(module, "install_key_holder", lambda *_, **__: actions.append("key holder"))

    if has_failure:
        with pytest.raises(SystemExit) as error:
            module.main()
        assert error.value.code == 1
    else:
        module.main()

    assert actions[:3] == [
        ["systemctl", "disable", "--now", "household-pocketpiggies@denise.service"],
        ["systemctl", "is-active", "household-pocketpiggies@denise.service"],
        "disable finance",
    ]
    assert "key holder" not in actions
    if has_failure:
        assert len(actions) == 3
    else:
        assert actions[3:] == [
            ["docker", "restart", "openclaw-denise"],
            [
                "docker",
                "exec",
                "openclaw-denise",
                "node",
                "dist/index.js",
                "plugins",
                "doctor",
                "--json",
            ],
        ]


def test_rollback_never_reports_finance_off_while_the_key_holder_still_runs(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "geteuid", lambda: 0, raising=False)
    monkeypatch.setattr(module, "SYSTEMD_UNITS", tmp_path)
    monkeypatch.setattr(sys, "argv", ["installer", "corey", "--owner", OWNER, "--rollback"])

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        stdout = "active\n" if command[1:2] == ["is-active"] else ""
        return subprocess.CompletedProcess(command, 0, stdout, "")

    monkeypatch.setattr(module.subprocess, "run", run)
    monkeypatch.setattr(module, "install_into", lambda *_, **__: pytest.fail("config touched"))

    with pytest.raises(SystemExit) as error:
        module.main()

    assert error.value.code == 1


@posix
@pytest.mark.parametrize(
    "hostile",
    [
        lambda config: json.dumps({**config, "commands": None}),
        lambda config: json.dumps({**config, "bindings": None}),
        lambda config: json.dumps({**config, "plugins": {**config["plugins"], "entries": None}}),
        lambda config: json.dumps(config)[:-1] + ', "deep": ' + "[" * 5000 + "]" * 5000 + "}",
        lambda config: json.dumps(
            {
                **config,
                "plugins": {
                    **config["plugins"],
                    "load": {"paths": ["/home/node/.openclaw/workspace/plugin"]},
                },
            }
        ),
    ],
)
def test_a_hostile_config_stops_only_its_own_finance_and_the_guard_goes_on(
    tmp_path: Path, hostile: Callable[[dict[str, Any]], str]
) -> None:
    module = installer()
    state_root, units = installed(tmp_path, "corey")
    installed(tmp_path, "denise")
    corey = state_root / "openclaw" / "openclaw.json"
    corey.write_text(hostile(json.loads(corey.read_text())), encoding="utf-8")
    denise = state_root / "openclaw-denise" / "openclaw.json"
    drifted = json.loads(denise.read_text())
    drifted["channels"]["telegram"]["enabled"] = True
    denise.write_text(json.dumps(drifted), encoding="utf-8")
    host = FakeHost(has_user=True)
    lines: list[str] = []
    naps: list[float] = []

    module.guard(
        runtime=tmp_path / "runtime",
        units=units,
        state_root=state_root,
        run=host,
        log=lines.append,
        sleep=naps.append,
    )

    assert host.commands == [["systemctl", "stop", "household-pocketpiggies@corey.service"]]
    assert naps == [module.GUARD_RETRY_SECONDS]
    assert json.loads(denise.read_text())["channels"]["telegram"]["enabled"] is False
    assert [line.split(":")[0] for line in lines] == ["corey", "denise"]


@posix
@pytest.mark.parametrize("problem", ["oversized", "hard link", "someone else's"])
def test_the_guard_reads_only_the_gateways_own_bounded_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, problem: str
) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    if problem == "oversized":
        config = json.loads(config_path.read_text())
        config["padding"] = "x" * module.MAX_CONFIG_BYTES
        config_path.write_text(json.dumps(config), encoding="utf-8")
    elif problem == "hard link":
        os.link(config_path, tmp_path / "second-name.json")
    else:
        real_fstat = os.fstat
        monkeypatch.setattr(
            module.os,
            "fstat",
            lambda descriptor: (
                _owned_by(real_fstat(descriptor), os.getuid() + 1)
                if stat.S_ISREG(real_fstat(descriptor).st_mode)
                else real_fstat(descriptor)
            ),
        )
    host = FakeHost(has_user=True)

    module.guard(
        runtime=tmp_path / "runtime",
        units=units,
        state_root=state_root,
        run=host,
        log=lambda line: None,
        sleep=lambda _: None,
    )

    assert host.commands == [["systemctl", "stop", "household-pocketpiggies@corey.service"]]


def _owned_by(metadata: os.stat_result, uid: int) -> os.stat_result:
    fields = list(metadata)
    fields[stat.ST_UID] = uid
    return os.stat_result(fields)


@posix
def test_the_guard_keeps_what_openclaw_records_beside_the_plugin_entry(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    config = json.loads(config_path.read_text())
    config["plugins"]["entries"]["pocket-piggies"]["acceptedCapabilities"] = ["tools"]
    config_path.write_text(json.dumps(config), encoding="utf-8")
    before = config_path.read_bytes()

    module.guard(
        runtime=tmp_path / "runtime",
        sleep=lambda _: None,
        units=units,
        state_root=state_root,
        run=FakeHost(has_user=True),
        log=lambda _: None,
    )

    assert config_path.read_bytes() == before


@posix
@pytest.mark.parametrize(
    "text",
    [
        # Within the byte cap, but indenting it on rewrite would take hundreds of megabytes.
        '"junk": ' + "[" * 300 + "0," * 100_000 + "0" + "]" * 300,
        '"junk": ' + "[" * 40 + "]" * 40,
        '"junk": [' + "0," * 20_000 + "0]",
    ],
    ids=["amplified on rewrite", "too deep", "too many values"],
)
def test_a_config_too_deep_or_large_to_rewrite_cheaply_stops_finance(
    tmp_path: Path, text: str
) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    config = json.loads(config_path.read_text())
    config["channels"]["telegram"]["enabled"] = True
    config_path.write_text(json.dumps(config)[:-1] + ", " + text + "}", encoding="utf-8")
    assert config_path.stat().st_size <= module.MAX_CONFIG_BYTES
    host = FakeHost(has_user=True)

    module.guard(
        units=units,
        state_root=state_root,
        run=host,
        log=lambda _: None,
        sleep=lambda _: None,
        runtime=tmp_path / "runtime",
    )

    assert host.commands == [["systemctl", "stop", "household-pocketpiggies@corey.service"]]


@posix
@pytest.mark.parametrize(
    "path",
    [
        "/opt/household-plugins/../../home/node/.openclaw/workspace/x",
        "/opt/household-plugins/..",
        "/opt/household-plugins/.",
        "/opt/household-plugins/a/b",
        "/opt/household-plugins/",
        "/home/node/.openclaw/workspace/plugin",
    ],
)
def test_a_plugin_from_anywhere_but_the_read_only_mount_stops_finance(
    tmp_path: Path, path: str
) -> None:
    module = installer()
    with pytest.raises(ValueError, match="outside /opt/household-plugins"):
        module.configured(
            {**as_on_the_box(), "plugins": {"load": {"paths": [path]}}}, "corey", OWNER
        )


@posix
def test_a_failing_stop_is_logged_and_the_guard_still_reaches_the_other_gateway(
    tmp_path: Path,
) -> None:
    module = installer()
    state_root, units = installed(tmp_path, "corey")
    installed(tmp_path, "denise")
    (state_root / "openclaw" / "openclaw.json").write_text("not json", encoding="utf-8")
    denise = state_root / "openclaw-denise" / "openclaw.json"
    drifted = json.loads(denise.read_text())
    drifted["channels"]["telegram"]["enabled"] = True
    denise.write_text(json.dumps(drifted), encoding="utf-8")
    lines: list[str] = []

    def failing(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(command, 60)

    # A stop systemd did not carry out fails the run, so the unit stops every key holder.
    with pytest.raises(SystemExit):
        module.guard(
            units=units,
            state_root=state_root,
            run=failing,
            log=lines.append,
            sleep=lambda _: None,
            runtime=tmp_path / "runtime",
        )

    assert lines == [
        "corey: stopping PocketPiggies failed: TimeoutExpired",
        "denise: put back the PocketPiggies policy in channels",
    ]
    assert json.loads(denise.read_text())["channels"]["telegram"]["enabled"] is False


@posix
def test_a_stop_systemd_refuses_fails_the_guard_run(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    (state_root / "openclaw" / "openclaw.json").write_text("not json", encoding="utf-8")
    lines: list[str] = []

    def refusing(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(command, 5, "", "")

    with pytest.raises(SystemExit):
        module.guard(
            units=units,
            state_root=state_root,
            run=refusing,
            log=lines.append,
            sleep=lambda _: None,
            runtime=tmp_path / "runtime",
        )
    assert lines == ["corey: stopping PocketPiggies failed: systemctl refused"]


@posix
def test_a_write_in_progress_is_ridden_out_by_one_retry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    real = module._guard_one
    attempts: list[int] = []

    def flaky(state: Path, persona: str, owner: str, log: Callable[[str], None]) -> bool:
        attempts.append(1)
        if len(attempts) == 1:
            raise ValueError("a regular openclaw.json file is required")
        return bool(real(state, persona, owner, log))

    monkeypatch.setattr(module, "_guard_one", flaky)
    host = FakeHost(has_user=True)

    module.guard(
        units=units,
        state_root=state_root,
        run=host,
        log=lambda _: None,
        sleep=lambda _: None,
        runtime=tmp_path / "runtime",
    )

    assert len(attempts) == 2 and host.commands == []


@posix
def test_a_config_that_keeps_drifting_back_stops_finance(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    host = FakeHost(has_user=True)
    lines: list[str] = []
    for repair in range(module.MAX_REPAIRS + 1):
        drifted = json.loads(config_path.read_text())
        drifted["channels"]["telegram"]["enabled"] = True
        config_path.write_text(json.dumps(drifted), encoding="utf-8")
        module.guard(
            units=units,
            state_root=state_root,
            run=host,
            log=lines.append,
            sleep=lambda _: None,
            runtime=tmp_path / "runtime",
            clock=lambda moment=1000.0 + repair: moment,
        )
        stopped = host.commands == [["systemctl", "stop", "household-pocketpiggies@corey.service"]]
        assert stopped == (repair == module.MAX_REPAIRS)
    assert lines[-1] == "corey: PocketPiggies stopped; its config keeps drifting back"


@posix
def test_a_config_at_the_shape_limits_is_still_repaired(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    config = json.loads(config_path.read_text())
    config["channels"]["telegram"]["enabled"] = True
    # The top-level value is depth 1, so 32 nested lists put the innermost at the limit.
    config_path.write_text(
        json.dumps(config)[:-1] + ', "junk": ' + "[" * 32 + "]" * 32 + "}", encoding="utf-8"
    )
    host = FakeHost(has_user=True)

    module.guard(
        units=units,
        state_root=state_root,
        run=host,
        log=lambda _: None,
        sleep=lambda _: None,
        runtime=tmp_path / "runtime",
    )

    assert host.commands == []
    assert json.loads(config_path.read_text())["channels"]["telegram"]["enabled"] is False


@posix
def test_a_traversing_plugin_path_reaching_the_guard_stops_finance(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    config = json.loads(config_path.read_text())
    config["plugins"]["load"]["paths"].append("/opt/household-plugins/../../tmp/x")
    config_path.write_text(json.dumps(config), encoding="utf-8")
    host = FakeHost(has_user=True)

    module.guard(
        units=units,
        state_root=state_root,
        run=host,
        log=lambda _: None,
        sleep=lambda _: None,
        runtime=tmp_path / "runtime",
    )

    assert host.commands == [["systemctl", "stop", "household-pocketpiggies@corey.service"]]


@pytest.mark.parametrize(
    "paths",
    [[5], ["/opt/household-plugins/x\n"], [""], [None]],
)
def test_plugin_paths_that_are_not_one_plain_name_under_the_mount_are_refused(
    paths: list[object],
) -> None:
    with pytest.raises(ValueError, match="outside /opt/household-plugins"):
        installer().configured(
            {**as_on_the_box(), "plugins": {"load": {"paths": paths}}}, "corey", OWNER
        )


def test_the_household_plugin_paths_are_accepted() -> None:
    paths = [
        "/opt/household-plugins/household-family-room",
        "/opt/household-plugins/household-openrouter-video",
        "/opt/household-plugins/household-speech",
    ]
    installed_config = installer().configured(
        {**as_on_the_box(), "plugins": {"load": {"paths": list(paths)}}}, "corey", OWNER
    )
    assert installed_config["plugins"]["load"]["paths"] == [
        *paths,
        "/opt/household-plugins/pocket-piggies-corey",
    ]


@posix
def test_repairs_spread_out_in_time_never_trip_the_breaker(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path)
    config_path = state_root / "openclaw" / "openclaw.json"
    host = FakeHost(has_user=True)
    for repair in range(module.MAX_REPAIRS * 2):
        drifted = json.loads(config_path.read_text())
        drifted["channels"]["telegram"]["enabled"] = True
        config_path.write_text(json.dumps(drifted), encoding="utf-8")
        module.guard(
            units=units,
            state_root=state_root,
            run=host,
            log=lambda _: None,
            sleep=lambda _: None,
            runtime=tmp_path / "runtime",
            clock=lambda moment=1000.0 + repair * 5: moment,
        )
    assert host.commands == []


@posix
def test_the_breaker_counts_each_gateway_alone_and_survives_a_corrupt_record(
    tmp_path: Path,
) -> None:
    module = installer()
    state_root, units = installed(tmp_path, "corey")
    installed(tmp_path, "denise")
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    corey_record = [1000.0 + index for index in range(module.MAX_REPAIRS)]
    (runtime / "repairs-corey.json").write_text(json.dumps(corey_record))
    (runtime / "repairs-denise.json").write_text("{not json")
    denise = state_root / "openclaw-denise" / "openclaw.json"
    drifted = json.loads(denise.read_text())
    drifted["channels"]["telegram"]["enabled"] = True
    denise.write_text(json.dumps(drifted), encoding="utf-8")
    host = FakeHost(has_user=True)

    module.guard(
        units=units,
        state_root=state_root,
        run=host,
        log=lambda _: None,
        sleep=lambda _: None,
        runtime=runtime,
        clock=lambda: 1030.0,
    )

    assert host.commands == []
    assert json.loads((runtime / "repairs-denise.json").read_text()) == [1030.0]


def test_the_guard_units_cannot_be_rate_limited_and_fail_closed() -> None:
    units = ROOT / "deploy" / "pocketpiggies"
    service = (units / "household-pocketpiggies-guard.service").read_text()
    assert "StartLimitIntervalSec=0\n" in service
    assert (
        'ExecStopPost=/bin/sh -c \'test "$$SERVICE_RESULT" = success || '
        'systemctl stop "household-pocketpiggies@*.service"\'\n'
    ) in service
    assert (
        "TriggerLimitIntervalSec=0\n" in (units / "household-pocketpiggies-guard.path").read_text()
    )
    assert "OnUnitActiveSec=15s\n" in (units / "household-pocketpiggies-guard.timer").read_text()
    # Without these the repair counts vanish between runs and the breaker never trips.
    assert "RuntimeDirectory=household-pocketpiggies-guard\n" in service
    assert "RuntimeDirectoryPreserve=yes\n" in service


@posix
def test_a_drop_in_removed_mid_run_reads_as_not_installed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = installer()
    _, units = installed(tmp_path)

    def vanished(self: Path, *_: object, **__: object) -> str:
        raise FileNotFoundError(self)

    monkeypatch.setattr(module.Path, "read_text", vanished)

    assert module.installed_owner(units, "corey") is None


@posix
def test_repairs_that_cannot_be_counted_stop_only_that_gateway(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path, "corey")
    installed(tmp_path, "denise")
    for state_name in ("openclaw", "openclaw-denise"):
        config_path = state_root / state_name / "openclaw.json"
        drifted = json.loads(config_path.read_text())
        drifted["channels"]["telegram"]["enabled"] = True
        config_path.write_text(json.dumps(drifted), encoding="utf-8")
    runtime = tmp_path / "runtime"
    runtime.write_text("not a directory")
    host = FakeHost(has_user=True)
    lines: list[str] = []

    module.guard(
        units=units,
        state_root=state_root,
        run=host,
        log=lines.append,
        sleep=lambda _: None,
        runtime=runtime,
    )

    assert host.commands == [
        ["systemctl", "stop", "household-pocketpiggies@corey.service"],
        ["systemctl", "stop", "household-pocketpiggies@denise.service"],
    ]
    assert all(
        json.loads((state_root / name / "openclaw.json").read_text())["channels"]["telegram"][
            "enabled"
        ]
        is False
        for name in ("openclaw", "openclaw-denise")
    )
    assert (
        lines[1] == "corey: PocketPiggies stopped; its repairs cannot be counted: FileExistsError"
    )


@posix
def test_a_drop_in_that_names_no_owner_stops_that_gateway(tmp_path: Path) -> None:
    module = installer()
    state_root, units = installed(tmp_path, "corey")
    installed(tmp_path, "denise")
    (units / "household-pocketpiggies@corey.service.d" / "gateway.conf").write_text("")
    host = FakeHost(has_user=True)
    lines: list[str] = []

    module.guard(
        units=units,
        state_root=state_root,
        run=host,
        log=lines.append,
        sleep=lambda _: None,
        runtime=tmp_path / "runtime",
    )

    assert host.commands == [["systemctl", "stop", "household-pocketpiggies@corey.service"]]
    assert lines == ["corey: PocketPiggies stopped; the corey drop-in names no owner"]


def provenance(plugin: str) -> dict[str, str]:
    return {
        "level": "warn",
        "pluginId": plugin,
        "message": "OpenClaw can't verify where this plugin came from. Review it with "
        f"'openclaw plugins inspect {plugin}'.",
    }


PROVENANCE_ONLY = [provenance("household-speech"), provenance("pocket-piggies")]


def doctor_report(diagnostics: list[dict[str, str]], errors: list[object] | None = None) -> str:
    """`plugins doctor --json` as 2026.9.4 prints it, with a banner line first."""
    report = {
        "ok": False,
        "pluginErrors": errors or [],
        "diagnostics": diagnostics,
        "sourceShadowing": [],
        "compatibility": [],
        "configurationWarnings": [],
    }
    return "OpenClaw 2026.9.4 (3a9d69d)\n" + json.dumps(report)


def test_doctor_passes_when_every_diagnostic_is_provenance() -> None:
    """On the box doctor exits 1 for every local plugin over provenance alone, so
    every --restart install ended in CalledProcessError after doing all its work."""
    assert installer().doctor_failures(doctor_report(PROVENANCE_ONLY)) == []


def test_doctor_names_a_real_pocket_piggies_diagnostic() -> None:
    broken = {
        "level": "error",
        "pluginId": "pocket-piggies",
        "message": "failed to load: no module",
    }
    failures = installer().doctor_failures(doctor_report([*PROVENANCE_ONLY, broken]))
    assert failures == ["pocket-piggies: failed to load: no module"]


def test_doctor_names_a_pocket_piggies_load_error() -> None:
    error = {"pluginId": "pocket-piggies", "error": "register threw"}
    assert installer().doctor_failures(doctor_report(PROVENANCE_ONLY, [error])) == [
        "pocket-piggies: register threw"
    ]


def test_doctor_leaves_other_plugins_to_their_own_installers() -> None:
    other = {"level": "error", "pluginId": "household-speech", "message": "failed to load"}
    assert installer().doctor_failures(doctor_report([other])) == []


def test_doctor_without_a_report_is_a_failure() -> None:
    assert installer().doctor_failures("Error: gateway not running") == [
        "plugins doctor printed no JSON report"
    ]


@pytest.mark.parametrize("has_problem", [False, True])
def test_restart_judges_doctor_by_its_report_not_its_exit_code(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    has_problem: bool,
) -> None:
    module = installer()
    monkeypatch.setattr(module.os, "geteuid", lambda: 0, raising=False)
    monkeypatch.setattr(module, "SYSTEMD_UNITS", tmp_path)
    monkeypatch.setattr(sys, "argv", ["installer", "corey", "--owner", OWNER, "--restart"])
    broken = {"level": "error", "pluginId": "pocket-piggies", "message": "failed to load"}

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if command[-3:] == ["plugins", "doctor", "--json"]:
            diagnostics = [*PROVENANCE_ONLY, broken] if has_problem else PROVENANCE_ONLY
            return subprocess.CompletedProcess(command, 1, doctor_report(diagnostics), "")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(module.subprocess, "run", run)
    monkeypatch.setattr(module, "install_into", lambda *_, **__: Path("/backup/openclaw.json"))
    monkeypatch.setattr(module, "install_key_holder", lambda *_, **__: None)

    if has_problem:
        with pytest.raises(SystemExit) as error:
            module.main()
        assert "pocket-piggies: failed to load" in str(error.value.code)
    else:
        module.main()
        assert "Verify the plugin" in capsys.readouterr().out


def test_a_household_persons_client_is_named_for_the_box_and_never_a_telegram_one() -> None:
    module = installer()

    named = module.default_client_id("corey", None)

    assert re.fullmatch(r"hh-[0-9a-f]{12}", named)
    assert named == module.default_client_id("corey", None), "the same on every run"
    assert named != module.default_client_id("denise", None)
    assert module.default_client_id("corey", TELEGRAM_ID) == "corey"
