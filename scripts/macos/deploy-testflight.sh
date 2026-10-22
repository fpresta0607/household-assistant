#!/usr/bin/env bash
#
# Export an existing archive and upload it to TestFlight.
#
# This is the only script in this repository that sends anything to Apple, so
# it refuses to run unless it was asked on purpose:
#
#   * --confirm must be passed explicitly. There is no default that uploads.
#     --dry-run needs no confirmation, because it sends nothing.
#   * It refuses outright when the GitHub event is a pull request, so that no
#     change proposed on a branch can reach TestFlight by arriving on the
#     self-hosted runner.
#
# Assumes: macOS with Xcode, an archive already built and signed by
#          build-ios.sh, the App Store profiles it signed with, and an App
#          Store Connect API key on disk. Authentication is the API key,
#          never an Apple ID and password: a key can be scoped and revoked,
#          and it means no human password is ever typed into, or asked for by,
#          anything in this repository.
# Changes: writes an .ipa and an export log under apps/ios/build/export/, and
#          uploads a build to App Store Connect. It does not submit for
#          review, does not change any App Store listing, and does not
#          distribute to any tester group.
#
# Usage:
#   deploy-testflight.sh --confirm [--help]
#   deploy-testflight.sh --dry-run
#
# Environment:
#   DEVELOPMENT_TEAM               required, the Apple Developer team id.
#   HA_APP_PROFILE                 required, the App Store profile for the app.
#   HA_WIDGET_PROFILE              required, the App Store profile for the widget.
#   HA_NOTIFICATIONS_PROFILE       the notification extension's profile, set when
#                                  project.yml declares that target.
#   HA_SHARE_PROFILE               the share extension's profile, set when
#                                  project.yml declares that target.
#   APP_STORE_CONNECT_KEY_ID       required, the key id.
#   APP_STORE_CONNECT_ISSUER_ID    required, the issuer id.
#   APP_STORE_CONNECT_KEY_PATH     required, a path to the .p8 private key.
#                                  The key is passed as a path, never as an
#                                  environment value, so it cannot appear in a
#                                  process listing or a build log.
#
# No value of any of these is printed by this script. Presence is checked,
# contents are not echoed, and the export options plist is written to a
# private temporary directory that is deleted on exit.
#
# --dry-run ran on GitHub's macOS 26 Mac on 14 October 2026. The export and
# the upload have not run yet: they wait for the first release.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

confirmed=0
for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      cat <<'TEXT'
deploy-testflight.sh - export an archive and upload it to TestFlight.

  --confirm   required to upload; without it this script refuses
  --dry-run   print what it would do, including the export options, and stop.
              Sends nothing, so it does not need --confirm.
  --help      this text

Environment (all required, none of the key values ever printed):
  DEVELOPMENT_TEAM             the Apple Developer team id
  HA_APP_PROFILE               the App Store profile for the app
  HA_WIDGET_PROFILE            the App Store profile for the widget
  HA_NOTIFICATIONS_PROFILE     the notification extension's profile, when it
                               is a target (optional)
  HA_SHARE_PROFILE             the share extension's profile, when it is a
                               target (optional)
  APP_STORE_CONNECT_KEY_ID     the App Store Connect API key id
  APP_STORE_CONNECT_ISSUER_ID  the App Store Connect issuer id
  APP_STORE_CONNECT_KEY_PATH   a path to the .p8 private key file

Refuses to run when GITHUB_EVENT_NAME is a pull request. Uploads to
TestFlight only; it never submits for review and never changes a listing.
TEXT
      exit 0
      ;;
    --confirm) confirmed=1 ;;
    --dry-run) HA_DRY_RUN=1 ;;
    *) ha_die "unknown argument ${arg}. Try --help." ;;
  esac
done

ha_require_macos

# The controlled trigger. Both halves matter: the flag stops an accidental
# run by a person, and the event check stops an accidental run by automation.
# The event check binds a dry run too, because a pull request has no business
# reaching this script at all.
case "${GITHUB_EVENT_NAME:-}" in
  pull_request|pull_request_target)
    ha_die "refusing to upload from a ${GITHUB_EVENT_NAME} event. Releases run from a tag or a manual dispatch; see .github/workflows/ios-release.yml."
    ;;
