"""The release and preview scripts in scripts/macos, asserted by running them.

The documented pre-upload line is `deploy-testflight.sh --dry-run`, and a dry
run sends nothing: every `ha_run` is a print, so the whole script can be run
from anywhere given a `uname` that reports Darwin, an `xcodebuild` on PATH that
is never invoked, and the files it checks for. That is what these set up, and
they assert the outcome rather than the absence of one refusal message. The
archive and the preview are driven the same way.

What is not exercised here: a real archive, export or upload, and whether
xcodebuild accepts these arguments. The release workflow's rehearsal runs the
archive on a GitHub Mac; the signed export and the upload wait for the first
real release.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from collections.abc import Iterator
from pathlib import Path

import pytest

from tests.capabilities import needs_posix_bash

pytestmark = needs_posix_bash

ROOT = Path(__file__).resolve().parent.parent
DEPLOY = ROOT / "scripts" / "macos" / "deploy-testflight.sh"
BUILD = ROOT / "scripts" / "macos" / "build-ios.sh"
TEST = ROOT / "scripts" / "macos" / "test-ios.sh"
MOTION_DEMO = "HouseholdAssistantUITests/MotionDemoTests/testMotionDemo"
ARCHIVE = ROOT / "apps" / "ios" / "build" / "HouseholdAssistant.xcarchive"
CONFIRM_REFUSAL = "refusing to upload without --confirm"
TEAM_ID = "PLACEHOLDERTEAMID"
APP_PROFILE = "Steward AI HouseholdAssistant App Store"
WIDGET_PROFILE = "Steward AI HouseholdAssistantWidgets App Store"
# The household values a signed archive needs, made up, and not the placeholders
# apps/ios/Household.xcconfig holds.
HOUSEHOLD = {
    "HOUSEHOLD_GATEWAY_HOST": "household.tail0000.ts.net",
    "GOOGLE_IOS_CLIENT_ID": "999999999999-zyxwvutsrqponmlkjihgfedcba987654",
}


@pytest.fixture
def archive() -> Iterator[None]:
    """The archive build-ios.sh leaves behind, which this script refuses to run without."""
    if ARCHIVE.exists():
        yield
        return
    ARCHIVE.mkdir(parents=True)
    yield
    shutil.rmtree(ARCHIVE)


def run_deploy(tmp_path: Path, *args: str, event: str = "") -> subprocess.CompletedProcess[str]:
    """Run deploy-testflight.sh on any machine, with everything it checks for in place."""
    bash = shutil.which("bash")
    assert bash is not None, "the macOS scripts are bash, and CI has to have it"
    shim = tmp_path / "bin"
    shim.mkdir()
    for name, body in (
        ("uname", "echo Darwin\n"),
        ("xcodebuild", 'echo "xcodebuild must not run in a dry run" >&2\nexit 99\n'),
    ):
        command = shim / name
        command.write_text(f"#!/bin/sh\n{body}")
        command.chmod(command.stat().st_mode | stat.S_IXUSR)
    key = tmp_path / "AuthKey.p8"
    key.write_text("not a key\n")
    return subprocess.run(
        [bash, DEPLOY.as_posix(), *args],
        env={
            **os.environ,
            "PATH": f"{shim}{os.pathsep}{os.environ['PATH']}",
            "GITHUB_EVENT_NAME": event,
            "DEVELOPMENT_TEAM": TEAM_ID,
            "HA_APP_PROFILE": APP_PROFILE,
            "HA_WIDGET_PROFILE": WIDGET_PROFILE,
            "APP_STORE_CONNECT_KEY_ID": "PLACEHOLDERKEYID",
            "APP_STORE_CONNECT_ISSUER_ID": "PLACEHOLDERISSUERID",
            "APP_STORE_CONNECT_KEY_PATH": key.as_posix(),
        },
        capture_output=True,
        text=True,
        check=False,
    )


def test_the_documented_dry_run_completes_and_sends_nothing(tmp_path: Path, archive: None) -> None:
    """docs/testflight.md documents a bare --dry-run as the step before the upload.

    It has to run to the end, show the export options with the team id removed,
    invoke nothing, and say plainly that nothing reached Apple. A dry run that
    reports an upload is worse than one that refuses to start.
    """
    result = run_deploy(tmp_path, "--dry-run")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "would run  xcodebuild -exportArchive" in result.stderr
    assert "<string>REDACTED</string>" in result.stderr
    assert TEAM_ID not in result.stderr
    assert "dry run complete" in result.stderr
    assert "uploaded." not in result.stderr


def test_an_upload_is_refused_without_confirm(tmp_path: Path, archive: None) -> None:
    """The guard that matters is untouched: nothing reaches Apple by accident."""
    result = run_deploy(tmp_path)
    assert result.returncode != 0
    assert CONFIRM_REFUSAL in result.stderr


def test_a_pull_request_event_is_refused_even_for_a_dry_run(tmp_path: Path, archive: None) -> None:
    """A change proposed on a branch has no business reaching this script at all."""
    result = run_deploy(tmp_path, "--dry-run", "--confirm", event="pull_request")
    assert result.returncode != 0
    assert "refusing to upload from a pull_request event" in result.stderr


def test_the_export_signs_each_bundle_with_its_own_profile(tmp_path: Path, archive: None) -> None:
    """A hosted Mac keeps no signing identity, so the export names exactly what to use."""
    result = run_deploy(tmp_path, "--dry-run")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "<string>manual</string>" in result.stderr
    assert "<string>Apple Distribution</string>" in result.stderr
    assert f"<key>com.siqstack.stewardai</key>\n    <string>{APP_PROFILE}</string>" in result.stderr
    assert (
        f"<key>com.siqstack.stewardai.widgets</key>\n    <string>{WIDGET_PROFILE}</string>"
        in result.stderr
    )


def run_mac_script(
    tmp_path: Path,
    script: Path,
    *args: str,
    env: dict[str, str] | None = None,
    shims: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a build or test script anywhere, with the Apple tools it checks for as shims."""
    bash = shutil.which("bash")
    assert bash is not None
    shim = tmp_path / "bin"
    shim.mkdir()
    simulator = "    iPhone 17 (0A1B2C3D-0000-4000-8000-000000000001) (Shutdown)"
    bodies = {
        "uname": "echo Darwin\n",
        "xcodegen": 'echo "xcodegen must not run in a dry run" >&2\nexit 99\n',
        "xcodebuild": 'echo "xcodebuild must not run in a dry run" >&2\nexit 99\n',
        "xcrun": f"echo '{simulator}'\n",
        **(shims or {}),
    }
    for name, body in bodies.items():
        command = shim / name
        command.write_text(f"#!/bin/sh\n{body}")
        command.chmod(command.stat().st_mode | stat.S_IXUSR)
    keep = {key: value for key, value in os.environ.items() if not key.startswith("HA_")}
    for name in ("DEVELOPMENT_TEAM", "HA_APP_PROFILE", "HA_WIDGET_PROFILE"):
        keep.pop(name, None)
    return subprocess.run(
        [bash, script.as_posix(), *args],
        env={**keep, "PATH": f"{shim}{os.pathsep}{os.environ['PATH']}", **(env or {})},
        capture_output=True,
        text=True,
        check=False,
    )


