"""openclaw-openrouter.py: every model, embedding and transcription route goes to OpenRouter.

The household is closing its OpenAI account, so anything still routed there fails
once it closes: the chat chain, an auxiliary model slot, memory-search embeddings,
voice-note transcription, or a conversation pinned to a model.

These configs and CLI outputs follow what the gateway the compose file pins (OpenClaw
2026.9.4) actually does. On 2026-10-06 its `config patch` validated the patch built
here, its `memory index` sent embeddings to a fake OpenRouter with the OpenRouter key,
its gateway transcribed voice notes through a fake OpenRouter STT endpoint, and its
`sessions.patch` set and cleared a pin. The JSON shapes the fakes below return are the
ones it printed.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from tests.capabilities import needs_nofollow_open

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "openclaw-openrouter.py"

CHAIN = (
    "openrouter/z-ai/glm-5.3-flash",
    "openrouter/z-ai/glm-5.3",
    "openrouter/deepseek/deepseek-v4-flash-0731",
)
# The chain's models as OpenRouter's list names them, with nothing more than their ids.
LISTED_CHAIN = [{"id": ref.removeprefix("openrouter/")} for ref in CHAIN]
# OpenRouter's list by id, as `apply` reads it: the chain's models and one more a phone
# may pick.
LISTED = {listed["id"]: listed for listed in [*LISTED_CHAIN, {"id": "anthropic/claude-sonnet-5"}]}


@pytest.fixture(scope="module")
def router() -> ModuleType:
    if str(SCRIPT.parent) not in sys.path:
        sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("openclaw_openrouter", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["openclaw_openrouter"] = module
    spec.loader.exec_module(module)
    return module


def corey_on_codex() -> dict[str, Any]:
    """Corey as the runbook left him: Codex first, an OpenAI utility model, his own pin."""
    return {
        "agents": {
            "defaults": {
                "model": {
                    "primary": "openai/gpt-5.6-luna",
                    "fallbacks": ["openrouter/z-ai/glm-5.3-flash"],
                },
                "utilityModel": "openai/gpt-5.4-mini",
            },
            "entries": {"main": {"identity": {"name": "Corey"}, "model": "openai/gpt-5.6-luna"}},
        },
        "plugins": {"entries": {"active-memory": {"config": {"model": "openai/gpt-5.4-mini"}}}},
    }


def denise_on_flash() -> dict[str, Any]:
    """Denise as the runbook left her, plus an OpenAI transcription entry and an image one."""
    return {
        "agents": {
            "defaults": {
                "model": {
                    "primary": "openrouter/z-ai/glm-5.3-flash",
                    "fallbacks": [
                        "openrouter/deepseek/deepseek-v4-flash-0731:free",
                        "openrouter/free",
                    ],
                }
            },
            "entries": {"main": {"identity": {"name": "Denise"}}},
        },
        "tools": {
            "media": {
                "models": [
                    {"provider": "openai", "model": "gpt-4o-transcribe", "capabilities": ["audio"]},
                    {"provider": "openrouter", "model": "auto", "capabilities": ["image"]},
                ]
            }
        },
    }


def test_every_route_to_openai_is_named(router: ModuleType) -> None:
    corey = router.config_problems(corey_on_codex())
    assert any(item.startswith("chat chain is openai/gpt-5.6-luna") for item in corey)
    assert "agent main has its own model, which overrides the chain" in corey
    assert "agents.defaults.utilityModel is openai/gpt-5.4-mini" in corey
    assert "plugins.entries.active-memory.config.model is openai/gpt-5.4-mini" in corey
    assert "memory search embeds with OpenAI, the default with no provider set" in corey
    assert (
        "voice notes are transcribed by auto-detection, which can pick OpenAI or nothing" in corey
    )

    denise = router.config_problems(denise_on_flash())
    assert "voice notes are transcribed by openai" in denise
    assert router.chain_problems(denise_on_flash(), LISTED) == [
        "openrouter/deepseek/deepseek-v4-flash-0731:free in the chat chain is not on "
        "OpenRouter's model list",
        "openrouter/free in the chat chain is not on OpenRouter's model list",
    ]


def test_the_patch_leaves_nothing_but_what_it_cannot_safely_change(router: ModuleType) -> None:
    config = corey_on_codex()
    patch = router.openrouter_patch(config, LISTED)

    # A null in the patch is how `config patch` deletes; it must survive building it.
    assert patch["agents"]["entries"]["main"]["model"] is None

    after = router.patched(config, patch)
    assert router.chat_chain(after) == CHAIN
    # The OpenAI utility model is replaced by the one for no-thinking completions.
    assert (
        after["agents"]["defaults"]["utilityModel"] == "openrouter/deepseek/deepseek-v4-flash-0731"
    )
    assert after["agents"]["entries"]["main"] == {"identity": {"name": "Corey"}}
    # A plugin's own model is not a slot that falls back to the chain, so it is
    # reported for a person to change rather than cleared.
    assert router.config_problems(after) == [
        "plugins.entries.active-memory.config.model is openai/gpt-5.4-mini"
    ]


def chosen_in_the_app(primary: str) -> dict[str, Any]:
    """A gateway after its person picked a primary in the app's Settings."""
    config = router_ready()
    config["agents"]["defaults"]["model"]["primary"] = primary
    return config


def router_ready() -> dict[str, Any]:
    return {
        "agents": {
            "defaults": {"model": {"primary": CHAIN[0], "fallbacks": list(CHAIN[1:])}},
            "entries": {"main": {"identity": {"name": "Corey"}}},
        }
    }


def test_a_primary_the_phone_chose_on_openrouter_passes_and_apply_keeps_it(
    router: ModuleType,
) -> None:
    config = chosen_in_the_app("openrouter/anthropic/claude-sonnet-5")
    assert not any(item.startswith("chat chain") for item in router.config_problems(config))

    after = router.patched(config, router.openrouter_patch(config, LISTED))
    assert router.chat_chain(after) == ("openrouter/anthropic/claude-sonnet-5", *CHAIN[1:])


@pytest.mark.parametrize(
    "primary", ["openai/gpt-5.6-luna", "openrouter/", "anthropic/claude-sonnet-5", ""]
)
def test_a_primary_off_openrouter_is_reported_and_apply_puts_the_default_back(
    router: ModuleType, primary: str
) -> None:
    config = chosen_in_the_app(primary)
    assert any(item.startswith("chat chain") for item in router.config_problems(config))

    after = router.patched(config, router.openrouter_patch(config, LISTED))
    assert router.chat_chain(after) == CHAIN


def test_a_fallback_openrouter_does_not_list_is_reported_and_apply_puts_the_households_back(
    router: ModuleType,
) -> None:
    config = chosen_in_the_app("openrouter/z-ai/glm-5.3")
    config["agents"]["defaults"]["model"]["fallbacks"] = ["openrouter/free"]
    assert router.chain_problems(config, LISTED) == [
        "openrouter/free in the chat chain is not on OpenRouter's model list"
    ]

    after = router.patched(config, router.openrouter_patch(config, LISTED))
    assert router.chat_chain(after) == ("openrouter/z-ai/glm-5.3", *CHAIN[1:])


@pytest.mark.parametrize(
    "fallbacks",
    [
        ["openrouter/anthropic/claude-sonnet-5", "openrouter/z-ai/glm-5.3"],
        ["openrouter/deepseek/deepseek-v4-flash-0731"],
        [],
    ],
)
def test_the_second_and_third_models_a_phone_picked_pass_and_apply_keeps_them(
    router: ModuleType, fallbacks: list[str]
) -> None:
    config = chosen_in_the_app(CHAIN[0])
    config["agents"]["defaults"]["model"]["fallbacks"] = fallbacks
    assert not any(item.startswith("chat chain") for item in router.config_problems(config))
    assert router.chain_problems(config, LISTED) == []

    after = router.patched(config, router.openrouter_patch(config, LISTED))
    assert router.chat_chain(after) == (CHAIN[0], *fallbacks)


