#!/usr/bin/env bash
#
# Generate the Xcode project, build it, and run the tests on a simulator.
#
# This is what the preview job in ios-ci.yml runs on one of GitHub's Macs, one
# step per call so each shows its own minutes, and what anyone with a Mac can
# run by hand, every step in one call.
#
# Assumes: macOS with Xcode, an iOS simulator runtime, and xcodegen on PATH.
#          Run scripts/macos/bootstrap.sh first if any of that is missing.
# Changes: writes apps/ios/HouseholdAssistant.xcodeproj (regenerated from
#          apps/ios/project.yml every build, and ignored by git), the build in
#          apps/ios/build/DerivedData and result bundles under apps/ios/build/.
#          Touches nothing else. Needs no signing identity, no team and no
#          credential: the simulator build runs with code signing switched off.
#
# Usage:
#   test-ios.sh [--dry-run] [--help] [step ...]
#
# Steps, always run in this order, every one when none is named:
#   build        generate the project and build it for testing
#   unit         the unit tests, leaving out the screenshot classes
#   ui           the UI tests: those HA_IOS_UI_TESTS names, or every one
#   screenshots  ScreenshotTests and ChartsAndPicturesScreenshots, which render
#                the states HA_IOS_SCREENSHOTS names, or every one, to
#                apps/ios/build/screenshots
#   films        the motion demo filmed twice, needs HA_IOS_RECORDING, and
#                left out of an every-step call without it
# A step after build runs from the build an earlier call left.
#
# Environment:
#   HA_IOS_DESTINATION   an xcodebuild -destination string. When unset, the
#                        first available iPhone simulator is used.
#   HA_IOS_UI_TESTS      UI tests for the ui step, by class or class/test inside
#                        HouseholdAssistantUITests, separated by spaces.
#   HA_IOS_SCREENSHOTS   screenshot states for the screenshots step, by id or
#                        the start of one, separated by spaces. Unset, or all,
#                        renders every state.
#   HA_IOS_RECORDING    a path for an .mp4 of the simulator while the motion
#                        demo test runs, and a second take beside it with
#                        Reduce Motion on, named <path>-reduce-motion.mp4. When
#                        set, the ui step leaves the motion demo to the films.
#                        Needs the script to pick the simulator, so it cannot
#                        be combined with HA_IOS_DESTINATION.
#   HA_IOS_UI_RECORDING  a path for an .mp4 of the simulator while the ui step
#                        runs, so a change's own UI tests show what it changed,
#                        passing or failing. Not with HA_IOS_DESTINATION.
#
# Every step ran green on GitHub's macOS 26 Mac on 15 October 2026 (run
# 38798308870), in one call. Separate calls per step have not yet run on a Mac.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

steps=""
for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      cat <<'TEXT'
test-ios.sh - generate the project, build it, and run the tests.

  test-ios.sh [--dry-run] [build] [unit] [ui] [screenshots] [films]

  --dry-run    print the xcodegen and xcodebuild commands and stop
  --help       this text

Steps run in the order above, every one when none is named. A step after build
runs from the build an earlier call left in apps/ios/build/DerivedData.

Environment:
  HA_IOS_DESTINATION   an xcodebuild -destination string. Defaults to the
                       first available iPhone simulator on the machine.
  HA_IOS_UI_TESTS      UI tests for the ui step, by class or class/test inside
                       HouseholdAssistantUITests, separated by spaces.
  HA_IOS_SCREENSHOTS   screenshot states, by id or the start of one, separated
                       by spaces. Unset, or all, renders every state.
  HA_IOS_RECORDING    a path for an .mp4 of the motion demo test, plus a
                       second take with Reduce Motion beside it. Needed by the
                       films step. Not with HA_IOS_DESTINATION.
  HA_IOS_UI_RECORDING  a path for an .mp4 of the ui step as it runs. Not with
                       HA_IOS_DESTINATION.
