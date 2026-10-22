#!/usr/bin/env python3
"""Every model, embedding and transcription route on both gateways goes to OpenRouter.

Routing policy, operator commands, validation evidence and recovery are documented
in docs/deploy/openclaw.md under "The model backend" and "The memory backend".
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from gateway_config import (
    GATEWAYS,
    Gateway,
    Runner,
    ask_gateway,
    backup,
    config_patch,
    field,
    first_json_object,
    gateway_cli,
    gateway_for,
    patched,
    read_config,
)

OPENROUTER_API = "https://openrouter.ai/api/v1"
OPENROUTER_KEY = "OPENROUTER_API_KEY"
OPENROUTER_PREFIX = "openrouter/"

# The chain both assistants answer on, the same on both so that neither is the weaker
# one by configuration. The primary is the owner-approved default; the larger GLM
# comes before DeepSeek V4 Flash because its free variant was measured ignoring the
# skill catalog (see the runbook's scripture section). That free variant left
# OpenRouter's list by 17 October 2026 (#199), so the chain names the same model's paid
# id, the cheapest live model for turns that are mostly prompt. Change it here and apply
# again; `check` and `verdict` report a model in the chain that OpenRouter no longer
# lists. Each person may pick their own assistant's primary and its second and third
# models, the fallbacks, from the app's Settings, any model on OpenRouter; apply keeps
# those choices and puts the household's fallbacks back only for fallbacks that are not
# distinct models OpenRouter lists apart from the primary.
CHAT_PRIMARY = "openrouter/z-ai/glm-5.3-flash"
CHAT_FALLBACKS = ("openrouter/z-ai/glm-5.3", "openrouter/deepseek/deepseek-v4-flash-0731")

# OpenRouter's public model list, read with no key.
OPENROUTER_MODELS = f"{OPENROUTER_API}/models"

# OpenRouter's own model ids, sent to its /audio/transcriptions and /embeddings.
TRANSCRIPTION_MODEL = "openai/whisper-large-v3-turbo"
EMBEDDING_MODEL = "openai/text-embedding-3-small"

# Photos the chat model is not handed itself: the image tool, and a photo the chat model
# cannot read, for which OpenClaw would otherwise try Anthropic, OpenAI and Google, never
# OpenRouter. OpenClaw calls this model with reasoning switched off, which glm-5.3-flash
# and gemini-3.5-flash refuse on OpenRouter ("Reasoning is mandatory"), measured on the
# box on 2026-10-07. OpenAI's newest image model, the owner's choice, and
# gemini-2.5-flash both described a test image correctly that way.
IMAGE_MODEL = "openrouter/openai/gpt-5.4-image-2"
IMAGE_FALLBACKS = ("openrouter/google/gemini-2.5-flash",)

# Completions that name no thinking level. OpenClaw 2026.9.4 sends them reasoning off
# ({"effort": "none"}), and OpenRouter refuses that for a model whose reasoning is
# mandatory, the chat primary glm-5.3-flash among them: memory-core's nightly dream diary
# fell back every night (#198) and new sessions got no title (#204), measured on the box
# on 2026-10-17. A model row cannot change what OpenClaw sends: for a model OpenRouter's
# live catalog lists, it applies a row's limits but not its thinkingLevelMap. So both
# slots such completions read name a model whose reasoning can be off, DeepSeek V4 Flash
# 0731, the chat chain's last fallback: agents.defaults.utilityModel (session and thread
# titles, progress narration, session observation, meeting notes) and memory-core's
# dreaming.model (the diary).
NO_THINKING_MODEL = "openrouter/deepseek/deepseek-v4-flash-0731"
DREAM_PLUGIN = "memory-core"

# Videos people send. OpenClaw 2026.9.4 describes a video only through Google directly,
# so the household-openrouter-video plugin registers this provider, which sends the
# video to OpenRouter's chat API, and tools.media.models routes video to it.
VIDEO_PROVIDER = "openrouter-video"
VIDEO_MODEL = "google/gemini-2.5-flash"
VIDEO_PLUGIN = "household-openrouter-video"
VIDEO_PLUGIN_PATH = f"/opt/household-plugins/{VIDEO_PLUGIN}"
VIDEO_PLUGIN_ON_HOST = Path(f"/opt/household-assistant/plugins/{VIDEO_PLUGIN}/openclaw.plugin.json")

# What pictures, videos and music are made with: household-pictures reads the image and
# video slots, and OpenClaw's own music_generate the music one. Left unset, OpenClaw's
# tools auto-detect whichever provider holds a key, so each is named to keep that
# OpenRouter. Images default to OpenRouter's current GPT image model, the owner's word of
# 17 October 2026, in its speed-oriented tier; video and music to OpenClaw 2026.9.4's own
# OpenRouter defaults. A model a phone picks in Settings (household-app's settings.js)
# stays, so these name only a slot that has no OpenRouter model.
GENERATION_MODELS = {
    "image": "openrouter/openai/gpt-image-2.5-flare",
    "video": "openrouter/google/veo-3.1-fast",
    "music": "openrouter/google/lyria-3-pro-preview",
}

# A spoken reply, when one is asked for, goes through OpenRouter's /audio/speech.
# Whether replies are spoken at all (`tts.auto`) stays as it was.
SPEECH_PROVIDER = "openrouter"

# Web search: Perplexity's Sonar, which OpenClaw reaches through the OpenRouter key.
# Left unset, auto-detection picks it when that is the only search key, and OpenAI's
# hosted search never wins auto-detection. `apply` does not write it: naming it needs
# the perplexity plugin installed, and 2026.9.4 refuses the whole patch without it.
SEARCH_PROVIDER = "perplexity"

# Keys whose value picks a model for some part of a turn.
MODEL_KEYS = frozenset(
    {
        "model",
        "primary",
        "fallbacks",
        "utilityModel",
        "imageModel",
        "pdfModel",
        "voiceModel",
        "preferredModel",
        "summaryModel",
    }
)

# Model slots that fall back to something sensible when unset, so one naming another
# provider is cleared rather than replaced: under agents.defaults they follow the chat
# chain, and under agents.entries.<id> they follow agents.defaults. The defaults' image,
# generation and utility models are named by `apply` itself, so it never clears them.
CLEARABLE_SLOTS = frozenset(
    {"utilityModel", "imageModel", "pdfModel", "voiceModel", "mediaModels", "heartbeat"}
)
SET_BY_APPLY = frozenset({"imageModel", "mediaModels", "utilityModel"})

# Changing memory.search restarts the gateway in process, measured at a second and a
# half on 2026.9.4, and a session patch sent during it fails.
PIN_ATTEMPTS = 3
PIN_RETRY_SECONDS = 5.0


def is_openrouter(ref: str) -> bool:
    return ref.startswith((OPENROUTER_PREFIX, f"{VIDEO_PROVIDER}/"))


def _skipped(path: tuple[str, ...]) -> bool:
    """Parts of the config that define providers or catalogs, or are judged on their own."""
    if path[:1] in (("models",), ("channels",)):
        return True
    if path[:3] == ("agents", "defaults", "models"):
        return True
    if path[:2] == ("memory", "search"):
        return True
    return len(path) >= 4 and path[:2] == ("agents", "entries") and path[3] in ("models", "memory")


def model_refs(node: object, path: tuple[str, ...] = ()) -> Iterator[tuple[tuple[str, ...], str]]:
    """Every (path, model ref) in the config that chooses a model for a turn.

    An entry that names its provider beside its model, `{"provider": "openrouter",
    "model": "openai/whisper-large-v3-turbo"}`, is read as one ref, because there the
    model is the provider's own id and its first segment is not a provider at all.
    So is a model in a block keyed by its provider, `providers.openrouter.model`, which
    is where a speech model is named.
    """
    if isinstance(node, dict):
        provider = node.get("provider")
        if not isinstance(provider, str) and path[-2:-1] == ("providers",):
            provider = path[-1]
        for key, value in node.items():
            here = (*path, str(key))
            if _skipped(here):
                continue
            if key == "model" and isinstance(provider, str) and isinstance(value, str) and value:
                yield here, f"{provider}/{value}"
            elif key in MODEL_KEYS and isinstance(value, str) and value:
                yield here, value
            elif key in MODEL_KEYS and isinstance(value, list):
                yield from ((here, item) for item in value if isinstance(item, str) and item)
            else:
                yield from model_refs(value, here)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from model_refs(value, (*path, str(index)))


def chat_chain(config: dict[str, Any]) -> tuple[str, ...]:
    defaults = (config.get("agents") or {}).get("defaults") or {}
    model = defaults.get("model")
    if isinstance(model, str):
        return (model,)
    if isinstance(model, dict):
        fallbacks = model.get("fallbacks") or []
        return (str(model.get("primary") or ""), *(str(item) for item in fallbacks))
    return ()


def chosen_primary(config: dict[str, Any]) -> str:
    """The chain's primary: a model on OpenRouter, as a phone may choose, or the default."""
    chain = chat_chain(config)
    primary = chain[0] if chain else ""
    return (
        primary
        if primary.startswith(OPENROUTER_PREFIX) and primary != OPENROUTER_PREFIX
        else CHAT_PRIMARY
    )