esac
# A dry run sends nothing: HA_DRY_RUN=1 turns every ha_run, the export included,
# into a print. Requiring the confirmation flag to see what would happen defeats
# the point of being able to look before you are sure.
[ "${confirmed}" = "1" ] || [ "${HA_DRY_RUN}" = "1" ] ||
  ha_die "refusing to upload without --confirm. This is the only script here that sends anything to Apple."

ha_need xcodebuild "Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

for var in DEVELOPMENT_TEAM HA_APP_PROFILE HA_WIDGET_PROFILE APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_PATH; do
  [ -n "${!var:-}" ] || ha_die "${var} is not set. See docs/testflight.md."
done
[ -f "${APP_STORE_CONNECT_KEY_PATH}" ] ||
  ha_die "APP_STORE_CONNECT_KEY_PATH does not point at a file. See docs/testflight.md."

root="$(ha_repo_root)"
ios="${root}/apps/ios"
archive="${ios}/build/HouseholdAssistant.xcarchive"
export_dir="${ios}/build/export"

[ -d "${archive}" ] ||
  ha_die "no archive at ${archive}. Run scripts/macos/build-ios.sh first."

# The export options carry the team id, so they are written to a private
# temporary directory rather than into the repository, and removed on exit
# whether this script succeeds or fails.
workdir="$(mktemp -d "${TMPDIR:-/tmp}/ios-export.XXXXXX")"
cleanup() { rm -rf "${workdir}"; }
trap cleanup EXIT INT TERM
options="${workdir}/ExportOptions.plist"
umask 077

# The notification and share extensions are signed only when project.yml
# declares them.
notifications_profile=""
if [ -n "${HA_NOTIFICATIONS_PROFILE:-}" ]; then
  notifications_profile="    <key>com.siqstack.stewardai.notifications</key>
    <string>${HA_NOTIFICATIONS_PROFILE}</string>"
fi
share_profile=""
if [ -n "${HA_SHARE_PROFILE:-}" ]; then
  share_profile="    <key>com.siqstack.stewardai.share</key>
    <string>${HA_SHARE_PROFILE}</string>"
fi

cat > "${options}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>teamID</key>
  <string>${DEVELOPMENT_TEAM}</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.siqstack.stewardai</key>
    <string>${HA_APP_PROFILE}</string>
    <key>com.siqstack.stewardai.widgets</key>
    <string>${HA_WIDGET_PROFILE}</string>
${notifications_profile}
${share_profile}
  </dict>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

if [ "${HA_DRY_RUN}" = "1" ]; then
  ha_head "dry run: what an upload would do"
else
  ha_head "exporting and uploading"
fi
ha_log "archive   ${archive}"
ha_log "method    app-store-connect, destination upload"
ha_log "auth      App Store Connect API key (id, issuer and key are set; values not shown)"

if [ "${HA_DRY_RUN}" = "1" ]; then
  ha_log "export options that would be used, with the team id removed:"
  sed 's|<string>'"${DEVELOPMENT_TEAM}"'</string>|<string>REDACTED</string>|' "${options}" >&2
fi

ha_run rm -rf "${export_dir}"
ha_run xcodebuild -exportArchive \
  -archivePath "${archive}" \
  -exportPath "${export_dir}" \
  -exportOptionsPlist "${options}" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "${APP_STORE_CONNECT_KEY_PATH}" \
  -authenticationKeyID "${APP_STORE_CONNECT_KEY_ID}" \
  -authenticationKeyIssuerID "${APP_STORE_CONNECT_ISSUER_ID}"

if [ "${HA_DRY_RUN}" = "1" ]; then
  ha_ok "dry run complete. Nothing was exported and nothing was sent to Apple."
  ha_log "Rerun with --confirm, and without --dry-run, to upload."
else
  ha_ok "uploaded. The build appears in App Store Connect once processing finishes, which takes a few minutes."
  ha_log "It is not distributed to any tester until someone adds it to a group there."
fi