@pytest.mark.parametrize(
    "fallbacks",
    [
        [CHAIN[0], "openrouter/z-ai/glm-5.3"],
        ["openrouter/z-ai/glm-5.3", "openrouter/z-ai/glm-5.3"],
        ["anthropic/claude-sonnet-5"],
    ],
)
def test_fallbacks_that_repeat_a_model_or_leave_openrouter_get_the_households_back(
    router: ModuleType, fallbacks: list[str]
) -> None:
    config = chosen_in_the_app(CHAIN[0])
    config["agents"]["defaults"]["model"]["fallbacks"] = fallbacks

    after = router.patched(config, router.openrouter_patch(config, LISTED))
    assert router.chat_chain(after) == CHAIN


NO_THINKING = "openrouter/deepseek/deepseek-v4-flash-0731"
GOOD_DIARY = {
    "subagent": {"allowModelOverride": True, "allowedModels": [NO_THINKING]},
    "config": {"dreaming": {"model": NO_THINKING}},
}


def test_completions_that_name_no_thinking_level_get_a_model_whose_reasoning_can_be_off(
    router: ModuleType,
) -> None:
    """OpenClaw sent glm-5.3-flash {"effort": "none"} for the dream diary's narrative and
    for session titles, and OpenRouter answered 400 "Reasoning is mandatory" (#198, #204)."""
    config = router_ready()

    before = router.config_problems(config)
    after = router.patched(config, router.openrouter_patch(config, LISTED))

    assert (
        "session titles and other short internal tasks run on the chat primary, "
        f"not {NO_THINKING}, whose reasoning can be off"
    ) in before
    assert (
        f"the dream diary's narrative runs on the chat primary, not {NO_THINKING}, "
        "whose reasoning can be off"
    ) in before
    assert after["agents"]["defaults"]["utilityModel"] == NO_THINKING
    assert after["plugins"]["entries"]["memory-core"] == GOOD_DIARY
    assert router.no_thinking_problems(after) == []


@pytest.mark.parametrize(
    ("utility", "entry", "problem"),
    [
        (
            CHAIN[0],
            GOOD_DIARY,
            f"session titles and other short internal tasks run on {CHAIN[0]}, "
            f"not {NO_THINKING}, whose reasoning can be off",
        ),
        (
            NO_THINKING,
            {"config": {"dreaming": {"model": CHAIN[0]}}},
            f"the dream diary's narrative runs on {CHAIN[0]}, not {NO_THINKING}, "
            "whose reasoning can be off",
        ),
        (
            NO_THINKING,
            {"config": {"dreaming": {"model": NO_THINKING}}},
            "memory-core may not choose its own model, so the dream diary runs on the chat primary",
        ),
        (
            NO_THINKING,
            {
                "subagent": {"allowModelOverride": True, "allowedModels": [CHAIN[0]]},
                "config": {"dreaming": {"model": NO_THINKING}},
            },
            f"memory-core's allowed models leave out {NO_THINKING}",
        ),
    ],
    ids=[
        "utility-on-the-primary",
        "diary-on-another-model",
        "override-not-allowed",
        "model-not-allowed",
    ],
)
def test_a_no_thinking_completion_that_would_run_elsewhere_is_reported_and_apply_puts_it_back(
    router: ModuleType, utility: str, entry: dict[str, Any], problem: str
) -> None:
    config = router_ready()
    config["agents"]["defaults"]["utilityModel"] = utility
    config["plugins"] = {"entries": {"memory-core": entry}}

    assert router.no_thinking_problems(config) == [problem]
    after = router.patched(config, router.openrouter_patch(config, LISTED))
    assert router.no_thinking_problems(after) == []


def test_transcription_goes_first_and_image_entries_stay(router: ModuleType) -> None:
    after = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))

    assert after["tools"]["media"]["models"] == [
        {
            "provider": "openrouter",
            "model": "openai/whisper-large-v3-turbo",
            "capabilities": ["audio"],
        },
        {"provider": "openrouter", "model": "auto", "capabilities": ["image"]},
        {
            "provider": "openrouter-video",
            "model": "google/gemini-2.5-flash",
            "capabilities": ["video"],
        },
    ]
    assert after["tools"]["media"]["audio"] == {"enabled": True}
    assert router.config_problems(after) == []


@pytest.mark.parametrize(
    ("search", "route"),
    [
        (None, "OpenAI, the default with no provider set"),
        ({"provider": "none"}, None),
        ({"enabled": False, "provider": "openai"}, None),
        ({"provider": "gemini"}, "gemini"),
        (
            {
                "provider": "openai-compatible",
                "remote": {"baseUrl": "https://openrouter.ai/api/v1"},
            },
            None,
        ),
        (
            {"provider": "openai-compatible", "remote": {"baseUrl": "https://api.openai.com/v1"}},
            "https://api.openai.com/v1",
        ),
        # OpenClaw's `openai` client with an address of its own, which is how the
        # runbook's memory section sends both agents' embeddings to OpenRouter.
        ({"provider": "openai", "remote": {"baseUrl": "https://openrouter.ai/api/v1"}}, None),
        (
            {"provider": "openai", "remote": {"baseUrl": "https://api.openai.com/v1"}},
            "https://api.openai.com/v1",
        ),
        ({"provider": "openai"}, "openai"),
    ],
)
def test_memory_search_is_judged_by_where_it_embeds(
    router: ModuleType, search: dict[str, Any] | None, route: str | None
) -> None:
    assert router.memory_route(search) == route


@pytest.mark.parametrize(
    ("search", "line"),
    [
        (None, "embeds with OpenAI, the default with no provider set"),
        ({"provider": "none"}, "embeds with nothing: search is off, so recall matches keywords"),
        (
            {
                "provider": "openai-compatible",
                "remote": {"baseUrl": "https://openrouter.ai/api/v1"},
            },
            "embeds with OpenRouter",
        ),
    ],
)
@needs_nofollow_open
def test_the_report_says_which_way_memory_goes(
    router: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    search: dict[str, Any] | None,
    line: str,
) -> None:
    config = denise_on_flash()
    if search is not None:
        config["memory"] = {"search": search}
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")

    router.check((gateway,), run=FakeGateways(router, {"openclaw-denise": state}))
    memory = next(row for row in capsys.readouterr().out.splitlines() if "memory" in row)
    assert line in memory


def test_image_and_video_entries_on_another_provider_are_reported_and_dropped(
    router: ModuleType,
) -> None:
    """OpenClaw picks a media entry by capability, so each one is a route of its own."""
    config = denise_on_flash()
    config["tools"]["media"]["models"] += [
        {"provider": "openai", "model": "gpt-5.4-mini", "capabilities": ["image"]},
        {"provider": "google", "model": "gemini-3.5-flash", "capabilities": ["video"]},
    ]

    before = router.config_problems(config)
    after = router.patched(config, router.openrouter_patch(config, LISTED))

    assert "tools.media.models.2.model is openai/gpt-5.4-mini" in before
    assert "tools.media.models.3.model is google/gemini-3.5-flash" in before
    assert after["tools"]["media"]["models"] == [
        {
            "provider": "openrouter",
            "model": "openai/whisper-large-v3-turbo",
            "capabilities": ["audio"],
        },
        {"provider": "openrouter", "model": "auto", "capabilities": ["image"]},
        {
            "provider": "openrouter-video",
            "model": "google/gemini-2.5-flash",
            "capabilities": ["video"],
        },
    ]
    assert router.config_problems(after) == []