def chosen_fallbacks(config: dict[str, Any], catalog: dict[str, dict[str, Any]]) -> tuple[str, ...]:
    """The chain's fallbacks as a phone picked them, none of them the primary, each once
    and on OpenRouter's list, none at all once both were cleared; or else the household's."""
    model = _defaults(config).get("model")
    held = chat_chain(config)[1:]
    is_picked = (
        isinstance(model, dict)
        and isinstance(model.get("fallbacks"), list)
        and chosen_primary(config) not in held
        and len(set(held)) == len(held)
        and all(
            ref.startswith(OPENROUTER_PREFIX) and ref.removeprefix(OPENROUTER_PREFIX) in catalog
            for ref in held
        )
    )
    return held if is_picked else CHAT_FALLBACKS


def read_catalog(run: Runner) -> dict[str, dict[str, Any]]:
    """OpenRouter's public model list, by model id."""
    completed = run(
        ["curl", "--fail", "--silent", "--show-error", "--max-time", "30", OPENROUTER_MODELS],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"OpenRouter's model list could not be read: {completed.stderr.strip()}")
    try:
        models = json.loads(completed.stdout).get("data")
    except (ValueError, AttributeError):
        models = None
    if not isinstance(models, list):
        raise RuntimeError("OpenRouter's model list has no models")
    return {
        model["id"]: model
        for model in models
        if isinstance(model, dict) and isinstance(model.get("id"), str)
    }


def chain_problems(config: dict[str, Any], catalog: dict[str, dict[str, Any]]) -> list[str]:
    """Models in the chat chain that OpenRouter no longer lists, so no turn reaches them."""
    return [
        f"{ref} in the chat chain is not on OpenRouter's model list"
        for ref in chat_chain(config)
        if ref.startswith(OPENROUTER_PREFIX) and ref.removeprefix(OPENROUTER_PREFIX) not in catalog
    ]


def _agent_entries(config: dict[str, Any]) -> dict[str, Any]:
    entries = (config.get("agents") or {}).get("entries")
    return entries if isinstance(entries, dict) else {}


def memory_off(search: object) -> bool:
    """Memory search switched off, which leaves recall to keyword matches alone."""
    search = search if isinstance(search, dict) else {}
    return search.get("enabled") is False or search.get("provider") == "none"