def test_an_archive_without_its_profiles_is_refused(tmp_path: Path) -> None:
    result = run_mac_script(tmp_path, BUILD, "--dry-run", env={"DEVELOPMENT_TEAM": TEAM_ID})

    assert result.returncode != 0
    assert "HA_APP_PROFILE is not set" in result.stderr


def test_a_signed_archive_is_refused_without_the_household_values(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path,
        BUILD,
        "--dry-run",
        env={
            "DEVELOPMENT_TEAM": TEAM_ID,
            "HA_APP_PROFILE": APP_PROFILE,
            "HA_WIDGET_PROFILE": WIDGET_PROFILE,
        },
    )

    assert result.returncode != 0
    assert "HOUSEHOLD_GATEWAY_HOST is not set" in result.stderr


@pytest.mark.parametrize(
    "placeholder",
    [
        {"HOUSEHOLD_GATEWAY_HOST": "household.example.ts.net"},
        {"GOOGLE_IOS_CLIENT_ID": "123456789012-abcdefghijklmnopqrstuvwxyz012345"},
    ],
)
def test_a_signed_archive_is_refused_with_a_placeholder(
    tmp_path: Path, placeholder: dict[str, str]
) -> None:
    env = {
        "DEVELOPMENT_TEAM": TEAM_ID,
        "HA_APP_PROFILE": APP_PROFILE,
        "HA_WIDGET_PROFILE": WIDGET_PROFILE,
    }
    result = run_mac_script(tmp_path, BUILD, "--dry-run", env={**env, **HOUSEHOLD, **placeholder})

    assert result.returncode != 0
    assert "still the placeholder" in result.stderr


