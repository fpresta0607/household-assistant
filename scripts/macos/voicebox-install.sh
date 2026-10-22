#!/usr/bin/env bash
#
# Install, or update, Voicebox as a launchd user agent.
#
# Rerunning this is how Voicebox is updated: it copies the current service
# over the installed one, rewrites the job description, and reloads it. It is
# safe to run any number of times and changes nothing it does not own.
#
# Assumes: macOS, python3 on PATH, and a logged-in user. A user agent rather
#          than a system daemon, because synthesis needs the logged-in user's
#          audio session and because a user agent needs no sudo at any point.
# Changes: writes, all inside the invoking user's home directory:
#            ~/Library/Application Support/Voicebox/voicebox.py
#            ~/Library/Logs/Voicebox/
#            ~/Library/LaunchAgents/<label>.plist
#          and loads the agent. It writes nothing outside $HOME, asks for no
#          password, and stores no credential: Voicebox has none.
#
# Usage:
#   voicebox-install.sh [--dry-run] [--help]
#
# Environment:
#   HA_VOICEBOX_PORT    loopback port, default 8787
#   HA_VOICEBOX_HOST    default 127.0.0.1. A non-loopback address is refused
#                       by the service itself unless VOICEBOX_ALLOW_PRIVATE=1,
#                       and a wildcard address is refused outright.
#   VOICEBOX_ENGINE     the engine to use. Left empty on purpose until
#                       voicebox-benchmark.sh has been run on this machine.
#   VOICEBOX_*          every other VOICEBOX_ variable set when this runs is
#                       written into the job description, so an engine that
#                       needs one (piper needs VOICEBOX_PIPER_MODEL) has it
#                       under launchd and not only in the installing shell.
#
# NOT YET RUN ON APPLE HARDWARE.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      cat <<'TEXT'
voicebox-install.sh - install or update the Voicebox launchd user agent.

  --dry-run   print every file it would write and every command it would run
  --help      this text

Rerun it to update: it replaces the installed service, rewrites the launchd
job description and reloads it. Everything it writes is under $HOME, and it
needs no sudo and holds no credential.

Environment:
  HA_VOICEBOX_HOST   default 127.0.0.1
  HA_VOICEBOX_PORT   default 8787
  VOICEBOX_ENGINE    left empty until voicebox-benchmark.sh has been run
  VOICEBOX_*         every other VOICEBOX_ variable set when this runs goes
                     into the job description, so an engine that needs one
                     (piper needs VOICEBOX_PIPER_MODEL) has it under launchd
TEXT
      exit 0
      ;;
    --dry-run) HA_DRY_RUN=1 ;;
    *) ha_die "unknown argument ${arg}. Try --help." ;;
  esac
done

# A dry run writes nothing, loads nothing and only renders the job description,
# so it runs anywhere. macOS is required by the steps that write and load, and
# requiring it here as well would mean the rendering is only ever exercised on
# the one machine nobody can check it from.
if [ "${HA_DRY_RUN}" != "1" ]; then
  ha_require_macos
fi
ha_need python3 "It ships with the Xcode command line tools; run scripts/macos/bootstrap.sh."

root="$(ha_repo_root)"
source_service="${root}/services/voicebox/voicebox.py"
template="${root}/services/voicebox/launchd.plist.template"
[ -f "${source_service}" ] || ha_die "missing ${source_service}"
[ -f "${template}" ] || ha_die "missing ${template}"

python_path="$(command -v python3)"
engine="${VOICEBOX_ENGINE:-}"

if [ "${HA_DRY_RUN}" = "1" ]; then
  ha_head "dry run: what an install would do"
else
  ha_head "installing"
fi
ha_log "label     ${HA_VOICEBOX_LABEL}"
ha_log "root      ${HA_VOICEBOX_ROOT}"
ha_log "logs      ${HA_VOICEBOX_LOGS}"
ha_log "listen    ${HA_VOICEBOX_HOST}:${HA_VOICEBOX_PORT}"
ha_log "engine    ${engine:-none chosen yet; run voicebox-benchmark.sh}"

ha_run mkdir -p "${HA_VOICEBOX_ROOT}" "${HA_VOICEBOX_LOGS}" "${HOME}/Library/LaunchAgents"
ha_run cp "${source_service}" "${HA_VOICEBOX_ROOT}/voicebox.py"