def memory_route(search: object) -> str | None:
    """Where memory search embeds, or None when it is OpenRouter or switched off.

    OpenClaw's `openai` embedding client is OpenAI-compatible: given an address of its
    own it sends there, which is how both gateways' agents reach OpenRouter today, so
    for it as for `openai-compatible` the address decides.
    """
    search = search if isinstance(search, dict) else {}
    provider = search.get("provider")
    if memory_off(search):
        return None
    remote = search.get("remote")
    base = str(remote.get("baseUrl") or "") if isinstance(remote, dict) else ""
    if provider in ("openai", "openai-compatible") and base:
        if not base.startswith("https://openrouter.ai/api"):
            return base
        fallback = search.get("fallback")
        return f"{fallback} fallback" if fallback and fallback != "none" else None
    if provider == "openai-compatible":
        return "no address"
    return f"{provider}" if provider else "OpenAI, the default with no provider set"


def agent_memory_route(default: object, search: object) -> str | None:
    """Where an agent's own memory search settings send its embeddings, or None.

    They override the default key by key, so an agent that sets only its own address
    still embeds there with the provider it inherits. A route the default alone already
    takes is the default's to report, not the agent's.
    """
    if not isinstance(search, dict):
        return None
    default = default if isinstance(default, dict) else {}
    effective = memory_route(patched(default, search))
    return effective if effective != memory_route(default) else None


def _media_entries(config: dict[str, Any]) -> list[dict[str, Any]]:
    media = (config.get("tools") or {}).get("media") or {}
    entries = media.get("models")
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


def _audio_entries(config: dict[str, Any]) -> list[dict[str, Any]]:
    """Media entries that can transcribe; one with no capabilities list can do anything."""
    return [
        entry
        for entry in _media_entries(config)
        if "audio" in (entry.get("capabilities") or ["audio"])
    ]


def transcription_route(config: dict[str, Any]) -> str | None:
    """Who transcribes voice notes, or None when it is OpenRouter."""
    audio = ((config.get("tools") or {}).get("media") or {}).get("audio") or {}
    if audio.get("enabled") is False:
        return "nobody: tools.media.audio.enabled is false"
    entries = _audio_entries(config)
    if not entries:
        return "auto-detection, which can pick OpenAI or nothing"
    first = entries[0]
    provider = first.get("provider") or first.get("command") or "an unnamed entry"
    return None if provider == "openrouter" else str(provider)


def config_problems(
    config: dict[str, Any], *, environment: frozenset[str] | None = None
) -> list[str]:
    """Everything in openclaw.json that can still reach somewhere other than OpenRouter."""
    wrong = []
    chain = chat_chain(config)
    if not chain or chain[0] != chosen_primary(config) or not all(map(is_openrouter, chain)):
        shown = ", ".join(chain) if chain else "not set"
        wrong.append(f"chat chain is {shown}, not the household chain")
    default_search = (config.get("memory") or {}).get("search")
    for agent_id, entry in _agent_entries(config).items():
        if isinstance(entry, dict) and entry.get("model"):
            wrong.append(f"agent {agent_id} has its own model, which overrides the chain")
        search = (entry.get("memory") or {}).get("search") if isinstance(entry, dict) else None
        route = agent_memory_route(default_search, search)
        if route:
            wrong.append(f"agent {agent_id} memory search embeds with {route}")
    for path, ref in model_refs(config):
        if not is_openrouter(ref):
            wrong.append(f"{'.'.join(path)} is {ref}")
    route = memory_route(default_search)
    if route:
        wrong.append(f"memory search embeds with {route}")
    route = transcription_route(config)
    if route:
        wrong.append(f"voice notes are transcribed by {route}")
    wrong.extend(media_problems(config, environment=environment))
    wrong.extend(no_thinking_problems(config))
    talk = (config.get("talk") or {}).get("provider")
    if isinstance(talk, str) and talk and talk != "openrouter":
        wrong.append(f"talk.provider is {talk}")
    return wrong


def _defaults(config: dict[str, Any]) -> dict[str, Any]:
    defaults = (config.get("agents") or {}).get("defaults")
    return defaults if isinstance(defaults, dict) else {}


def _primary(slot: object) -> str | None:
    """The primary model of a slot that takes a ref or {primary, fallbacks}."""
    if isinstance(slot, str):
        return slot or None
    if isinstance(slot, dict) and isinstance(slot.get("primary"), str):
        return slot["primary"] or None
    return None


def speech_provider(config: dict[str, Any]) -> str | None:
    provider = (config.get("tts") or {}).get("provider")
    return provider if isinstance(provider, str) and provider else None


def search_provider(config: dict[str, Any]) -> str | None:
    search = ((config.get("tools") or {}).get("web") or {}).get("search") or {}
    provider = search.get("provider") if isinstance(search, dict) else None
    return provider if isinstance(provider, str) and provider else None


def search_route(config: dict[str, Any], environment: frozenset[str] | None = None) -> str | None:
    search = ((config.get("tools") or {}).get("web") or {}).get("search") or {}
    if search.get("enabled") is False:
        return None
    provider = search_provider(config)
    if provider is not None and provider != SEARCH_PROVIDER:
        return provider
    entry = ((config.get("plugins") or {}).get("entries") or {}).get(SEARCH_PROVIDER) or {}
    settings = (entry.get("config") or {}).get("webSearch")
    if settings is None:
        settings = search.get(SEARCH_PROVIDER) or {}
    base = settings.get("baseUrl")
    if isinstance(base, str) and base.strip():
        return None if base.strip().rstrip("/") == OPENROUTER_API else base.strip()
    credential = settings.get("apiKey") or search.get("apiKey")
    if isinstance(credential, dict):
        if credential.get("source") == "env" and credential.get("id") == OPENROUTER_KEY:
            return None
        return "Perplexity directly (configured credential)"
    if isinstance(credential, str) and credential.strip():
        if credential.strip().lower().startswith("sk-or-") or credential.strip() == (
            "${OPENROUTER_API_KEY}"
        ):
            return None
        return "Perplexity directly (configured credential)"
    configured_environment = config.get("env") or {}
    variables = configured_environment.get("vars") or {}
    if (
        "PERPLEXITY_API_KEY" in (environment or ())
        or variables.get("PERPLEXITY_API_KEY")
        or configured_environment.get("PERPLEXITY_API_KEY")
    ):
        return "Perplexity directly (PERPLEXITY_API_KEY)"
    if provider == SEARCH_PROVIDER and environment is None:
        return "an unresolved credential route"
    return None