def test_an_agent_s_own_embedding_address_is_judged_with_the_provider_it_inherits(
    router: ModuleType,
) -> None:
    on_openrouter = router.patched(
        denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED)
    )
    config = router.patched(
        on_openrouter,
        {
            "agents": {
                "entries": {
                    "main": {
                        "memory": {
                            "search": {
                                "remote": {
                                    "baseUrl": "https://api.openai.com/v1",
                                    "apiKey": {
                                        "source": "env",
                                        "provider": "default",
                                        "id": "OPENAI_API_KEY",
                                    },
                                }
                            }
                        }
                    }
                }
            }
        },
    )

    patch = router.openrouter_patch(config, LISTED)

    assert router.config_problems(config) == [
        "agent main memory search embeds with https://api.openai.com/v1"
    ]
    assert patch["agents"]["entries"]["main"]["memory"]["search"] is None
    assert router.config_problems(router.patched(config, patch)) == []


def agent_embeddings_on_openrouter() -> dict[str, Any]:
    """`agents.entries.main.memory.search` as the runbook's memory section sets it."""
    return {
        "provider": "openai",
        "model": "openai/text-embedding-3-small",
        "remote": {
            "baseUrl": "https://openrouter.ai/api/v1",
            "apiKey": {"source": "env", "provider": "default", "id": "OPENROUTER_API_KEY"},
        },
    }


@pytest.mark.parametrize(
    ("default", "writes_default"),
    [
        ({"provider": "none"}, False),  # Corey: search off by default, on for his agent
        (None, True),  # Denise: no default, so one that is not OpenAI is written
    ],
)
def test_the_box_s_working_agent_embeddings_are_kept(
    router: ModuleType, default: dict[str, Any] | None, writes_default: bool
) -> None:
    config = denise_on_flash()
    config["agents"]["entries"]["main"]["memory"] = {"search": agent_embeddings_on_openrouter()}
    if default is not None:
        config["memory"] = {"search": default}

    patch = router.openrouter_patch(config, LISTED)
    after = router.patched(config, patch)

    assert not any("memory" in item for item in router.config_problems(after))
    assert ("memory" in patch) is writes_default
    assert after["agents"]["entries"]["main"]["memory"]["search"] == (
        agent_embeddings_on_openrouter()
    )
    if not writes_default:
        assert after["memory"] == {"search": default}


def test_an_agent_that_only_switches_its_memory_search_off_is_left_alone(
    router: ModuleType,
) -> None:
    config = router.patched(
        denise_on_flash(),
        {"agents": {"entries": {"main": {"memory": {"search": {"enabled": False}}}}}},
    )

    patch = router.openrouter_patch(config, LISTED)

    assert "main" not in (patch["agents"].get("entries") or {})
    assert not any(item.startswith("agent main") for item in router.config_problems(config))


