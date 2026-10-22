"""openclaw-verify.sh's compose reads, asserted by running the script.

Two gateway services share one compose file, so every read of it has to be
scoped to the gateway being checked. Unscoped, `awk '$1=="image:"'` returned
both services' values as one newline-joined string, and the digest, memory and
CPU comparisons all failed against a box that was in fact correct. That is the
defect these pin.

Each case runs the real script against a two-service compose file whose two
services differ in all three values, with a `docker` on PATH that reports the
gateway under test and a cgroup tree carrying its ceilings, then asserts those
three checks pass and that the other service's values appear nowhere.

The tailnet checks get the same treatment: a `tailscale` on PATH that prints a
given serve config, so the funnel and proxy reads are asserted against the
JSON shape the box's `tailscale serve status --json` returns.

So does the heartbeat check: the `docker` shim prints a given scheduler listing
for `cron list --all --json`, shaped like the one the gateway returns, so the
check is asserted to count enabled heartbeats and nothing else.

And the family group check: the state directory gets an `openclaw.json`, and the
real openclaw-family-group.py beside the script reads it.

And the calendar library check: the `docker` shim prints a given result for the
import the script runs inside the container.

The harness replaces docker, tailscale and curl on PATH, so no case reaches the
network.

What is not exercised here: a real box. The container, firewall, HTTP probe and
state checks have no stand-in, so they fail in this harness and the script exits
non-zero; only the lines named in each test are asserted.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from tests.capabilities import needs_getuid, needs_posix_bash

pytestmark = needs_posix_bash

ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / "scripts" / "openclaw-verify.sh"

GATEWAY_DIGEST = "sha256:" + "a" * 64
DENISE_DIGEST = "sha256:" + "b" * 64

# Shaped like the deployed file: a top-level networks block, comments inside a
# service block, and the ceilings nested under deploy.resources.limits. The two
# services differ in every value read, which an unscoped read cannot express.
COMPOSE = f"""\
networks:
  deploy_default:
    external: true

services:
  openclaw-gateway:
    image: openclaw/openclaw:2026.9.4@{GATEWAY_DIGEST}
    container_name: openclaw-gateway
    # A comment inside the block, which the scoped read has to walk past.
    ports:
      - "127.0.0.1:18789:18789"
    deploy:
      resources:
        limits:
          cpus: "2.50"
          memory: 3072M

  openclaw-denise:
    image: openclaw/openclaw:2026.9.4@{DENISE_DIGEST}
    container_name: openclaw-denise
    ports:
      - "127.0.0.1:18790:18789"
    deploy:
      resources:
        limits:
          cpus: "1.50"
          memory: 1408M