def tts_scopes(
    config: dict[str, Any],
) -> Iterator[tuple[tuple[str, ...], dict[str, Any]]]:
    root = config.get("tts") or {}
    yield ("tts",), root
    for agent_id, entry in _agent_entries(config).items():
        overrides = entry.get("tts") if isinstance(entry, dict) else None
        if isinstance(overrides, dict):
            yield ("agents", "entries", agent_id, "tts"), overrides
    for channel_id, channel in (config.get("channels") or {}).items():
        if not isinstance(channel, dict):
            continue
        channel_tts = channel.get("tts") or {}
        if "tts" in channel:
            yield ("channels", channel_id, "tts"), channel_tts
        for account_id, account in (channel.get("accounts") or {}).items():
            overrides = account.get("tts") if isinstance(account, dict) else None
            if isinstance(overrides, dict):
                yield (
                    ("channels", channel_id, "accounts", account_id, "tts"),
                    overrides,
                )


def speech_problems(config: dict[str, Any], environment: frozenset[str] | None) -> list[str]:
    wrong = []
    configured_environment = config.get("env") or {}
    variables = configured_environment.get("vars") or {}
    is_openai_configured = (
        "OPENAI_API_KEY" in (environment or ())
        or variables.get("OPENAI_API_KEY")
        or configured_environment.get("OPENAI_API_KEY")
    )
    openai_plugin = ((config.get("plugins") or {}).get("entries") or {}).get("openai") or {}
    root = config.get("tts") or {}
    for path, overrides in tts_scopes(config):
        inherited = root
        if path[0] == "channels" and len(path) == 5:
            channel = config["channels"][path[1]]
            inherited = patched(root, channel.get("tts") or {})
        effective = patched(inherited, overrides)
        subject = "speech" if path == ("tts",) else ".".join(path)
        provider = effective.get("provider")
        if provider != SPEECH_PROVIDER:
            wrong.append(f"{subject} goes to {provider or 'whichever provider has a key'}")
        providers = effective.get("providers") or {}
        # The OpenRouter block's model is read as OpenRouter's own, which holds only
        # while the block still sends there.
        own = providers.get(SPEECH_PROVIDER)
        base = own.get("baseUrl") if isinstance(own, dict) else None
        if isinstance(base, str) and base.strip():
            address = base.strip()
            if not f"{address.rstrip('/')}/".startswith("https://openrouter.ai/"):
                wrong.append(f"{subject} sends its OpenRouter requests to {address}")
        if (providers.get("microsoft") or {}).get("enabled") is not False:
            wrong.append(f"{subject} can fall back to microsoft")
        for provider, settings in providers.items():
            if provider in (SPEECH_PROVIDER, "microsoft", "edge") or not isinstance(settings, dict):
                continue
            if settings.get("apiKey") or settings.get("command"):
                wrong.append(f"{subject} can fall back to {provider}")
        if is_openai_configured and openai_plugin.get("enabled") is not False:
            problem = f"{subject} can fall back to openai"
            if problem not in wrong:
                wrong.append(problem)
    return wrong


def media_problems(
    config: dict[str, Any], *, environment: frozenset[str] | None = None
) -> list[str]:
    """Photos, generated media, speech and search, each named and on OpenRouter.

    A ref naming another provider is reported with the other model refs; this is about
    the ones left unset, where OpenClaw picks a provider by whoever holds a key.
    """
    wrong = []
    defaults = _defaults(config)
    if _primary(defaults.get("imageModel")) is None:
        wrong.append("no image model, so a photo the chat model cannot read goes elsewhere")
    media = defaults.get("mediaModels")
    media = media if isinstance(media, dict) else {}
    for kind in GENERATION_MODELS:
        if _primary(media.get(kind)) is None:
            wrong.append(f"{kind} generation is left to whichever provider has a key")
    wrong.extend(video_problems(config, environment=environment))
    wrong.extend(speech_problems(config, environment))
    route = search_route(config, environment)
    if route:
        wrong.append(f"web search goes to {route}")
    return wrong


def no_thinking_problems(config: dict[str, Any]) -> list[str]:
    """Whether completions that name no thinking level run on a model that takes it off."""
    wrong = []
    utility = _defaults(config).get("utilityModel")
    if utility != NO_THINKING_MODEL:
        runs_on = utility or "the chat primary"
        wrong.append(
            f"session titles and other short internal tasks run on {runs_on}, "
            f"not {NO_THINKING_MODEL}, whose reasoning can be off"
        )
    entry = ((config.get("plugins") or {}).get("entries") or {}).get(DREAM_PLUGIN) or {}
    model = ((entry.get("config") or {}).get("dreaming") or {}).get("model")
    subagent = entry.get("subagent") or {}
    allowed = subagent.get("allowedModels")
    if model != NO_THINKING_MODEL:
        runs_on = model or "the chat primary"
        wrong.append(
            f"the dream diary's narrative runs on {runs_on}, not {NO_THINKING_MODEL}, "
            "whose reasoning can be off"
        )
    elif subagent.get("allowModelOverride") is not True:
        wrong.append(
            f"{DREAM_PLUGIN} may not choose its own model, "
            "so the dream diary runs on the chat primary"
        )
    elif isinstance(allowed, list) and NO_THINKING_MODEL not in allowed:
        wrong.append(f"{DREAM_PLUGIN}'s allowed models leave out {NO_THINKING_MODEL}")
    return wrong


