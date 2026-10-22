#!/usr/bin/env bash
#
# Is Voicebox healthy, and is it still only listening where it should be?
#
# The second question is the one worth a script. A service that speaks
# household conversation must never be reachable from outside this machine,
# and the way that goes wrong is quiet: an edited setting, a restored backup,
# a copied plist. So this checks the actual listening socket rather than
# trusting the configuration that produced it.
#
# Assumes: macOS. Voicebox may or may not be installed; this reports either way.
# Changes: nothing. It reads a socket table, makes one GET, and prints.
#
# Usage:
#   voicebox-health.sh [--help]
#
# Exit status is 0 only when the agent is loaded, the health endpoint answers
# ok, and every listening socket the service owns is loopback or private.
#
# NOT YET RUN ON APPLE HARDWARE.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-}" in
  -h|--help)
    cat <<'TEXT'
voicebox-health.sh - check the Voicebox agent, its health endpoint and its
listening socket.

  --help   this text

Reads only. Exits non-zero if the agent is not loaded, the health endpoint
does not answer ok, or the service is listening anywhere other than loopback
or a private address.
TEXT
    exit 0
    ;;
  "") ;;
  *) ha_die "unknown argument ${1}. Try --help." ;;
esac

ha_require_macos

fail=0
report() {
  printf '%-6s %-28s %s\n' "$1" "$2" "$3"
  [ "$1" = "PASS" ] || fail=1
}

service="gui/$(id -u)/${HA_VOICEBOX_LABEL}"

if launchctl print "${service}" >/dev/null 2>&1; then
  pid="$(launchctl print "${service}" | sed -n 's/^[[:space:]]*pid = \([0-9]*\).*/\1/p' | head -1)"
  if [ -n "${pid}" ]; then
    report PASS "launchd agent" "running, pid ${pid}"
  else
    report FAIL "launchd agent" "loaded but not running; see voicebox-start.sh logs"
    pid=""
  fi
else
  report FAIL "launchd agent" "not loaded; run voicebox-install.sh"
  pid=""
fi

url="http://${HA_VOICEBOX_HOST}:${HA_VOICEBOX_PORT}/health"
# No -f, deliberately. A 503 is a real answer rather than an outage: it is what
# the service returns before an engine has been chosen, and its body carries the
# detail naming what is wrong. -f discards exactly that body, which left the
# owner with a generic line for the one status designed to be specific.
if body="$(curl -sS --max-time 5 "${url}" 2>/dev/null)"; then
  status="$(printf '%s' "${body}" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  engine="$(printf '%s' "${body}" | sed -n 's/.*"engine"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  detail="$(printf '%s' "${body}" | sed -n 's/.*"detail"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ "${status}" = "ok" ]; then
    report PASS "health endpoint" "${url} reports ok, engine ${engine}"
  else
    report FAIL "health endpoint" "${url} reports ${status:-unreadable}${detail:+: ${detail}}"
  fi
else
  report FAIL "health endpoint" "${url} did not answer"
fi

# The listening socket, read from the kernel rather than from any setting.
if [ -n "${pid}" ]; then
  listening="$(lsof -nP -a -p "${pid}" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $(NF-1) }' || true)"
  if [ -z "${listening}" ]; then
    report FAIL "listening socket" "the process owns no listening TCP socket"
  else
    exposed=""
    for socket in ${listening}; do
      address="${socket%:*}"
      case "${address}" in
        127.0.0.*|\[::1\]|localhost) ;;
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
        *) exposed="${exposed} ${socket}" ;;
      esac
    done
    if [ -n "${exposed}" ]; then
      report FAIL "listening socket" "reachable beyond this machine on${exposed}"
    else
      report PASS "listening socket" "$(printf '%s' "${listening}" | tr '\n' ' ')"
    fi
  fi
fi

echo
if [ "${fail}" -eq 0 ]; then
  echo "VOICEBOX HEALTHY"
else
  echo "VOICEBOX NOT HEALTHY"
  exit 1
fi
