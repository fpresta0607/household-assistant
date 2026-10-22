#!/usr/bin/env bash
# Prove a SIQsermon backup actually opens, without touching the live stack.
#
# Everything it creates is named ha-phase0-* and lives on its own docker
# network with no published ports, so no firewall or port change is involved.
# Temp containers carry hard memory limits: on a box with no swap, an
# unbounded rehearsal instance would be a threat to the live databases.
#
# Usage: siqsermon-restore-rehearsal.sh /var/backups/siqsermon/<stamp>
set -euo pipefail

src="${1:?usage: siqsermon-restore-rehearsal.sh <backup-dir>}"
[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

NET=ha-phase0-rehearsal
NEO_VOL=ha-phase0-neo4j
QDR_VOL=ha-phase0-qdrant
NEO_CT=ha-phase0-neo4j-1
QDR_CT=ha-phase0-qdrant-1
WORK=/var/tmp/ha-phase0/rehearsal
OPENCLAW_COMPOSE=/opt/household-assistant/docker-compose.yml

# The drill runs when the live stack is damaged or gone, so a missing container
# is a thing to report, not a reason to die before the first check prints.
neo4j_image="$(docker inspect -f '{{.Config.Image}}' deploy-neo4j-1 2>/dev/null || true)"
qdrant_image="$(docker inspect -f '{{.Config.Image}}' deploy-qdrant-1 2>/dev/null || true)"

cleanup() {
  docker rm -f "${NEO_CT}" "${QDR_CT}" >/dev/null 2>&1 || true
  docker volume rm "${NEO_VOL}" "${QDR_VOL}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT
cleanup

fail=0
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %-34s %s\n' "$1" "$3"
  else
    printf 'FAIL  %-34s expected %s, restored %s\n' "$1" "$2" "$3"; fail=1
  fi
}

# A corrupt artifact, a missing manifest and an absent container are all things
# this drill exists to discover. Every one of them has to reach the verdict at
# the bottom rather than abort the script under errexit on the way there.
for required in SHA256SUMS MANIFEST.tsv neo4j.dump app.db app_data.tar.gz \
                runtime.env sqlite-counts.tsv; do
  [[ -f "${src}/${required}" ]] \
    || { echo "FAIL  ${required} missing from ${src}"; fail=1; }
done
for c in deploy-neo4j-1:"${neo4j_image}" deploy-qdrant-1:"${qdrant_image}"; do
  [[ -n ${c#*:} ]] \
    || { echo "FAIL  ${c%%:*} is not present, so the drill cannot name its image"; fail=1; }
done
[[ ${fail} -eq 0 ]] || { echo; echo "REHEARSAL FAILED"; exit 1; }

echo "=== 0. stored bytes match the recorded checksums ==="
if ! ( cd "${src}" && sha256sum -c SHA256SUMS ) | sed 's/^/  /'; then
  echo "  FAIL  stored bytes do not match SHA256SUMS"; fail=1
fi

manifest() { awk -F'\t' -v k="$1" '$1==k{print $2}' "${src}/MANIFEST.tsv" || true; }
snapshot="$(manifest qdrant_snapshot)"
want_nodes="$(manifest neo4j_nodes)"
want_rels="$(manifest neo4j_relationships)"
want_points="$(manifest qdrant_verses_points)"
[[ -n ${snapshot} && -f "${src}/${snapshot}" ]] || {
  echo "FAIL  the qdrant snapshot named in the manifest is missing"
  echo; echo "REHEARSAL FAILED"; exit 1; }

mkdir -p "${WORK}"
docker network create "${NET}" >/dev/null
docker volume create "${NEO_VOL}" >/dev/null
docker volume create "${QDR_VOL}" >/dev/null

echo
echo "=== 1. neo4j: load the dump into a fresh store ==="
# The backup dir is 0700 root, and the neo4j image runs as uid 7474, so stage
# the dump somewhere it can traverse rather than loosening the backup.
mkdir -p "${WORK}/neo4j-dump" && chmod 755 "${WORK}" "${WORK}/neo4j-dump"
cp "${src}/neo4j.dump" "${WORK}/neo4j-dump/neo4j.dump"
chmod 644 "${WORK}/neo4j-dump/neo4j.dump"
docker run --rm \
  -v "${NEO_VOL}":/data -v "${WORK}/neo4j-dump":/backup:ro \
  "${neo4j_image}" \
  neo4j-admin database load neo4j --from-path=/backup --overwrite-destination=true \
  2>&1 | grep -vE '^(Files:|$)' | sed 's/^/  /' || true

# NEO4J_AUTH=none: the dump carries the neo4j database, not the system
# database that holds credentials, so the rehearsal instance has no users of
# its own and the production password is never handled here.
docker run -d --name "${NEO_CT}" --network "${NET}" \
  --memory 1200m --cpus 1.0 \
  -e NEO4J_AUTH=none \
  -e NEO4J_server_memory_heap_max__size=512m \
  -e NEO4J_server_memory_pagecache_size=256m \
  -v "${NEO_VOL}":/data \
  "${neo4j_image}" >/dev/null

echo "  waiting for the rehearsal instance to open the store"
for _ in $(seq 60); do
  docker exec "${NEO_CT}" cypher-shell --format plain 'RETURN 1;' >/dev/null 2>&1 && break
  sleep 5
done

rq() { docker exec "${NEO_CT}" cypher-shell --format plain "$1" | tail -n +2; }
check "neo4j nodes"         "${want_nodes}"  "$(rq 'MATCH (n) RETURN count(n);')"
check "neo4j relationships" "${want_rels}"   "$(rq 'MATCH ()-[r]->() RETURN count(r);')"
echo "  label breakdown from the restored store:"
rq 'CALL db.labels() YIELD label CALL { WITH label MATCH (n) WHERE label IN labels(n) RETURN count(n) AS c } RETURN label + " " + toString(c) ORDER BY label;' \
  | tr -d '"' | sed 's/^/    /' || true

echo
echo "=== 2. qdrant: recover the collection from the snapshot at startup ==="
mkdir -p "${WORK}/qdrant-snap" && chmod 755 "${WORK}/qdrant-snap"
cp "${src}/${snapshot}" "${WORK}/qdrant-snap/${snapshot}"
chmod 644 "${WORK}/qdrant-snap/${snapshot}"
docker run -d --name "${QDR_CT}" --network "${NET}" \
  --memory 768m --cpus 1.0 \
  -v "${QDR_VOL}":/qdrant/storage -v "${WORK}/qdrant-snap":/backup:ro \
  "${qdrant_image}" \
  ./qdrant --snapshot "/backup/${snapshot}:verses" >/dev/null

qip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${QDR_CT}" 2>/dev/null || true)"
echo "  waiting for the rehearsal instance to finish recovery"
for _ in $(seq 60); do
  curl -sf "http://${qip}:6333/collections/verses" >/dev/null 2>&1 && break
  sleep 5
done
got_points="$(curl -sf "http://${qip}:6333/collections/verses" | jq -r '.result.points_count')" || got_points=
check "qdrant verses points" "${want_points}" "${got_points}"
echo "  a restored vector answers a real search:"
curl -sf "http://${qip}:6333/collections/verses/points/scroll" \
  -H 'content-type: application/json' -d '{"limit":1,"with_payload":true}' \
  | jq -c '.result.points[0].payload' | sed 's/^/    /' || true

echo
echo "=== 3. sqlite: open the backup copy and count ==="
tmpdb="${WORK}/app.db"
mkdir -p "${WORK}" && cp "${src}/app.db" "${tmpdb}"
if ! python3 - "${tmpdb}" "${src}/sqlite-counts.tsv" <<'PY' | sed 's/^/  /'
import sqlite3, sys
db, expected_file = sys.argv[1:3]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
print("integrity_check", con.execute("pragma integrity_check").fetchone()[0])
expected = dict(l.rstrip("\n").split("\t") for l in open(expected_file) if l.strip())
bad = 0
for table, want in sorted(expected.items()):
    got = con.execute('select count(*) from "%s"' % table).fetchone()[0]
    ok = "PASS" if str(got) == want else "FAIL"
    bad += ok == "FAIL"
    print(f"{ok}  sqlite {table:<26} {got}")
# The rows have to be readable, not just countable.
print("sample project titles:",
      [r[0] for r in con.execute("select * from projects limit 3")])
sys.exit(1 if bad else 0)
PY
then fail=1; fi

echo
echo "=== 4. app_data archive extracts and carries the real files ==="
mkdir -p "${WORK}/app_data"
if ! tar -xzf "${src}/app_data.tar.gz" -C "${WORK}/app_data"; then
  echo "  FAIL  app_data.tar.gz does not extract"; fail=1
fi
for f in app.db BSB.json theographic-bible-metadata-master; do
  [[ -e "${WORK}/app_data/${f}" ]] && printf '  PASS  app_data/%s\n' "${f}" \
    || { printf '  FAIL  app_data/%s missing\n' "${f}"; fail=1; }
done
printf '  voice samples restored: %s\n' "$(find "${WORK}/app_data/voice" -type f | wc -l)"
printf '  sermon/presentation dirs: %s\n' "$(ls "${WORK}/app_data/presentations" | wc -l)"

echo
echo "=== 5. runtime.env restored, contents never printed ==="
printf '  bytes=%s mode=%s keys=%s\n' \
  "$(stat -c %s "${src}/runtime.env")" "$(stat -c %a "${src}/runtime.env")" \
  "$(grep -cE '^[A-Za-z_]+=' "${src}/runtime.env")"

echo
echo "=== 6. assistant state restores into a scratch location and opens ==="
openclaw_archive="$(manifest openclaw_archive)"
if [[ ${openclaw_archive} == missing ]]; then
  echo "  FAIL  the backup recorded the assistant state as missing"; fail=1
elif [[ -z ${openclaw_archive} || ${openclaw_archive} == none ]]; then
  echo "  this backup predates OpenClaw, nothing to restore"
elif [[ ! -f "${src}/${openclaw_archive}" ]]; then
  echo "  FAIL  the manifest names ${openclaw_archive} but it is not in the backup"; fail=1
else
  # Same staging reason as neo4j above: the backup dir is 0700 root and the
  # image runs as uid 1000.
  mkdir -p "${WORK}/openclaw-archive" "${WORK}/openclaw-restore"
  cp "${src}/${openclaw_archive}" "${WORK}/openclaw-archive/"
  chmod 700 "${WORK}/openclaw-archive" "${WORK}/openclaw-restore"
  chmod 600 "${WORK}/openclaw-archive/${openclaw_archive}"
  chown -R 1000:1000 "${WORK}/openclaw-archive" "${WORK}/openclaw-restore"
  # The drill exists for the case where the runtime is gone, so fall back to
  # the pinned image the compose file declares.
  openclaw_image="$(docker inspect -f '{{.Config.Image}}' openclaw-gateway 2>/dev/null || true)"
  if [[ -z ${openclaw_image} && -f ${OPENCLAW_COMPOSE} ]]; then
    openclaw_image="$(awk '$1=="image:"{print $2}' "${OPENCLAW_COMPOSE}")"
  fi
  # `backup restore` verifies the manifest, hardlinks, symlink containment and
  # every SQLite database before it writes anything, and refuses a target that
  # is not empty. It stages files only; it never touches live state.
  if [[ -z ${openclaw_image} ]]; then
    echo "  FAIL  no openclaw image: neither the gateway container nor ${OPENCLAW_COMPOSE}"
    echo "        names one. Re-run scripts/openclaw-install.sh to reinstate the"
    echo "        deployed compose file, then run this drill again."; fail=1
  elif ! docker run --rm --memory 512m --cpus 1.0 \
    -e HOME=/home/node -e OPENCLAW_HOME=/home/node \
    -v "${WORK}/openclaw-archive":/archive:ro \
    -v "${WORK}/openclaw-restore":/restore \
    --entrypoint node "${openclaw_image}" \
    dist/index.js backup restore "/archive/${openclaw_archive}" --target /restore/out \
    2>&1 | sed 's/^/  /'
  then
    echo "  FAIL  backup restore did not complete"; fail=1
  fi

  restored_db="$(find "${WORK}/openclaw-restore/out" -name openclaw.sqlite -print -quit 2>/dev/null || true)"
  if [[ -z ${restored_db} ]]; then
    echo "  FAIL  no openclaw.sqlite in the restored tree"; fail=1
  else
    python3 - "${restored_db}" <<'PY' | sed 's/^/  /' || fail=1
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
integrity = con.execute("pragma integrity_check").fetchone()[0]
print(f"{'PASS' if integrity == 'ok' else 'FAIL'}  openclaw.sqlite integrity_check {integrity}")
tables = [t for (t,) in con.execute(
    "select name from sqlite_master where type='table' order by name")]
print(f"{'PASS' if tables else 'FAIL'}  openclaw.sqlite tables {len(tables)}")
sys.exit(0 if integrity == "ok" and tables else 1)
PY
  fi
  for f in openclaw.json workspace/IDENTITY.md workspace/AGENTS.md; do
    if find "${WORK}/openclaw-restore/out" -path "*/${f}" 2>/dev/null | grep -q .; then
      printf '  PASS  restored %s\n' "${f}"
    else
      printf '  FAIL  restored %s missing\n' "${f}"; fail=1
    fi
  done
fi

echo
[[ ${fail} -eq 0 ]] && echo "REHEARSAL PASSED" || { echo "REHEARSAL FAILED"; exit 1; }