def _slot_path(path: tuple[str, ...]) -> tuple[str, ...] | None:
    """The slot to clear for a ref found at `path`, or None when it is not clearable."""
    if path[:2] == ("agents", "defaults"):
        rest, head = path[2:], path[:2]
        if rest and rest[0] in SET_BY_APPLY:
            return None
    elif path[:2] == ("agents", "entries") and len(path) > 3:
        rest, head = path[3:], path[:3]
    elif path == ("tts", "summaryModel") or (
        path[:2] == ("tools", "media") and path[-1] == "preferredModel"
    ):
        return path
    else:
        return None
    if not rest or rest[0] not in CLEARABLE_SLOTS:
        return None
    if rest[0] == "mediaModels":
        return (*head, *rest[:2])
    if rest[0] == "heartbeat":
        return (*head, "heartbeat", "model")
    return (*head, rest[0])


def _put(patch: dict[str, Any], path: tuple[str, ...], value: object) -> None:
    """Set one key deep in a patch. A None stays in the patch: it is how a patch deletes."""
    node = patch
    for key in path[:-1]:
        child = node.get(key)
        if not isinstance(child, dict):
            child = node[key] = {}
        node = child
    node[path[-1]] = value


def media_models(config: dict[str, Any]) -> list[dict[str, Any]]:
    """The media models with explicit OpenRouter transcription and video routes.

    OpenClaw picks an entry by capability, so an image or video entry naming another
    provider is a live route there: only those already on OpenRouter are kept.
    """
    audio = _audio_entries(config)
    kept = [
        entry
        for entry in _media_entries(config)
        if entry not in audio and entry.get("provider") == "openrouter"
    ]
    transcription = {
        "provider": "openrouter",
        "model": TRANSCRIPTION_MODEL,
        "capabilities": ["audio"],
    }
    video = {"provider": VIDEO_PROVIDER, "model": VIDEO_MODEL, "capabilities": ["video"]}
    return [transcription, *kept, video]


def _plugins(config: dict[str, Any]) -> dict[str, Any]:
    plugins = config.get("plugins")
    return plugins if isinstance(plugins, dict) else {}


def video_plugin_patch(config: dict[str, Any]) -> dict[str, Any]:
    """Enable the video plugin and merge its load path and any existing allow list.

    A patch replaces a list whole, so each list is written back with what it held.
    """
    plugins = _plugins(config)
    patch: dict[str, Any] = {"entries": {VIDEO_PLUGIN: {"enabled": True}}}
    load = plugins.get("load")
    paths = load.get("paths") if isinstance(load, dict) else None
    paths = paths if isinstance(paths, list) else []
    if VIDEO_PLUGIN_PATH not in paths:
        patch["load"] = {"paths": [*paths, VIDEO_PLUGIN_PATH]}
    allow = plugins.get("allow")
    if isinstance(allow, list) and VIDEO_PLUGIN not in allow:
        patch["allow"] = [*allow, VIDEO_PLUGIN]
    return patch


def video_problems(
    config: dict[str, Any], *, environment: frozenset[str] | None = None
) -> list[str]:
    """Whether a video someone sends is described through OpenRouter."""
    wrong = []
    video = ((config.get("tools") or {}).get("media") or {}).get("video") or {}
    if video.get("enabled") is False:
        wrong.append("video understanding is disabled")
    routed = any(
        entry.get("provider") == VIDEO_PROVIDER
        and "video" in (entry.get("capabilities") or ["video"])
        for entry in _media_entries(config)
    )
    if not routed:
        wrong.append("videos people send have no OpenRouter route, so Google or nobody reads them")
    plugins = _plugins(config)
    if plugins.get("enabled") is False:
        wrong.append(f"the {VIDEO_PLUGIN} plugin is blocked by plugins.enabled=false")
    if VIDEO_PLUGIN in (plugins.get("deny") or []):
        wrong.append(f"the {VIDEO_PLUGIN} plugin is blocked by plugins.deny")
    allow = plugins.get("allow")
    if isinstance(allow, list) and allow and VIDEO_PLUGIN not in allow:
        wrong.append(f"the {VIDEO_PLUGIN} plugin is blocked by plugins.allow")
    load = plugins.get("load")
    paths = load.get("paths") if isinstance(load, dict) else None
    entry = (plugins.get("entries") or {}).get(VIDEO_PLUGIN)
    if VIDEO_PLUGIN_PATH not in (paths if isinstance(paths, list) else []) or not (
        isinstance(entry, dict) and entry.get("enabled") is True
    ):
        wrong.append(f"the {VIDEO_PLUGIN} plugin is not loaded and enabled")
    if environment is not None and OPENROUTER_KEY not in environment:
        wrong.append(
            f"the {VIDEO_PLUGIN} plugin requires {OPENROUTER_KEY} in the container's environment"
        )
    return wrong


def _named_slot(existing: object, default: str) -> dict[str, Any]:
    """A generation slot on OpenRouter: the primary it holds there, as a phone may choose,
    or the default, and only the fallbacks it held there."""
    held = _primary(existing)
    primary = (
        held
        if held is not None and held.startswith(OPENROUTER_PREFIX) and held != OPENROUTER_PREFIX
        else default
    )
    slot: dict[str, Any] = {"primary": primary}
    if isinstance(existing, dict) and existing.get("fallbacks"):
        slot["fallbacks"] = [ref for ref in existing["fallbacks"] if is_openrouter(str(ref))]
    return slot


