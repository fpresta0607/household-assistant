#!/usr/bin/env python3
"""Who can reach Corey and Denise in the family group, and the one policy both follow.

Admission rules, operator commands, the private-tool exception and recovery are
documented in docs/deploy/openclaw.md under "The family group".
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from gateway_config import (
    GATEWAY_TIMEOUT_SECONDS,
    GATEWAYS,
    Gateway,
    Runner,
    UnsupportedConfig,
    ask_gateway,
    backup,
    config_patch,
    field,
    first_json_object,
    gateway_for,
    load_household,
    patched,
    read_config,
    session_patch,
    sessions_kept_apart,
)

# The family group, "The Fam", and the two people by the Telegram user id the channel
# authenticates, from the box's household file. Telegram gives a basic group a new id
# if it is ever upgraded to a supergroup; OpenClaw follows that move in its own config,
# and familyGroup in the household file has to follow it by hand. The coordination
# relay reads the same file, so the two cannot disagree.
IDENTIFIERS = load_household()
FAMILY_GROUP = IDENTIFIERS.family_group
HOUSEHOLD = IDENTIFIERS.telegram_ids

# Any id that is not one of the two, standing for whoever else is ever added to the
# group. Neither assistant may answer them.
SOMEONE_ELSE = "1000000001"

# These senders use the addressed gateway's tools without a Phase 1 envelope.
# See the owner-authorized policy in docs/deploy/openclaw.md, "The family group".
GROUP_SENDERS: dict[str, tuple[str, ...]] = {
    "corey": ("franco", "gia"),
    "denise": ("franco", "gia"),
}

# The household-family-room plugin, as both gateways load it: from the read-only mount
# docker-compose.yml gives them, which openclaw-install.sh fills from the repository.
ROOM_PLUGIN = "household-family-room"
ROOM_PLUGIN_PATH = f"/opt/household-plugins/{ROOM_PLUGIN}"
ROOM_PLUGIN_ON_HOST = Path("/opt/household-assistant/plugins") / ROOM_PLUGIN / "index.js"

# The plugin's tool for reading the group's earlier messages. It is optional, so under
# a tool profile only `tools.alsoAllow` hands it to the model.
HISTORY_TOOL = "family_history"


@dataclass(frozen=True, slots=True)
class Admission:
    """Whether a group message that mentions the bot reaches the agent, and if not, why."""

    admitted: bool
    reason: str = ""


@dataclass(frozen=True, slots=True)
class Allowlist:
    """An allowFrom list the way OpenClaw's Telegram channel normalizes one."""

    ids: frozenset[str]
    wildcard: bool
    has_entries: bool

    def allows(self, sender: str) -> bool:
        # An empty list allows everyone here. Every caller below decides first
        # whether an empty list is acceptable, which is exactly how OpenClaw splits it.
        if not self.has_entries or self.wildcard:
            return True
        return sender in self.ids


def allowlist(entries: object) -> Allowlist:
    if entries is None:
        entries = []
    if not isinstance(entries, list):
        raise UnsupportedConfig(f"an allowFrom that is not a list: {entries!r}")
    raw = [text for text in (str(entry).strip() for entry in entries) if text]
    if any(entry.startswith("accessGroup:") for entry in raw):
        raise UnsupportedConfig("allowFrom names an access group, which this check cannot expand")
    stripped = (re.sub(r"^(telegram|tg):", "", entry, flags=re.IGNORECASE) for entry in raw)
    # OpenClaw ignores an entry that is not a numeric user id, but it still counts
    # towards "the list has entries", which is what decides empty-means-everyone.
    ids = frozenset(entry for entry in stripped if re.fullmatch(r"[0-9]+", entry))
    return Allowlist(ids=ids, wildcard="*" in raw, has_entries=bool(raw))


def telegram_section(config: dict[str, Any]) -> dict[str, Any] | None:
    channels = config.get("channels")
    telegram = channels.get("telegram") if isinstance(channels, dict) else None
    if not isinstance(telegram, dict):
        return None
    if telegram.get("accounts"):
        raise UnsupportedConfig(
            "channels.telegram has named accounts; this check reads the single default account"
        )
    return telegram