# Every VOICEBOX_ variable set here is carried into the job description, so an
# engine that needs a model path finds it under launchd instead of failing on
# every request with a variable the service was never given. Host and port come
# from the installer's own settings; anything else is the owner's.
export VOICEBOX_HOST="${HA_VOICEBOX_HOST}"
export VOICEBOX_PORT="${HA_VOICEBOX_PORT}"

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# An unset or empty variable is left out: an engine that expects a path must
# not be handed an empty string and told that it was configured.
environment_names() {
  local name
  env | sed -n 's/^\(VOICEBOX_[A-Z0-9_]*\)=.*/\1/p' | sort -u | while IFS= read -r name; do
    [ -n "${!name}" ] || continue
    printf '%s\n' "${name}"
  done
}

environment_pairs() {
  local name
  environment_names | while IFS= read -r name; do
    printf '    <key>%s</key>\n    <string>%s</string>\n' "${name}" "$(xml_escape "${!name}")"
  done
}

# The job description, from the template, with every token replaced.
plist_body="$(sed \
  -e "s|@LABEL@|${HA_VOICEBOX_LABEL}|g" \
  -e "s|@PYTHON@|${python_path}|g" \
  -e "s|@INSTALL_ROOT@|${HA_VOICEBOX_ROOT}|g" \
  -e "s|@LOG_DIR@|${HA_VOICEBOX_LOGS}|g" \
  "${template}")"

# awk rather than sed for this one, because the replacement is many lines and
# a multi-line sed replacement is not portable between GNU and BSD sed.
plist_body="$(printf '%s\n' "${plist_body}" |
  PLIST_ENVIRONMENT="$(environment_pairs)" awk '
    /@ENVIRONMENT@/ { printf "%s\n", ENVIRON["PLIST_ENVIRONMENT"]; next }
    { print }
  ')"

if printf '%s' "${plist_body}" | grep -q '@[A-Z_]\{1,\}@'; then
  ha_die "the launchd template still has an unreplaced token; refusing to install a broken job"
fi

# What actually landed in the job description, every run, so that nobody has to
# read the plist to find out. Names only: a value is never printed, because the
# whole point of a log is that it gets copied somewhere else.
ha_log "job env   $(environment_names | tr '\n' ' ')"

if [ "${HA_DRY_RUN}" = "1" ]; then
  ha_log "would write ${HA_VOICEBOX_PLIST}:"
  printf '%s\n' "${plist_body}" >&2
else
  printf '%s\n' "${plist_body}" > "${HA_VOICEBOX_PLIST}"
  plutil -lint "${HA_VOICEBOX_PLIST}" >/dev/null ||
    ha_die "the generated ${HA_VOICEBOX_PLIST} is not a valid property list"
  ha_ok "wrote ${HA_VOICEBOX_PLIST}"
fi

if [ "${HA_DRY_RUN}" = "1" ]; then
  ha_head "dry run: what loading would do"
else
  ha_head "loading"
fi
# bootout then bootstrap is the idempotent pair: booting out a job that is not
# loaded is not an error worth stopping for, and bootstrap then loads the job
# description that was just written rather than the one launchd remembers.
# Its stderr is dropped only on a real run, because on a dry run that stderr is
# the `would run` line itself and dropping it hides a step from the owner.
if [ "${HA_DRY_RUN}" = "1" ]; then
  ha_run launchctl bootout "gui/$(id -u)/${HA_VOICEBOX_LABEL}"
else
  ha_run launchctl bootout "gui/$(id -u)/${HA_VOICEBOX_LABEL}" 2>/dev/null || true
fi
ha_run launchctl bootstrap "gui/$(id -u)" "${HA_VOICEBOX_PLIST}"

if [ "${HA_DRY_RUN}" = "1" ]; then
  ha_ok "dry run complete. Nothing was written, nothing was copied and no agent was loaded."
  ha_log "Rerun without --dry-run to install."
else
  ha_ok "installed. Check it with scripts/macos/voicebox-health.sh"
fi
if [ -z "${engine}" ]; then
  ha_warn "no engine is chosen, so /speak will refuse until one is."
  ha_warn "Run scripts/macos/voicebox-benchmark.sh, then rerun this with VOICEBOX_ENGINE set."
fi