@pytest.mark.parametrize("default_provider", ["none", "openai"])
def test_an_agent_provider_override_keeps_its_inherited_openrouter_endpoint(
    router: ModuleType, default_provider: str
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    default = agent_embeddings_on_openrouter()
    default["provider"] = default_provider
    config["memory"] = {"search": default}
    config["agents"]["entries"]["main"]["memory"] = {"search": {"provider": "openai"}}

    patch = router.openrouter_patch(config, LISTED)
    after = router.patched(config, patch)

    assert router.config_problems(config) == []
    assert "memory" not in patch
    assert after["memory"]["search"] == default
    assert after["agents"]["entries"]["main"]["memory"]["search"] == {"provider": "openai"}
    assert router.config_problems(after) == []


@pytest.mark.parametrize("location", ["default", "agent", "inherited"])
def test_memory_fallbacks_are_reported_and_disabled_without_changing_working_embeddings(
    router: ModuleType, location: str
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    default = agent_embeddings_on_openrouter()
    agent = agent_embeddings_on_openrouter()
    if location == "default":
        default["fallback"] = "gemini"
    elif location == "agent":
        default = {"provider": "none"}
        agent["fallback"] = "gemini"
    else:
        default.update(provider="none", fallback="gemini")
        agent = {"provider": "openai"}
    config["memory"] = {"search": default}
    if location != "default":
        config["agents"]["entries"]["main"]["memory"] = {"search": agent}

    before = router.config_problems(config)
    after = router.patched(config, router.openrouter_patch(config, LISTED))

    subject = "memory search" if location == "default" else "agent main memory search"
    assert before == [f"{subject} embeds with gemini fallback"]
    if location == "default":
        assert after["memory"]["search"] == {**default, "fallback": "none"}
    else:
        assert after["memory"]["search"] == default
        assert after["agents"]["entries"]["main"]["memory"]["search"] == {
            **agent,
            "fallback": "none",
        }
    assert router.config_problems(after) == []


def test_turning_transcription_off_is_reported(router: ModuleType) -> None:
    off = {"tools": {"media": {"audio": {"enabled": False}}}}
    assert router.transcription_route(off) == "nobody: tools.media.audio.enabled is false"


# `models status --json` and `sessions --json` as 2026.9.4 printed them, trimmed to the
# fields read, with the banner line the CLI can print first.
def models_status(*, openrouter: bool, resolved: str, missing: list[str]) -> str:
    providers = [
        {"provider": "github-copilot", "effective": {"kind": "env"}, "profiles": {"count": 0}}
    ]
    if openrouter:
        providers.append(
            {"provider": "openrouter", "effective": {"kind": "env"}, "profiles": {"count": 0}}
        )
    status: dict[str, Any] = {
        "defaultModel": resolved,
        "resolvedDefault": resolved,
        "fallbacks": [],
        "imageModel": None,
        "utilityModel": {"ref": None, "source": "none"},
        "auth": {
            "providersWithOAuth": [],
            "missingProvidersInUse": missing,
            "providers": providers,
        },
    }
    return "[openclaw] banner\n" + json.dumps(status)


def sessions_listing(pins: dict[str, str]) -> str:
    sessions = [{"key": "agent:main:telegram:group:-5100000001", "modelProvider": "openrouter"}]
    for key, ref in pins.items():
        provider, model = ref.split("/", 1)
        sessions.append({"key": key, "providerOverride": provider, "modelOverride": model})
    return json.dumps({"count": len(sessions), "sessions": sessions})


class FakeGateways:
    """The gateway CLI, as far as the script uses it, against config files on disk."""

    def __init__(self, router: ModuleType, states: dict[str, Path]) -> None:
        self.router = router
        self.states = states
        self.keys = dict.fromkeys(states, True)
        self.environment: dict[str, dict[str, bool]] = {name: {} for name in states}
        self.pins: dict[str, dict[str, str]] = {name: {} for name in states}
        self.failures_before_pin_clears = 0
        self.calls: list[tuple[str, str]] = []
        self.blocked: set[str] = set()
        self.catalog: list[dict[str, Any]] = list(LISTED_CHAIN)

    def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if argv[0] == "curl":
            assert argv[-1] == self.router.OPENROUTER_MODELS, argv
            self.calls.append(("openrouter", "model list"))
            return subprocess.CompletedProcess(argv, 0, json.dumps({"data": self.catalog}), "")
        assert argv[:2] == ["docker", "exec"], argv
        rest = argv[2:]
        if rest[0] == "-i":
            rest = rest[1:]
        container, command = rest[0], rest[3:]
        if rest[1:3] == ["node", "--eval"]:
            self.calls.append((container, "credential environment"))
            presence = {
                "OPENROUTER_API_KEY": self.keys[container],
                "OPENAI_API_KEY": False,
                "PERPLEXITY_API_KEY": False,
                **self.environment[container],
            }
            return subprocess.CompletedProcess(argv, 0, json.dumps({"environment": presence}), "")
        path = self.states[container] / "openclaw.json"
        self.calls.append((container, " ".join(command[:3])))
        if command[:2] == ["models", "status"]:
            config = json.loads(path.read_text())
            chain = self.router.chat_chain(config)
            missing = ["openai"] if any(ref.startswith("openai/") for ref in chain) else []
            out = models_status(openrouter=self.keys[container], resolved=chain[0], missing=missing)
            return subprocess.CompletedProcess(argv, 0, out, "")
        if command[0] == "sessions":
            return subprocess.CompletedProcess(argv, 0, sessions_listing(self.pins[container]), "")
        if command[:3] == ["gateway", "call", "sessions.patch"]:
            if self.failures_before_pin_clears:
                self.failures_before_pin_clears -= 1
                return subprocess.CompletedProcess(argv, 1, "", "gateway restarting")
            key = json.loads(command[command.index("--params") + 1])["key"]
            self.pins[container].pop(key)
            return subprocess.CompletedProcess(argv, 0, "{}", "")
        if command[:2] == ["config", "patch"]:
            if "--dry-run" in command:
                return subprocess.CompletedProcess(argv, 0, json.dumps({"ok": True}), "")
            merged = self.router.patched(
                json.loads(path.read_text()), json.loads(str(kwargs["input"]))
            )
            path.write_text(json.dumps(merged))
            return subprocess.CompletedProcess(argv, 0, "Applied.", "")
        if command[:2] == ["memory", "index"]:
            return subprocess.CompletedProcess(argv, 0, "Memory index updated (main).", "")
        if command[:3] == ["infer", "video", "providers"]:
            plugins = json.loads(path.read_text()).get("plugins") or {}
            is_loadable = (
                self.router.VIDEO_PLUGIN_PATH in ((plugins.get("load") or {}).get("paths") or [])
                and ((plugins.get("entries") or {}).get(self.router.VIDEO_PLUGIN) or {}).get(
                    "enabled"
                )
                is True
                and plugins.get("enabled") is not False
                and "household-openrouter-video" not in (plugins.get("deny") or [])
                and (not plugins.get("allow") or "household-openrouter-video" in plugins["allow"])
                and container not in self.blocked
            )
            described = [{"id": "google", "capabilities": ["image", "audio", "video"]}]
            if is_loadable:
                described.insert(0, {"id": "openrouter-video", "capabilities": ["video"]})
            out = "[openclaw] banner\n" + json.dumps({"generation": [], "description": described})
            return subprocess.CompletedProcess(argv, 0, out, "")
        raise AssertionError(f"unexpected gateway command {command}")


def write_state(path: Path, config: dict[str, Any]) -> Path:
    path.mkdir(parents=True)
    (path / "openclaw.json").write_text(json.dumps(config))
    (path / "openclaw.json").chmod(0o600)
    return path


@pytest.fixture(autouse=True)
def installed_video_plugin(
    router: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> Path:
    """The plugin as scripts/openclaw-install.sh leaves it on the host."""
    manifest: Path = tmp_path / "plugins" / str(router.VIDEO_PLUGIN) / "openclaw.plugin.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(json.dumps({"id": router.VIDEO_PLUGIN}))
    monkeypatch.setattr(router, "VIDEO_PLUGIN_ON_HOST", manifest)
    return manifest


@pytest.fixture
def gateways(router: ModuleType, tmp_path: Path) -> tuple[Any, ...]:
    corey = write_state(tmp_path / "openclaw", corey_on_codex())
    denise = write_state(tmp_path / "openclaw-denise", denise_on_flash())
    return (
        router.Gateway("corey", "openclaw-gateway", corey, "franco"),
        router.Gateway("denise", "openclaw-denise", denise, "gia"),
    )


@pytest.fixture
def fake(router: ModuleType, gateways: tuple[Any, ...]) -> FakeGateways:
    return FakeGateways(router, {g.container: g.state for g in gateways})


def test_live_state_names_the_key_the_credentials_and_the_pins(
    router: ModuleType, gateways: tuple[Any, ...], fake: FakeGateways
) -> None:
    fake.pins["openclaw-denise"]["agent:main:main"] = "openai/gpt-5.6-luna"
    fake.pins["openclaw-gateway"]["agent:main:main"] = "openrouter/z-ai/glm-5.3-flash"

    corey = router.read_live(gateways[0], fake)
    denise = router.read_live(gateways[1], fake)

    assert corey.openrouter_key is True
    assert "in use without a credential: openai" in router.live_problems(corey)
    assert "effective model openai/gpt-5.6-luna" in router.live_problems(corey)
    # A pin to another OpenRouter model is a choice someone made, and it stays.
    assert corey.pinned_elsewhere == ()
    assert router.live_problems(denise) == [
        "agent:main:main is pinned to openai/gpt-5.6-luna",
        "the CLI cannot load the openrouter-video video provider",
    ]


@needs_nofollow_open
def test_apply_refuses_without_an_openrouter_key_and_touches_nothing(
    router: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}
    fake.keys["openclaw-denise"] = False

    assert router.apply(gateways, run=fake, dry_run=False) == 1

    assert "OPENROUTER_API_KEY" in capsys.readouterr().err
    writes = ("config patch", "gateway call", "memory index")
    assert [call for call in fake.calls if call[1].startswith(writes)] == []
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]


@needs_nofollow_open
def test_apply_clears_pins_then_writes_then_reindexes(
    router: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(router, "PIN_RETRY_SECONDS", 0)
    fake.pins["openclaw-denise"]["agent:main:main"] = "openai/gpt-5.6-luna"
    fake.failures_before_pin_clears = 1
    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert router.apply(gateways, run=fake, dry_run=False) == 1  # the plugin model is left

    denise_calls = [command for container, command in fake.calls if container == "openclaw-denise"]
    writes = [
        command
        for command in denise_calls
        if command.startswith(("gateway call", "config patch --stdin", "memory index"))
    ]
    assert writes == [
        "config patch --stdin",  # the dry run, before anything is written
        "gateway call sessions.patch",  # refused mid-restart
        "gateway call sessions.patch",  # and retried
        "config patch --stdin",
        "memory index --force",
    ]
    assert fake.pins["openclaw-denise"] == {}
    for gateway in gateways:
        (saved,) = gateway.state.glob("openclaw.json.pre-openrouter-*")
        assert saved.read_bytes() == before[gateway.persona]
        assert stat.S_IMODE(saved.stat().st_mode) == 0o600
        config = json.loads(gateway.config_path.read_text())
        assert router.chat_chain(config) == CHAIN

    fake.calls.clear()
    router.apply(gateways, run=fake, dry_run=False)
    assert not any(command.startswith("config patch --stdin") for _, command in fake.calls)


@needs_nofollow_open
def test_a_memory_rebuild_that_runs_out_of_time_does_not_stop_the_other_gateway(
    router: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    def slow_index_on_corey(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if "openclaw-gateway" in argv and argv[-5:-3] == ["memory", "index"]:
            raise subprocess.TimeoutExpired(argv, 900)
        return fake(argv, **kwargs)

    router.apply(gateways, run=slow_index_on_corey, dry_run=False)

    out = capsys.readouterr().out
    assert "corey: memory index NOT rebuilt" in out
    assert "memory index --force --agent main" in out
    assert "denise: memory index rebuilt" in out
    for gateway in gateways:
        assert router.chat_chain(json.loads(gateway.config_path.read_text())) == CHAIN


@needs_nofollow_open
def test_check_always_asks_the_gateways(
    router: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(router, "GATEWAYS", gateways)

    router.main(["check"], run=fake)
    with pytest.raises(SystemExit) as refused:
        router.main(["check", "--config-only"], run=fake)

    assert {command for _, command in fake.calls} >= {
        "models status --json",
        "sessions --json --limit",
    }
    assert refused.value.code == 2
    assert "unrecognized arguments: --config-only" in capsys.readouterr().err


@needs_nofollow_open
def test_a_dry_run_writes_nothing_and_clears_nothing(
    router: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake.pins["openclaw-denise"]["agent:main:main"] = "openai/gpt-5.6-luna"
    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert router.apply(gateways, run=fake, dry_run=True) == 0

    out = capsys.readouterr().out
    assert "denise would clear the pin on agent:main:main (openai/gpt-5.6-luna)" in out
    assert "corey would still need a hand: plugins.entries.active-memory.config.model" in out
    assert fake.pins["openclaw-denise"] == {"agent:main:main": "openai/gpt-5.6-luna"}
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]


@needs_nofollow_open
def test_verdict_is_one_line_about_one_gateway(router: ModuleType, tmp_path: Path) -> None:
    good = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    state = write_state(tmp_path / "good", good)
    fake = FakeGateways(router, {"openclaw-denise": state})
    assert router.verdict("openclaw-denise", state, run=fake) == "ok"
    bad = write_state(tmp_path / "bad", denise_on_flash())
    assert "voice notes are transcribed by openai" in router.verdict(
        "openclaw-denise", bad, run=fake
    )
    assert router.verdict("openclaw-denise", tmp_path / "missing").startswith("unreadable:")
    assert router.verdict("someone-else", state) == "no policy for container someone-else"


@needs_nofollow_open
def test_an_unreadable_model_list_stops_apply_and_fails_check_and_verdict(
    router: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    def no_list(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if argv[0] == "curl":
            return subprocess.CompletedProcess(argv, 22, "", "curl: (22) error: 503")
        return fake(argv, **kwargs)

    before = {g.persona: g.config_path.read_bytes() for g in gateways}

    assert router.apply(gateways, run=no_list, dry_run=False) == 1
    assert "OpenRouter's model list could not be read: curl: (22)" in capsys.readouterr().err
    assert router.check(gateways, run=no_list) == 1
    assert "OpenRouter's model list could not be read" in capsys.readouterr().out
    assert router.verdict(gateways[1].container, gateways[1].state, run=no_list).startswith(
        "unreadable: OpenRouter's model list could not be read"
    )
    writes = ("config patch", "gateway call", "memory index")
    assert [call for call in fake.calls if call[1].startswith(writes)] == []
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]


# Every GLM 5.3 and DeepSeek V4 id on OpenRouter's model list as it printed it on
# 2026-10-17, the families the household chain draws from. The chain's free DeepSeek,
# deepseek/deepseek-v4-flash-0731:free, is not among them (#199).
LISTED_ON_2026_10_17 = (
    "deepseek/deepseek-v4-flash",
    "deepseek/deepseek-v4-flash-0731",
    "deepseek/deepseek-v4-flash-vision-exp",
    "deepseek/deepseek-v4-pro",
    "deepseek/deepseek-v4-pro-0813",
    "deepseek/deepseek-v4.1-flash",
    "deepseek/deepseek-v4.1-flash-1017",
    "deepseek/deepseek-v4.1-flash:batch",
    "z-ai/glm-5.3",
    "z-ai/glm-5.3-flash",
    "z-ai/glm-5.3-flash:batch",
    "z-ai/glm-5.3-flashx",
    "z-ai/glm-5.3-prime",
    "z-ai/glm-5.3:batch",
    "~deepseek/deepseek-v4-flash-latest",
)


def test_every_model_in_the_household_chain_is_on_openrouter_s_list(router: ModuleType) -> None:
    catalog = {model_id: {"id": model_id} for model_id in LISTED_ON_2026_10_17}
    config = router.patched(router_ready(), router.openrouter_patch(router_ready(), LISTED))

    assert router.chat_chain(config) == (router.CHAT_PRIMARY, *router.CHAT_FALLBACKS)
    assert router.chain_problems(config, catalog) == []


@pytest.mark.parametrize("missing", CHAIN)
@needs_nofollow_open
def test_a_chain_model_openrouter_no_longer_lists_fails_check_and_verdict(
    router: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str], missing: str
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {gateway.container: state})
    fake.catalog = [listed for listed in LISTED_CHAIN if f"openrouter/{listed['id']}" != missing]
    problem = f"{missing} in the chat chain is not on OpenRouter's model list"

    assert router.chain_problems(config, {m["id"]: m for m in fake.catalog}) == [problem]
    assert router.verdict(gateway.container, state, run=fake) == problem
    assert router.check((gateway,), run=fake) == 1
    assert problem in capsys.readouterr().out
    assert router.plan(gateway, fake).left == (problem,)


def test_an_entry_that_names_openrouter_is_read_as_one_ref(router: ModuleType) -> None:
    """An OpenRouter model id starts with its upstream vendor, which is not a provider."""
    config = {
        "plugins": {
            "entries": {
                "a": {"config": {"provider": "openrouter", "model": "openai/gpt-5.6-luna"}},
                "b": {"config": {"provider": "openai", "model": "gpt-5.4-mini"}},
            }
        }
    }
    assert list(router.model_refs(config)) == [
        (("plugins", "entries", "a", "config", "model"), "openrouter/openai/gpt-5.6-luna"),
        (("plugins", "entries", "b", "config", "model"), "openai/gpt-5.4-mini"),
    ]


@pytest.mark.parametrize(
    "scope",
    [
        ("tts",),
        ("agents", "entries", "main", "tts"),
        ("tts", "personas", "household"),
    ],
)
def test_a_speech_model_is_read_with_the_provider_block_it_sits_in(
    router: ModuleType, scope: tuple[str, ...]
) -> None:
    """Under `providers.<id>` the provider is the key, so the model is that provider's own id.

    Both gateways speak with `tts.providers.openrouter.model: elevenlabs/eleven-v4-turbo`
    since 9 October, and the audit read that as a model on a provider called elevenlabs.
    """
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    block = config
    for key in scope:
        block = block.setdefault(key, {})
    providers = block.setdefault("providers", {})
    providers["openrouter"] = {"model": "elevenlabs/eleven-v4-turbo", "speakerVoice": "sarah"}

    assert router.config_problems(config) == []

    providers["elevenlabs"] = {"model": "eleven_multilingual_v2"}
    path = ".".join((*scope, "providers", "elevenlabs", "model"))
    assert router.config_problems(config) == [f"{path} is elevenlabs/eleven_multilingual_v2"]


@pytest.mark.parametrize(
    ("base_url", "problems"),
    [
        ("https://openrouter.ai/api/v1", []),
        ("https://openrouter.ai/v1/", []),
        (
            "https://api.openai.com/v1",
            ["speech sends its OpenRouter requests to https://api.openai.com/v1"],
        ),
        (
            "https://openrouter.ai.example.com/api/v1",
            ["speech sends its OpenRouter requests to https://openrouter.ai.example.com/api/v1"],
        ),
    ],
    ids=["openrouter", "openrouter-legacy", "openai", "lookalike-host"],
)
def test_openrouter_speech_is_judged_by_the_address_it_is_sent_to(
    router: ModuleType, base_url: str, problems: list[str]
) -> None:
    """A model the OpenRouter block names is only OpenRouter's if the block still goes there."""
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    config["tts"]["providers"]["openrouter"] = {
        "model": "elevenlabs/eleven-v4-turbo",
        "baseUrl": base_url,
    }

    assert router.config_problems(config) == problems


@needs_nofollow_open
def test_apply_says_when_it_could_not_ask_a_gateway(
    router: ModuleType,
    gateways: tuple[Any, ...],
    capsys: pytest.CaptureFixture[str],
) -> None:
    def down(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(argv, 1, "", "Error: No such container")

    assert router.apply(gateways, run=down, dry_run=False) == 1
    err = capsys.readouterr().err
    assert "could not read openclaw-gateway's credentials" in err
    assert "no OpenRouter key" not in err


def test_photos_generation_and_speech_are_named_on_openrouter(router: ModuleType) -> None:
    """Left unset, each goes to whichever provider holds a key; photos never to OpenRouter."""
    bare = denise_on_flash()
    wrong = router.config_problems(bare)
    assert "no image model, so a photo the chat model cannot read goes elsewhere" in wrong
    for kind in ("image", "video", "music"):
        assert f"{kind} generation is left to whichever provider has a key" in wrong
    assert "speech goes to whichever provider has a key" in wrong

    after = router.patched(bare, router.openrouter_patch(bare, LISTED))
    defaults = after["agents"]["defaults"]
    # OpenAI's newest image model on OpenRouter, the owner's choice, reads and makes
    # images; gemini-2.5-flash backs up reading, the one job OpenClaw runs with
    # reasoning off, which both answered on the box on 2026-10-07.
    assert defaults["imageModel"] == {
        "primary": "openrouter/openai/gpt-5.4-image-2",
        "fallbacks": ["openrouter/google/gemini-2.5-flash"],
    }
    assert defaults["mediaModels"] == {
        "image": {"primary": "openrouter/openai/gpt-image-2.5-flare"},
        "video": {"primary": "openrouter/google/veo-3.1-fast"},
        "music": {"primary": "openrouter/google/lyria-3-pro-preview"},
    }
    assert after["tts"] == {
        "provider": "openrouter",
        "providers": {"microsoft": {"enabled": False}},
    }
    assert router.config_problems(after) == []


def test_videos_people_send_are_routed_to_the_openrouter_video_plugin(router: ModuleType) -> None:
    """OpenClaw 2026.9.4 describes video only through Google unless something else is named."""
    config = denise_on_flash()
    config["plugins"] = {
        "load": {"paths": ["/opt/household-plugins/household-family-room"]},
        "allow": ["household-family-room"],
        "entries": {"household-family-room": {"enabled": True}},
    }

    before = router.config_problems(config)
    after = router.patched(config, router.openrouter_patch(config, LISTED))

    assert "videos people send have no OpenRouter route, so Google or nobody reads them" in before
    assert "the household-openrouter-video plugin is not loaded and enabled" in before
    assert "the household-openrouter-video plugin is blocked by plugins.allow" in before
    assert {
        "provider": "openrouter-video",
        "model": "google/gemini-2.5-flash",
        "capabilities": ["video"],
    } in after["tools"]["media"]["models"]
    # The lists that name plugins are written back whole, so the family room stays.
    assert after["plugins"]["load"]["paths"] == [
        "/opt/household-plugins/household-family-room",
        "/opt/household-plugins/household-openrouter-video",
    ]
    assert after["plugins"]["allow"] == ["household-family-room", "household-openrouter-video"]
    assert after["plugins"]["entries"]["household-family-room"] == {"enabled": True}
    assert after["plugins"]["entries"]["household-openrouter-video"] == {"enabled": True}
    assert not any("video" in item for item in router.config_problems(after))


def test_check_reports_cli_loadability_without_certifying_daemon_registration(
    router: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The providers command runs locally and cannot prove the daemon loaded the plugin."""
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {"openclaw-denise": state})
    monkeypatch.setattr(router, "read_config", lambda _gateway: config)

    assert router.check((gateway,), run=fake) == 0
    fake.blocked.add("openclaw-denise")
    assert router.check((gateway,), run=fake) == 1

    out = capsys.readouterr().out
    assert "described by openrouter-video/google/gemini-2.5-flash" in out
    assert "CLI loadability only. Running gateway registration is unverified" in out
    assert "the CLI cannot load the openrouter-video video provider" in out
    assert "the gateway has not loaded" not in out


@pytest.mark.parametrize("is_enabled", [None, True, False])
def test_video_enabled_flag_is_shared_by_audit_check_and_verdict(
    router: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    is_enabled: bool | None,
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    if is_enabled is not None:
        config["tools"]["media"]["video"] = {"enabled": is_enabled}
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {gateway.container: state})
    monkeypatch.setattr(router, "read_config", lambda _gateway: config)

    problems = router.config_problems(config)
    result = router.check((gateway,), run=fake)
    verdict = router.verdict(gateway.container, state, run=fake)

    if is_enabled is False:
        assert problems == ["video understanding is disabled"]
        assert result == 1
        assert verdict == "video understanding is disabled"
        out = capsys.readouterr().out
        assert "disabled" in out
        assert "described by" not in out
    else:
        assert problems == []
        assert result == 0
        assert verdict == "ok"
        assert "described by openrouter-video/google/gemini-2.5-flash" in capsys.readouterr().out


@pytest.mark.parametrize(
    ("policy", "expected", "expected_plan"),
    [
        ({}, [], []),
        ({"enabled": True, "deny": [], "allow": []}, [], []),
        (
            {"deny": ["another-plugin"], "allow": ["household-openrouter-video"]},
            [],
            [],
        ),
        (
            {"enabled": False},
            ["the household-openrouter-video plugin is blocked by plugins.enabled=false"],
            ["the household-openrouter-video plugin is blocked by plugins.enabled=false"],
        ),
        (
            {"deny": ["household-openrouter-video"]},
            ["the household-openrouter-video plugin is blocked by plugins.deny"],
            ["the household-openrouter-video plugin is blocked by plugins.deny"],
        ),
        (
            {"allow": ["household-family-room"]},
            ["the household-openrouter-video plugin is blocked by plugins.allow"],
            [],
        ),
        (
            {
                "enabled": False,
                "deny": ["household-openrouter-video"],
                "allow": ["household-family-room"],
            },
            [
                "the household-openrouter-video plugin is blocked by plugins.enabled=false",
                "the household-openrouter-video plugin is blocked by plugins.deny",
                "the household-openrouter-video plugin is blocked by plugins.allow",
            ],
            [
                "the household-openrouter-video plugin is blocked by plugins.enabled=false",
                "the household-openrouter-video plugin is blocked by plugins.deny",
            ],
        ),
    ],
)
def test_plugin_policy_blocks_are_reported_and_only_the_allow_list_is_merged(
    router: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    policy: dict[str, bool | list[str]],
    expected: list[str],
    expected_plan: list[str],
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    config["plugins"].update(policy)
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {gateway.container: state})
    monkeypatch.setattr(router, "read_config", lambda _gateway: config)
    before = gateway.config_path.read_bytes()

    problems = router.config_problems(config)
    result = router.check((gateway,), run=fake)
    verdict = router.verdict(gateway.container, state, run=fake)
    plan = router.plan(gateway, run=fake)

    assert problems == expected
    assert result == int(bool(expected))
    assert verdict == ("; ".join(expected) if expected else "ok")
    assert plan.left == tuple(expected_plan)
    out = capsys.readouterr().out
    if expected:
        assert "described by" not in out
        for blocker in expected:
            assert blocker in out
    else:
        assert "described by openrouter-video/google/gemini-2.5-flash" in out
    proposed = router.patched(config, plan.patch)
    for key in ("enabled", "deny"):
        assert proposed["plugins"].get(key) == config["plugins"].get(key)
    if "allow" in policy:
        assert proposed["plugins"]["allow"] == (
            ["household-family-room", "household-openrouter-video"]
            if policy["allow"] == ["household-family-room"]
            else ["household-openrouter-video"]
        )
    else:
        assert "allow" not in proposed["plugins"]
    assert gateway.config_path.read_bytes() == before


@pytest.mark.parametrize("has_environment_key", [False, True])
def test_video_environment_key_is_required_even_with_an_authenticated_profile(
    router: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    has_environment_key: bool,
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {gateway.container: state})
    fake.environment[gateway.container]["OPENROUTER_API_KEY"] = has_environment_key
    monkeypatch.setattr(router, "read_config", lambda _gateway: config)
    before = gateway.config_path.read_bytes()

    def authenticated_profile(
        argv: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        completed = fake(argv, **kwargs)
        if argv[-3:] == ["models", "status", "--json"]:
            status = json.loads(completed.stdout.split("\n", 1)[1])
            status["auth"]["providers"] = [
                {
                    "provider": "openrouter",
                    "effective": {"kind": "profiles"},
                    "profiles": {"count": 1},
                }
            ]
            return subprocess.CompletedProcess(argv, 0, json.dumps(status), "")
        return completed

    environment = frozenset({"OPENROUTER_API_KEY"}) if has_environment_key else frozenset()
    expected = (
        []
        if has_environment_key
        else [
            "the household-openrouter-video plugin requires OPENROUTER_API_KEY "
            "in the container's environment"
        ]
    )

    assert router.video_problems(config, environment=environment) == expected
    assert router.config_problems(config, environment=environment) == expected
    assert router.read_live(gateway, authenticated_profile).openrouter_key is True
    assert router.check((gateway,), run=authenticated_profile) == int(not has_environment_key)
    report = capsys.readouterr().out
    assert router.verdict(gateway.container, state, run=authenticated_profile) == (
        "ok" if has_environment_key else expected[0]
    )
    if has_environment_key:
        assert router.plan(gateway, authenticated_profile).left == ()
        assert router.apply((gateway,), run=authenticated_profile, dry_run=False) == 0
        assert "described by openrouter-video/google/gemini-2.5-flash" in report
    else:
        with pytest.raises(RuntimeError, match="OPENROUTER_API_KEY"):
            router.plan(gateway, authenticated_profile)
        assert router.apply((gateway,), run=authenticated_profile, dry_run=False) == 1
        assert "OPENROUTER_API_KEY" in capsys.readouterr().err
        assert expected[0] in report
        assert "described by" not in report
    writes = ("config patch", "gateway call", "memory index")
    assert [call for call in fake.calls if call[1].startswith(writes)] == []
    assert gateway.config_path.read_bytes() == before


def test_apply_refuses_until_the_video_plugin_is_installed_and_touches_nothing(
    router: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    installed_video_plugin: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {g.persona: g.config_path.read_bytes() for g in gateways}
    installed_video_plugin.unlink()

    assert router.apply(gateways, run=fake, dry_run=False) == 1

    assert "scripts/openclaw-install.sh" in capsys.readouterr().err
    assert fake.calls == []
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]


def test_a_generation_slot_keeps_its_settings_and_only_openrouter_fallbacks(
    router: ModuleType,
) -> None:
    config = denise_on_flash()
    config["agents"]["defaults"]["mediaModels"] = {
        "image": {
            "primary": "openai/gpt-image-2",
            "fallbacks": ["openai/gpt-image-1", "openrouter/black-forest-labs/flux-2"],
            "timeoutMs": 180000,
        },
        "video": "openai/sora-2",
    }
    config["agents"]["entries"]["main"]["imageModel"] = "openai/gpt-5.6-luna"
    config["tts"] = {"provider": "openai", "summaryModel": "openai/gpt-5.4-mini", "auto": "off"}

    after = router.patched(config, router.openrouter_patch(config, LISTED))

    media = after["agents"]["defaults"]["mediaModels"]
    assert media["image"] == {
        "primary": "openrouter/openai/gpt-image-2.5-flare",
        "fallbacks": ["openrouter/black-forest-labs/flux-2"],
        "timeoutMs": 180000,
    }
    assert media["video"] == {"primary": "openrouter/google/veo-3.1-fast"}
    assert "imageModel" not in after["agents"]["entries"]["main"]
    # Speech moves to OpenRouter; whether replies are spoken stays as it was.
    assert after["tts"] == {
        "provider": "openrouter",
        "auto": "off",
        "providers": {"microsoft": {"enabled": False}},
    }
    assert router.config_problems(after) == []


def test_web_search_is_reported_when_named_elsewhere_and_never_written(
    router: ModuleType,
) -> None:
    """Naming perplexity needs its plugin installed, or 2026.9.4 refuses the whole patch."""
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    assert "web" not in config["tools"]
    assert router.config_problems(config) == []

    config["tools"]["web"] = {"search": {"provider": "codex"}}
    assert router.config_problems(config) == ["web search goes to codex"]
    assert "web" not in router.openrouter_patch(config, LISTED)["tools"]

    config["tools"]["web"] = {"search": {"provider": "perplexity"}}
    assert router.config_problems(config, environment=frozenset({"OPENROUTER_API_KEY"})) == []


@pytest.mark.parametrize("is_enabled", [True, False])
def test_speech_audit_reports_a_credentialed_fallback_even_with_an_enabled_flag(
    router: ModuleType, is_enabled: bool
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    config["tts"]["providers"]["openai"] = {
        "apiKey": {"source": "env", "provider": "default", "id": "OPENAI_API_KEY"},
        "enabled": is_enabled,
    }

    assert router.config_problems(config) == ["speech can fall back to openai"]


def test_microsoft_speech_fallback_is_disabled_without_changing_voice_settings(
    router: ModuleType,
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    config["tts"]["providers"] = {"microsoft": {"enabled": True, "voice": "en-US-GuyNeural"}}
    config["tts"]["auto"] = "inbound"

    before = router.config_problems(config)
    after = router.patched(config, router.openrouter_patch(config, LISTED))

    assert before == ["speech can fall back to microsoft"]
    assert after["tts"] == {
        "provider": "openrouter",
        "auto": "inbound",
        "providers": {"microsoft": {"enabled": False, "voice": "en-US-GuyNeural"}},
    }
    assert router.config_problems(after) == []


@needs_nofollow_open
def test_apply_validates_the_speech_provider_patch_before_writing_either_gateway(
    router: ModuleType,
    gateways: tuple[Any, ...],
    fake: FakeGateways,
    capsys: pytest.CaptureFixture[str],
) -> None:
    before = {gateway.persona: gateway.config_path.read_bytes() for gateway in gateways}
    validated: list[object] = []

    def reject_speech_patch(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if "--dry-run" in argv and "patch" in argv:
            patch = json.loads(str(kwargs["input"]))
            validated.append(patch["tts"]["providers"])
            return subprocess.CompletedProcess(argv, 1, "", "speech settings rejected")
        return fake(argv, **kwargs)

    assert router.apply(gateways, run=reject_speech_patch, dry_run=False) == 1

    assert validated == [{"microsoft": {"enabled": False}}]
    assert "speech settings rejected" in capsys.readouterr().err
    for gateway in gateways:
        assert gateway.config_path.read_bytes() == before[gateway.persona]
    assert not any(command.startswith("config patch") for _, command in fake.calls)


@pytest.mark.parametrize("location", ["plugin", "legacy"])
@pytest.mark.parametrize(
    ("base_url", "credential", "is_direct"),
    [
        ("https://api.perplexity.ai", "pplx-test-credential", True),
        (None, "pplx-test-credential", True),
        (None, {"source": "env", "provider": "default", "id": "PERPLEXITY_API_KEY"}, True),
        ("https://openrouter.ai/api/v1", "sk-or-test-credential", False),
        (None, "sk-or-test-credential", False),
        (None, {"source": "env", "provider": "default", "id": "OPENROUTER_API_KEY"}, False),
    ],
)
@needs_nofollow_open
def test_check_and_verdict_judge_perplexity_by_endpoint_and_credential_source(
    router: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    location: str,
    base_url: str | None,
    credential: str | dict[str, str],
    is_direct: bool,
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    settings = {"apiKey": credential}
    if base_url is not None:
        settings["baseUrl"] = base_url
    config["tools"]["web"] = {"search": {"provider": "perplexity"}}
    if location == "plugin":
        config["plugins"]["entries"]["perplexity"] = {"config": {"webSearch": settings}}
    else:
        config["tools"]["web"]["search"]["perplexity"] = settings
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {"openclaw-denise": state})

    result = router.check((gateway,), run=fake)
    verdict = router.verdict("openclaw-denise", state, run=fake)

    assert result == int(is_direct)
    assert ("web search goes to" in verdict) is is_direct
    assert ("web search goes to" in capsys.readouterr().out) is is_direct
    patch = router.openrouter_patch(config, LISTED)
    assert "web" not in patch["tools"]
    assert router.patched(config, patch)["tools"]["web"] == config["tools"]["web"]


def test_perplexity_environment_credential_and_disabled_search_are_judged(
    router: ModuleType,
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    config["env"] = {"vars": {"PERPLEXITY_API_KEY": "pplx-test-credential"}}

    assert router.config_problems(config) == [
        "web search goes to Perplexity directly (PERPLEXITY_API_KEY)"
    ]
    config["tools"]["web"] = {"search": {"enabled": False}}
    assert router.config_problems(config) == []


@pytest.mark.parametrize(
    "path",
    [
        ("agents", "entries", "main", "tts"),
        ("channels", "telegram", "tts"),
        ("channels", "telegram", "accounts", "family", "tts"),
    ],
)
@pytest.mark.parametrize("has_provider_override", [True, False])
@needs_nofollow_open
def test_apply_removes_scoped_speech_routes_and_keeps_voice_and_auto_settings(
    router: ModuleType,
    tmp_path: Path,
    path: tuple[str, ...],
    has_provider_override: bool,
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    scope = config
    for key in path:
        scope = scope.setdefault(key, {})
    scope.update(
        {"auto": "off", "providers": {"microsoft": {"enabled": True, "voice": "en-US-GuyNeural"}}}
    )
    if has_provider_override:
        scope["provider"] = "microsoft"
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {gateway.container: state})

    assert f"{'.'.join(path)} can fall back to microsoft" in router.verdict(
        gateway.container, state, run=fake
    )
    assert router.apply((gateway,), run=fake, dry_run=False) == 0

    migrated = json.loads(gateway.config_path.read_text())
    scope = migrated
    for key in path:
        scope = scope[key]
    assert scope == {"auto": "off", "providers": {"microsoft": {"voice": "en-US-GuyNeural"}}}
    assert router.verdict(gateway.container, state, run=fake) == "ok"


@pytest.mark.parametrize("has_openai_key", [True, False])
@needs_nofollow_open
def test_live_speech_audit_includes_an_environment_backed_openai_fallback(
    router: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    has_openai_key: bool,
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {gateway.container: state})
    fake.environment[gateway.container]["OPENAI_API_KEY"] = has_openai_key

    assert router.check((gateway,), run=fake) == int(has_openai_key)
    assert ("speech can fall back to openai" in capsys.readouterr().out) is has_openai_key
    assert router.verdict(gateway.container, state, run=fake) == (
        "speech can fall back to openai" if has_openai_key else "ok"
    )


@pytest.mark.parametrize("has_perplexity_key", [True, False])
@needs_nofollow_open
def test_search_audit_prefers_the_containers_perplexity_key_over_openrouter(
    router: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    has_perplexity_key: bool,
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    config["tools"]["web"] = {"search": {"provider": "perplexity"}}
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {gateway.container: state})
    fake.environment[gateway.container]["PERPLEXITY_API_KEY"] = has_perplexity_key

    assert router.check((gateway,), run=fake) == int(has_perplexity_key)
    assert (
        "Perplexity directly (PERPLEXITY_API_KEY)" in capsys.readouterr().out
    ) is has_perplexity_key
    assert router.verdict(gateway.container, state, run=fake) == (
        "web search goes to Perplexity directly (PERPLEXITY_API_KEY)"
        if has_perplexity_key
        else "ok"
    )
    assert "web" not in router.openrouter_patch(config, LISTED)["tools"]


def test_a_failed_container_environment_probe_cannot_certify_the_routes(
    router: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    config = router.patched(denise_on_flash(), router.openrouter_patch(denise_on_flash(), LISTED))
    config["tools"]["web"] = {"search": {"provider": "perplexity"}}
    state = write_state(tmp_path / "state", config)
    gateway = router.Gateway("denise", "openclaw-denise", state, "gia")
    fake = FakeGateways(router, {gateway.container: state})
    monkeypatch.setattr(router, "read_config", lambda _gateway: config)
    before = gateway.config_path.read_bytes()

    def unavailable(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if "--eval" in argv:
            return subprocess.CompletedProcess(argv, 1, "", "container not running")
        return fake(argv, **kwargs)

    assert router.check((gateway,), run=unavailable) == 1
    assert "unresolved credential route" in capsys.readouterr().out
    assert router.verdict(gateway.container, state, run=unavailable) == (
        "unreadable: container credential presence gave no answer"
    )
    with pytest.raises(RuntimeError, match="could not read openclaw-denise's credentials"):
        router.plan(gateway, unavailable)
    assert router.apply((gateway,), run=unavailable, dry_run=False) == 1
    assert "credential environment" in capsys.readouterr().err
    writes = ("config patch", "gateway call", "memory index")
    assert [call for call in fake.calls if call[1].startswith(writes)] == []
    assert gateway.config_path.read_bytes() == before


def test_container_environment_probe_executes_without_exposing_credentials(
    router: ModuleType, tmp_path: Path
) -> None:
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is not available")
    environment = {
        **os.environ,
        "OPENROUTER_API_KEY": "sk-or-regression-secret",
        "OPENAI_API_KEY": " ",
        "PERPLEXITY_API_KEY": "pplx-regression-secret",
    }
    observed: list[str] = []

    def run_node(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            [node, *argv[4:]], env=environment, text=True, capture_output=True, check=False
        )
        observed.append(completed.stdout)
        return completed

    gateway = router.Gateway("denise", "openclaw-denise", tmp_path, "gia")
    assert router.read_environment(gateway, run_node) == frozenset(
        {"OPENROUTER_API_KEY", "PERPLEXITY_API_KEY"}
    )
    assert all("regression-secret" not in output for output in observed)


def test_an_image_or_video_model_a_phone_picked_on_openrouter_stays(router: ModuleType) -> None:
    config = denise_on_flash()
    config["agents"]["defaults"]["mediaModels"] = {
        "image": {"primary": "openrouter/google/gemini-3.1-flash-image"},
        "video": "openrouter/x-ai/grok-imagine-video-1.5",
        "music": {"primary": "openrouter/"},
    }

    after = router.patched(config, router.openrouter_patch(config, LISTED))

    assert after["agents"]["defaults"]["mediaModels"] == {
        "image": {"primary": "openrouter/google/gemini-3.1-flash-image"},
        "video": {"primary": "openrouter/x-ai/grok-imagine-video-1.5"},
        "music": {"primary": "openrouter/google/lyria-3-pro-preview"},
    }


def test_apply_preserves_the_vision_model_selected_on_the_phone(router: ModuleType) -> None:
    config = denise_on_flash()
    config["agents"]["defaults"]["imageModel"] = {
        "primary": "openrouter/acme/selected-vision",
        "fallbacks": [],
    }
    patch = router.openrouter_patch(config, LISTED)
    assert patch["agents"]["defaults"]["imageModel"]["primary"] == "openrouter/acme/selected-vision"
    assert patch["agents"]["defaults"]["imageModel"].get("fallbacks", []) == []