def _group_entries(telegram: dict[str, Any]) -> dict[str, Any]:
    groups = telegram.get("groups")
    return groups if isinstance(groups, dict) else {}


def _group_config(telegram: dict[str, Any], chat_id: str) -> dict[str, Any] | None:
    groups = _group_entries(telegram)
    entry = groups.get(chat_id, groups.get("*"))
    return entry if isinstance(entry, dict) else None


def _group_allowlist(telegram: dict[str, Any], group: dict[str, Any] | None) -> Allowlist:
    entries = group.get("allowFrom") if group is not None else None
    if entries is None:
        entries = telegram.get("groupAllowFrom")
    if entries is None:
        entries = telegram.get("allowFrom")
    return allowlist(entries)


def admission(config: dict[str, Any], chat_id: str, sender: str) -> Admission:
    """Would OpenClaw 2026.9.4 hand this sender's mentioning group message to the agent?

    The steps and their order are the gateway's own: `evaluateTelegramGroupBaseAccess`,
    then `evaluateTelegramGroupPolicyAccess` with `resolveChannelGroupPolicy` for the
    chat. The reasons follow the wording of the gateway's own log lines, so one can be
    matched to the other. Forum topics and named accounts are not modelled; the
    household group has neither.
    """
    telegram = telegram_section(config)
    if telegram is None:
        return Admission(False, "no telegram channel configured")
    if telegram.get("enabled") is False:
        return Admission(False, "telegram channel disabled")
    groups = _group_entries(telegram)
    group = _group_config(telegram, chat_id)

    if group is not None and group.get("enabled") is False:
        return Admission(False, "group disabled")
    override = group.get("allowFrom") if group is not None else None
    if override is not None:
        listed = allowlist(override)
        if not listed.has_entries or not listed.allows(sender):
            return Admission(False, "group allowFrom override")

    # The channel's groupPolicy defaults to allowlist when the config does not set it:
    # the schema fills it in before the gateway reads it.
    root_policy = telegram.get("groupPolicy") or "allowlist"
    policy = (group.get("groupPolicy") if group is not None else None) or root_policy
    if policy == "disabled":
        return Admission(False, "groupPolicy: disabled")

    allowlist_on = root_policy == "allowlist" or bool(groups)
    chat_allowed = root_policy != "disabled" and (
        not allowlist_on or "*" in groups or group is not None
    )
    if allowlist_on and not chat_allowed:
        return Admission(False, "not-allowed")
    listed_by_id = allowlist_on and chat_allowed and isinstance(groups.get(chat_id), dict)

    if policy == "allowlist":
        senders = _group_allowlist(telegram, group)
        # With no sender list anywhere, a group listed by its own id lets every member
        # in, and a group let in by "*" alone lets nobody in.
        if not senders.has_entries:
            if not listed_by_id:
                return Admission(False, "groupPolicy: allowlist, no group allowlist entries")
        elif not senders.allows(sender):
            return Admission(False, "groupPolicy: allowlist, sender not listed")
    return Admission(True)


def mention_required(config: dict[str, Any], chat_id: str) -> bool:
    """The group's requireMention: its own entry, then "*", then OpenClaw's default, on.

    A person can still flip one conversation with `/activation always`, which is session
    state rather than config and so is not visible here.
    """
    telegram = telegram_section(config) or {}
    groups = _group_entries(telegram)
    for key in (chat_id, "*"):
        node = groups.get(key)
        if isinstance(node, dict) and isinstance(node.get("requireMention"), bool):
            return bool(node["requireMention"])
    return True


def token_source(config: dict[str, Any]) -> str:
    """Where the bot token comes from, without ever printing the token.

    `channels add --channel telegram --token` writes the token into openclaw.json as a
    literal, and a bot set up by hand that way keeps it there until someone moves it.
    """
    telegram = telegram_section(config) or {}
    token = telegram.get("botToken")
    if isinstance(token, dict):
        return f"env reference ({token.get('id', 'unnamed')})"
    if isinstance(token, str) and token:
        return "a literal in openclaw.json; move it to the env file"
    if telegram.get("tokenFile"):
        return "a token file"
    return "not in openclaw.json (TELEGRAM_BOT_TOKEN, if anything)"


