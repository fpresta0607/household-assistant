#!/usr/bin/env bash
# Install the app's family room on the IONOS box: the household-app plugin into the
# read-only plugin mount, the host relay and the Spend page's spend job, and their systemd
# units. Idempotent: run it again after a change and it replaces each in place.
#
#   scp -r scripts deploy root@<box>:/tmp/household-app-release/
#   ssh root@<box> bash /tmp/household-app-release/scripts/household-app-install.sh
#
# What it does NOT do: touch docker-compose.yml, either env file, either gateway's
# config, or any container. No gateway loads the plugin until
# scripts/openclaw-household-app.py names it in that gateway's config, one gateway at a
# time, so installing changes nothing either assistant does. The relay starts here and
# finds nothing to carry until a gateway writes its first outbox, and the spend job only
# reads a gateway that answers and writes nothing until both have.
set -euo pipefail

RELEASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The roots it writes, overridable so the tests can run it against a throwaway tree.
# The defaults substitute only when unset, so an explicitly empty root reaches the guard
# below and is refused.
HOUSEHOLD_APP_TARGET="${HOUSEHOLD_APP_TARGET-/opt/household-assistant/app-relay}"
HOUSEHOLD_APP_PLUGINS="${HOUSEHOLD_APP_PLUGINS-/opt/household-assistant/plugins}"
HOUSEHOLD_APP_STATE="${HOUSEHOLD_APP_STATE-/var/lib/household-assistant}"
HOUSEHOLD_APP_UNITS="${HOUSEHOLD_APP_UNITS-/etc/systemd/system}"

for root in "${HOUSEHOLD_APP_TARGET}" "${HOUSEHOLD_APP_PLUGINS}" "${HOUSEHOLD_APP_STATE}" "${HOUSEHOLD_APP_UNITS}"; do
  case "${root}" in
    /*) ;;
    *)
      echo "refusing to install: '${root}' is not an absolute path" >&2
      exit 2
      ;;
  esac
  # This runs rm -rf under the plugin root as root, so the root itself and anything too
  # shallow are refused after canonicalising.
  canonical="$(realpath -m -- "${root}" | tr -s '/')"
  depth="$(printf '%s' "${canonical}" | tr -cd '/' | wc -c)"
  if [[ "${canonical}" == "/" || ${depth} -lt 2 ]]; then
    echo "refusing to install: '${root}' resolves to '${canonical}'," \
      "which is the filesystem root or too shallow to run rm -rf under" >&2
    exit 2
  fi
done

echo "==> the plugin into ${HOUSEHOLD_APP_PLUGINS}/household-app"
# Only this plugin, replaced whole. The others in the mount are deployed on their own
# schedule, and pocket-piggies-corey and -denise are copies only the box has.
install -d -m 0755 "${HOUSEHOLD_APP_PLUGINS}"
rm -rf "${HOUSEHOLD_APP_PLUGINS:?}/household-app"
cp -r "${RELEASE}/deploy/openclaw/plugins/household-app" "${HOUSEHOLD_APP_PLUGINS}/household-app"
chown -R root:root "${HOUSEHOLD_APP_PLUGINS}/household-app"
chmod -R u=rwX,go=rX "${HOUSEHOLD_APP_PLUGINS}/household-app"

echo "==> the relay into ${HOUSEHOLD_APP_TARGET}"
install -d -m 0755 "${HOUSEHOLD_APP_TARGET}"
install -m 0755 "${RELEASE}/scripts/household-app-relay.py" "${HOUSEHOLD_APP_TARGET}/household-app-relay.py"
install -m 0755 "${RELEASE}/scripts/household-spend.py" "${HOUSEHOLD_APP_TARGET}/household-spend.py"
install -m 0644 "${RELEASE}/scripts/gateway_config.py" "${HOUSEHOLD_APP_TARGET}/gateway_config.py"

echo "==> its state directory"
# Where the relay keeps what it has carried and the spend job its ledger, root-only and
# outside both containers.
install -d -m 0700 "${HOUSEHOLD_APP_STATE}/coordination"

echo "==> systemd units"
install -d -m 0755 "${HOUSEHOLD_APP_UNITS}"
for unit in household-app-relay.service household-app-relay.path household-app-relay.timer \
  household-spend.service household-spend.timer; do
  install -m 0644 "${RELEASE}/deploy/household-app/${unit}" "${HOUSEHOLD_APP_UNITS}/${unit}"
done
systemctl daemon-reload
systemctl enable --now household-app-relay.path household-app-relay.timer household-spend.timer

echo
echo "household-app is installed. No gateway loads it until:"
echo "  python3 ${RELEASE}/scripts/openclaw-household-app.py apply --gateway corey"
