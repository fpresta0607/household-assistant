#!/usr/bin/env bash
# Database-consistent backup of the stateful services on the shared VPS:
# the SIQsermon stack, the assistant state once OpenClaw is installed, and the
# coordination relay's own database, which lives outside both gateways.
#
# ponytail: the destination is still /var/backups/siqsermon/<stamp>/ because
# Phase 0 named it when SIQsermon was the only service and the Phase 0 runbook
# points at that path. Rename the root, and this script with it, the next time
# something else has to change here.
#
# Neo4j Community has no online backup, so its database is stopped for the
# duration of the dump and started again afterwards. Caddy and port 443 are
# never touched, so the site stays reachable; the backend returns errors for
# graph queries during the window.
#
# Writes to /var/backups/siqsermon/<utc-timestamp>/ and prints nothing from
# runtime.env. Run as root on the box.
set -euo pipefail

RUNTIME_ENV=/etc/siqsermon/runtime.env
COMPOSE_FILE=/opt/siqsermon/current/deploy/docker-compose.prod.yml
BACKUP_ROOT=/var/backups/siqsermon

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=household-backup-lib.sh
source "${here}/household-backup-lib.sh"
[[ -f ${RUNTIME_ENV} ]] || { echo "missing ${RUNTIME_ENV}" >&2; exit 1; }