"""

# OpenRouter's model list as the openrouter.py verdict reads it, trimmed to the chat
# chain's entries as printed on 2026-10-17: every model in the chain is listed (#199).
OPENROUTER_MODELS = {
    "data": [
        {"id": "z-ai/glm-5.3-flash", "name": "Z.ai: GLM 5.3 Flash"},
        {"id": "z-ai/glm-5.3", "name": "Z.ai: GLM 5.3"},
        {"id": "deepseek/deepseek-v4-flash-0731", "name": "DeepSeek: DeepSeek V4 Flash 0731"},
    ]
}


def run_verify(
    tmp_path: Path,
    container: str,
    digest: str,
    memory_mib: int,
    cpu_quota: int,
    serve: dict[str, object] | None = None,
    jobs: dict[str, object] | None = None,
    config: dict[str, object] | None = None,
    environment: dict[str, bool] | None = None,
    library_import: str | None = None,
    state_owner: int | None = None,
    state_files: tuple[str, ...] = (),
    state_links: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run openclaw-verify.sh with the one gateway's docker and cgroup in place.

    The harness replaces docker, tailscale and curl, so no case reaches the
    network. `serve` is what `tailscale serve status --json` prints; without it
    `tailscale` prints nothing and fails, as on a box without Tailscale. `jobs`
    is what the gateway's `cron list --all --json` prints; without it that call
    prints nothing, as when the gateway does not answer. `curl` prints
    OPENROUTER_MODELS for OpenRouter's model list, and otherwise prints 000 and
    exits 7, the way curl reports a connection it could not make. `config` is the
    gateway's openclaw.json; without it the state directory has none.
    `library_import` is what `python3 -c 'import requests; ...'` prints inside the
    container, failing unless it is `ok`; without it that call prints nothing.
    `state_files` are created under the state directory, `state_links` are
    symbolic links there to the given targets, and `state_owner` is the uid the
    script expects them all to belong to.
    """
    bash = shutil.which("bash")
    assert bash is not None, "the deployment scripts are bash, and CI has to have it"

    compose = tmp_path / "docker-compose.yml"
    compose.write_text(COMPOSE)

    container_id = "0" * 64
    shim = tmp_path / "bin"
    shim.mkdir()
    cron_list = ""
    if jobs is not None:
        (tmp_path / "jobs.json").write_text(json.dumps(jobs))
        cron_list = (
            f'  *"cron list --all --json"*) cat "{(tmp_path / "jobs.json").as_posix()}" ;;\n'
        )
    library = ""
    if library_import is not None:
        (tmp_path / "library.txt").write_text(library_import)
        status = 0 if library_import.strip() == "ok" else 1
        library = (
            f'  *"import requests"*) cat "{(tmp_path / "library.txt").as_posix()}"; '
            f"exit {status} ;;\n"
        )
    docker = shim / "docker"
    (tmp_path / "environment.json").write_text(
        json.dumps(
            {
                "environment": environment
                or {
                    "OPENROUTER_API_KEY": True,
                    "OPENAI_API_KEY": False,
                    "PERPLEXITY_API_KEY": False,
                }
            }
        )
    )
    docker.write_text(
        "#!/bin/sh\n"
        'case "$*" in\n'
        f'  *RepoDigests*) echo "openclaw/openclaw@{digest}" ;;\n'
        '  *"{{.Image}}"*) echo "sha256:an-image-id" ;;\n'
        f'  *"{{{{.Id}}}}"*) echo "{container_id}" ;;\n'
        f"{cron_list}"
        f"{library}"
        f'  *"node --eval"*) cat "{(tmp_path / "environment.json").as_posix()}" ;;\n'
        '  *) echo "" ;;\n'
        "esac\n"
    )
    docker.chmod(docker.stat().st_mode | stat.S_IXUSR)

    tailscale = shim / "tailscale"
    if serve is not None:
        (tmp_path / "serve.json").write_text(json.dumps(serve))
        tailscale.write_text(
            "#!/bin/sh\n"
            'case "$*" in\n'
            """  "status --self --json") echo '{"Self":{"DNSName":"box.example.ts.net."}}' ;;\n"""
            f'  "serve status --json") cat "{(tmp_path / "serve.json").as_posix()}" ;;\n'
            "esac\n"
        )
    else:
        tailscale.write_text("#!/bin/sh\nexit 1\n")
    tailscale.chmod(tailscale.stat().st_mode | stat.S_IXUSR)

    (tmp_path / "models.json").write_text(json.dumps(OPENROUTER_MODELS))
    curl = shim / "curl"
    curl.write_text(
        "#!/bin/sh\n"
        'case "$*" in\n'
        f'  *openrouter.ai/api/v1/models*) cat "{(tmp_path / "models.json").as_posix()}" ;;\n'
        "  *) printf 000; exit 7 ;;\n"
        "esac\n"
    )
    curl.chmod(curl.stat().st_mode | stat.S_IXUSR)

    cgroup = tmp_path / "cgroup" / f"docker-{container_id}.scope"
    cgroup.mkdir(parents=True)
    (cgroup / "memory.max").write_text(f"{memory_mib * 1048576}\n")
    (cgroup / "memory.peak").write_text(f"{416 * 1048576}\n")
    # cgroup v2 states a CPU ceiling as a quota over a period, both microseconds.
    (cgroup / "cpu.max").write_text(f"{cpu_quota} 100000\n")

    state = tmp_path / "state"
    state.mkdir()
    if config is not None:
        (state / "openclaw.json").write_text(json.dumps(config))
    for name in state_files:
        (state / name).parent.mkdir(parents=True, exist_ok=True)
        (state / name).write_text("")
    for name, target in (state_links or {}).items():
        (state / name).parent.mkdir(parents=True, exist_ok=True)
        (state / name).symlink_to(target)

    return subprocess.run(
        [bash, VERIFY.as_posix()],
        env={
            **os.environ,
            "PATH": f"{shim}{os.pathsep}{os.environ['PATH']}",
            "CT": container,
            "PORT": "18789",
            "STATE": state.as_posix(),
            "COMPOSE": compose.as_posix(),
            "CGROUP": (tmp_path / "cgroup").as_posix(),
            **({"STATE_OWNER": str(state_owner)} if state_owner is not None else {}),
        },
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize(
    ("container", "digest", "memory_mib", "cpu_quota", "cpus", "other"),
    [
        (
            "openclaw-gateway",
            GATEWAY_DIGEST,
            3072,
            250_000,
            "2.50",
            (DENISE_DIGEST, "1408MiB", "1.50"),
        ),
        (
            "openclaw-denise",
            DENISE_DIGEST,
            1408,
            150_000,
            "1.50",
            (GATEWAY_DIGEST, "3072MiB", "2.50"),
        ),
    ],
)
def test_the_compose_reads_are_scoped_to_the_gateway_being_checked(
    tmp_path: Path,
    container: str,
    digest: str,
    memory_mib: int,
    cpu_quota: int,
    cpus: str,
    other: tuple[str, str, str],
) -> None:
    """A correct gateway has to pass, and the sibling service's values must not leak."""
    result = run_verify(tmp_path, container, digest, memory_mib, cpu_quota)
    output = result.stdout

    for name, value in (
        ("image digest", digest),
        ("memory ceiling", f"{memory_mib}MiB"),
        ("cpu ceiling", cpus),
    ):
        assert f"PASS  {name:<32} {value}" in output, output
    for leaked in other:
        assert leaked not in output, output


SERVED = {
    "TCP": {"18789": {"HTTPS": True}},
    "Web": {"box.example.ts.net:18789": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:18789"}}}},
}


@pytest.mark.parametrize(
    ("serve", "expected"),
    [
        (
            SERVED,
            [
                "PASS  tailscale funnel                 off",
                "PASS  tailnet proxy                    http://127.0.0.1:18789",
            ],
        ),
        (
            {**SERVED, "AllowFunnel": {"box.example.ts.net:443": True}},
            ["FAIL  tailscale funnel                 expected off, got on"],
        ),
        (
            {
                **SERVED,
                "Foreground": {"a-session": {"AllowFunnel": {"box.example.ts.net:443": True}}},
            },
            ["FAIL  tailscale funnel                 expected off, got on"],
        ),
        (
            {},
            ["FAIL  tailnet proxy                    expected http://127.0.0.1:18789, got none"],
        ),
    ],
    ids=["served-on-the-tailnet", "any-funnel-fails", "foreground-funnel-fails", "not-served"],
)
def test_the_tailnet_checks_read_the_serve_config(
    tmp_path: Path, serve: dict[str, object], expected: list[str]
) -> None:
    """A funnel on any port fails, and the proxy is read under this box's own name."""
    result = run_verify(tmp_path, "openclaw-gateway", GATEWAY_DIGEST, 3072, 250_000, serve)

    for line in expected:
        assert line in result.stdout, result.stdout


def heartbeat_job(agent: str, *, is_enabled: bool) -> dict[str, object]:
    """One gateway-owned heartbeat monitor, shaped as `cron list --all --json` prints it."""
    return {
        "declarationKey": f"heartbeat:{agent}",
        "name": f"heartbeat-{agent}",
        "enabled": is_enabled,
        "schedule": {"kind": "every", "everyMs": 1_800_000},
        "sessionTarget": "main",
        "payload": {"kind": "heartbeat"},
    }


# A reminder the household set up, enabled and in the main session like the
# real ones, so a check that counted enabled jobs rather than enabled heartbeats
# would fail on it.
REMINDER = {
    "name": "a-reminder",
    "enabled": True,
    "schedule": {"kind": "at", "at": "2026-10-02T00:45:00.000Z"},
    "sessionTarget": "current",
    "payload": {"kind": "agentTurn"},
}


@pytest.mark.parametrize(
    ("jobs", "expected"),
    [
        (
            {"jobs": [heartbeat_job("main", is_enabled=False), REMINDER]},
            "PASS  recurring heartbeat              off",
        ),
        (
            {"jobs": [heartbeat_job("main", is_enabled=True), REMINDER]},
            "FAIL  recurring heartbeat              expected off, got on (1 enabled)",
        ),
        (
            {
                "jobs": [
                    heartbeat_job("main", is_enabled=False),
                    heartbeat_job("ops", is_enabled=True),
                ]
            },
            "FAIL  recurring heartbeat              expected off, got on (1 enabled)",
        ),
        (
            {"ok": False, "error": {"type": "cli_error", "message": "gateway closed"}},
            "FAIL  recurring heartbeat              expected off, got unreadable",
        ),
        (
            None,
            "FAIL  recurring heartbeat              expected off, got unreadable",
        ),
    ],
    ids=[
        "heartbeat-disabled",
        "heartbeat-enabled",
        "per-agent-heartbeat-enabled",
        "gateway-error",
        "gateway-silent",
    ],
)
def test_verify_fails_while_any_recurring_heartbeat_is_enabled(
    tmp_path: Path, jobs: dict[str, object] | None, expected: str
) -> None:
    """Only a scheduler with every heartbeat disabled passes; one it cannot read fails."""
    result = run_verify(tmp_path, "openclaw-gateway", GATEWAY_DIGEST, 3072, 250_000, jobs=jobs)

    assert expected in result.stdout, result.stdout


# What Corey's gateway printed until 9 October: requests was there, and what it
# imports was not.
HALF_INSTALLED = (
    "Traceback (most recent call last):\n"
    '  File "<string>", line 1, in <module>\n'
    "ModuleNotFoundError: No module named 'urllib3'\n"
)


@pytest.mark.parametrize(
    ("library_import", "expected"),
    [
        ("ok\n", f"PASS  {'calendar library':<32} ok"),
        (
            HALF_INSTALLED,
            f"FAIL  {'calendar library':<32} expected ok, got "
            "ModuleNotFoundError: No module named 'urllib3'",
        ),
        (None, f"FAIL  {'calendar library':<32} expected ok, got unreadable"),
    ],
    ids=["complete", "half-installed", "container-silent"],
)
def test_verify_fails_while_the_calendar_skill_cannot_import_its_library(
    tmp_path: Path, library_import: str | None, expected: str
) -> None:
    """The calendar skill dies on `import requests` unless all it pulls in is there too."""
    result = run_verify(
        tmp_path, "openclaw-gateway", GATEWAY_DIGEST, 3072, 250_000, library_import=library_import
    )

    assert expected in result.stdout, result.stdout


def family_group(**groups: object) -> dict[str, object]:
    """A named agent with the family-room plugin, whose Telegram channel has only the
    given group entries."""
    room = "household-family-room"
    return {
        "agents": {"entries": {"main": {"identity": {"name": "Denise"}}}},
        "channels": {"telegram": {"enabled": True, "groups": groups}},
        "tools": {"alsoAllow": ["family_history"]},
        "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
        "plugins": {
            "load": {"paths": [f"/opt/household-plugins/{room}"]},
            "entries": {
                room: {
                    "enabled": True,
                    "hooks": {"allowConversationAccess": True},
                    "config": {"groupChatId": "-5100000001"},
                }
            },
        },
    }


@pytest.mark.parametrize(
    ("container", "config", "expected"),
    [
        (
            "openclaw-denise",
            family_group(
                **{
                    "-5100000001": {
                        "requireMention": True,
                        "allowFrom": ["7100000001", "7100000002"],
                        "ingest": True,
                    }
                }
            ),
            "PASS  family group                     ok",
        ),
        (
            "openclaw-denise",
            family_group(),
            "FAIL  family group                     expected ok, got "
            "franco dropped (not-allowed); gia dropped (not-allowed)",
        ),
        (
            "openclaw-gateway",
            family_group(**{"*": {"requireMention": True}}),
            "FAIL  family group                     expected ok, got "
            "franco dropped (groupPolicy: allowlist, no group allowlist entries); "
            "gia dropped (groupPolicy: allowlist, no group allowlist entries)",
        ),
        (
            "openclaw-gateway",
            None,
            "FAIL  family group                     expected ok, got unreadable:",
        ),
    ],
    ids=["follows-the-policy", "group-not-allowed", "no-senders-allowed", "no-config"],
)
def test_verify_fails_while_the_household_cannot_reach_the_gateway_in_the_group(
    tmp_path: Path, container: str, config: dict[str, object] | None, expected: str
) -> None:
    """A gateway that drops the family group fails verification, whatever else passes."""
    result = run_verify(tmp_path, container, GATEWAY_DIGEST, 3072, 250_000, config=config)

    assert expected in result.stdout, result.stdout


@pytest.mark.parametrize("telegram_enabled", [False, True])
def test_migrated_gateway_checks_the_app_and_requires_telegram_off(
    tmp_path: Path, telegram_enabled: bool
) -> None:
    from tests.test_openclaw_household_app import as_on_the_box, load

    app = load(ROOT / "scripts" / "openclaw-household-app.py", "verify_household_app")
    original = as_on_the_box()
    config = app.patched(
        original,
        app.household_patch(
            original,
            app.GATEWAYS[0],
            app.GATEWAYS[1],
            owner_keys=[],
            peer_keys=[],
            peer_identity={},
        ),
    )
    config["channels"]["telegram"]["enabled"] = telegram_enabled
    result = run_verify(tmp_path, "openclaw-gateway", GATEWAY_DIGEST, 3072, 250_000, config=config)
    label = "household app"
    expected = (
        f"FAIL  {label:<32} expected ok, got" if telegram_enabled else f"PASS  {label:<32} ok"
    )
    assert expected in result.stdout, result.stdout
    assert "family group                     " not in result.stdout


OPENROUTER_ROUTES: dict[str, object] = {
    "agents": {
        "defaults": {
            "model": {
                "primary": "openrouter/z-ai/glm-5.3-flash",
                "fallbacks": [
                    "openrouter/z-ai/glm-5.3",
                    "openrouter/deepseek/deepseek-v4-flash-0731",
                ],
            },
            "imageModel": {
                "primary": "openrouter/openai/gpt-5.4-image-2",
                "fallbacks": ["openrouter/google/gemini-2.5-flash"],
            },
            "utilityModel": "openrouter/deepseek/deepseek-v4-flash-0731",
            "mediaModels": {
                "image": {"primary": "openrouter/openai/gpt-5.4-image-2"},
                "video": {"primary": "openrouter/google/veo-3.1-fast"},
                "music": {"primary": "openrouter/google/lyria-3-pro-preview"},
            },
        }
    },
    "tts": {"provider": "openrouter", "providers": {"microsoft": {"enabled": False}}},
    "memory": {
        "search": {
            "provider": "openai-compatible",
            "model": "openai/text-embedding-3-small",
            "remote": {"baseUrl": "https://openrouter.ai/api/v1"},
        }
    },
    "tools": {
        "media": {
            "models": [
                {
                    "provider": "openrouter",
                    "model": "openai/whisper-large-v3-turbo",
                    "capabilities": ["audio"],
                },
                {
                    "provider": "openrouter-video",
                    "model": "google/gemini-2.5-flash",
                    "capabilities": ["video"],
                },
            ],
            "audio": {"enabled": True},
        },
    },
    "plugins": {
        "load": {"paths": ["/opt/household-plugins/household-openrouter-video"]},
        "entries": {
            "household-openrouter-video": {"enabled": True},
            "memory-core": {
                "subagent": {
                    "allowModelOverride": True,
                    "allowedModels": ["openrouter/deepseek/deepseek-v4-flash-0731"],
                },
                "config": {"dreaming": {"model": "openrouter/deepseek/deepseek-v4-flash-0731"}},
            },
        },
    },
}


@pytest.mark.parametrize(
    ("config", "expected"),
    [
        (OPENROUTER_ROUTES, "PASS  openrouter only                  ok"),
        (
            {
                **OPENROUTER_ROUTES,
                "agents": {
                    "defaults": {
                        **OPENROUTER_ROUTES["agents"]["defaults"],  # type: ignore[index]
                        "model": {
                            "primary": "openrouter/z-ai/glm-5.3-flash",
                            "fallbacks": [
                                "openrouter/z-ai/glm-5.3",
                                "openrouter/deepseek/deepseek-v4-flash-0731:free",
                            ],
                        },
                    }
                },
            },
            "FAIL  openrouter only                  expected ok, got "
            "openrouter/deepseek/deepseek-v4-flash-0731:free in the chat chain is not on "
            "OpenRouter's model list",
        ),
        (
            {
                **OPENROUTER_ROUTES,
                "plugins": {
                    "load": {"paths": ["/opt/household-plugins/household-openrouter-video"]},
                    "entries": {"household-openrouter-video": {"enabled": True}},
                },
            },
            "FAIL  openrouter only                  expected ok, got "
            "the dream diary's narrative runs on the chat primary",
        ),
        (
            {
                **OPENROUTER_ROUTES,
                "agents": {
                    "defaults": {
                        **OPENROUTER_ROUTES["agents"]["defaults"],  # type: ignore[index]
                        "utilityModel": "openrouter/z-ai/glm-5.3-flash",
                    }
                },
            },
            "FAIL  openrouter only                  expected ok, got "
            "session titles and other short internal tasks run on openrouter/z-ai/glm-5.3-flash",
        ),
        (
            {**OPENROUTER_ROUTES, "memory": {}},
            "FAIL  openrouter only                  expected ok, got "
            "memory search embeds with OpenAI, the default with no provider set",
        ),
        (
            {**OPENROUTER_ROUTES, "tts": {"provider": "openrouter"}},
            "FAIL  openrouter only                  expected ok, got "
            "speech can fall back to microsoft",
        ),
    ],
    ids=[
        "all-openrouter",
        "fallback-off-openrouter-s-list",
        "dream-diary-on-the-primary",
        "titles-on-the-primary",
        "memory-on-openai",
        "speech-fallback-enabled",
    ],
)
def test_verify_fails_while_anything_still_routes_to_openai(
    tmp_path: Path, config: dict[str, object], expected: str
) -> None:
    """The openrouter.py verdict is read from the same state directory as the rest."""
    result = run_verify(tmp_path, "openclaw-gateway", GATEWAY_DIGEST, 3072, 250_000, config=config)

    assert expected in result.stdout, result.stdout


SPEAK_TOOLS = {
    "profile": "coding",
    "alsoAllow": ["speak"],
    "deny": ["codex", "memory-wiki", "onepassword"],
}
SPOKEN_REPLIES: dict[str, object] = {
    "tools": SPEAK_TOOLS,
    "session": {"dmScope": "per-channel-peer", "groupScope": "per-group"},
    "tts": {"auto": "off", "provider": "openrouter"},
    "plugins": {
        "load": {"paths": ["/opt/household-plugins/household-speech"]},
        "entries": {
            "household-speech": {
                "enabled": True,
                "hooks": {"allowConversationAccess": True},
                "config": {"replyCharacters": 8000, "dayCharacters": 25000},
            },
            "telegram": {"enabled": True},
        },
    },
}


@pytest.mark.parametrize(
    ("config", "expected"),
    [
        (SPOKEN_REPLIES, "PASS  spoken replies                   ok"),
        (
            {**SPOKEN_REPLIES, "tools": {**SPEAK_TOOLS, "alsoAllow": ["speak", "tts"]}},
            "FAIL  spoken replies                   expected ok, got "
            "the assistant is still handed OpenClaw's own tts tool, which no ceiling covers",
        ),
        (
            {**SPOKEN_REPLIES, "tts": {"auto": "always", "provider": "openrouter"}},
            "FAIL  spoken replies                   expected ok, got "
            "tts.auto is always, so replies are spoken unasked and no ceiling covers them",
        ),
        (
            None,
            "FAIL  spoken replies                   expected ok, got unreadable:",
        ),
    ],
    ids=["through-the-plugin", "built-in-tool-still-offered", "spoken-unasked", "no-config"],
)
def test_verify_fails_while_a_spoken_reply_can_go_around_the_speech_plugin(
    tmp_path: Path, config: dict[str, object] | None, expected: str
) -> None:
    """The speech.py verdict is read from the same state directory as the rest."""
    result = run_verify(tmp_path, "openclaw-denise", DENISE_DIGEST, 1408, 150_000, config=config)

    assert expected in result.stdout, result.stdout


STATE_FILES = (
    "workspace/USER.md",
    "workspace/USER.md.bak",
    "pocketpiggies/broker.sock",
    "home/home.sock",
)
CHECK = "state the backup can read"


def check_line(output: str) -> str:
    return next((text for text in output.splitlines() if CHECK in text), "")


@needs_getuid
def test_state_that_belongs_to_the_gateway_passes(tmp_path: Path) -> None:
    result = run_verify(
        tmp_path,
        "openclaw-gateway",
        GATEWAY_DIGEST,
        3072,
        250_000,
        state_owner=os.getuid(),
        state_files=STATE_FILES,
        state_links={"plugin-skills/canvas": "/app/dist/extensions/canvas/skills/canvas"},
    )
    assert f"PASS  {CHECK:<32} none" in result.stdout, result.stdout


@needs_getuid
def test_a_file_the_gateway_does_not_own_is_named(tmp_path: Path) -> None:
    """On 14 October root-owned USER.md.bak files in Corey's workspace made
    `openclaw backup create`, which runs as the gateway's user, refuse his whole state.
    The PocketPiggies and home socket directories belong to their key holders on purpose."""
    result = run_verify(
        tmp_path,
        "openclaw-gateway",
        GATEWAY_DIGEST,
        3072,
        250_000,
        state_owner=os.getuid() + 1,
        state_files=STATE_FILES,
    )
    line = check_line(result.stdout)
    assert line.startswith("FAIL"), result.stdout
    assert "workspace/USER.md.bak" in line
    assert "pocketpiggies" not in line
    assert "home/home.sock" not in line
    assert result.returncode != 0


@needs_getuid
def test_an_absolute_link_the_backup_would_archive_is_named(tmp_path: Path) -> None:
    """Then an empty virtualenv in the same workspace, whose python3 pointed at
    /usr/bin/python3: the archive refuses an absolute link. Links under the
    directories `backup create` skips as regenerable are left out."""
    result = run_verify(
        tmp_path,
        "openclaw-gateway",
        GATEWAY_DIGEST,
        3072,
        250_000,
        state_owner=os.getuid(),
        state_files=STATE_FILES,
        state_links={
            "workspace/.venv/bin/python3": "/usr/bin/python3",
            "plugin-skills/canvas": "/app/dist/extensions/canvas/skills/canvas",
            "agents/main/agent/codex-home/tmp/arg0/x/codex": "/app/node_modules/codex",
        },
    )
    line = check_line(result.stdout)
    assert line.startswith("FAIL"), result.stdout
    assert "workspace/.venv/bin/python3" in line
    assert "plugin-skills" not in line
    assert "codex-home" not in line