def configured_model(config: dict[str, Any]) -> str:
    """The primary model the gateway's one agent answers on, as configured."""
    agents = config.get("agents")
    agents = agents if isinstance(agents, dict) else {}
    entries = agents.get("entries")
    main = entries.get("main") if isinstance(entries, dict) else None
    defaults = agents.get("defaults")
    for node in (main, defaults):
        model = node.get("model") if isinstance(node, dict) else None
        if isinstance(model, str) and model:
            return model
        if isinstance(model, dict) and isinstance(model.get("primary"), str):
            return str(model["primary"])
    return "not set"


def _main_agent(config: dict[str, Any]) -> dict[str, Any]:
    agents = config.get("agents")
    entries = agents.get("entries") if isinstance(agents, dict) else None
    main = entries.get("main") if isinstance(entries, dict) else None
    return main if isinstance(main, dict) else {}


def name_is_a_mention(config: dict[str, Any]) -> bool:
    """Whether saying the assistant's name, typed or spoken, counts as addressing it.

    OpenClaw builds that pattern from mentionPatterns when either level sets it, and
    otherwise from the agent's identity name in openclaw.json; a name that is only in
    the workspace's IDENTITY.md does not count. Without a pattern only the @handle and
    replies reach the bot, and a voice note is never checked for a name at all.
    """
    main = _main_agent(config)
    messages = config.get("messages")
    for chat in (
        main.get("groupChat"),
        messages.get("groupChat") if isinstance(messages, dict) else None,
    ):
        if isinstance(chat, dict) and "mentionPatterns" in chat:
            return bool(chat.get("mentionPatterns"))
    identity = main.get("identity")
    name = identity.get("name") if isinstance(identity, dict) else None
    return isinstance(name, str) and bool(name.strip())


def voice_preflight_disabled(config: dict[str, Any], chat_id: str) -> bool:
    """Whether the group skips transcribing a voice note to look for the name."""
    groups = _group_entries(telegram_section(config) or {})
    node = groups.get(chat_id)
    if not isinstance(node, dict):
        node = groups.get("*")
    return isinstance(node, dict) and node.get("disableAudioPreflight") is True


def ingests_skipped_messages(config: dict[str, Any], chat_id: str) -> bool:
    """Whether a message the gateway skipped still reaches its hooks, voice notes included.

    Off by default, and without it the family-room plugin never sees a voice note that
    did not name the assistant, so the note is gone.
    """
    groups = _group_entries(telegram_section(config) or {})
    node = groups.get(chat_id)
    if isinstance(node, dict) and "ingest" in node:
        return node.get("ingest") is True
    fallback = groups.get("*")
    return isinstance(fallback, dict) and fallback.get("ingest") is True


def _plugins(config: dict[str, Any]) -> dict[str, Any]:
    plugins = config.get("plugins")
    return plugins if isinstance(plugins, dict) else {}


def _string_list(value: object) -> list[str]:
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def room_plugin_problems(config: dict[str, Any]) -> list[str]:
    """What keeps the family-room plugin from running on this gateway, from its config."""
    plugins = _plugins(config)
    if plugins.get("enabled") is False:
        return ["plugins are switched off, so the family-room plugin cannot run"]
    wrong = []
    load = plugins.get("load")
    if ROOM_PLUGIN_PATH not in _string_list(load.get("paths") if isinstance(load, dict) else None):
        wrong.append(f"the family-room plugin is not loaded from {ROOM_PLUGIN_PATH}")
    if ROOM_PLUGIN in _string_list(plugins.get("deny")):
        wrong.append("plugins.deny blocks the family-room plugin")
    allow = plugins.get("allow")
    if isinstance(allow, list) and ROOM_PLUGIN not in _string_list(allow):
        wrong.append("plugins.allow leaves the family-room plugin out")
    entries = plugins.get("entries")
    entry = entries.get(ROOM_PLUGIN) if isinstance(entries, dict) else None
    if not isinstance(entry, dict) or entry.get("enabled") is not True:
        wrong.append("the family-room plugin is not enabled")
        return wrong
    hooks = entry.get("hooks")
    hooks = hooks if isinstance(hooks, dict) else {}
    if (
        hooks.get("allowConversationAccess") is not True
        or hooks.get("allowPromptInjection") is False
    ):
        wrong.append("the family-room plugin may not add context to a turn")
    settings = entry.get("config")
    if not isinstance(settings, dict) or settings.get("groupChatId") != FAMILY_GROUP:
        wrong.append(f"the family-room plugin is not watching The Fam ({FAMILY_GROUP})")
    return wrong


