#!/usr/bin/env bash
#
# Generate the Xcode project, build it, and render every screen and state of
# the app on a simulator, as PNGs.
#
# This is what the ios-screenshots workflow runs on a GitHub-hosted Mac, and
# what a person runs by hand to see every screen before putting the app on a
# phone. It runs one test class, ScreenshotTests, and nothing else.
#
# Assumes: macOS with Xcode, an iOS simulator runtime, and xcodegen on PATH.
#          Run scripts/macos/bootstrap.sh first if any of that is missing.
# Changes: writes apps/ios/HouseholdAssistant.xcodeproj (regenerated from
#          apps/ios/project.yml every run, and ignored by git), a result
#          bundle at apps/ios/build/screenshots.xcresult, and one PNG per
#          state under apps/ios/build/screenshots/. Touches nothing else.
#          Needs no signing identity, no team and no credential: the
#          simulator build runs with code signing switched off.
#
# Usage:
#   screenshots-ios.sh [--dry-run] [--help]
#
# Environment:
#   HA_IOS_DESTINATION   an xcodebuild -destination string. When unset, the
#                        first available iPhone simulator is used.
#
# NOT YET RUN ON APPLE HARDWARE.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      cat <<'TEXT'
screenshots-ios.sh - generate the project, build it, and render every screen.

  --dry-run   print the xcodegen and xcodebuild commands and stop
  --help      this text

Environment:
  HA_IOS_DESTINATION   an xcodebuild -destination string; defaults to the
                       first available iPhone simulator on the machine.

Writes one PNG per screen and state to apps/ios/build/screenshots/.
TEXT
      exit 0
      ;;
    --dry-run) HA_DRY_RUN=1 ;;
    *) ha_die "unknown argument ${arg}. Try --help." ;;
  esac
done

ha_require_macos
ha_need xcodegen "Run scripts/macos/bootstrap.sh."
ha_need xcodebuild "Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

root="$(ha_repo_root)"
ios="${root}/apps/ios"
project="${ios}/HouseholdAssistant.xcodeproj"
screenshots="${ios}/build/screenshots"

ha_head "generating the project from project.yml"
ha_run xcodegen generate --spec "${ios}/project.yml" --project "${ios}"

destination="${HA_IOS_DESTINATION:-}"
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

ha_head "building and rendering"
# Stale renders would be read as this run's; xcodebuild refuses to overwrite
# a result bundle.
ha_run rm -rf "${screenshots}" "${ios}/build/screenshots.xcresult"
# -skipMacroValidation: SwiftStreamingMarkdown depends on ordo-one/equatable,
# whose `@Equatable` is a Swift macro, and xcodebuild refuses to run a package
# macro nobody has trusted ("Macro EquatableMacros from package Equatable must
# be enabled before it can be used"). In Xcode that is a one-time Trust &
# Enable click; a script has no one to click it. The flag trusts only the
# macros in the resolved graph, which apps/ios/project.yml and the packages'
# own manifests pin to exact versions or commits.
ha_run xcodebuild test \
  -project "${project}" \
  -scheme HouseholdAssistant \
  -configuration Debug \
  -destination "${destination}" \
  -only-testing:HouseholdAssistantTests/ScreenshotTests \
  -resultBundlePath "${ios}/build/screenshots.xcresult" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES

if [ "${HA_DRY_RUN}" != "1" ]; then
  count="$(find "${screenshots}" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  [ "${count}" -gt 0 ] || ha_die "the test passed but wrote no PNG under ${screenshots}"
  ha_ok "${count} screenshots in ${screenshots}"
else
  ha_ok "dry run complete"
fi
