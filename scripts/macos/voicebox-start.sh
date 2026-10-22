#!/usr/bin/env bash
#
# Start, stop, restart, inspect or tail the Voicebox launchd agent.
#
# One script rather than six, because every one of these is the same launchctl
# call with a different verb, and six files that each wrap one command is six
# files to keep in step.
#
# Assumes: macOS, and that scripts/macos/voicebox-install.sh has run.
# Changes: the running state of the launchd agent, and nothing on disk.
#          Updating the service is voicebox-install.sh; rerun that.
#
# Usage:
#   voicebox-start.sh [start|stop|restart|status|logs] [--dry-run] [--help]
#
# The action defaults to start.
#
# NOT YET RUN ON APPLE HARDWARE.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

action="start"
for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      cat <<'TEXT'
voicebox-start.sh - control the Voicebox launchd agent.

  start     load the agent and start it (the default)
  stop      stop it and unload it; it stays installed
  restart   stop and start, without reloading the job description
  status    what launchd thinks, and what the health endpoint says
  logs      the last 50 lines of both log files

  --dry-run   print the launchctl commands and stop
  --help      this text

Updating the service is scripts/macos/voicebox-install.sh; rerun it.
TEXT
      exit 0
      ;;
    --dry-run) HA_DRY_RUN=1 ;;
    start|stop|restart|status|logs) action="${arg}" ;;
    *) ha_die "unknown argument ${arg}. Try --help." ;;
  esac
done

ha_require_macos

domain="gui/$(id -u)"
service="${domain}/${HA_VOICEBOX_LABEL}"

require_installed() {
  [ -f "${HA_VOICEBOX_PLIST}" ] ||
    ha_die "Voicebox is not installed. Run scripts/macos/voicebox-install.sh first."
}

case "${action}" in
  start)
    require_installed
    # bootstrap loads it if it is not loaded; kickstart starts it if it is.
    ha_run launchctl bootstrap "${domain}" "${HA_VOICEBOX_PLIST}" 2>/dev/null || true
    ha_run launchctl kickstart "${service}"
    ha_ok "started ${HA_VOICEBOX_LABEL}"
    ;;

  stop)
    require_installed
    ha_run launchctl bootout "${service}"
    ha_ok "stopped ${HA_VOICEBOX_LABEL}. It is still installed; start it again with: $0 start"
    ;;

  restart)
    require_installed
    # -k kills the running process and lets KeepAlive bring it straight back.
    ha_run launchctl kickstart -k "${service}"
    ha_ok "restarted ${HA_VOICEBOX_LABEL}"
    ;;

  status)
    ha_head "launchd"
    if launchctl print "${service}" >/dev/null 2>&1; then
      launchctl print "${service}" | grep -E '^\s*(state|pid|last exit code|program) ' || true
    else
      ha_warn "${HA_VOICEBOX_LABEL} is not loaded"
    fi
    ha_head "health"
    "$(dirname -- "${BASH_SOURCE[0]}")/voicebox-health.sh" || true
    ;;

  logs)
    for log in "${HA_VOICEBOX_LOGS}/voicebox.out.log" "${HA_VOICEBOX_LOGS}/voicebox.err.log"; do
      ha_head "${log}"
      if [ -f "${log}" ]; then
        tail -50 "${log}"
      else
        ha_warn "not written yet"
      fi
    done
    ;;
esac