compose() {
  RUNTIME_ENV_FILE="${RUNTIME_ENV}" docker compose \
    --env-file "${RUNTIME_ENV}" -f "${COMPOSE_FILE}" "$@"
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${BACKUP_ROOT}/${stamp}"
mkdir -p "${dest}"
chmod 700 "${BACKUP_ROOT}" "${dest}"
echo "backup destination ${dest}"

neo4j_image="$(docker inspect -f '{{.Config.Image}}' deploy-neo4j-1)"
qdrant_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' deploy-qdrant-1)"
app_data_dir="$(docker volume inspect -f '{{.Mountpoint}}' deploy_app_data)"

# Where this script fails fast and where it must not, because the distinction
# has been rediscovered twice in review:
#
#   Acquiring SIQsermon's data (everything down to runtime.env) fails fast. If
#   the graph, the snapshot or app.db cannot be read there is no backup to
#   write, and the half-filled timestamped directory it leaves is obviously
#   incomplete: it has no MANIFEST.tsv and no SHA256SUMS, so nothing can mistake
#   it for a good one.
#
#   Everything after that point may not abort. SIQsermon's data is on disk by
#   then, and an assistant that is missing or failing to archive must never cost
#   SIQsermon the manifest and checksums that make its dump restorable.

# --- source counts, recorded before anything moves -------------------------
echo "recording source counts"
cypher() {
  docker exec deploy-neo4j-1 bash -c \
    "cypher-shell -u neo4j -p \"\${NEO4J_AUTH#*/}\" --format plain \"$1\"" | tail -n +2
}
nodes="$(cypher 'MATCH (n) RETURN count(n);')"
rels="$(cypher 'MATCH ()-[r]->() RETURN count(r);')"
points="$(curl -sf "http://${qdrant_ip}:6333/collections/verses" | jq -r '.result.points_count')"

python3 - "${app_data_dir}/app.db" "${dest}/app.db" "${dest}/sqlite-counts.tsv" <<'PY'
import sqlite3, sys
src, out, counts = sys.argv[1:4]
live = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
# sqlite3's online backup API is consistent against a concurrently written db.
copy = sqlite3.connect(out)
live.backup(copy)
copy.close()
# Read-write: the copy inherits the live database's WAL, and only a read-write
# connection checkpoints it away on close instead of leaving -wal and -shm to be hashed.
copy = sqlite3.connect(out)
assert copy.execute("pragma integrity_check").fetchone()[0] == "ok"
tables = [t for (t,) in copy.execute(
    "select name from sqlite_master where type='table' order by name")]
with open(counts, "w") as fh:
    for t in tables:
        n = copy.execute('select count(*) from "%s"' % t).fetchone()[0]
        fh.write("%s\t%s\n" % (t, n))
copy.close()
PY

# --- neo4j: offline dump ---------------------------------------------------
echo "stopping neo4j for a consistent dump"
# The image drops to its own uid, so hand it a dir it can write to.
mkdir -p "${dest}/neo4j-dump" && chmod 777 "${dest}/neo4j-dump"
compose stop neo4j
# A failed dump must not leave the database down.
trap 'compose up -d --wait neo4j || true' EXIT
docker run --rm \
  -v deploy_neo4j_data:/data -v "${dest}/neo4j-dump":/backup \
  "${neo4j_image}" \
  neo4j-admin database dump neo4j --to-path=/backup
echo "starting neo4j"
compose up -d --wait neo4j
trap - EXIT
mv "${dest}/neo4j-dump/neo4j.dump" "${dest}/neo4j.dump"
rmdir "${dest}/neo4j-dump"

# --- qdrant: snapshot ------------------------------------------------------
echo "taking qdrant snapshot"
snap_json="$(curl -sf -X POST "http://${qdrant_ip}:6333/collections/verses/snapshots")"
snapshot="$(jq -r '.result.name' <<<"${snap_json}")"
snap_checksum="$(jq -r '.result.checksum' <<<"${snap_json}")"
# Snapshots land in /qdrant/snapshots, which the stack does not mount as a
# volume, so they come out of the container layer rather than off the host.
docker cp "deploy-qdrant-1:/qdrant/snapshots/verses/${snapshot}" "${dest}/${snapshot}"
copied_checksum="$(sha256sum "${dest}/${snapshot}" | cut -d' ' -f1)"
[[ "${copied_checksum}" == "${snap_checksum}" ]] || {
  echo "qdrant snapshot checksum mismatch" >&2; exit 1; }
# The snapshot inside qdrant is our artifact, not user data; drop it so the
# container does not carry a second copy of the collection.
curl -sf -X DELETE "http://${qdrant_ip}:6333/collections/verses/snapshots/${snapshot}" >/dev/null

# --- application data volume and runtime env -------------------------------
echo "archiving app_data"
tar -czf "${dest}/app_data.tar.gz" -C "${app_data_dir}" .
cp "${RUNTIME_ENV}" "${dest}/runtime.env"
chmod 600 "${dest}/runtime.env"

# --- assistant state ---------------------------------------------------------
# SIQsermon's data is already on disk by now, so nothing below may abort the run: an
# assistant that is missing or failing to archive is recorded in the manifest and
# reported by the exit code at the very end. household-backup-lib.sh says how.
openclaw_failed=0
archive_assistant openclaw openclaw-gateway "${OPENCLAW_STATE}" "${OPENCLAW_SECRETS}" "${OPENCLAW_CODEX}"
archive_assistant denise openclaw-denise "${DENISE_STATE}" "${DENISE_SECRETS}" "${DENISE_CODEX}"
archive_coordination

# --- manifest --------------------------------------------------------------
cat > "${dest}/MANIFEST.tsv" <<EOF
taken_at_utc	${stamp}
neo4j_nodes	${nodes}
neo4j_relationships	${rels}
qdrant_verses_points	${points}
qdrant_snapshot	${snapshot}
openclaw_archive	${openclaw_archive}
codex_archive	${openclaw_codex_archive}
denise_archive	${denise_archive}
denise_codex_archive	${denise_codex_archive}
coordination_archive	${coordination_archive}
EOF
cat "${dest}/sqlite-counts.tsv" | sed 's/^/sqlite_/' >> "${dest}/MANIFEST.tsv"

( cd "${dest}" && sha256sum ./* > "${dest}.sums" && mv "${dest}.sums" SHA256SUMS && chmod 600 SHA256SUMS )
ls -l "${dest}"
echo
echo "MANIFEST:"; cat "${dest}/MANIFEST.tsv"
echo
echo "backup complete: ${dest}"
[[ ${openclaw_failed} -eq 0 ]] || {
  echo "SIQsermon data is backed up; the assistant state is not" >&2; exit 1; }