def _also_allowed(config: dict[str, Any]) -> list[object]:
    tools = config.get("tools")
    allowed = tools.get("alsoAllow") if isinstance(tools, dict) else None
    return allowed if isinstance(allowed, list) else []


def history_problems(config: dict[str, Any]) -> list[str]:
    """What keeps the assistant from reading the group's earlier messages."""
    wrong = []
    if HISTORY_TOOL not in _also_allowed(config):
        wrong.append(
            f"the assistant is not handed {HISTORY_TOOL}, so it cannot read the group's "
            "earlier messages"
        )
    if not sessions_kept_apart(config):
        wrong.append(
            f"DMs are not kept per sender and groups per group, so {HISTORY_TOOL} is never "
            "handed over"
        )
    return wrong


def history_patch(config: dict[str, Any]) -> dict[str, Any]:
    """The tool handed over and sessions kept apart, keeping what each list already held."""
    patch = session_patch(config)
    allowed = _also_allowed(config)
    if HISTORY_TOOL not in allowed:
        patch["tools"] = {"alsoAllow": [*allowed, HISTORY_TOOL]}
    return patch


@dataclass(frozen=True, slots=True)
class Finding:
    """One sender's outcome on one gateway, against what the policy says it should be."""

    who: str
    expected: bool
    outcome: Admission

    @property
    def holds(self) -> bool:
        return self.expected == self.outcome.admitted


def findings(config: dict[str, Any], persona: str) -> list[Finding]:
    allowed = set(GROUP_SENDERS[persona])
    found = [
        Finding(person, person in allowed, admission(config, FAMILY_GROUP, user_id))
        for person, user_id in HOUSEHOLD.items()
    ]
    found.append(Finding("anyone else", False, admission(config, FAMILY_GROUP, SOMEONE_ELSE)))
    return found


def problems(config: dict[str, Any], persona: str) -> list[str]:
    """Everything that keeps this gateway from following the policy. Empty means it does."""
    wrong = []
    for finding in findings(config, persona):
        if finding.holds:
            continue
        if finding.expected:
            wrong.append(f"{finding.who} dropped ({finding.outcome.reason})")
        else:
            wrong.append(f"{finding.who} answered")
    telegram = telegram_section(config) or {}
    senders = _group_allowlist(telegram, _group_config(telegram, FAMILY_GROUP))
    allowed = {HOUSEHOLD[person] for person in GROUP_SENDERS[persona]}
    unexpected = sorted(
        sender
        for sender in senders.ids - allowed
        if admission(config, FAMILY_GROUP, sender).admitted
    )
    if unexpected:
        wrong.append(f"unexpected senders answered: {', '.join(unexpected)}")
    if not mention_required(config, FAMILY_GROUP):
        wrong.append("answers unmentioned messages")
    if not name_is_a_mention(config):
        wrong.append("its name is not a mention, so only its @handle and replies reach it")
    if voice_preflight_disabled(config, FAMILY_GROUP):
        wrong.append("voice notes are not checked for its name")
    if not ingests_skipped_messages(config, FAMILY_GROUP):
        wrong.append("a voice note that does not name it is dropped unheard")
    wrong.extend(room_plugin_problems(config))
    wrong.extend(history_problems(config))
    return wrong