TEXT
      exit 0
      ;;
    --dry-run) HA_DRY_RUN=1 ;;
    build|unit|ui|screenshots|films) steps="${steps} ${arg}" ;;
    *) ha_die "unknown argument ${arg}. Try --help." ;;
  esac
done

recording="${HA_IOS_RECORDING:-}"
if [ -z "${steps}" ]; then
  steps=" build unit ui screenshots"
  [ -z "${recording}" ] || steps="${steps} films"
fi
wants() {
  case "${steps} " in *" $1 "*) return 0 ;; esac
  return 1
}
if wants films && [ -z "${recording}" ]; then
  ha_die "the films step needs HA_IOS_RECORDING, the path for the first take."
fi

ha_require_macos
ha_need xcodegen "Run scripts/macos/bootstrap.sh."
ha_need xcodebuild "Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

root="$(ha_repo_root)"
ios="${root}/apps/ios"
project="${ios}/HouseholdAssistant.xcodeproj"
derived="${ios}/build/DerivedData"
# The app's bundle id, from apps/ios/project.yml, and the test the film is of: one
# fixed walk through what the app animates, the same length every run.
HA_IOS_BUNDLE_ID="com.siqstack.stewardai"
motion_demo="HouseholdAssistantUITests/MotionDemoTests/testMotionDemo"

if wants build; then
  ha_head "generating the project from project.yml"
  ha_run xcodegen generate --spec "${ios}/project.yml" --project "${ios}"
fi

# Pick a simulator rather than hard-coding a device name that ages out with
# every Xcode release. simctl prints each available device with its udid in
# parentheses; the first iPhone is good enough, and HA_IOS_DESTINATION
# overrides it when a particular device matters. Every call picks the same one.
destination="${HA_IOS_DESTINATION:-}"
if [ -n "${destination}" ] && [ -n "${recording}" ]; then
  ha_die "HA_IOS_RECORDING needs this script to pick the simulator, so unset HA_IOS_DESTINATION."
fi
ui_recording="${HA_IOS_UI_RECORDING:-}"
if [ -n "${destination}" ] && [ -n "${ui_recording}" ]; then
  ha_die "HA_IOS_UI_RECORDING needs this script to pick the simulator, so unset HA_IOS_DESTINATION."
fi
udid=""
if [ -z "${destination}" ]; then
  udid="$(xcrun simctl list devices available |
            grep -E '^ +iPhone' |
            head -1 |
            sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p')"
  [ -n "${udid}" ] ||
    ha_die "no available iPhone simulator. Open Xcode once, or run: xcodebuild -downloadPlatform iOS"
  destination="platform=iOS Simulator,id=${udid}"
fi
ha_log "destination  ${destination}"

# CODE_SIGNING_ALLOWED=NO keeps this path free of certificates, profiles and
# the keychain entirely. A simulator build needs none of it, and continuous
# integration must not be the thing that unlocks a signing identity.
# -skipMacroValidation: SwiftStreamingMarkdown depends on ordo-one/equatable,
# whose `@Equatable` is a Swift macro, and xcodebuild refuses to run a package
# macro nobody has trusted ("Macro EquatableMacros from package Equatable must
# be enabled before it can be used"). In Xcode that is a one-time Trust &
# Enable click; a script has no one to click it. The flag trusts only the
# macros in the resolved graph, which apps/ios/project.yml and the packages'
# own manifests pin to exact versions or commits.
# One DerivedData path, so every step finds the build and a cache can keep it.
# No code coverage and no index: nothing reads either, and both slow the build
# and the tests.
set -- \
  -project "${project}" \
  -scheme HouseholdAssistant \
  -configuration Debug \
  -destination "${destination}" \
  -derivedDataPath "${derived}" \
  -enableCodeCoverage NO \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  ONLY_ACTIVE_ARCH=YES