def test_a_signed_archive_keys_each_profile_to_its_target(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path,
        BUILD,
        "--dry-run",
        env={
            "DEVELOPMENT_TEAM": TEAM_ID,
            "HA_APP_PROFILE": APP_PROFILE,
            "HA_WIDGET_PROFILE": WIDGET_PROFILE,
            "HA_BUILD_NUMBER": "42",
            **HOUSEHOLD,
        },
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "would run  xcodebuild archive" in result.stderr
    assert "-xcconfig" in result.stderr
    assert "DEVELOPMENT_TEAM=<redacted>" in result.stderr
    assert TEAM_ID not in result.stderr
    assert "CURRENT_PROJECT_VERSION=42" in result.stderr
    assert "CODE_SIGNING_ALLOWED=NO" not in result.stderr


def test_a_rehearsal_needs_no_signing_values_and_archives_unsigned(tmp_path: Path) -> None:
    result = run_mac_script(tmp_path, BUILD, "--rehearse", "--dry-run")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "would run  xcodebuild -showBuildSettings" in result.stderr
    archive_line = next(
        line for line in result.stderr.splitlines() if "would run  xcodebuild archive" in line
    )
    assert "CODE_SIGNING_ALLOWED=NO" in archive_line


def test_the_build_for_testing_compiles_on_past_the_first_error(tmp_path: Path) -> None:
    result = run_mac_script(tmp_path, TEST, "--dry-run")

    assert result.returncode == 0, result.stdout + result.stderr
    build = next(
        line for line in result.stderr.splitlines()
        if "would run  xcodebuild build-for-testing" in line
    )  # fmt: skip
    assert "-IDEBuildingContinueBuildingAfterErrors=YES" in build


def test_the_preview_records_the_simulator_it_tests_on(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path, TEST, "--dry-run", env={"HA_IOS_RECORDING": "build/preview/recording.mp4"}
    )

    assert result.returncode == 0, result.stdout + result.stderr
    udid = "0A1B2C3D-0000-4000-8000-000000000001"
    assert f"platform=iOS Simulator,id={udid}" in result.stderr
    # The recording films the motion demo after the tests, not minutes of building.
    steps = [line for line in result.stderr.splitlines() if line.startswith("would run  xc")]
    order = [
        "xcodebuild build-for-testing",
        "-only-testing:HouseholdAssistantTests",
        "-only-testing:HouseholdAssistantUITests",
        f"xcrun simctl boot {udid}",
        f"xcrun simctl privacy {udid} grant microphone com.siqstack.stewardai",
        f"xcrun simctl io {udid} recordVideo",
        f"-only-testing:{MOTION_DEMO}",
    ]
    positions = [next(i for i, step in enumerate(steps) if part in step) for part in order]
    assert positions == sorted(positions), steps


def test_a_failed_test_step_still_runs_every_step_after_it(tmp_path: Path) -> None:
    # Arrange: xcodebuild whose unit tests fail, writing down each call.
    calls = tmp_path / "xcodebuild-calls"
    xcodebuild = (
        f'echo "$*" >> "{calls.as_posix()}"\n'
        'case "$*" in *"-only-testing:HouseholdAssistantTests "*) exit 65 ;; esac\n'
    )
    recording = tmp_path / "preview" / "recording.mp4"

    # Act: a real run, not a dry run, against the shims.
    result = run_mac_script(
        tmp_path,
        TEST,
        env={"HA_IOS_RECORDING": recording.as_posix()},
        shims={"xcodegen": "exit 0\n", "xcodebuild": xcodebuild},
    )

    # Assert: the UI tests and both takes still ran, and the run still fails, naming why.
    assert result.returncode != 0
    ran = calls.read_text(encoding="utf-8").splitlines()
    steps = ["build-for-testing", "HouseholdAssistantTests ", "HouseholdAssistantUITests "]
    assert [any(step in call for call in ran) for step in steps] == [True, True, True], ran
    assert sum(f"-only-testing:{MOTION_DEMO}" in call for call in ran) == 2, ran
    assert "unit tests" in result.stderr.splitlines()[-1]


@pytest.mark.parametrize("is_filmed", [True, False])
def test_the_motion_demo_runs_once_with_the_ui_tests_or_under_the_recorder(
    tmp_path: Path, is_filmed: bool
) -> None:
    env = {"HA_IOS_RECORDING": "build/preview/recording.mp4"} if is_filmed else {}

    result = run_mac_script(tmp_path, TEST, "--dry-run", env=env)

    assert result.returncode == 0, result.stdout + result.stderr
    ui_tests = next(
        line for line in result.stderr.splitlines()
        if "-only-testing:HouseholdAssistantUITests " in line
    )  # fmt: skip
    assert (f"-skip-testing:{MOTION_DEMO}" in ui_tests) == is_filmed
    assert (f"-only-testing:{MOTION_DEMO}" in result.stderr) == is_filmed


def test_each_take_keeps_its_own_result_bundle(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path, TEST, "--dry-run", env={"HA_IOS_RECORDING": "build/preview/recording.mp4"}
    )

    assert result.returncode == 0, result.stdout + result.stderr
    takes = [
        line for line in result.stderr.splitlines()
        if line.startswith("would run  xcodebuild") and f"-only-testing:{MOTION_DEMO}" in line
    ]  # fmt: skip
    bundles = [line.split("-resultBundlePath ")[1].split()[0] for line in takes]
    assert [bundle.rsplit("/", 1)[1] for bundle in bundles] == [
        "recording-results.xcresult",
        "recording-reduce-motion-results.xcresult",
    ]
    assert all(bundle.endswith("/apps/ios/build/" + bundle.rsplit("/", 1)[1]) for bundle in bundles)


def test_the_preview_films_the_demo_then_again_with_reduce_motion(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path, TEST, "--dry-run", env={"HA_IOS_RECORDING": "build/preview/recording.mp4"}
    )

    assert result.returncode == 0, result.stdout + result.stderr
    udid = "0A1B2C3D-0000-4000-8000-000000000001"
    steps = [line for line in result.stderr.splitlines() if line.startswith("would run  xc")]
    reduce_motion = (
        f"xcrun simctl spawn {udid} defaults write com.apple.Accessibility ReduceMotionEnabled"
    )
    record = f"xcrun simctl io {udid} recordVideo --codec=h264 --force build/preview/recording"
    order = [
        f"xcrun simctl privacy {udid} grant microphone com.siqstack.stewardai",
        f"{record}.mp4",
        f"-only-testing:{MOTION_DEMO}",
        f"{reduce_motion} -bool YES",
        f"xcrun simctl shutdown {udid}",
        f"xcrun simctl boot {udid}",
        f"{record}-reduce-motion.mp4",
        f"-only-testing:{MOTION_DEMO}",
        f"{reduce_motion} -bool NO",
    ]
    start = 0
    for part in order:
        found = next((i for i, step in enumerate(steps) if i >= start and part in step), None)
        assert found is not None, (part, steps[start:])
        start = found + 1


def dry_run_commands(result: subprocess.CompletedProcess[str]) -> list[str]:
    return [line for line in result.stderr.splitlines() if line.startswith("would run  xc")]


@pytest.mark.parametrize(
    ("step", "present", "absent"),
    [
        ("build", ["xcodegen generate", "xcodebuild build-for-testing"],
         ["test-without-building"]),
        ("unit", ["-only-testing:HouseholdAssistantTests "
                  "-skip-testing:HouseholdAssistantTests/ScreenshotTests"],
         ["xcodegen", "build-for-testing", "HouseholdAssistantUITests", "recordVideo"]),
        ("screenshots", ["-only-testing:HouseholdAssistantTests/ScreenshotTests"],
         ["xcodegen", "build-for-testing", "HouseholdAssistantUITests", "recordVideo"]),
    ],
)  # fmt: skip
def test_a_named_step_runs_alone(
    tmp_path: Path, step: str, present: list[str], absent: list[str]
) -> None:
    result = run_mac_script(tmp_path, TEST, "--dry-run", step)

    assert result.returncode == 0, result.stdout + result.stderr
    commands = "\n".join(dry_run_commands(result))
    assert all(part in commands for part in present), commands
    assert not any(part in commands for part in absent), commands


def test_the_ui_step_runs_only_the_ui_tests_it_is_given(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path,
        TEST,
        "--dry-run",
        "ui",
        env={"HA_IOS_UI_TESTS": "ScrollHitchTests TapHitchTests/testTapLands"},
    )

    assert result.returncode == 0, result.stdout + result.stderr
    [ui_tests] = dry_run_commands(result)
    assert "-only-testing:HouseholdAssistantUITests/ScrollHitchTests " in ui_tests
    assert "-only-testing:HouseholdAssistantUITests/TapHitchTests/testTapLands " in ui_tests
    assert "-only-testing:HouseholdAssistantUITests " not in ui_tests


def test_the_whole_ui_step_leaves_the_chat_timings_out(tmp_path: Path) -> None:
    result = run_mac_script(tmp_path, TEST, "--dry-run", "ui")

    assert result.returncode == 0, result.stdout + result.stderr
    [ui_tests] = dry_run_commands(result)
    assert "-only-testing:HouseholdAssistantUITests " in ui_tests
    assert "-skip-testing:HouseholdAssistantUITests/ChatSpeedTests " in ui_tests
    assert "-skip-testing:HouseholdAssistantUITests/ThousandsChatSpeedTests " in ui_tests


@pytest.mark.parametrize(
    ("named", "said"),
    [
        ("call. room.direct.call-row", "screenshots  call. room.direct.call-row"),
        ("all", None),
        (None, None),
    ],
)
def test_the_screenshots_step_says_which_states_it_renders(
    tmp_path: Path, named: str | None, said: str | None
) -> None:
    env = {"HA_IOS_SCREENSHOTS": named} if named else {}

    result = run_mac_script(tmp_path, TEST, "--dry-run", "screenshots", env=env)

    assert result.returncode == 0, result.stdout + result.stderr
    lines = [line for line in result.stderr.splitlines() if line.startswith("screenshots  ")]
    assert lines == ([said] if said else [])


def test_the_films_step_is_refused_without_a_path_for_the_film(tmp_path: Path) -> None:
    result = run_mac_script(tmp_path, TEST, "--dry-run", "films")

    assert result.returncode != 0
    assert "the films step needs HA_IOS_RECORDING" in result.stderr


def test_every_step_shares_one_build_without_coverage_or_index(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path, TEST, "--dry-run", env={"HA_IOS_RECORDING": "build/preview/recording.mp4"}
    )

    assert result.returncode == 0, result.stdout + result.stderr
    builds = [line for line in dry_run_commands(result) if "would run  xcodebuild" in line]
    assert len(builds) == 6, builds
    for line in builds:
        assert line.count("-derivedDataPath ") == 1
        assert "/apps/ios/build/DerivedData " in line
        assert "-enableCodeCoverage NO" in line
        assert "COMPILER_INDEX_STORE_ENABLE=NO" in line


def test_a_recording_cannot_follow_a_simulator_it_did_not_pick(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path,
        TEST,
        "--dry-run",
        env={
            "HA_IOS_RECORDING": "build/preview/recording.mp4",
            "HA_IOS_DESTINATION": "platform=iOS Simulator,name=iPhone 17",
        },
    )

    assert result.returncode != 0
    assert "HA_IOS_RECORDING needs this script to pick the simulator" in result.stderr


@pytest.mark.parametrize("is_set", [True, False])
def test_the_export_names_the_notification_extension_only_when_it_is_signed(
    tmp_path: Path, archive: None, monkeypatch: pytest.MonkeyPatch, is_set: bool
) -> None:
    if is_set:
        monkeypatch.setenv("HA_NOTIFICATIONS_PROFILE", "Steward AI notifications App Store")
    else:
        monkeypatch.delenv("HA_NOTIFICATIONS_PROFILE", raising=False)

    result = run_deploy(tmp_path, "--dry-run")

    assert result.returncode == 0, result.stdout + result.stderr
    named = "<key>com.siqstack.stewardai.notifications</key>" in result.stderr
    assert named is is_set
    if is_set:
        assert "<string>Steward AI notifications App Store</string>" in result.stderr


def test_a_signed_archive_names_the_notification_extension_profile(tmp_path: Path) -> None:
    result = run_mac_script(
        tmp_path,
        BUILD,
        "--dry-run",
        env={
            "DEVELOPMENT_TEAM": TEAM_ID,
            "HA_APP_PROFILE": APP_PROFILE,
            "HA_WIDGET_PROFILE": WIDGET_PROFILE,
            "HA_NOTIFICATIONS_PROFILE": "Steward AI notifications App Store",
            **HOUSEHOLD,
        },
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "/ Steward AI notifications App Store" in result.stderr


@pytest.mark.parametrize("is_set", [True, False])
def test_the_export_names_the_share_extension_only_when_it_is_signed(
    tmp_path: Path, archive: None, monkeypatch: pytest.MonkeyPatch, is_set: bool
) -> None:
    if is_set:
        monkeypatch.setenv("HA_SHARE_PROFILE", "Steward AI share App Store")
    else:
        monkeypatch.delenv("HA_SHARE_PROFILE", raising=False)

    result = run_deploy(tmp_path, "--dry-run")

    assert result.returncode == 0, result.stdout + result.stderr
    named = "<key>com.siqstack.stewardai.share</key>" in result.stderr
    assert named is is_set
    if is_set:
        assert "<string>Steward AI share App Store</string>" in result.stderr
