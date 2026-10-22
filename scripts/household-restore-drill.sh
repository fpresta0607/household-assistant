#!/usr/bin/env bash
# Prove a household backup restores, without touching either live gateway.
#
# Each gateway's archive goes through OpenClaw's own `backup restore`, which verifies
# the manifest, links and every SQLite database before it writes, into a scratch
# directory, and what comes out is read back: both databases opened and checked, the
# files a gateway cannot start or remember without found. The coordination copy is
# opened and its off switch's table queried. household-backup.sh runs this on every
# backup it writes; run it by hand on any other.
#
# usage: household-restore-drill.sh /var/backups/household-assistant/<stamp>
set -euo pipefail

src="${1:?usage: household-restore-drill.sh <backup-dir>}"
OPENCLAW_COMPOSE=/opt/household-assistant/docker-compose.yml
WORK="$(mktemp -d /var/tmp/household-drill.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

fail=0
pass() { printf '  PASS  %s\n' "$1"; }
flunk() { printf '  FAIL  %s\n' "$1"; fail=1; }
manifest() { awk -F'\t' -v k="$1" '$1==k{print $2}' "${src}/MANIFEST.tsv" 2>/dev/null || true; }

echo "=== restore drill of ${src} ==="
if [[ -f ${src}/SHA256SUMS ]] && ( cd "${src}" && sha256sum --quiet -c SHA256SUMS ); then
  pass "stored bytes match SHA256SUMS"
else
  flunk "stored bytes do not match SHA256SUMS, or it is missing"
fi

# The drill is for the day the runtime is damaged, so fall back to the image the
# compose file pins when the gateway is gone.
image="$(docker inspect -f '{{.Config.Image}}' openclaw-gateway 2>/dev/null || true)"
if [[ -z ${image} && -f ${OPENCLAW_COMPOSE} ]]; then
  image="$(awk '$1=="image:"{print $2; exit}' "${OPENCLAW_COMPOSE}" || true)"
fi

# drill_gateway <label>: restore <label>_archive and read it back.
drill_gateway() {
  local label=$1 archive restored
  archive="$(manifest "${label}_archive")"
  echo "--- ${label} ---"
  if [[ ${archive} == none ]]; then
    echo "  not installed when the backup was taken"
    return
  elif [[ -z ${archive} || ${archive} == missing || ! -f ${src}/${archive} ]]; then
    flunk "${label}: the backup holds no archive (${archive:-no manifest entry})"
    return
  elif [[ -z ${image} ]]; then
    flunk "${label}: no openclaw image to restore with"
    return
  fi
  # The backup directory is 0700 root and the image runs as uid 1000.
  # The box has no user named for uid 1000, so it is handed over by number.
  install -d -m 0700 "${WORK}/${label}" "${WORK}/${label}/archive" "${WORK}/${label}/restore"
  install -m 0600 "${src}/${archive}" "${WORK}/${label}/archive/${archive}"
  chown -R 1000:1000 "${WORK}/${label}"
  if docker run --rm --memory 512m --cpus 1.0 \
    -e HOME=/home/node -e OPENCLAW_HOME=/home/node \
    -v "${WORK}/${label}/archive":/archive:ro \
    -v "${WORK}/${label}/restore":/restore \
    --entrypoint node "${image}" \
    dist/index.js backup restore "/archive/${archive}" --target /restore/out >"${WORK}/${label}/restore.log" 2>&1; then
    pass "${label}: backup restore completed"
  else
    flunk "${label}: backup restore did not complete: $(tail -n 1 "${WORK}/${label}/restore.log")"
    return
  fi
  restored="$(find "${WORK}/${label}/restore/out" -type d -path '*/home/node/.openclaw' -print -quit)"
  if [[ -z ${restored} ]]; then
    flunk "${label}: no .openclaw directory in the restored tree"
    return
  fi
  for file in openclaw.json workspace/AGENTS.md workspace/USER.md household-memory/kept.json; do
    if [[ -s ${restored}/${file} ]]; then pass "${label}: restored ${file}"; else flunk "${label}: ${file} missing or empty"; fi
  done
  for database in state/openclaw.sqlite agents/main/agent/openclaw-agent.sqlite; do
    if python3 - "${restored}/${database}" <<'OPENS'; then
import sqlite3
import sys

con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
verdict = con.execute("pragma integrity_check").fetchone()[0]
tables = con.execute("select count(*) from sqlite_master where type = 'table'").fetchone()[0]
if verdict != "ok" or tables == 0:
    sys.exit(f"integrity_check {verdict}, {tables} tables")
print(f"  {tables} tables")
OPENS
      pass "${label}: ${database} opens and passes integrity_check"
    else
      flunk "${label}: ${database} does not open cleanly"
    fi
  done
  local codex
  codex="$(manifest "${label}_codex_archive")"
  [[ ${label} == openclaw ]] && codex="$(manifest codex_archive)"
  if [[ -n ${codex} && ${codex} != missing && -f ${src}/${codex} ]] && tar -tzf "${src}/${codex}" >/dev/null; then
    pass "${label}: codex state archive reads"
  elif [[ ${codex} != none && -n ${codex} ]]; then
    flunk "${label}: codex state archive ${codex} does not read"
  fi
}

drill_gateway openclaw
drill_gateway denise

echo "--- coordination ---"
coordination="$(manifest coordination_archive)"
if [[ ${coordination} == none ]]; then
  echo "  not installed when the backup was taken"
elif [[ -f ${src}/${coordination} ]] && python3 - "${src}/${coordination}" <<'FLAG'; then
import sqlite3
import sys

con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
if con.execute("pragma integrity_check").fetchone()[0] != "ok":
    sys.exit("integrity_check failed")
con.execute("select count(*) from coordination_flag").fetchone()
FLAG
  pass "coordination.db opens and carries the off switch's table"
else
  flunk "coordination.db is missing or does not open"
fi

echo
[[ ${fail} -eq 0 ]] && echo "DRILL PASSED" || { echo "DRILL FAILED"; exit 1; }
