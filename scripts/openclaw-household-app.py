#!/usr/bin/env python3
"""Names the household app's channel in one gateway's config, as root on the box.

The household-app plugin (deploy/openclaw/plugins/household-app) is the family's own
app as an OpenClaw channel: the family room both people and both assistants share, and
each person's thread with their assistant. scripts/household-app-install.sh puts it in
the plugin mount; nothing loads it until this names it in a gateway's config:

- the plugin, loaded from the mount and enabled;
- `channels.household`: whose gateway this is, its assistant, and who is on the other
  gateway, with each person's paired phones pinned;
- `household:<person>` in `commands.ownerAllowFrom`, so the owner is the owner in the
  app as on Telegram, and nobody else is;
- `channels.household.familyTools`: The Fam's tool allowlist on this gateway, so a
  family-room turn gets the tools a turn in The Fam gets. The Telegram entry is the one
  source: with no plain allowlist there, the room's list is removed and the plugin gives
  family-room turns no tools at all, and `apply` says so;
- the plugin's `household_location` tool in `tools.alsoAllow`, so the assistant can say
  where its owner is in the owner's own thread, while the owner shares it from the app;
- the plugin's `household_cart` tool beside it, the household's shared shopping cart;
- the plugin's `household_today` tool beside them, with which the assistant writes the
  Today card above the pins on Chats, and `household_brief`, its one line for the day,
  which the phones from before the card show and each card writes too;
- the plugin's `household_react` tool beside them, with which the assistant puts a tapback
  on a person's message in the app, sparingly;
- the plugin's `household_note` tool beside them, the household note both assistants keep
  for what the family tracks together, which every app turn starts with;
- the plugin's turn hook allowed (`hooks.allowConversationAccess`), which OpenClaw asks of
  a plugin loaded from a path: it adds the assistant's name and how its person asked it to
  talk, from the app's Settings, to every turn, Telegram's included;
- `channels.household.talkDailyCharacters`: how many characters the gateway speaks for
  Talk and voice samples in a day, written only where a gateway has none, so a ceiling a
  person set stays;
- `channels.household.googleClientId`: Google's iOS OAuth client the app signs in with for
  Connect Google, which the gateway exchanges the phone's code with. It is not a secret,
  and it must be the one in the app's project.yml;
- the Today card, a scheduled job in the gateway's own scheduler rather than its config:
  at 4:45 each morning, before the phone's 5 AM morning reset, and at 16:45 for tonight and
  tomorrow morning, in the gateway's time zone, a run of the main agent of its own reads
  the day and writes the card with `household_today`, delivering to no chat. It is added
  by the daily brief's declaration key, so the brief's job becomes the card's, apply again
  changes nothing and a changed job is put back, and check reports one missing or changed.
  A job someone switched off stays off.

The phones are read from each gateway's own pairing list: this gateway's for its owner,
the other's for the other person. Their keys are what the gateways check a family-room
message's signature against, so the list printed here is worth reading: it should name
exactly the phones each person paired. Run apply again after a phone is paired or
replaced.

One gateway at a time, as the household's rollouts go:

    python3 scripts/openclaw-household-app.py check
    python3 scripts/openclaw-household-app.py apply --gateway corey --dry-run
    python3 scripts/openclaw-household-app.py apply --gateway corey

Writing the channel restarts that gateway's channels in process. Telegram is disabled;
its old family allowlist is retained only as the existing privacy policy for app turns.
"""

from __future__ import annotations

import argparse
import datetime
import os
import subprocess
import sys
import time
from collections.abc import Sequence
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
    first_json_object,
    gateway_cli,
    load_household,
    patched,
    read_config,
    sessions_kept_apart,
)