def policy_patch(persona: str) -> dict[str, Any]:
    """The change `apply` makes: The Fam listed by id, its senders, mention on.

    Listing the group by id with its own allowFrom leaves every other setting alone.
    DMs keep their own allowFrom and pairing, other groups keep "*", and a sender list
    on the group itself overrides the channel's for this group only. Checking voice
    notes for the name is OpenClaw's default; it is written out so a "*" entry cannot
    turn it off for The Fam. `ingest` shows the messages the gateway skipped to its
    hooks, which is how the family-room plugin hears a voice note that named nobody.
    """
    return {
        "channels": {
            "telegram": {
                "groups": {
                    FAMILY_GROUP: {
                        "requireMention": True,
                        "allowFrom": [HOUSEHOLD[person] for person in GROUP_SENDERS[persona]],
                        "disableAudioPreflight": False,
                        "ingest": True,
                    }
                }
            }
        }
    }


def room_plugin_patch(config: dict[str, Any]) -> dict[str, Any]:
    """The family-room plugin's entry, and its path added to the lists that name plugins.

    A patch replaces a list whole, so each list is written back with what it already
    held. A deny entry, a global switch-off or prompt injection turned off are left for
    a person: `plan` refuses rather than undo a decision someone made on purpose.
    """
    plugins = _plugins(config)
    patch: dict[str, Any] = {
        "entries": {
            ROOM_PLUGIN: {
                "enabled": True,
                "hooks": {"allowConversationAccess": True},
                "config": {"groupChatId": FAMILY_GROUP},
            }
        }
    }
    load = plugins.get("load")
    paths = load.get("paths") if isinstance(load, dict) else None
    if ROOM_PLUGIN_PATH not in _string_list(paths):
        patch["load"] = {"paths": [*(paths if isinstance(paths, list) else []), ROOM_PLUGIN_PATH]}
    allow = plugins.get("allow")
    if isinstance(allow, list) and ROOM_PLUGIN not in _string_list(allow):
        patch["allow"] = [*allow, ROOM_PLUGIN]
    return {"plugins": patch}


def name_patch(persona: str) -> dict[str, Any]:
    """The agent's name in openclaw.json, for a gateway whose name is not a mention."""
    return {"agents": {"entries": {"main": {"identity": {"name": persona.capitalize()}}}}}


@dataclass(frozen=True, slots=True)
class BotProbe:
    """What Telegram says about the bot, through the gateway's own probe."""

    username: str | None = None
    reads_all_group_messages: bool | None = None
    error: str | None = None