def openrouter_patch(config: dict[str, Any], catalog: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """The one change `apply` makes to a gateway, judging a phone's fallbacks by `catalog`,
    OpenRouter's model list."""
    media = _defaults(config).get("mediaModels")
    media = media if isinstance(media, dict) else {}
    patch: dict[str, Any] = {
        "agents": {
            "defaults": {
                "model": {
                    "primary": chosen_primary(config),
                    "fallbacks": list(chosen_fallbacks(config, catalog)),
                },
                "imageModel": (
                    _named_slot(_defaults(config).get("imageModel"), IMAGE_MODEL)
                    if is_openrouter(str(_primary(_defaults(config).get("imageModel")) or ""))
                    else {"primary": IMAGE_MODEL, "fallbacks": list(IMAGE_FALLBACKS)}
                ),
                "utilityModel": NO_THINKING_MODEL,
                "mediaModels": {
                    kind: _named_slot(media.get(kind), model)
                    for kind, model in GENERATION_MODELS.items()
                },
            }
        },
        "tts": {"provider": SPEECH_PROVIDER, "providers": {"microsoft": {"enabled": False}}},
        "tools": {"media": {"models": media_models(config), "audio": {"enabled": True}}},
        "plugins": video_plugin_patch(config),
    }
    patch["plugins"]["entries"][DREAM_PLUGIN] = {
        "subagent": {"allowModelOverride": True, "allowedModels": [NO_THINKING_MODEL]},
        "config": {"dreaming": {"model": NO_THINKING_MODEL}},
    }
    # The default is written only when it embeds somewhere else. One already on
    # OpenRouter, or switched off on purpose as Corey's is, stays as it was.
    default_search = (config.get("memory") or {}).get("search") or {}
    if memory_route(default_search):
        patch["memory"] = {"search": {"fallback": "none"}}
        if memory_route(patched(default_search, {"fallback": "none"})):
            patch["memory"] = {
                "search": {
                    "provider": "openai-compatible",
                    "fallback": "none",
                    "model": EMBEDDING_MODEL,
                    "remote": {
                        "baseUrl": OPENROUTER_API,
                        "apiKey": {"source": "env", "provider": "default", "id": OPENROUTER_KEY},
                    },
                },
            }
        # An agent inherits the default this patch writes, so it is judged against that.
        default_search = patched(default_search, patch["memory"]["search"])
    for agent_id, entry in _agent_entries(config).items():
        if not isinstance(entry, dict):
            continue
        if entry.get("model"):
            _put(patch, ("agents", "entries", agent_id, "model"), None)
        search = (entry.get("memory") or {}).get("search")
        if isinstance(search, dict) and agent_memory_route(default_search, search):
            effective = patched(default_search, search)
            if memory_route(patched(effective, {"fallback": "none"})):
                _put(patch, ("agents", "entries", agent_id, "memory", "search"), None)
            else:
                _put(patch, ("agents", "entries", agent_id, "memory", "search", "fallback"), "none")
    for path, ref in model_refs(config):
        slot = _slot_path(path)
        if not is_openrouter(ref) and slot is not None:
            _put(patch, slot, None)
    for path, overrides in tts_scopes(config):
        if path == ("tts",):
            continue
        if "provider" in overrides:
            _put(patch, (*path, "provider"), None)
        if "enabled" in ((overrides.get("providers") or {}).get("microsoft") or {}):
            _put(patch, (*path, "providers", "microsoft", "enabled"), None)
    return patch


@dataclass(frozen=True, slots=True)
class Live:
    """Container credential presence, CLI model status and video-provider loadability, and pins."""

    openrouter_key: bool | None = None
    effective: tuple[str, ...] = ()
    missing_credentials: tuple[str, ...] = ()
    openai_signed_in: bool = False
    pinned: tuple[tuple[str, str], ...] = ()
    errors: tuple[str, ...] = ()
    environment: frozenset[str] | None = None
    is_video_provider_loadable: bool | None = None

    @property
    def pinned_elsewhere(self) -> tuple[tuple[str, str], ...]:
        return tuple((key, ref) for key, ref in self.pinned if not is_openrouter(ref))


def read_environment(gateway: Gateway, run: Runner) -> frozenset[str]:
    keys = [OPENROUTER_KEY, "OPENAI_API_KEY", "PERPLEXITY_API_KEY"]
    script = (
        "process.stdout.write(JSON.stringify({environment:Object.fromEntries("
        f"{json.dumps(keys)}.map(key => [key, Boolean(process.env[key]?.trim())])"
        ")}))"
    )
    completed = run(
        ["docker", "exec", gateway.container, "node", "--eval", script],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    answer = first_json_object(completed.stdout, "environment")
    variables = answer.get("environment") if answer is not None else None
    if completed.returncode != 0 or not isinstance(variables, dict):
        raise RuntimeError("container credential presence gave no answer")
    if any(not isinstance(variables.get(key), bool) for key in keys):
        raise RuntimeError("container credential presence gave an incomplete answer")
    return frozenset(key for key in keys if variables[key])


def read_live(gateway: Gateway, run: Runner) -> Live:
    """Container key presence, CLI model and video-provider status, and session pins.

    No credential values are returned, and CLI loadability does not prove daemon registration.
    """
    errors = []
    environment = None
    try:
        environment = read_environment(gateway, run)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        errors.append(f"credential environment: {error}")
    status = None
    try:
        status = first_json_object(
            ask_gateway(gateway, run, "models", "status", "--json").stdout, "auth"
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        errors.append(f"models status: {error}")
    sessions = None
    try:
        listing = ask_gateway(gateway, run, "sessions", "--json", "--limit", "all").stdout
        sessions = first_json_object(listing, "sessions")
    except (OSError, subprocess.TimeoutExpired) as error:
        errors.append(f"sessions: {error}")
    is_video_provider_loadable = None
    try:
        listing = ask_gateway(gateway, run, "infer", "video", "providers", "--json").stdout
        described = first_json_object(listing, "description")
    except (OSError, subprocess.TimeoutExpired) as error:
        errors.append(f"video providers: {error}")
    else:
        if described is None or not isinstance(described.get("description"), list):
            errors.append("video providers gave no answer")
        else:
            is_video_provider_loadable = any(
                isinstance(provider, dict) and provider.get("id") == VIDEO_PROVIDER
                for provider in described["description"]
            )

    key = None
    effective: list[str] = []
    missing: tuple[str, ...] = ()
    openai = False
    if status is None:
        errors.append("models status gave no answer")
    else:
        auth = status.get("auth") or {}
        providers = {
            p.get("provider"): p for p in auth.get("providers") or [] if isinstance(p, dict)
        }
        openrouter = providers.get("openrouter") or {}
        key = (openrouter.get("effective") or {}).get("kind") not in (None, "missing")
        missing = tuple(str(p) for p in auth.get("missingProvidersInUse") or [])
        openai_profiles = ((providers.get("openai") or {}).get("profiles") or {}).get("count") or 0
        openai = "openai" in (auth.get("providersWithOAuth") or []) or openai_profiles > 0
        for name in ("resolvedDefault", "imageModel"):
            value = status.get(name)
            if isinstance(value, str) and value:
                effective.append(value)
        effective.extend(str(ref) for ref in status.get("fallbacks") or [] if ref)
        utility = status.get("utilityModel")
        if isinstance(utility, dict) and isinstance(utility.get("ref"), str):
            effective.append(utility["ref"])
    pinned: list[tuple[str, str]] = []
    if sessions is None:
        errors.append("sessions gave no answer")
    else:
        for session in sessions.get("sessions") or []:
            provider = session.get("providerOverride") if isinstance(session, dict) else None
            if provider:
                pinned.append(
                    (str(session.get("key")), f"{provider}/{session.get('modelOverride')}")
                )
    return Live(
        openrouter_key=key,
        effective=tuple(effective),
        missing_credentials=missing,
        openai_signed_in=openai,
        pinned=tuple(pinned),
        errors=tuple(errors),
        environment=environment,
        is_video_provider_loadable=is_video_provider_loadable,
    )


def live_problems(live: Live) -> list[str]:
    wrong = list(live.errors)
    if live.openrouter_key is False:
        wrong.append(f"no OpenRouter key: {OPENROUTER_KEY} is not in the container's environment")
    wrong.extend(
        f"in use without a credential: {provider}" for provider in live.missing_credentials
    )
    wrong.extend(f"effective model {ref}" for ref in live.effective if not is_openrouter(ref))
    wrong.extend(f"{key} is pinned to {ref}" for key, ref in live.pinned_elsewhere)
    if live.is_video_provider_loadable is False:
        wrong.append(f"the CLI cannot load the {VIDEO_PROVIDER} video provider")
    return wrong


def report(gateway: Gateway, run: Runner) -> bool:
    print(f"{gateway.persona} ({gateway.container})")
    try:
        config = read_config(gateway)
    except (OSError, ValueError) as error:
        hint = " (run as root)" if isinstance(error, PermissionError) else ""
        field("unreadable", f"{error}{hint}")
        print()
        return False
    state = read_live(gateway, run)
    wrong = config_problems(config, environment=state.environment)
    field("chat", " -> ".join(chat_chain(config)) or "not set")
    search = (config.get("memory") or {}).get("search")
    route = memory_route(search)
    if memory_off(search):
        route = "nothing: search is off, so recall matches keywords only"
    field("memory", f"embeds with {route or 'OpenRouter'}")
    route = transcription_route(config)
    field("voice notes", f"transcribed by {route}" if route else "transcribed by OpenRouter")
    image = _defaults(config).get("imageModel")
    photos = [_primary(image) or "not set"]
    if isinstance(image, dict):
        photos.extend(str(ref) for ref in image.get("fallbacks") or [])
    field("photos", " -> ".join(photos))
    videos = next(
        (
            f"{entry.get('provider')}/{entry.get('model')}"
            for entry in _media_entries(config)
            if "video" in (entry.get("capabilities") or ["video"])
        ),
        "not routed",
    )
    field(
        "videos",
        ". ".join(video_problems(config, environment=state.environment))
        or f"described by {videos}",
    )
    field("video probe", "CLI loadability only. Running gateway registration is unverified")
    media = _defaults(config).get("mediaModels")
    media = media if isinstance(media, dict) else {}
    made = ", ".join(
        f"{kind} {_primary(media.get(kind)) or 'not set'}" for kind in GENERATION_MODELS
    )
    field("generates", made)
    field("speech", speech_provider(config) or "not set")
    field(
        "web search", search_provider(config) or "Perplexity through the OpenRouter key, if set up"
    )
    wrong.extend(live_problems(state))
    try:
        catalog = read_catalog(run)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        wrong.append(str(error))
    else:
        wrong.extend(chain_problems(config, catalog))
    field("key", "OpenRouter key present" if state.openrouter_key else "no OpenRouter key")
    pins = ", ".join(f"{key} -> {ref}" for key, ref in state.pinned) or "none"
    field("pinned", pins)
    if state.openai_signed_in:
        field("openai", "a sign-in is still stored; nothing routes to it once this passes")
    field("verdict", "; ".join(wrong) if wrong else "OpenRouter routes configured")
    print()
    return not wrong


def check(gateways: Sequence[Gateway], *, run: Runner) -> int:
    print("Where each gateway sends its model, embedding and transcription calls")
    print()
    healthy = [report(gateway, run) for gateway in gateways]
    return 0 if all(healthy) else 1


def verdict(container: str, state: Path, *, run: Runner = subprocess.run) -> str:
    """One line for openclaw-verify.sh: `ok`, or what still leaves OpenRouter."""
    gateway = gateway_for(container, state)
    if gateway is None:
        return f"no policy for container {container}"
    try:
        config = read_config(gateway)
        environment = read_environment(gateway, run)
        wrong = config_problems(config, environment=environment)
        wrong.extend(chain_problems(config, read_catalog(run)))
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        return f"unreadable: {error}"
    return "; ".join(wrong) if wrong else "ok"


@dataclass(frozen=True, slots=True)
class Plan:
    gateway: Gateway
    patch: dict[str, Any]
    needed: bool
    left: tuple[str, ...]
    pins: tuple[tuple[str, str], ...]


def plan(gateway: Gateway, run: Runner) -> Plan:
    if not VIDEO_PLUGIN_ON_HOST.is_file():
        raise RuntimeError(
            f"the {VIDEO_PLUGIN} plugin is not installed at {VIDEO_PLUGIN_ON_HOST.parent}; run "
            "scripts/openclaw-install.sh first, which also mounts it into both containers"
        )
    config = read_config(gateway)
    live = read_live(gateway, run)
    if live.openrouter_key is None or live.environment is None:
        raise RuntimeError(
            f"{gateway.persona}: could not read {gateway.container}'s credentials "
            f"({'; '.join(live.errors) or 'no answer'}); is the container running?"
        )
    if live.openrouter_key is False or OPENROUTER_KEY not in live.environment:
        raise RuntimeError(
            f"{gateway.persona}: no OpenRouter key in {gateway.container}. Put {OPENROUTER_KEY} "
            "in its env file under /etc/household-assistant and recreate the container"
        )
    catalog = read_catalog(run)
    patch = openrouter_patch(config, catalog)
    result = patched(config, patch)
    return Plan(
        gateway,
        patch,
        needed=result != config,
        left=tuple(config_problems(result, environment=live.environment))
        + tuple(chain_problems(result, catalog))
        + live.errors,
        pins=live.pinned_elsewhere,
    )


def clear_pin(gateway: Gateway, run: Runner, key: str) -> bool:
    """`sessions.patch` with a null model, through the gateway itself.

    Retried, because the gateway refuses calls for the second or two it spends
    restarting in process, and a retry is cheaper than a wrong answer about a pin.
    """
    params = json.dumps({"key": key, "model": None})
    for attempt in range(PIN_ATTEMPTS):
        if attempt:
            time.sleep(PIN_RETRY_SECONDS)
        completed = run(
            gateway_cli(gateway, "gateway", "call", "sessions.patch", "--params", params, "--json"),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        if completed.returncode == 0:
            return True
    return False


def reindex_memory(gateway: Gateway, run: Runner) -> bool:
    """A new embedding provider pauses vector search until the index is rebuilt.

    A rebuild that fails or runs out of time is reported, with the command to retry it,
    rather than stopping `apply` before the other gateway.
    """
    try:
        completed = run(
            gateway_cli(gateway, "memory", "index", "--force", "--agent", "main"),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=900,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return completed.returncode == 0


def apply(gateways: Sequence[Gateway], *, run: Runner, dry_run: bool) -> int:
    """Plan and validate both gateways before writing either, so they never end up apart."""
    try:
        plans = [plan(gateway, run) for gateway in gateways]
        for p in plans:
            if p.needed:
                config_patch(p.gateway, p.patch, run, dry_run=True)
                print(f"{p.gateway.persona}: the gateway validated the patch")
            else:
                print(f"{p.gateway.persona}: config already routes everything to OpenRouter")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"refused, nothing written: {error}", file=sys.stderr)
        return 1
    if dry_run:
        print()
        print("dry run: nothing written.")
        for p in plans:
            if p.needed:
                print(f"  {p.gateway.persona} patch: {json.dumps(p.patch)}")
            for key, ref in p.pins:
                print(f"  {p.gateway.persona} would clear the pin on {key} ({ref})")
            for item in p.left:
                print(f"  {p.gateway.persona} would still need a hand: {item}")
        return 0

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for p in plans:
        # Pins first: the memory change below restarts the gateway in process, and a
        # pin cleared afterwards meets it mid-restart.
        for key, ref in p.pins:
            outcome = "cleared" if clear_pin(p.gateway, run, key) else "could NOT clear"
            print(f"{p.gateway.persona}: {outcome} the pin on {key} ({ref})")
        if p.needed:
            saved = backup(p.gateway, "openrouter", stamp)
            try:
                config_patch(p.gateway, p.patch, run, dry_run=False)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                print(
                    f"{p.gateway.persona}: write failed, previous config at {saved}",
                    file=sys.stderr,
                )
                print(f"  {error}", file=sys.stderr)
                return 1
            print(f"{p.gateway.persona}: written; previous config at {saved}")
            if reindex_memory(p.gateway, run):
                print(f"{p.gateway.persona}: memory index rebuilt")
            else:
                retry = " ".join(
                    gateway_cli(p.gateway, "memory", "index", "--force", "--agent", "main")
                )
                print(f"{p.gateway.persona}: memory index NOT rebuilt; vector recall stays paused")
                print(f"  until this succeeds: {retry}")
        for item in p.left:
            print(f"{p.gateway.persona}: still needs a hand: {item}")
    print()
    return check(gateways, run=run)


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="read-only: both gateways side by side")
    applier = commands.add_parser("apply", help="route both gateways through OpenRouter")
    applier.add_argument(
        "--dry-run", action="store_true", help="validate on both and list the pins, write nothing"
    )
    one = commands.add_parser("verdict", help="one gateway, one line, for openclaw-verify.sh")
    one.add_argument("--container", required=True)
    one.add_argument("--state", required=True, type=Path)
    arguments = parser.parse_args(argv)

    if arguments.command == "verdict":
        print(verdict(arguments.container, arguments.state, run=run))
        return 0
    if arguments.command == "check":
        return check(GATEWAYS, run=run)
    if os.geteuid() != 0:
        parser.error("run as root on the box")
    return apply(GATEWAYS, run=run, dry_run=arguments.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
