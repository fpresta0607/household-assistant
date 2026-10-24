#!/usr/bin/env bash
# Bring a household's box to this checkout and prove it: both gateways, their plugins and
# config, the Bible, the tailnet, the nightly backup, then openclaw-verify.sh on each.
#
# Run as root on the box, from the checkout:
#   scripts/household-converge.sh
#
# Every step is idempotent, so a pass that stopped can be run again from the start. It
# exits non-zero when any step fails or any gateway does not verify, which is the verdict
# scripts/household-update.py acts on: a release whose pass fails is rolled back.
#
# It runs only on a box whose household file names its members (scripts/household_file.py).
# The first household's box, whose file names none, carries PocketPiggies, Home Assistant
# and the rest of what docs/deploy/openclaw.md describes, and is brought up to a release by
# hand, under its rollout lock, as that document says.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The roots it writes, overridable so the tests can run it against a throwaway tree. Each
# step it runs refuses to go on as anyone but root.
STATE_ROOT="${HOUSEHOLD_STATE_ROOT-/var/lib/household-assistant}"
BIBLE="${STATE_ROOT}/scripture/bible.sqlite"
BACKUP_DIR="${HOUSEHOLD_BACKUP_DIR-/opt/household-assistant/backup}"
UNITS="${HOUSEHOLD_UNITS-/etc/systemd/system}"

step() { printf '\n==> %s\n' "$*"; }

if ! python3 "${here}/household_file.py" has-members; then
  echo "this box's household file names no members: it is the first household's, which is" >&2
  echo "brought up to a release by hand (docs/deploy/openclaw.md, Bringing the box up to this)" >&2
  exit 2
fi
members="$(python3 "${here}/household_file.py" members)"
personas=()
while IFS=$'\t' read -r _ assistant _; do personas+=("${assistant}"); done <<<"${members}"

# Every model route goes to OpenRouter on the household's own key, which the setup typed
# into each env file; without it nothing below can answer.
while IFS=$'\t' read -r _ assistant _ _ _ _ env_file _; do
  if ! grep -q '^OPENROUTER_API_KEY=.' "${env_file}" 2>/dev/null; then
    echo "${assistant} has no OpenRouter key in ${env_file}; run scripts/household-setup.py first" >&2
    exit 1
  fi
done <<<"${members}"

# The household's key for the publisher's push relay, made once, before the gateways are
# made so each reads it from its env file. It prints the one line the household sends the
# publisher, every time, until the publisher has let the household in.
if python3 "${here}/household_file.py" has-push-relay; then
  step "the household's key for the push relay"
  python3 "${here}/household-push-key.py"
fi

step "the gateways, their skills and plugins"
"${here}/openclaw-install.sh"

if [[ ! -s ${BIBLE} ]]; then
  step "the Bible, built once from its public sources"
  first_env="$(head -n 1 <<<"${members}" | cut -f7)"
  python3 "${here}/scripture-build.py" --embed --env-file "${first_env}"
fi

step "every model route to OpenRouter"
python3 "${here}/openclaw-openrouter.py" apply

step "the household app's plugin and spend job"
bash "${here}/household-app-install.sh"

for persona in "${personas[@]}"; do
  step "${persona}: memory, the app, scripture, speech, pictures, the tailnet and the heartbeat"
  python3 "${here}/openclaw-memory.py" apply --gateway "${persona}"
  python3 "${here}/openclaw-household-app.py" apply --gateway "${persona}"
  python3 "${here}/openclaw-scripture.py" apply --gateway "${persona}"
  python3 "${here}/openclaw-speech.py" apply --gateway "${persona}"
  python3 "${here}/openclaw-pictures.py" apply --gateway "${persona}"
  python3 "${here}/openclaw-box.py" apply --gateway "${persona}"
done

step "each gateway on the household's tailnet"
# HTTPS on the box's tailnet name, proxied to each loopback port, for the tailnet only:
# never `tailscale funnel`, which openclaw-verify.sh fails on.
while IFS=$'\t' read -r _ _ _ _ port _; do
  tailscale serve --bg --https="${port}" "http://127.0.0.1:${port}" >/dev/null </dev/null
done <<<"${members}"

step "the nightly backup"
install -d -m 0755 "${BACKUP_DIR}" "${UNITS}"
for script in household-backup.sh household-restore-drill.sh; do
  install -m 0755 "${here}/${script}" "${BACKUP_DIR}/${script}"
done
install -m 0644 "${here}/household-backup-lib.sh" "${here}/household_file.py" "${BACKUP_DIR}/"
install -m 0644 "${here}/../deploy/backup/household-backup.service" \
  "${here}/../deploy/backup/household-backup.timer" "${UNITS}/"
systemctl daemon-reload
systemctl enable --now household-backup.timer >/dev/null

step "every gateway, end to end"
# A box that holds only the household's gateways listens to the world on nothing and lets
# in only SSH, and its calendars come through the app.
failed=0
while IFS=$'\t' read -r _ assistant container _ port state _; do
  echo "--- ${assistant}"
  WORLD_PORTS="" UFW_RULES="22/tcp" CALENDAR_LIBRARY=skip \
    CT="${container}" PORT="${port}" STATE="${state}" \
    "${here}/openclaw-verify.sh" </dev/null || failed=1
done <<<"${members}"
if [[ ${failed} -ne 0 ]]; then
  echo "the box did not verify" >&2
  exit 1
fi
echo
echo "HOUSEHOLD CONVERGED"