def probe_bot(gateway: Gateway, run: Runner) -> BotProbe:
    """`channels status --probe` asks Telegram's getMe with the gateway's own token.

    The token never leaves the container. The probe is read-only.
    """
    try:
        completed = ask_gateway(
            gateway, run, "channels", "status", "--probe", "--json", "--channel", "telegram"
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return BotProbe(error=str(error))
    status = first_json_object(completed.stdout, "channels")
    channels = status.get("channels") if status is not None else None
    telegram = channels.get("telegram") if isinstance(channels, dict) else None
    if not isinstance(telegram, dict):
        return BotProbe(error=(completed.stderr or completed.stdout).strip()[-300:] or "no answer")
    probe = telegram.get("probe")
    bot = probe.get("bot") if isinstance(probe, dict) else None
    if not isinstance(bot, dict):
        detail = telegram.get("lastError") or "the gateway returned no bot details"
        return BotProbe(error=str(detail))
    reads_all = bot.get("canReadAllGroupMessages")
    username = bot.get("username")
    return BotProbe(
        username=str(username) if username else None,
        reads_all_group_messages=reads_all if isinstance(reads_all, bool) else None,
        error=str(telegram["lastError"]) if telegram.get("lastError") else None,
    )


def probe_room_plugin(gateway: Gateway, run: Runner) -> str | None:
    """None when the gateway has the family-room plugin loaded, else what it said.

    Calls the plugin's own method with no posts, which keeps nothing and writes nothing.
    """
    params = json.dumps({"speaker": "Check", "posts": []})
    try:
        completed = ask_gateway(
            gateway, run, "gateway", "call", f"{ROOM_PLUGIN}.peer", "--params", params, "--json"
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return str(error)
    if completed.returncode == 0 and first_json_object(completed.stdout, "accepted") is not None:
        return None
    failure = first_json_object(completed.stdout, "error")
    said = failure.get("error") if failure is not None else None
    if isinstance(said, dict) and said.get("message"):
        return str(said["message"])
    return (completed.stderr or completed.stdout).strip()[-200:] or "no answer"


def describe(finding: Finding) -> str:
    if finding.outcome.admitted:
        said = "answered when they mention the bot"
    else:
        said = f"dropped ({finding.outcome.reason})"
    if finding.holds:
        return said
    return f"{said}   <- should be {'answered' if finding.expected else 'dropped'}"


def privacy_line(probe: BotProbe) -> str:
    if probe.reads_all_group_messages is True:
        return "off: Telegram delivers every group message to this bot"
    if probe.reads_all_group_messages is False:
        return (
            "on: Telegram delivers only @mentions, replies to the bot and commands, "
            "so no voice notes, unless the bot is a group admin"
        )
    return f"unknown ({probe.error or 'not probed'})"


def report(gateway: Gateway, *, probe: BotProbe | None, room: str | bool | None = False) -> bool:
    """Print one gateway's block. True when it follows the policy.

    `room` is the family-room probe: False when it was not run, None when the plugin
    answered, or what the gateway said instead.
    """
    print(f"{gateway.persona} ({gateway.container}), {gateway.person}'s assistant")
    try:
        config = read_config(gateway)
        found = findings(config, gateway.persona)
        wrong = problems(config, gateway.persona)
    except (OSError, ValueError) as error:
        hint = " (run as root)" if isinstance(error, PermissionError) else ""
        field("unreadable", f"{error}{hint}")
        print()
        return False
    for finding in found:
        field(finding.who, describe(finding))
    field("mention", "required" if mention_required(config, FAMILY_GROUP) else "NOT required")
    if probe is not None:
        field("bot", f"@{probe.username}" if probe.username else "unknown")
        field("privacy", privacy_line(probe))
    field("token", token_source(config))
    field("model", configured_model(config))
    if room is not False:
        field("room", "the family-room plugin is loaded" if room is None else f"NOT loaded: {room}")
    if probe is not None and probe.reads_all_group_messages is False:
        wrong.append("Telegram privacy mode is on, so voice notes never reach it")
    if isinstance(room, str):
        wrong.append("the family-room plugin is not running")
    field("verdict", "; ".join(wrong) if wrong else "follows the policy")
    print()
    return not wrong


def check(gateways: Sequence[Gateway], *, run: Runner, probe: bool) -> int:
    print(f"The Fam ({FAMILY_GROUP}): what each gateway does with a message that mentions it")
    print()
    healthy = [
        report(
            gateway,
            probe=probe_bot(gateway, run) if probe else None,
            room=probe_room_plugin(gateway, run) if probe else False,
        )
        for gateway in gateways
    ]
    return 0 if all(healthy) else 1


def verdict(container: str, state: Path) -> str:
    """One word for openclaw-verify.sh: `ok`, or what is wrong with this one gateway."""
    gateway = gateway_for(container, state)
    if gateway is None:
        return f"no policy for container {container}"
    try:
        wrong = problems(read_config(gateway), gateway.persona)
    except (OSError, ValueError) as error:
        return f"unreadable: {error}"
    return "; ".join(wrong) if wrong else "ok"


@dataclass(frozen=True, slots=True)
class Plan:
    gateway: Gateway
    patch: dict[str, Any]
    needed: bool


def plan(gateway: Gateway) -> Plan:
    """The patch for one gateway, refused unless the result would follow the policy."""
    if not ROOM_PLUGIN_ON_HOST.is_file():
        raise UnsupportedConfig(
            f"the family-room plugin is not installed at {ROOM_PLUGIN_ON_HOST.parent}; run "
            "scripts/openclaw-install.sh first, which also mounts it into both containers"
        )
    config = read_config(gateway)
    group = _group_config(telegram_section(config) or {}, FAMILY_GROUP)
    if group is not None and (
        group.get("enabled") is False or group.get("groupPolicy") == "disabled"
    ):
        raise UnsupportedConfig(
            f"{gateway.persona}: the group was switched off on purpose, so look before changing it"
        )
    patch = patched(policy_patch(gateway.persona), room_plugin_patch(config))
    patch = patched(patch, history_patch(config))
    if not name_is_a_mention(config):
        patch = patched(patch, name_patch(gateway.persona))
    result = patched(config, patch)
    wrong = problems(result, gateway.persona)
    if wrong:
        raise UnsupportedConfig(
            f"{gateway.persona}: the group entry alone would not fix this ({'; '.join(wrong)}); "
            "something else was switched off on purpose, so look before changing it"
        )
    return Plan(gateway, patch, needed=result != config)


def apply(gateways: Sequence[Gateway], *, run: Runner, dry_run: bool) -> int:
    """Validate and back up both gateways before writing, restoring attempted writes on failure."""
    try:
        plans = [plan(gateway) for gateway in gateways]
    except (OSError, ValueError) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    pending = [p for p in plans if p.needed]
    for p in plans:
        if not p.needed:
            print(f"{p.gateway.persona}: already follows the policy, nothing to write")
    if not pending:
        return 0
    try:
        for p in pending:
            config_patch(p.gateway, p.patch, run, dry_run=True)
            print(f"{p.gateway.persona}: the gateway validated the patch")
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    if dry_run:
        print()
        print("dry run: nothing written. The patch for each gateway:")
        for p in pending:
            print(f"  {p.gateway.persona}: {json.dumps(p.patch)}")
        return 0

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    try:
        backups = [(p, backup(p.gateway, "family-group", stamp)) for p in pending]
    except (OSError, ValueError) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    attempted: list[tuple[Plan, Path]] = []
    try:
        for p, saved in backups:
            attempted.append((p, saved))
            config_patch(p.gateway, p.patch, run, dry_run=False)
            print(f"{p.gateway.persona}: written; previous config at {saved}")
        if check(gateways, run=run, probe=False) != 0:
            raise RuntimeError("written configs do not follow the policy")
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"apply failed: {error}", file=sys.stderr)
        for p, saved in reversed(attempted):
            try:
                restored = run(
                    [
                        "docker",
                        "exec",
                        p.gateway.container,
                        "cp",
                        f"/home/node/.openclaw/{saved.name}",
                        "/home/node/.openclaw/openclaw.json",
                    ],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    timeout=GATEWAY_TIMEOUT_SECONDS,
                    check=False,
                )
                if restored.returncode != 0:
                    detail = (restored.stderr or restored.stdout).strip()[-600:]
                    raise RuntimeError(f"{p.gateway.container} refused the restore: {detail}")
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as recovery_error:
                print(
                    f"{p.gateway.persona}: rollback failed; previous config at {saved}: "
                    f"{recovery_error}",
                    file=sys.stderr,
                )
            else:
                print(
                    f"{p.gateway.persona}: restored previous config from {saved}", file=sys.stderr
                )
        return 1
    print()
    print("Each gateway hot-reloads the change; its log says so within seconds:")
    for p in pending:
        print(f"  docker logs --since 5m {p.gateway.container} 2>&1 | grep 'hot reload'")
    print()
    return 0


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways side by side")
    applier = commands.add_parser("apply", help="write the group entry into both gateways")
    applier.add_argument(
        "--dry-run", action="store_true", help="validate the patch on both, write nothing"
    )
    applier.add_argument(
        "--gateway",
        choices=[gateway.persona for gateway in GATEWAYS],
        help="write only this gateway, to roll a change out one at a time",
    )
    one = commands.add_parser("verdict", help="one gateway, one line, for openclaw-verify.sh")
    one.add_argument("--container", required=True)
    one.add_argument("--state", required=True, type=Path)
    arguments = parser.parse_args(argv)

    if arguments.command == "verdict":
        print(verdict(arguments.container, arguments.state))
        return 0
    if arguments.command == "check":
        return check(GATEWAYS, run=run, probe=True)
    if os.geteuid() != 0:
        parser.error("run as root on the box")
    chosen = [gateway for gateway in GATEWAYS if arguments.gateway in (None, gateway.persona)]
    return apply(chosen, run=run, dry_run=arguments.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
