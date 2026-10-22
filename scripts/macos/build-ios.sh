#!/usr/bin/env bash
#
# Archive the iOS app for distribution.
#
# This produces the .xcarchive and stops. Exporting it and sending it to
# TestFlight is scripts/macos/deploy-testflight.sh, which is separate on
# purpose: archiving is safe to run at any time, uploading is not.
#
# Assumes: macOS with Xcode and xcodegen on PATH. For a signed archive, the
#          Apple Distribution identity in a keychain on the search list and an
#          App Store profile for the app and for the widget in Xcode's profile
#          folder, both put there by `app-store-connect.py signing`. The
#          archive signs by hand with those, so it needs no Apple ID signed in
#          to Xcode and never talks to Apple.
# Changes: writes apps/ios/HouseholdAssistant.xcodeproj (regenerated from the
#          spec every run), apps/ios/build/HouseholdAssistant.xcarchive, and an
#          xcconfig in a private temporary directory that is deleted on exit.
#          Nothing else.
#
# Usage:
#   build-ios.sh [--dry-run] [--rehearse] [--help]
#
# Environment:
#   DEVELOPMENT_TEAM    required to sign. The ten-character Apple Developer
#                       team id. Its value is never printed.
#   HA_APP_PROFILE      required to sign. The App Store profile for the app.
#   HA_WIDGET_PROFILE   required to sign. The App Store profile for the widget.
#   HA_NOTIFICATIONS_PROFILE
#                       the App Store profile for the notification extension,
#                       set when project.yml declares that target.
#   HA_SHARE_PROFILE    the App Store profile for the share extension, set when
#                       project.yml declares that target.
#   HA_BUILD_NUMBER     optional. Overrides CURRENT_PROJECT_VERSION, so that a
#                       release workflow can stamp a monotonic build number
#                       without editing project.yml.
#   HOUSEHOLD_GATEWAY_HOST
#                       required to sign. The box's tailnet name, which the
#                       repository holds only as a placeholder
#                       (apps/ios/Household.xcconfig).
#   GOOGLE_IOS_CLIENT_ID
#                       required to sign. Google's iOS client id, the part
#                       before .apps.googleusercontent.com, likewise.
#
# --rehearse needs none of the signing or household values: it shows the signing settings
# each target would get, then archives with signing switched off, which proves
# the Release build compiles and leaves nothing that could be uploaded.
#
# --rehearse ran green on GitHub's macOS 26 Mac on 14 October 2026. The signed
# archive has not run yet: it waits for the first release.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

rehearse=0
for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      cat <<'TEXT'
build-ios.sh - archive the iOS app.

  --dry-run    print the xcodegen and xcodebuild commands and stop
  --rehearse   show each target's signing settings, then archive unsigned
  --help       this text

Environment:
  DEVELOPMENT_TEAM    the Apple Developer team id, never printed
  HA_APP_PROFILE      the App Store profile for the app
  HA_WIDGET_PROFILE   the App Store profile for the widget
  HA_NOTIFICATIONS_PROFILE
                      the notification extension's profile, when it is a target
  HA_SHARE_PROFILE    the share extension's profile, when it is a target
  HA_BUILD_NUMBER     optional, overrides CURRENT_PROJECT_VERSION
  HOUSEHOLD_GATEWAY_HOST, GOOGLE_IOS_CLIENT_ID
                      the household's values, never the placeholders

Writes apps/ios/build/HouseholdAssistant.xcarchive. It never talks to Apple:
uploading is deploy-testflight.sh.
TEXT
      exit 0
      ;;
    --dry-run) HA_DRY_RUN=1 ;;
    --rehearse) rehearse=1 ;;
    *) ha_die "unknown argument ${arg}. Try --help." ;;
  esac
done

ha_require_macos
ha_need xcodegen "Run scripts/macos/bootstrap.sh."
ha_need xcodebuild "Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

if [ "${rehearse}" = "1" ]; then
  # Names that show where each real value would land, and that no signing
  # identity or profile on any machine carries.
  DEVELOPMENT_TEAM="rehearsal"
  HA_APP_PROFILE="rehearsal app profile"
  HA_WIDGET_PROFILE="rehearsal widget profile"
  HA_NOTIFICATIONS_PROFILE="rehearsal notifications profile"
  HA_SHARE_PROFILE="rehearsal share profile"
fi
for var in DEVELOPMENT_TEAM HA_APP_PROFILE HA_WIDGET_PROFILE; do
  [ -n "${!var:-}" ] ||
    ha_die "${var} is not set. The release workflow sets it from app-store-connect.py signing; see docs/apple-signing.md."
done

root="$(ha_repo_root)"
ios="${root}/apps/ios"
# A signed archive with Household.xcconfig's placeholders would send every phone to a
# gateway that does not exist, so it needs the real values. A rehearsal keeps them.
if [ "${rehearse}" = "0" ]; then
  for var in HOUSEHOLD_GATEWAY_HOST GOOGLE_IOS_CLIENT_ID; do
    [ -n "${!var:-}" ] ||
      ha_die "${var} is not set. The release workflow sets it from the testflight environment; see apps/ios/Household.xcconfig."
  done
  if grep -qF -e "${HOUSEHOLD_GATEWAY_HOST}" -e "${GOOGLE_IOS_CLIENT_ID}" "${ios}/Household.xcconfig"; then
    ha_die "HOUSEHOLD_GATEWAY_HOST or GOOGLE_IOS_CLIENT_ID is still the placeholder in apps/ios/Household.xcconfig."
  fi
