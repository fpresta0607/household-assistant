#!/usr/bin/env bash
# Install the group coordination surface on the IONOS box. Idempotent: run it again
# after a change and it replaces the code, the skill and the units in place.
#
#   scp -r household scripts deploy root@<box>:/tmp/coordination-release/
#   ssh root@<box> bash /tmp/coordination-release/scripts/coordination-install.sh
#
# What it does NOT do: touch docker-compose.yml, either env file, or any container.
# The relay runs on the host and reads each gateway's state read-only, so nothing
# here needs a restart, a recreate or a shared-config change.
set -euo pipefail

RELEASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The three roots it writes, and the only three. They are overridable so the test
# suite can run this script against a throwaway tree and see what it really touches.
# Prefixed, because this script runs `rm -rf` under them and an operator's shell can
# easily already carry a TARGET or a STATE meant for something else entirely. The
# defaults substitute only when unset, so an explicitly empty root reaches the guard
# below and is refused rather than quietly becoming the production path.
COORDINATION_TARGET="${COORDINATION_TARGET-/opt/household-assistant/coordination}"
COORDINATION_STATE="${COORDINATION_STATE-/var/lib/household-assistant}"
COORDINATION_UNITS="${COORDINATION_UNITS-/etc/systemd/system}"

for root in "${COORDINATION_TARGET}" "${COORDINATION_STATE}" "${COORDINATION_UNITS}"; do
  case "${root}" in
    /*) ;;
    *)
      echo "refusing to install: '${root}' is not an absolute path" >&2
      exit 2
      ;;
  esac
  # A leading slash is not a guard. '/' and '/tmp/..' both have one and both resolve
  # to the filesystem root, and this script runs `rm -rf` under these roots as root:
  # COORDINATION_TARGET=/ would have meant `rm -rf //household` and a scan of the
  # whole filesystem for __pycache__. Canonicalise first, then refuse the root itself
  # and anything too shallow to run rm -rf under. -m because on a first install these
  # directories do not exist yet.
  # Squeezed as well as canonicalised, because `//` is not `/` to realpath: POSIX
  # leaves a leading double slash implementation-defined, so it can come back
  # unchanged and walk straight past a test for "/".
  canonical="$(realpath -m -- "${root}" | tr -s '/')"
  depth="$(printf '%s' "${canonical}" | tr -cd '/' | wc -c)"
  if [[ "${canonical}" == "/" || ${depth} -lt 2 ]]; then
    echo "refusing to install: '${root}' resolves to '${canonical}'," \
      "which is the filesystem root or too shallow to run rm -rf under" >&2
    exit 2
  fi
done

echo "==> code into ${COORDINATION_TARGET}"
install -d -m 0755 "${COORDINATION_TARGET}"
rm -rf "${COORDINATION_TARGET}/household"
cp -r "${RELEASE}/household" "${COORDINATION_TARGET}/household"
install -m 0755 "${RELEASE}/scripts/coordination-daemon.py" "${COORDINATION_TARGET}/coordination-daemon.py"
# The daemon reads the household file through it, from the directory it runs in.
install -m 0644 "${RELEASE}/scripts/gateway_config.py" "${COORDINATION_TARGET}/gateway_config.py"
find "${COORDINATION_TARGET}" -name '__pycache__' -type d -prune -exec rm -rf {} +

echo "==> root-owned calendar reader"
# This closes the window where an assistant can swap the code between planner runs.
# It does not make the code trusted: the installer copies it from an assistant-owned
# workspace, and rerunning the installer is the operator's deliberate refresh action.
install -d -m 0755 "${COORDINATION_TARGET}/calendar"
install -m 0755 \
  "${COORDINATION_STATE}/openclaw/workspace/skills/apple-cal-anywhere/scripts/applecal.py" \
  "${COORDINATION_TARGET}/calendar/applecal.py"
chown root:root "${COORDINATION_TARGET}/calendar" "${COORDINATION_TARGET}/calendar/applecal.py"

echo "==> state directory"
# The relay's own database. On the host, outside both containers, so a
# `docker compose up -d --force-recreate` leaves the off switch exactly as it was.
install -d -m 0700 "${COORDINATION_STATE}/coordination"

echo "==> the coordinate skill, in both workspaces"
for workspace in "${COORDINATION_STATE}/openclaw/workspace" "${COORDINATION_STATE}/openclaw-denise/workspace"; do
  install -d -m 0755 "${workspace}/skills/coordinate"
  install -m 0644 \
    "${RELEASE}/deploy/openclaw/skills/coordinate/SKILL.md" \
    "${workspace}/skills/coordinate/SKILL.md"
  install -m 0755 \
    "${RELEASE}/deploy/openclaw/skills/coordinate/coordinate.py" \
    "${workspace}/skills/coordinate/coordinate.py"
  # The assistant writes here and the daemon reads here. It is inside the state mount
  # the gateway already has, which is why no compose change is needed to reach it.
  install -d -m 0755 "${workspace}/coordination-outbox"
  chown 1000:1000 "${workspace}/skills/coordinate" \
    "${workspace}/skills/coordinate/SKILL.md" "${workspace}/skills/coordinate/coordinate.py" \
    "${workspace}/coordination-outbox"
done

echo "==> systemd units"
install -d -m 0755 "${COORDINATION_UNITS}"
install -m 0644 "${RELEASE}/deploy/coordination/household-coordination@.service" \
  "${COORDINATION_UNITS}"/household-coordination@.service
install -m 0644 "${RELEASE}/deploy/coordination/household-coordination@tick.timer" \
  "${COORDINATION_UNITS}"/household-coordination@tick.timer
install -m 0644 "${RELEASE}/deploy/coordination/household-coordination@plan.timer" \
  "${COORDINATION_UNITS}"/household-coordination@plan.timer
systemctl daemon-reload

echo "==> the relay ticks; the planner does not"
systemctl enable --now household-coordination@tick.timer
# household-coordination@plan.timer stays stopped on purpose. The first proposal goes
# to the CFO, not to the family group. Start it by hand once he has read it:
#   systemctl enable --now household-coordination@plan.timer
systemctl --no-pager status household-coordination@tick.timer | head -5

echo
echo "relay is live. Off switch: type '!coordination off' in the family group."
echo "First planner run, to read rather than to post:"
echo "  systemd-run --pipe --wait --property=EnvironmentFile=/etc/household-assistant/openclaw.env \\"
echo "    --setenv=PYTHONPATH=${COORDINATION_TARGET} /usr/bin/python3 ${COORDINATION_TARGET}/coordination-daemon.py plan --dry-run"
