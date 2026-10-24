#!/usr/bin/env bash
# Install the app's family room on the IONOS box: the household-app plugin into the
# read-only plugin mount, and the Spend page's spend job and its systemd units. Idempotent:
# run it again after a change and it replaces each in place. The host relay that carried
# the family room between the gateways until each read the other's share itself
# (household-app's peer-link.js) is taken away, with its units.
#
#   scp -r scripts deploy root@<box>:/tmp/household-app-release/
#   ssh root@<box> bash /tmp/household-app-release/scripts/household-app-install.sh
#
# What it does NOT do: touch docker-compose.yml, either env file, either gateway's
# config, or any container. No gateway loads the plugin until
# scripts/openclaw-household-app.py names it in that gateway's config, one gateway at a
# time, so installing changes nothing either assistant does. The spend job only reads a
# gateway that answers and writes nothing until both have.
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

echo "==> the spend job into ${HOUSEHOLD_APP_TARGET}"
install -d -m 0755 "${HOUSEHOLD_APP_TARGET}"
install -m 0755 "${RELEASE}/scripts/household-spend.py" "${HOUSEHOLD_APP_TARGET}/household-spend.py"
install -m 0644 "${RELEASE}/scripts/gateway_config.py" "${HOUSEHOLD_APP_TARGET}/gateway_config.py"
install -m 0644 "${RELEASE}/scripts/household_file.py" "${HOUSEHOLD_APP_TARGET}/household_file.py"
rm -f "${HOUSEHOLD_APP_TARGET}/household-app-relay.py"

echo "==> its state directory"
# Where the spend job keeps its ledger, root-only and outside both containers.
install -d -m 0700 "${HOUSEHOLD_APP_STATE}/coordination"

echo "==> systemd units"
install -d -m 0755 "${HOUSEHOLD_APP_UNITS}"
# The host relay's, from before the gateways read each other's share, go first.
relay_units=(household-app-relay.path household-app-relay.timer household-app-relay.service)
systemctl disable --now "${relay_units[@]}" 2>/dev/null || true
for unit in "${relay_units[@]}"; do
  rm -f "${HOUSEHOLD_APP_UNITS:?}/${unit}"
done
for unit in household-spend.service household-spend.timer; do
  install -m 0644 "${RELEASE}/deploy/household-app/${unit}" "${HOUSEHOLD_APP_UNITS}/${unit}"
done
systemctl daemon-reload
systemctl enable --now household-spend.timer

echo
echo "household-app is installed. No gateway loads it until:"
echo "  python3 ${RELEASE}/scripts/openclaw-household-app.py apply --gateway corey"
