#!/usr/bin/env bash
#
# Bring a Mac up to the point where it can build the iOS app.
#
# Assumes: macOS on Apple Silicon or Intel, a logged-in user, and a network.
#          Xcode itself, the Xcode licence and Homebrew are human steps; this
#          script reports them and refuses to guess, because each one needs an
#          Apple ID, an administrator password, or both.
# Changes: installs, through Homebrew, only the prerequisites that are missing.
#          It never upgrades, never reinstalls, never replaces a tool that is
#          already there, and never writes outside Homebrew's own prefix.
#          It handles no password, no Apple ID and no key of any kind.
#
# Usage:
#   bootstrap.sh [--dry-run] [--check] [--help]
#
#     --check     inspect and report; install nothing (same as --dry-run
#                 without the "would run" lines)
#     --dry-run   print every install it would perform
#
# NOT YET RUN ON APPLE HARDWARE.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'TEXT'
bootstrap.sh - bring a Mac up to the point where it can build the iOS app.

  --check     inspect and report; install nothing
  --dry-run   print every install it would perform
  --help      this text

Installs only what is missing, through Homebrew, and never upgrades or
replaces a tool that is already there. Xcode, the Xcode licence and Homebrew
itself are reported as human steps: each needs an Apple ID, an administrator
password, or both. This script handles no password, no Apple ID and no key.
TEXT
}

check_only=0
for arg in "$@"; do
  case "${arg}" in
    -h|--help) usage; exit 0 ;;
    --check) check_only=1 ;;
    --dry-run) HA_DRY_RUN=1 ;;
    *) ha_die "unknown argument ${arg}. Try --help." ;;
  esac
done

ha_require_macos

missing=0
human=0

ha_head "the machine"
ha_log "macOS   $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
ha_log "arch    $(uname -m)"
ha_log "user    $(id -un)"

ha_head "things only a human can do"

# Xcode. xcode-select -p points at the command line tools until a full Xcode is
# selected, and xcodebuild without a full Xcode cannot build an iOS app at all.
if ! ha_have xcodebuild; then
  ha_warn "Xcode is not installed. Install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
  human=$((human + 1))
elif ! xcode-select -p 2>/dev/null | grep -q '\.app'; then
  ha_warn "xcode-select points at $(xcode-select -p), which is the command line tools rather than Xcode."
  ha_warn "fix it with: sudo xcode-select -s /Applications/Xcode.app"
  human=$((human + 1))
else
  ha_ok "Xcode $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}') at $(xcode-select -p)"
  # A fresh Xcode refuses every command until its licence is accepted.
  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    ha_warn "Xcode has not finished its first launch. Run: sudo xcodebuild -runFirstLaunch"
    ha_warn "and accept the licence with: sudo xcodebuild -license accept"
    human=$((human + 1))
  else
    ha_ok "Xcode first launch complete and licence accepted"
  fi
fi

# Command line tools, which is what gives us git, python3 and the compilers.
if [ -d "/Library/Developer/CommandLineTools" ] || xcode-select -p >/dev/null 2>&1; then
  ha_ok "command line tools present"
else
  ha_warn "command line tools missing. Run: xcode-select --install"
  human=$((human + 1))
fi

# Homebrew. Installing it needs an administrator password and rewrites a large
# part of /opt or /usr/local, so it is reported rather than performed.
if ha_have brew; then
  ha_ok "Homebrew $(brew --version | head -1 | awk '{print $2}') at $(command -v brew)"
else
  ha_warn "Homebrew is not installed, and installing it needs your administrator password."
  ha_warn "See https://brew.sh and then re-run this script."
  human=$((human + 1))
fi

ha_head "things this script can install"

# XcodeGen turns apps/ios/project.yml into the Xcode project. It is the one
# build dependency this repository actually adds.
if ha_have xcodegen; then
  ha_ok "xcodegen $(xcodegen --version 2>/dev/null | tail -1)"
elif [ "${check_only}" = "1" ]; then
  ha_warn "xcodegen missing; would install it with Homebrew"
  missing=$((missing + 1))
elif ha_have brew; then
  ha_log "installing xcodegen"
  ha_run brew install xcodegen
else
  ha_warn "xcodegen missing and Homebrew is not available to install it"
  missing=$((missing + 1))
fi

ha_head "things that should already be here"

for tool in git python3 curl plutil launchctl; do
  if ha_have "${tool}"; then
    ha_ok "${tool} at $(command -v "${tool}")"
  else
    ha_warn "${tool} is missing, which is unexpected on a working macOS install"
    missing=$((missing + 1))
  fi
done

ha_head "simulators"

if ha_have xcrun && xcrun simctl list runtimes 2>/dev/null | grep -q 'iOS'; then
  ha_ok "$(xcrun simctl list runtimes 2>/dev/null | grep -c 'iOS') iOS simulator runtime(s) installed"
else
  ha_warn "no iOS simulator runtime found. Open Xcode once, or run: xcodebuild -downloadPlatform iOS"
  human=$((human + 1))
fi

ha_head "result"
if [ "${human}" -gt 0 ]; then
  ha_warn "${human} item(s) need a person. Work through docs/apple-activation-checklist.md."
fi
if [ "${missing}" -gt 0 ]; then
  ha_die "${missing} prerequisite(s) still missing"
fi
if [ "${human}" -gt 0 ]; then
  exit 1
fi
ha_ok "the machine is ready; run scripts/macos/verify.sh to confirm"