fi
project="${ios}/HouseholdAssistant.xcodeproj"
archive="${ios}/build/HouseholdAssistant.xcarchive"

if grep -q 'com\.example\.' "${ios}/project.yml"; then
  ha_die "the bundle identifiers in apps/ios/project.yml are still the com.example placeholder. Replace the prefix with one you have registered; see docs/apple-signing.md."
fi

ha_head "generating the project from project.yml"
ha_run xcodegen generate --spec "${ios}/project.yml" --project "${ios}"

# Each signed target gets its own App Store profile, keyed by PRODUCT_NAME,
# which project.yml fixes for both. The settings apply only to the iOS SDK, so
# the Swift macros the build runs on this Mac are not touched, and a package
# target looks up a profile name nobody set, which leaves it empty, as a
# package needs.
workdir="$(mktemp -d "${TMPDIR:-/tmp}/ios-archive.XXXXXX")"
cleanup() { rm -rf "${workdir}"; }
trap cleanup EXIT INT TERM
xcconfig="${workdir}/signing.xcconfig"
cat > "${xcconfig}" <<XCCONFIG
CODE_SIGN_STYLE[sdk=iphoneos*] = Manual
CODE_SIGN_IDENTITY[sdk=iphoneos*] = Apple Distribution
HA_PROFILE_HouseholdAssistant = ${HA_APP_PROFILE}
HA_PROFILE_HouseholdAssistantWidgets = ${HA_WIDGET_PROFILE}
HA_PROFILE_HouseholdAssistantNotifications = ${HA_NOTIFICATIONS_PROFILE:-}
HA_PROFILE_HouseholdAssistantShare = ${HA_SHARE_PROFILE:-}
PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*] = \$(HA_PROFILE_\$(PRODUCT_NAME))
XCCONFIG
# An xcconfig on the command line outranks Household.xcconfig and Local.xcconfig.
if [ "${rehearse}" = "0" ]; then
  printf 'HOUSEHOLD_GATEWAY_HOST = %s\nGOOGLE_IOS_CLIENT_ID = %s\n' \
    "${HOUSEHOLD_GATEWAY_HOST}" "${GOOGLE_IOS_CLIENT_ID}" >> "${xcconfig}"
fi

ha_head "archiving"
ha_log "team         set (value not shown)"
ha_log "profiles     ${HA_APP_PROFILE} / ${HA_WIDGET_PROFILE}${HA_NOTIFICATIONS_PROFILE:+ / ${HA_NOTIFICATIONS_PROFILE}}${HA_SHARE_PROFILE:+ / ${HA_SHARE_PROFILE}}"
ha_log "archive      ${archive}"

# An existing archive at the same path is replaced rather than merged into.
ha_run rm -rf "${archive}"

# -skipMacroValidation: SwiftStreamingMarkdown depends on ordo-one/equatable,
# whose `@Equatable` is a Swift macro, and xcodebuild refuses to run a package
# macro nobody has trusted ("Macro EquatableMacros from package Equatable must
# be enabled before it can be used"). In Xcode that is a one-time Trust &
# Enable click; a script has no one to click it. The flag trusts only the
# macros in the resolved graph, which apps/ios/project.yml and the packages'
# own manifests pin to exact versions or commits.
set -- \
  -project "${project}" \
  -scheme HouseholdAssistant \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -xcconfig "${xcconfig}" \
  -skipMacroValidation \
  "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
if [ -n "${HA_BUILD_NUMBER:-}" ]; then
  set -- "$@" "CURRENT_PROJECT_VERSION=${HA_BUILD_NUMBER}"
fi

if [ "${rehearse}" = "1" ]; then
  ha_head "the signing settings each target would archive with"
  if [ "${HA_DRY_RUN}" = "1" ]; then
    ha_run xcodebuild -showBuildSettings "$@"
  else
    xcodebuild -showBuildSettings "$@" |
      grep -E '^Build settings for|^ +(CODE_SIGN_STYLE|CODE_SIGN_IDENTITY|PROVISIONING_PROFILE_SPECIFIER|PRODUCT_BUNDLE_IDENTIFIER) = ' >&2
  fi
  ha_head "archiving with signing switched off"
  ha_run xcodebuild archive "$@" -archivePath "${archive}" CODE_SIGNING_ALLOWED=NO
else
  ha_run xcodebuild archive "$@" -archivePath "${archive}"
fi

if [ "${HA_DRY_RUN}" != "1" ]; then
  [ -d "${archive}" ] || ha_die "xcodebuild reported success but ${archive} does not exist"
  ha_ok "archived ${archive}"
else
  ha_ok "dry run complete"
fi