# Built once, then each test step runs from that build.
# Xcode stops starting compile jobs after the first one fails, so a broken build
# names only the first broken batch of files. Going on past it names every error
# in one run, which on a paid Mac is the difference between one run and several.
if wants build; then
  ha_head "building for testing"
  ha_run xcodebuild build-for-testing "$@" -IDEBuildingContinueBuildingAfterErrors=YES
fi

# A failed test step does not stop the ones after it: on a paid Mac each run
# should bring back every result, screenshot and film it can. The script still
# fails at the end, naming each step that failed.
failed=""

# xcodebuild refuses to overwrite an existing result bundle, so each step clears
# its own first.
if wants unit; then
  ha_head "unit tests"
  unit=(-only-testing:HouseholdAssistantTests)
  if [ -n "${HA_IOS_UNIT_TESTS:-}" ]; then
    unit=()
    # Each selector is one class or class/test, as with HA_IOS_UI_TESTS below.
    for name in ${HA_IOS_UNIT_TESTS}; do
      unit+=("-only-testing:HouseholdAssistantTests/${name}")
    done
  fi
  ha_run rm -rf "${ios}/build/test-results.xcresult"
  ha_run xcodebuild test-without-building "$@" \
    "${unit[@]}" \
    -skip-testing:HouseholdAssistantTests/ScreenshotTests \
    -skip-testing:HouseholdAssistantTests/ChartsAndPicturesScreenshots \
    -resultBundlePath "${ios}/build/test-results.xcresult" ||
    failed="${failed}, unit tests"
fi

if wants ui; then
  ha_head "UI tests"
  if [ -n "${HA_IOS_UI_TESTS:-}" ]; then
    ui=()
    for name in ${HA_IOS_UI_TESTS}; do
      ui+=("-only-testing:HouseholdAssistantUITests/${name}")
    done
  else
    ui=(-only-testing:HouseholdAssistantUITests)
    # The chat's timings measure rather than check, and take a quarter of an hour, so they
    # run only when a fix names them.
    ui+=("-skip-testing:HouseholdAssistantUITests/ChatSpeedTests" "-skip-testing:HouseholdAssistantUITests/ThousandsChatSpeedTests")
    # When it is filmed, the motion demo runs under the recorder instead of here.
    [ -z "${recording}" ] || ui+=("-skip-testing:${motion_demo}")
  fi
  ui+=(-resultBundlePath "${ios}/build/ui-test-results.xcresult")
  ha_run rm -rf "${ios}/build/ui-test-results.xcresult"
  ui_recorder=""
  if [ -n "${ui_recording}" ]; then
    # On the simulator the film sees, not a clone of it.
    ui+=(-parallel-testing-enabled NO)
    ha_run mkdir -p "$(dirname -- "${ui_recording}")"
    ha_run xcrun simctl boot "${udid}" || true
    ha_run xcrun simctl bootstatus "${udid}" -b
    if [ "${HA_DRY_RUN}" = "1" ]; then
      ha_run xcrun simctl io "${udid}" recordVideo --codec=h264 --force "${ui_recording}"
    else
      ha_log "+ xcrun simctl io ${udid} recordVideo --codec=h264 --force ${ui_recording} & (from $(date -u +%H:%M:%S) UTC)"
      xcrun simctl io "${udid}" recordVideo --codec=h264 --force "${ui_recording}" &
      ui_recorder=$!
    fi
  fi
  ha_run xcodebuild test-without-building "$@" "${ui[@]}" || failed="${failed}, UI tests"
  if [ -n "${ui_recorder}" ]; then
    # An interrupt is what makes simctl finish the file.
    kill -INT "${ui_recorder}" 2>/dev/null || true
    wait "${ui_recorder}" 2>/dev/null || true
  fi
fi

