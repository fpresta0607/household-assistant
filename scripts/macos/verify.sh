#!/usr/bin/env bash
#
# Report what this Mac has, what it is missing, and what still needs a person.
#
# Assumes: macOS. Nothing else; it is safe to run on a machine where nothing
#          has been set up yet, and that is the point.
# Changes: nothing at all. This script only reads.
#
# Usage:
#   verify.sh [--help]
#
# Exit status is 0 only when every required line reads PASS. A HUMAN line is
# not a failure of the machine, but it does keep the exit status non-zero,
# because the pipeline cannot run until those items are done. An INFO line
# reports something that is not this machine's business either way and never
# affects the exit status.
#
# NOT YET RUN ON APPLE HARDWARE.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-}" in
  -h|--help)
    cat <<'TEXT'
verify.sh - report what is present, what is missing, and what needs a human.

  --help   this text

Reads only. Prints one line per check, tagged PASS, MISS, HUMAN or INFO, and
exits non-zero if anything is MISS or HUMAN. An INFO line never affects the
exit status.
TEXT
    exit 0
    ;;
  "") ;;
  *) ha_die "unknown argument ${1}. Try --help." ;;
esac

ha_require_macos

root="$(ha_repo_root)"
fail=0

# report <tag> <name> <detail>
report() {
  printf '%-6s %-34s %s\n' "$1" "$2" "$3"
  [ "$1" = "PASS" ] || fail=1
}

# note <name> <detail>; reported, never counted. For things whose absence from
# this machine is the correct state rather than an outstanding task.
note() {
  printf '%-6s %-34s %s\n' "INFO" "$1" "$2"
}

# check <name> <detail-command...>; PASS when the command succeeds. Every tool
# checked this way is one bootstrap.sh installs, so a MISS names it rather than
# leaving the owner to work out which step closes the line.
check() {
  local name="$1"; shift
  local out
  if out="$("$@" 2>/dev/null)"; then
    report PASS "${name}" "${out}"
  else
    report MISS "${name}" "not available; run scripts/macos/bootstrap.sh"
  fi
}

echo "== machine"
report PASS "macOS version" "$(sw_vers -productVersion)"
report PASS "architecture" "$(uname -m)"

echo
echo "== toolchain"
if ha_have xcodebuild && xcode-select -p 2>/dev/null | grep -q '\.app'; then
  report PASS "Xcode" "$(xcodebuild -version | head -1) at $(xcode-select -p)"
else
  report HUMAN "Xcode" "install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
fi

if ha_have xcodebuild && xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  report PASS "Xcode licence and first launch" "accepted"
else
  report HUMAN "Xcode licence and first launch" "sudo xcodebuild -runFirstLaunch; sudo xcodebuild -license accept"
fi

check "Homebrew" brew --version
check "xcodegen" xcodegen --version
check "git" git --version
check "python3" python3 --version

if ha_have xcrun && xcrun simctl list runtimes 2>/dev/null | grep -q iOS; then
  report PASS "iOS simulator runtime" "$(xcrun simctl list runtimes 2>/dev/null | grep -c iOS) installed"
else
  report HUMAN "iOS simulator runtime" "open Xcode once, or: xcodebuild -downloadPlatform iOS"
fi

echo
echo "== this repository"
for path in apps/ios/project.yml services/voicebox/voicebox.py .github/workflows/ios-ci.yml; do
  if [ -f "${root}/${path}" ]; then
    report PASS "${path}" "present"
  else
    report MISS "${path}" "expected at ${root}/${path}"
  fi
done

# The bundle identifiers now carry the owner's registered prefix, so this
# check reports the placeholder only if the prefix is ever reverted, which no
# signed build could survive. See docs/apple-signing.md.
if grep -q 'com\.example\.' "${root}/apps/ios/project.yml" 2>/dev/null; then
  report HUMAN "bundle identifier prefix" "still com.example; replace it in apps/ios/project.yml"
else
  report PASS "bundle identifier prefix" "replaced"
fi

echo
echo "== signing and release inputs"
# Informational, never counted. Releases run on GitHub's Macs, which take the
# key from the testflight environment and the team id from the profile, so this
# shell is the wrong place to look and their absence here is the correct state.
# Presence only. No value from any of these is ever printed or logged.
for var in DEVELOPMENT_TEAM APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_PATH; do
  if [ -n "${!var:-}" ]; then
    note "${var}" "set in this shell (value not shown)"
  else
    note "${var}" "not set in this shell, which is right: the release on GitHub's Mac takes it from the testflight environment"
  fi
done

echo
echo "== voicebox"
if [ -f "${HA_VOICEBOX_PLIST}" ]; then
  report PASS "launchd agent installed" "${HA_VOICEBOX_PLIST}"
  if launchctl print "gui/$(id -u)/${HA_VOICEBOX_LABEL}" >/dev/null 2>&1; then
    report PASS "launchd agent loaded" "${HA_VOICEBOX_LABEL}"
  else
    report MISS "launchd agent loaded" "run scripts/macos/voicebox-start.sh"
  fi
else
  report MISS "launchd agent installed" "run scripts/macos/voicebox-install.sh"
fi

# Read the engine from the installed job description, not from this shell.
# The engine is a property of the service, and voicebox-install.sh writes it
# into the launchd job; the shell that happens to be running this script knows
# nothing about it. Reading VOICEBOX_ENGINE here instead would report HUMAN in
# every terminal opened after the install, failing forever over an install that
# in fact succeeded.
if [ -f "${HA_VOICEBOX_PLIST}" ] &&
   installed_engine="$(plutil -extract EnvironmentVariables.VOICEBOX_ENGINE raw -o - \
                         "${HA_VOICEBOX_PLIST}" 2>/dev/null)" &&
   [ -n "${installed_engine}" ]; then
  report PASS "speech engine chosen" "${installed_engine}, from the installed job description"
else
  report HUMAN "speech engine chosen" "run scripts/macos/voicebox-benchmark.sh, then reinstall with VOICEBOX_ENGINE set"
fi

echo
if [ "${fail}" -eq 0 ]; then
  echo "VERIFIED"
else
  echo "NOT READY - each line above says what it needs"
  exit 1
fi
