"""The household's own OpenClaw plugins, tested by node.

The plugins are JavaScript because the gateway loads them in process. Their tests are
in tests/js and use node's built-in runner, so they need nothing installed. CI's runners
carry node, and these skip rather than fail on a machine without it.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PLUGINS = ROOT / "deploy" / "openclaw" / "plugins"
TESTS = ROOT / "tests" / "js"


def node_or_skip() -> str:
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is not installed")
    return node


@pytest.mark.filterwarnings("error::pytest.PytestUnhandledThreadExceptionWarning")
@pytest.mark.parametrize(
    "tests",
    [
        "household_app_amazon_mail.test.mjs",
        "household_app_apple.test.mjs",
        "household_app_approvals.test.mjs",
        "household_app_automations.test.mjs",
        "household_app_brief.test.mjs",
        "household_app_call_setup.test.mjs",
        "household_app_call_turn.test.mjs",
        "household_app_cards.test.mjs",
        "household_app_cart.test.mjs",
        "household_app_claims.test.mjs",
        "household_app_connect.test.mjs",
        "household_app_connectors.test.mjs",
        "household_app_did.test.mjs",
        "household_app_emergency.test.mjs",
        "household_app_digest.test.mjs",
        "household_app_family_history.test.mjs",
        "household_app_family_parity.test.mjs",
        "household_app_family_posts.test.mjs",
        "household_app_family_tools.test.mjs",
        "household_app_google_connect.test.mjs",
        "household_app_google_token.test.mjs",
        "household_app_handovers.test.mjs",
        "household_app_home.test.mjs",
        "household_app_location.test.mjs",
        "household_app_maps.test.mjs",
        "household_app_meals.test.mjs",
        "household_app_media.test.mjs",
        "household_app_order_mail.test.mjs",
        "household_app_mentions.test.mjs",
        "household_app_microsoft_connect.test.mjs",
        "household_app_models.test.mjs",
        "household_app_note_turns.test.mjs",
        "household_app_notes.test.mjs",
        "household_app_notion_connect.test.mjs",
        "household_app_pair.test.mjs",
        "household_app_pairing.test.mjs",
        "household_app_peer_link.test.mjs",
        "household_app_phone_metrics.test.mjs",
        "household_app_phones.test.mjs",
        "household_app_photos.test.mjs",
        "household_app_push.test.mjs",
        "household_app_reply_media.test.mjs",
        "household_app_room.test.mjs",
        "household_app_send.test.mjs",
        "household_app_settings.test.mjs",
        "household_app_signature.test.mjs",
        "household_app_speak.test.mjs",
        "household_app_speech_guard.test.mjs",
        "household_app_spend.test.mjs",
        "household_app_spend_in.test.mjs",
        "household_app_store.test.mjs",
        "household_app_tapbacks.test.mjs",
        "household_app_today.test.mjs",
        "household_app_turns.test.mjs",
        "household_app_vault.test.mjs",
        "household_app_voice_notes.test.mjs",
        "household_app_wishes.test.mjs",
        "household_app_video.test.mjs",
        "household_app_vision.test.mjs",
        "household_memory.test.mjs",
        "household_openrouter_video.test.mjs",
        "household_pictures.test.mjs",
        "household_scripture.test.mjs",
        "steward_cards_skill.test.mjs",
    ],
)
def test_each_plugin_passes_its_own_tests(tests: str) -> None:
    completed = subprocess.run(
        [node_or_skip(), "--test", str(TESTS / tests)],
        cwd=ROOT,
        capture_output=True,
        encoding="utf-8",
        timeout=120,
        check=False,
    )
    assert completed.returncode == 0, completed.stdout[-4000:] + completed.stderr[-2000:]


@pytest.mark.parametrize(
    "plugin",
    [
        "household-openrouter-video",
        "household-pictures",
        "household-scripture",
    ],
)
def test_the_extension_each_package_declares_is_its_manifest_plugin(plugin: str) -> None:
    """OpenClaw finds a plugin by the manifest's id and loads the package's extension."""
    node = node_or_skip()
    manifest = json.loads((PLUGINS / plugin / "openclaw.plugin.json").read_text(encoding="utf-8"))
    package = json.loads((PLUGINS / plugin / "package.json").read_text(encoding="utf-8"))

    assert manifest["id"] == plugin
    assert package["type"] == "module"
    extensions = package["openclaw"]["extensions"]
    assert extensions
    for extension in extensions:
        loaded = subprocess.run(
            [
                node,
                "--input-type=module",
                "--eval",
                "const entry = await import(process.argv[1]); console.log(entry.default.id);",
                (PLUGINS / plugin / extension).resolve().as_uri(),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        assert loaded.returncode == 0, loaded.stderr[-2000:]
        assert loaded.stdout.strip() == manifest["id"]


def test_each_manifest_declares_what_its_config_and_providers_are() -> None:
    """What 2026.9.4 reads from a manifest without running the plugin."""
    video = json.loads(
        (PLUGINS / "household-openrouter-video" / "openclaw.plugin.json").read_text(
            encoding="utf-8"
        )
    )

    # OpenClaw only routes tools.media.models to a provider a manifest owns.
    assert video["contracts"]["mediaUnderstandingProviders"] == ["openrouter-video"]
    assert video["configSchema"]["properties"] == {}
    pictures = json.loads(
        (PLUGINS / "household-pictures" / "openclaw.plugin.json").read_text(encoding="utf-8")
    )
    assert pictures["contracts"]["tools"] == ["picture", "video"]
    assert pictures["configSchema"]["required"] == ["pictureDayDollars", "videoDayDollars"]
    assert set(pictures["configSchema"]["properties"]) == {"pictureDayDollars", "videoDayDollars"}