PLUGIN = "household-app"
PLUGIN_PATH = f"/opt/household-plugins/{PLUGIN}"
PLUGIN_ON_HOST = Path(f"/opt/household-assistant/plugins/{PLUGIN}/openclaw.plugin.json")
CHANNEL = "household"
PEOPLE = {"franco": "Franco", "gia": "Gia"}
# The household's identifiers, from the box's household file.
IDENTIFIERS = load_household()
# Where each person's phone reaches their assistant's gateway: the box's tailnet routes
# (docs/deploy/openclaw.md). The /app setup code carries it, so nobody types an address.
PHONE_URLS = {
    "corey": f"wss://{IDENTIFIERS.gateway_host}:18789",
    "denise": f"wss://{IDENTIFIERS.gateway_host}:18790",
}
# Who lets a new phone in that signed in with Apple, from his own app, on both gateways.
APPROVER = "franco"
# The Fam, whose tool allowlist the family room copies.
FAMILY_GROUP = IDENTIFIERS.family_group
# The plugin's tools: where the owner is while they share it, the household's shared
# cart, the assistant's Today card and its line for the day, the house's thermostat and
# music, a tapback on a person's message, the household note, a draft the owner sends
# with one tap, and the Sunday digest. They are optional, so under a tool profile only
# `tools.alsoAllow` hands them to the model.
APP_TOOLS = [
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
# The PocketPiggies guard rewrites `tools.alsoAllow` as everything else in its order,
# then these three. Putting the new tool before them leaves the guard nothing to do.
# Must equal FINANCE_TOOLS in pocket-piggies-install.py.
FINANCE_TOOLS = ["pocketpiggies_catalog", "pocketpiggies_read", "pocketpiggies_records"]
# Talk's daily ceiling. At two cents for each thousand characters of ElevenLabs speech
# through OpenRouter that is 40 cents a day for each assistant.
TALK_DAILY_CHARACTERS = 20000
# Google's iOS OAuth client for com.siqstack.stewardai (PKCE, no secret). The app's
# build carries the part before the ending (GOOGLE_IOS_CLIENT_ID), and the gateway
# refuses a code exchange with any other client.
GOOGLE_CLIENT_ID = IDENTIFIERS.google_client_id
# The Today card's job. A cron expression with no time zone runs on the gateway's own
# clock, which the compose file sets to the household's: 4:45 prepares a fresh verse
# before the phone's 5 AM morning reset, and 16:45 writes tonight and tomorrow
# morning. An isolated run starts with no chat to answer, and `--no-deliver` keeps its
# last words off every chat, so the card reaches the phone only through the tool. The
# declaration key, the daily brief's before it, makes adding it again bring the one job to
# this shape rather than add a second, and leaves whether it is on alone.
TODAY_JOB_KEY = "household-app:daily-brief"
TODAY_JOB_NAME = "Today card"
TODAY_SCHEDULE = "45 4,16 * * *"
TODAY_PROMPT = (
    "Write the Today card for the Steward AI app, what your person sees at the top of their "
    "conversations. Read today's calendar, today's reminders and your own scheduled jobs for "
    "today and tomorrow morning, and think of anything else you know about today. Then call "
    "household_today once with what is still ahead from now until tomorrow noon, the soonest "
    "first, at most eight, each with its start time and a short title, and for the first one or "
    "two a short detail that helps, such as when to leave. Use where someone is only from what "
    "they share with you in Steward now, and another person's plans only from what they told "
    "you or said in the family room. In the morning, give today's verse: the one from the "
    "devotional you sent this morning, or if it has not run yet, one you choose now with the "
    "scripture skill, not yesterday's, with its reference exactly as the skill prints it, its "
    "words and its link. Do not wait for a later devotional job. Later in the day, leave the "
    "verse out to keep the morning's. Send "
    "nothing to any chat or person and change nothing. Once it is written, reply NO_REPLY."
)
TODAY_JOB_COMMAND = [
    "automations",
    "add",
    "--declaration-key",
    TODAY_JOB_KEY,
    "--name",
    TODAY_JOB_NAME,
    "--cron",
    TODAY_SCHEDULE,
    "--agent",
    "main",
    "--session",
    "isolated",
    "--message",
    TODAY_PROMPT,
    "--no-deliver",
    "--json",
]
# What `automations list --json` shows of that job when it is as apply adds it.
TODAY_JOB_SHAPE: dict[str, object] = {
    "name": TODAY_JOB_NAME,
    "agent": "main",
    "schedule": ("cron", TODAY_SCHEDULE, None),
    "session": "isolated",
    "prompt": ("agentTurn", TODAY_PROMPT, None),
    "delivery": ("none", None, None),
}
# The Steward app names itself `openclaw-ios` in the handshake (apps/ios ClientInfo).
APP_CLIENT = "openclaw-ios"
KEY_LENGTH = 43
# How long the gateway gets to restart onto the plugin before the channel is written.
LOAD_WAIT_SECONDS = 180
LOAD_POLL_SECONDS = 5

__all__ = ["GATEWAYS", "Gateway", "UnsupportedConfig", "patched"]


def _section(config: dict[str, Any], key: str) -> dict[str, Any]:
    value = config.get(key)
    return value if isinstance(value, dict) else {}


def _strings(value: object) -> list[str]:
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def _is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _also_allowed(config: dict[str, Any]) -> list[object]:
    allowed = _section(config, "tools").get("alsoAllow")
    return allowed if isinstance(allowed, list) else []


def assistant_identity(config: dict[str, Any], persona: str) -> dict[str, str]:
    """The assistant's name and emoji as its gateway gives them, for the family room."""
    main = _section(_section(_section(config, "agents"), "entries"), "main")
    identity = _section(main, "identity")
    name = identity.get("name")
    emoji = identity.get("emoji")
    found = {
        "name": name.strip() if isinstance(name, str) and name.strip() else persona.capitalize()
    }
    if isinstance(emoji, str) and emoji.strip():
        found["emoji"] = emoji.strip()
    return found


def family_tools(config: dict[str, Any]) -> list[str] | None:
    """The Fam's tool allowlist on this gateway, which the family room copies.

    Only The Fam's own entry counts, and only a non-empty `tools.allow` of names with
    nothing beside it, since a copy of the allow list alone would drop a deny. None
    otherwise, and the family room then gets no tools.
    """
    groups = _section(_section(_section(config, "channels"), "telegram"), "groups")
    tools = _section(_section(groups, FAMILY_GROUP), "tools")
    names = _strings(tools.get("allow"))
    if list(tools) != ["allow"] or not names or names != tools["allow"]:
        return None
    return names


def _app_phones(devices: dict[str, Any]) -> list[dict[str, Any]]:
    rows = devices.get("paired")
    return [
        row
        for row in (rows if isinstance(rows, list) else [])
        if isinstance(row, dict)
        and row.get("clientId") == APP_CLIENT
        and row.get("role") == "operator"
        and isinstance(row.get("publicKey"), str)
        and len(row["publicKey"]) == KEY_LENGTH
        and all(character.isalnum() or character in "-_" for character in row["publicKey"])
    ]


def phone_keys(devices: dict[str, Any]) -> list[str]:
    """The public keys of the app's paired phones in one `devices list --json` answer."""
    return [row["publicKey"] for row in _app_phones(devices)]


def describe_phones(devices: dict[str, Any]) -> list[str]:
    """One line per pinned phone, without its key."""
    lines = []
    for row in _app_phones(devices):
        approved = row.get("approvedAtMs")
        day = (
            datetime.datetime.fromtimestamp(approved / 1000, tz=datetime.UTC).strftime("%Y-%m-%d")
            if isinstance(approved, int)
            else "at an unknown time"
        )
        lines.append(f"{row.get('deviceId')} {row.get('displayName') or 'unnamed'}, approved {day}")
    return lines


def refusals(config: dict[str, Any]) -> None:
    """Raise for a setting someone chose on purpose that this would have to undo."""
    plugins = _section(config, "plugins")
    if plugins.get("enabled") is False:
        raise UnsupportedConfig(
            "plugins are switched off on this gateway; turn them on by hand first"
        )
    if PLUGIN in _strings(plugins.get("deny")):
        raise UnsupportedConfig(f"plugins.deny blocks {PLUGIN}; take it out by hand first")
    if not sessions_kept_apart(config):
        raise UnsupportedConfig(
            "this gateway keeps every DM or group in one shared main session; the app's "
            "threads need DMs per person and groups per group (openclaw-family-group.py apply)"
        )


def plugin_patch(config: dict[str, Any]) -> dict[str, Any]:
    """The plugin, loaded from the mount and enabled, and its tool handed to the model.

    It goes first and on its own: 2026.9.4 validates `channels.household` against the
    plugins the gateway has already loaded, so the channel is refused until this has been
    written and the gateway has restarted onto it. With no channel named, the plugin
    starts nothing and its tool tells nothing. A patch replaces a list whole, so each list
    keeps what it held.
    """
    plugins = _section(config, "plugins")
    patch: dict[str, Any] = {
        "entries": {PLUGIN: {"enabled": True, "hooks": {"allowConversationAccess": True}}}
    }
    paths = _section(plugins, "load").get("paths")
    if PLUGIN_PATH not in _strings(paths):
        patch["load"] = {"paths": [*(paths if isinstance(paths, list) else []), PLUGIN_PATH]}
    allow = plugins.get("allow")
    if isinstance(allow, list) and PLUGIN not in _strings(allow):
        patch["allow"] = [*allow, PLUGIN]
    whole: dict[str, Any] = {"plugins": patch}
    allowed = _also_allowed(config)
    missing = [tool for tool in APP_TOOLS if tool not in allowed]
    if missing:
        others = [tool for tool in allowed if tool not in FINANCE_TOOLS]
        finance = [tool for tool in allowed if tool in FINANCE_TOOLS]
        whole["tools"] = {"alsoAllow": [*others, *missing, *finance]}
    return whole


def channel_patch(
    config: dict[str, Any],
    gateway: Gateway,
    peer: Gateway,
    *,
    owner_keys: list[str],
    peer_keys: list[str],
    peer_identity: dict[str, str],
) -> dict[str, Any]:
    """The household channel for this gateway's person, and that person as its owner."""
    room: dict[str, Any] = {
        "enabled": True,
        "owner": {"id": gateway.person, "name": PEOPLE[gateway.person], "deviceKeys": owner_keys},
        "assistant": {"id": gateway.persona, **assistant_identity(config, gateway.persona)},
        "peer": {
            "person": {"id": peer.person, "name": PEOPLE[peer.person], "deviceKeys": peer_keys},
            "assistant": {
                "id": peer.persona,
                "name": peer_identity.get("name") or peer.persona.capitalize(),
            },
        },
        "phoneUrl": PHONE_URLS[gateway.persona],
        "approver": APPROVER,
        "googleClientId": GOOGLE_CLIENT_ID,
    }
    existing = _section(_section(config, "channels"), CHANNEL)
    if not _is_count(existing.get("talkDailyCharacters")):
        room["talkDailyCharacters"] = TALK_DAILY_CHARACTERS
    tools = family_tools(config)
    if tools is not None:
        room["familyTools"] = tools
    elif "familyTools" in existing:
        # A list The Fam no longer has goes with it.
        room["familyTools"] = None
    patch: dict[str, Any] = {"channels": {CHANNEL: room}}
    if "telegram" in _section(config, "channels"):
        patch["channels"]["telegram"] = {"enabled": False}
    owners = _section(config, "commands").get("ownerAllowFrom")
    owner_entry = f"{CHANNEL}:{gateway.person}"
    if owner_entry not in _strings(owners):
        patch["commands"] = {
            "ownerAllowFrom": [*(owners if isinstance(owners, list) else []), owner_entry]
        }
    return patch


def household_patch(
    config: dict[str, Any],
    gateway: Gateway,
    peer: Gateway,
    *,
    owner_keys: list[str],
    peer_keys: list[str],
    peer_identity: dict[str, str],
) -> dict[str, Any]:
    """Everything that makes this gateway run the app's channel for its person."""
    return {
        **plugin_patch(config),
        **channel_patch(
            config,
            gateway,
            peer,
            owner_keys=owner_keys,
            peer_keys=peer_keys,
            peer_identity=peer_identity,
        ),
    }


def _channel_validates(gateway: Gateway, patch: dict[str, Any], run: Runner) -> bool:
    try:
        config_patch(gateway, patch, run, dry_run=True)
    except RuntimeError:
        return False
    return True


def problems(config: dict[str, Any], gateway: Gateway) -> list[str]:
    """What keeps this gateway from running the app's channel for its person."""
    wrong = []
    plugins = _section(config, "plugins")
    if plugins.get("enabled") is False:
        wrong.append("plugins are switched off")
    if PLUGIN_PATH not in _strings(_section(plugins, "load").get("paths")):
        wrong.append(f"the {PLUGIN} plugin is not loaded from {PLUGIN_PATH}")
    if PLUGIN in _strings(plugins.get("deny")):
        wrong.append(f"plugins.deny blocks the {PLUGIN} plugin")
    allow = plugins.get("allow")
    if isinstance(allow, list) and PLUGIN not in _strings(allow):
        wrong.append(f"plugins.allow leaves the {PLUGIN} plugin out")
    entry = _section(_section(plugins, "entries"), PLUGIN)
    if entry.get("enabled") is not True:
        wrong.append(f"the {PLUGIN} plugin is not enabled")
    hooks = _section(entry, "hooks")
    if (
        hooks.get("allowConversationAccess") is not True
        or hooks.get("allowPromptInjection") is False
    ):
        wrong.append("the assistant's name and manner from Settings do not reach its turns")
    wrong.extend(
        f"the assistant is not handed {tool}"
        for tool in APP_TOOLS
        if tool not in _also_allowed(config)
    )
    room = _section(_section(config, "channels"), CHANNEL)
    if room.get("enabled") is False:
        wrong.append("the household channel is switched off")
    if not _is_count(room.get("talkDailyCharacters")):
        wrong.append("Talk has no daily ceiling")
    if room.get("googleClientId") != GOOGLE_CLIENT_ID:
        wrong.append("Connect Google in the app is not set up on this gateway")
    if (
        _section(room, "owner").get("id") != gateway.person
        or _section(room, "assistant").get("id") != gateway.persona
    ):
        wrong.append(
            f"the household channel does not name {gateway.person} and {gateway.persona} "
            "as this gateway's"
        )
    if f"{CHANNEL}:{gateway.person}" not in _strings(
        _section(config, "commands").get("ownerAllowFrom")
    ):
        wrong.append(f"{gateway.person} is not the owner in the app")
    if not sessions_kept_apart(config):
        wrong.append("DMs or groups share one main session")
    if _section(_section(config, "channels"), "telegram").get(
        "enabled"
    ) is not False and "telegram" in _section(config, "channels"):
        wrong.append("Telegram must be disabled; household communication uses the app")
    tools = family_tools(config)
    if tools is None:
        wrong.append(
            f"The Fam ({FAMILY_GROUP}) has no tool allowlist, so the family room gets no tools"
        )
    elif room.get("familyTools") != tools:
        wrong.append("the family room's tools are not The Fam's")
    return wrong


def _peer_of(gateway: Gateway) -> Gateway:
    return next(other for other in GATEWAYS if other.persona != gateway.persona)


def _devices(gateway: Gateway, run: Runner) -> dict[str, Any]:
    completed = ask_gateway(gateway, run, "devices", "list", "--json")
    if completed.returncode != 0:
        raise RuntimeError(f"{gateway.container} would not list its devices")
    return first_json_object(completed.stdout, "paired") or {"paired": []}


def today_job(jobs: dict[str, Any]) -> dict[str, Any] | None:
    """The Today card's job in one `automations list --all --json` answer, if any."""
    rows = jobs.get("jobs")
    return next(
        (
            row
            for row in (rows if isinstance(rows, list) else [])
            if isinstance(row, dict) and row.get("declarationKey") == TODAY_JOB_KEY
        ),
        None,
    )


def today_job_changes(job: dict[str, Any]) -> list[str]:
    """The parts of the Today card's job that are not as apply adds them."""
    schedule = _section(job, "schedule")
    payload = _section(job, "payload")
    delivery = _section(job, "delivery")
    # OpenClaw 2026.9.4 stores "last" as the channel of a job added with no channel at all,
    # and a job that delivers to nobody reaches no chat through it, so that is no change.
    channel = None if delivery.get("channel") == "last" else delivery.get("channel")
    found = {
        "name": job.get("name"),
        "agent": job.get("agentId"),
        "schedule": (schedule.get("kind"), schedule.get("expr"), schedule.get("tz")),
        "session": job.get("sessionTarget"),
        "prompt": (payload.get("kind"), payload.get("message"), payload.get("model")),
        "delivery": (delivery.get("mode"), channel, delivery.get("to")),
    }
    return [part for part, value in found.items() if value != TODAY_JOB_SHAPE[part]]


def describe_today_job(job: dict[str, Any] | None) -> str:
    if job is None:
        return "missing"
    changes = today_job_changes(job)
    if changes:
        return "changed: " + ", ".join(changes)
    return "switched off" if job.get("enabled") is False else "ok"


def _jobs(gateway: Gateway, run: Runner) -> dict[str, Any]:
    completed = ask_gateway(gateway, run, "automations", "list", "--all", "--json")
    jobs = first_json_object(completed.stdout, "jobs") if completed.returncode == 0 else None
    if jobs is None:
        raise RuntimeError(f"{gateway.container} would not list its scheduled jobs")
    return jobs


def _write_today_job(gateway: Gateway, run: Runner) -> None:
    _scheduler(gateway, run, TODAY_JOB_COMMAND)
    # OpenClaw 2026.9.4 brings a job it already has by the declaration key to the schedule
    # and prompt it is given, but keeps the job's name, which was the daily brief's.
    job = today_job(_jobs(gateway, run))
    if job is not None and job.get("name") != TODAY_JOB_NAME:
        _scheduler(gateway, run, ["cron", "edit", str(job.get("id")), "--name", TODAY_JOB_NAME])


def _scheduler(gateway: Gateway, run: Runner, command: list[str]) -> None:
    completed = run(
        gateway_cli(gateway, *command),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=GATEWAY_TIMEOUT_SECONDS,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()[-600:]
        raise RuntimeError(f"{gateway.container} refused the Today card's job: {detail}")


def verdict(container: str, state: Path) -> str:
    gateway = next((g for g in GATEWAYS if g.container == container), None)
    if gateway is None:
        return f"unknown container {container}"
    gateway = Gateway(gateway.persona, container, state, gateway.person)
    try:
        wrong = problems(read_config(gateway), gateway)
    except (OSError, ValueError) as error:
        return f"unreadable: {error}"
    return "; ".join(wrong) if wrong else "ok"


def check(gateways: Sequence[Gateway], run: Runner) -> int:
    healthy = True
    for gateway in gateways:
        print(f"{gateway.persona} ({gateway.container}):")
        try:
            config = read_config(gateway)
        except (OSError, ValueError) as error:
            print(f"  unreadable: {error}")
            healthy = False
            continue
        wrong = problems(config, gateway)
        print("  channel     " + ("ok" if not wrong else "; ".join(wrong)))
        room = _section(_section(config, "channels"), CHANNEL)
        owner_keys = _section(room, "owner").get("deviceKeys")
        peer_keys = _section(_section(room, "peer"), "person").get("deviceKeys")
        print(
            f"  phones      {len(_strings(owner_keys))} of {gateway.person}'s pinned, "
            f"{len(_strings(peer_keys))} of the other person's"
        )
        try:
            job = describe_today_job(today_job(_jobs(gateway, run)))
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            job = f"unreadable: {error}"
        print(f"  Today card  {job}")
        healthy = healthy and not wrong and job == "ok"
    return 0 if healthy else 1


def apply(gateway: Gateway, *, run: Runner, dry_run: bool) -> int:
    peer = _peer_of(gateway)
    try:
        if not PLUGIN_ON_HOST.is_file():
            raise RuntimeError(
                f"the {PLUGIN} plugin is not installed at {PLUGIN_ON_HOST.parent}; "
                "run scripts/household-app-install.sh first"
            )
        config = read_config(gateway)
        refusals(config)
        own_devices = _devices(gateway, run)
        peer_devices = _devices(peer, run)
        plugin = plugin_patch(config)
        needs_plugin = patched(config, plugin) != config
        channel = channel_patch(
            config,
            gateway,
            peer,
            owner_keys=phone_keys(own_devices),
            peer_keys=phone_keys(peer_devices),
            peer_identity=assistant_identity(read_config(peer), peer.persona),
        )
        needs_channel = patched(config, channel) != config
        job = today_job(_jobs(gateway, run))
        needs_job = job is None or bool(today_job_changes(job))
        is_job_off = not needs_job and job is not None and job.get("enabled") is False
        if not needs_plugin and not needs_channel and not needs_job:
            print(f"{gateway.persona}: nothing to write")
            if is_job_off:
                print("  Today card switched off, left as it is")
            return 0
        if needs_plugin:
            config_patch(gateway, plugin, run, dry_run=True)
            print(f"{gateway.persona}: the gateway validated the plugin")
            print("  the channel is validated once the gateway has loaded the plugin")
        elif needs_channel:
            config_patch(gateway, channel, run, dry_run=True)
            print(f"{gateway.persona}: the gateway validated the channel")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1

    for label, devices in (
        (f"{gateway.person}'s phones", own_devices),
        (f"{peer.person}'s phones", peer_devices),
    ):
        lines = describe_phones(devices)
        print(f"  {label}: " + ("none paired yet" if not lines else ""))
        for line in lines:
            print(f"    {line}")
    if family_tools(config) is None:
        print(
            f"  warning: The Fam ({FAMILY_GROUP}) has no tool allowlist here, so a family-room "
            "turn gets no tools until it has one and apply runs again"
        )
    if needs_job:
        print(
            f"  Today card {describe_today_job(job)}, apply writes it at {TODAY_SCHEDULE} in the "
            "gateway's time zone, as a run of the main agent of its own that delivers to no chat"
        )
    elif is_job_off:
        print("  Today card switched off, left as it is")
    if dry_run:
        print("dry run: nothing written.")
        return 0

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    saved: Path | None = None
    try:
        if needs_plugin or needs_channel:
            saved = backup(gateway, PLUGIN, stamp)
        if needs_plugin:
            config_patch(gateway, plugin, run, dry_run=False)
            print(f"{gateway.persona}: plugin written; waiting for the gateway to load it")
            deadline = time.monotonic() + LOAD_WAIT_SECONDS
            while not _channel_validates(gateway, channel, run):
                if time.monotonic() > deadline:
                    raise RuntimeError(
                        f"the gateway did not load the plugin within {LOAD_WAIT_SECONDS} s; "
                        "the plugin is written and the channel is not"
                    )
                time.sleep(LOAD_POLL_SECONDS)
        if needs_channel:
            config_patch(gateway, channel, run, dry_run=False)
        # After the config, so the tool its prompt names is the assistant's by its first run.
        if needs_job:
            _write_today_job(gateway, run)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"{gateway.persona}: not written: {error}", file=sys.stderr)
        return 1
    if saved is not None:
        print(f"{gateway.persona}: written; previous config at {saved}")
        print(f"  verdict: {verdict(gateway.container, gateway.state)}")
    if needs_job:
        print(f"{gateway.persona}: the Today card's job written")
    return 0


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways side by side")
    applier = commands.add_parser("apply", help="name the app's channel in one gateway's config")
    applier.add_argument(
        "--gateway", required=True, choices=[gateway.persona for gateway in GATEWAYS]
    )
    applier.add_argument("--dry-run", action="store_true", help="validate the patch, write nothing")
    one = commands.add_parser("verdict", help="one gateway, one line, for openclaw-verify.sh")
    one.add_argument("--container", required=True)
    one.add_argument("--state", required=True, type=Path)
    arguments = parser.parse_args(argv)

    if arguments.command == "verdict":
        print(verdict(arguments.container, arguments.state))
        return 0
    if arguments.command == "check":
        return check(GATEWAYS, run)
    # The real runner reaches the containers and the state, which only root may; a test
    # hands in its own runner and a throwaway state.
    if run is subprocess.run and hasattr(os, "geteuid") and os.geteuid() != 0:
        parser.error("run as root on the box")
    chosen = next(gateway for gateway in GATEWAYS if gateway.persona == arguments.gateway)
    return apply(chosen, run=run, dry_run=arguments.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
