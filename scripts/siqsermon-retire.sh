#!/usr/bin/env bash
# Retires SIQsermon, which is no longer an app: its one remaining job, the assistants'
# scripture, now runs in the gateways (the household-scripture plugin). Two steps, in this
# order, each run as root from a checkout:
#
#   scripts/siqsermon-retire.sh export   # while the gateways are still on SIQsermon's network
#     1. the last backup of SIQsermon's data and both assistants (siqsermon-backup.sh)
#     2. the household's sermons and study plans, read through SIQsermon's backend from
#        inside Corey's gateway, into both gateways' household-scripture/import/
#
#   ... then build the Bible (scripture-build.py --embed), install (openclaw-install.sh,
#   which recreates both gateways off SIQsermon's network) and hand the plugin to both
#   gateways (openclaw-scripture.py apply): docs/deploy/siqsermon-retirement.md ...
#
#   scripts/siqsermon-retire.sh stop
#     3. refuses unless both gateways read the Bible through the plugin and neither is
#        still on SIQsermon's network, then stops SIQsermon's containers. Its files in
#        /opt/siqsermon and /etc/siqsermon stay, so `docker compose up -d` in its deploy
#        directory would bring it back.
set -euo pipefail

SIQ_DIR=/opt/siqsermon/current/deploy
SIQ_ENV=/etc/siqsermon/runtime.env
SIQ_NETWORK=deploy_default
STATE_ROOT=/var/lib/household-assistant
COREY_CONTAINER=openclaw-gateway
IMPORT_IN_CONTAINER=/home/node/.openclaw/household-scripture/import
OC_UID=1000
OC_GID=1000

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export_archive() {
  echo "1. the last backup of SIQsermon's data and both assistants"
  "${here}/siqsermon-backup.sh"

  echo "2. sermons and study plans, from inside ${COREY_CONTAINER}"
  docker exec -i -u node "${COREY_CONTAINER}" python3 - --out "${IMPORT_IN_CONTAINER}" \
    < "${here}/siqsermon-export.py"
  local from="${STATE_ROOT}/openclaw/household-scripture/import"
  local to="${STATE_ROOT}/openclaw-denise/household-scripture/import"
  install -d -m 0700 -o "${OC_UID}" -g "${OC_GID}" "${STATE_ROOT}/openclaw-denise/household-scripture" "${to}"
  for file in siqsermon-sermons.json siqsermon-plans.json; do
    install -m 0600 -o "${OC_UID}" -g "${OC_GID}" "${from}/${file}" "${to}/${file}"
  done
  echo "both gateways keep them the next time the scripture tool is used"
}

stop_siqsermon() {
  echo "3. checking both gateways read the Bible through the plugin"
  if ! python3 "${here}/openclaw-scripture.py" check; then
    echo "refused: finish the scripture plugin first (docs/deploy/siqsermon-retirement.md)" >&2
    exit 1
  fi
  local attached
  attached="$(docker network inspect "${SIQ_NETWORK}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)"
  for container in openclaw-gateway openclaw-denise; do
    if [[ " ${attached} " == *" ${container} "* ]]; then
      echo "refused: ${container} is still on ${SIQ_NETWORK}; run scripts/openclaw-install.sh first" >&2
      exit 1
    fi
  done
  echo "stopping SIQsermon"
  (cd "${SIQ_DIR}" && docker compose --env-file "${SIQ_ENV}" -f docker-compose.prod.yml down)
  echo "SIQsermon is stopped. Its files stay in /opt/siqsermon and /etc/siqsermon, and its last"
  echo "backup is the newest folder in /var/backups/siqsermon."
}

case "${1:-}" in
  export) export_archive ;;
  stop) stop_siqsermon ;;
  *)
    echo "usage: siqsermon-retire.sh export|stop" >&2
    exit 2
    ;;
esac
