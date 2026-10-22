#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for the scripts in scripts/macos. Sourced, never executed.
#
# Assumes: bash 3.2, which is the bash Apple ships in /bin/bash. Nothing here
#          uses an associative array, `readarray`, `${var,,}` or any other
#          bash 4 feature, so the scripts run whether the Mac has a newer bash
#          on PATH or not.
# Changes:  nothing. Every function here prints, checks, or runs what it was
#          handed. Nothing in this file installs, deletes or writes.

# 1 turns every ha_run into a print. Scripts that take --dry-run set it.
HA_DRY_RUN="${HA_DRY_RUN:-0}"

# All progress goes to stderr so that a script's real output can be piped.
ha_log()  { printf '%s\n' "$*" >&2; }
ha_ok()   { printf 'ok     %s\n' "$*" >&2; }
ha_warn() { printf 'warn   %s\n' "$*" >&2; }
ha_die()  { printf 'error  %s\n' "$*" >&2; exit 1; }

ha_head() { printf '\n== %s\n' "$*" >&2; }

# The repository root, resolved from this file rather than from the caller's
# working directory, so every script works from anywhere.
ha_repo_root() { ( cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd ); }

ha_have() { command -v "$1" >/dev/null 2>&1; }

# ha_need <command> <what to do about it>
ha_need() { ha_have "$1" || ha_die "$1 is not on PATH. $2"; }

ha_require_macos() {
  [ "$(uname -s)" = "Darwin" ] ||
    ha_die "this script only runs on macOS; uname reports $(uname -s). Run --help from anywhere else."
}

# Print a command with the value of any KEY=VALUE argument whose KEY reads
# like a credential replaced by <redacted>. Build settings are passed to
# xcodebuild on the command line, so the command line is exactly the place a
# team id or a key id would otherwise end up in a log.
ha_redact() {
  local arg out="" previous=""
  for arg in "$@"; do
    case "${previous}" in
      # xcodebuild takes these as a separate following argument.
      -authenticationKeyID|-authenticationKeyIssuerID|-authenticationKeyPath)
        out="${out} <redacted>"; previous="${arg}"; continue ;;
    esac
    case "${arg}" in
      *TEAM=*|*TOKEN=*|*SECRET=*|*PASSWORD=*|*KEY_ID=*|*ISSUER*=*|*_KEY=*)
        out="${out} ${arg%%=*}=<redacted>" ;;
      *)
        out="${out} ${arg}" ;;
    esac
    previous="${arg}"
  done
  printf '%s' "${out# }"
}

# Echo a command and run it, or only echo it when HA_DRY_RUN=1. Either way the
# echo is redacted, so nothing here can write a credential into a build log.
ha_run() {
  if [ "${HA_DRY_RUN}" = "1" ]; then
    printf 'would run  %s\n' "$(ha_redact "$@")" >&2
    return 0
  fi
  printf '+ %s\n' "$(ha_redact "$@")" >&2
  "$@"
}

# Voicebox install locations. Everything lives under the invoking user's home;
# no script in this directory writes outside it or asks for sudo.
HA_VOICEBOX_LABEL="${HA_VOICEBOX_LABEL:-com.example.householdassistant.voicebox}"
HA_VOICEBOX_ROOT="${HA_VOICEBOX_ROOT:-${HOME}/Library/Application Support/Voicebox}"
HA_VOICEBOX_LOGS="${HA_VOICEBOX_LOGS:-${HOME}/Library/Logs/Voicebox}"
HA_VOICEBOX_PLIST="${HA_VOICEBOX_PLIST:-${HOME}/Library/LaunchAgents/${HA_VOICEBOX_LABEL}.plist}"
HA_VOICEBOX_HOST="${HA_VOICEBOX_HOST:-127.0.0.1}"
HA_VOICEBOX_PORT="${HA_VOICEBOX_PORT:-8787}"