if wants screenshots; then
  ha_head "screenshots to build/screenshots"
  # Only the states a change touches: the test host renders a state only when
  # its id starts with one of the comma-separated names in STEWARD_SCREENSHOTS,
  # which xcodebuild hands it from TEST_RUNNER_STEWARD_SCREENSHOTS. Unset, or
  # all, renders every one.
  if [ -n "${HA_IOS_SCREENSHOTS:-}" ] && [ "${HA_IOS_SCREENSHOTS}" != "all" ]; then
    export TEST_RUNNER_STEWARD_SCREENSHOTS="${HA_IOS_SCREENSHOTS// /,}"
    ha_log "screenshots  ${HA_IOS_SCREENSHOTS}"
  fi
  ha_run rm -rf "${ios}/build/screenshot-results.xcresult"
  ha_run xcodebuild test-without-building "$@" \
    -only-testing:HouseholdAssistantTests/ScreenshotTests \
    -only-testing:HouseholdAssistantTests/ChartsAndPicturesScreenshots \
    -resultBundlePath "${ios}/build/screenshot-results.xcresult" ||
    failed="${failed}, screenshots"
fi

if wants films; then
  # The motion demo test walks the demo household, which plays from data inside
  # the Debug build with no gateway, through what the app animates. The
  # simulator is filmed while it runs. Parallel testing would run it on a clone
  # the film does not see.
  recorder=""
  stop_recording() {
    if [ -n "${recorder}" ]; then
      # An interrupt is what makes simctl finish the file.
      kill -INT "${recorder}" 2>/dev/null || true
      wait "${recorder}" 2>/dev/null || true
      recorder=""
    fi
  }
  # film <file> <xcodebuild arguments...>
  # Each take keeps its result bundle beside the others, so a failed take
  # brings back what the screen held when it failed.
  film() {
    local file="$1"
    local bundle
    bundle="${ios}/build/$(basename -- "${file%.mp4}")-results.xcresult"
    shift
    ha_run rm -rf "${bundle}"
    if [ "${HA_DRY_RUN}" = "1" ]; then
      ha_run xcrun simctl io "${udid}" recordVideo --codec=h264 --force "${file}"
    else
      ha_log "+ xcrun simctl io ${udid} recordVideo --codec=h264 --force ${file} &"
      xcrun simctl io "${udid}" recordVideo --codec=h264 --force "${file}" &
      recorder=$!
    fi
    local status=0
    ha_run xcodebuild test-without-building "$@" \
      -only-testing:"${motion_demo}" \
      -parallel-testing-enabled NO \
      -resultBundlePath "${bundle}" || status=$?
    stop_recording
    return "${status}"
  }
  reduce_motion() {
    ha_run xcrun simctl spawn "${udid}" defaults write com.apple.Accessibility ReduceMotionEnabled -bool "$1"
  }
  trap stop_recording EXIT

  ha_head "recording the app"
  ha_run mkdir -p "$(dirname -- "${recording}")"
  # The tests leave the simulator booted. Booting a booted simulator is an
  # error simctl reports and that changes nothing, so it does not stop the run.
  ha_run xcrun simctl boot "${udid}" || true
  ha_run xcrun simctl bootstatus "${udid}" -b
  # Allowed before the film, so iOS's microphone question is in no take.
  ha_run xcrun simctl privacy "${udid}" grant microphone "${HA_IOS_BUNDLE_ID}"
  film "${recording}" "$@" || failed="${failed}, motion demo"

  ha_head "recording the app again with Reduce Motion"
  reduce_motion YES
  # The setting is read when the simulator starts, so it starts again.
  ha_run xcrun simctl shutdown "${udid}"
  ha_run xcrun simctl boot "${udid}"
  ha_run xcrun simctl bootstatus "${udid}" -b
  film "${recording%.mp4}-reduce-motion.mp4" "$@" || failed="${failed}, motion demo with Reduce Motion"
  # A Mac someone runs this on by hand keeps the simulator it had.
  reduce_motion NO
fi

[ -z "${failed}" ] ||
  ha_die "failed: ${failed#, }. Every step after a failure still ran, so the log, screenshots and films hold all this run reached."
ha_ok "finished:${steps}"
