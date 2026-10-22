#!/usr/bin/env bash
# Prove the proposed neo4j limits before they are proposed.
#
# Lowering a container's memory limit without lowering the JVM's heap and page
# cache does not remove the risk, it moves it: the JVM still believes it may
# take heap + pagecache, and the kernel kills it at the new, lower ceiling.
# So this starts a throwaway neo4j on a copy of the real dump, with exactly
# the settings the pull request proposes, and runs the query shapes the app
# runs against it.
#
# Usage: neo4j-limit-validation.sh /var/backups/siqsermon/<stamp>
set -euo pipefail

src="${1:?usage: neo4j-limit-validation.sh <backup-dir>}"
[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# The proposed configuration, kept in one place so it is obvious what is
# being validated.
HEAP=512m
PAGECACHE=512m
LIMIT=1792m

VOL=ha-phase0-limitcheck
CT=ha-phase0-limitcheck-1
WORK=/var/tmp/ha-phase0/limitcheck

cleanup() {
  docker rm -f "${CT}" >/dev/null 2>&1 || true
  docker volume rm "${VOL}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT
cleanup

image="$(docker inspect -f '{{.Config.Image}}' deploy-neo4j-1)"
mkdir -p "${WORK}/dump" && chmod -R 755 "${WORK}"
cp "${src}/neo4j.dump" "${WORK}/dump/neo4j.dump" && chmod 644 "${WORK}/dump/neo4j.dump"
docker volume create "${VOL}" >/dev/null

echo "loading the real store into a throwaway volume"
docker run --rm -v "${VOL}":/data -v "${WORK}/dump":/backup:ro "${image}" \
  neo4j-admin database load neo4j --from-path=/backup --overwrite-destination=true \
  2>&1 | grep -E 'Done:' | sed 's/^/  /'

echo "starting neo4j with heap=${HEAP} pagecache=${PAGECACHE} under --memory ${LIMIT}"
docker run -d --name "${CT}" --memory "${LIMIT}" --memory-swappiness 10 \
  -e NEO4J_AUTH=none \
  -e NEO4J_server_memory_heap_initial__size="${HEAP}" \
  -e NEO4J_server_memory_heap_max__size="${HEAP}" \
  -e NEO4J_server_memory_pagecache_size="${PAGECACHE}" \
  -v "${VOL}":/data "${image}" >/dev/null

for _ in $(seq 60); do
  docker exec "${CT}" cypher-shell --format plain 'RETURN 1;' >/dev/null 2>&1 && break
  sleep 5
done

q() { docker exec "${CT}" cypher-shell --format plain "$1" | tail -n +2; }

echo "the store opens and the data is all there:"
printf '  nodes         %s\n' "$(q 'MATCH (n) RETURN count(n);')"
printf '  relationships %s\n' "$(q 'MATCH ()-[r]->() RETURN count(r);')"

echo "the query shapes the retrieval path uses, repeated to warm the page cache:"
for round in 1 2 3; do
  start=$(date +%s%N)
  q 'MATCH (v:Verse)-[:HAS_RENDERING]->(t:TranslationRendering) RETURN count(t);' >/dev/null 2>&1 \
    || q 'MATCH (v:Verse)--(t:TranslationRendering) RETURN count(t);' >/dev/null
  q 'MATCH (p:Person)--(e:Event) RETURN count(*);' >/dev/null
  q 'MATCH (v:Verse) WHERE v.osis STARTS WITH "Ps.23" RETURN count(v);' >/dev/null
  q 'MATCH (n) RETURN count(n);' >/dev/null
  q 'MATCH ()-[r]->() RETURN count(r);' >/dev/null
  end=$(date +%s%N)
  usage="$(docker stats --no-stream --format '{{.MemUsage}}' "${CT}")"
  printf '  round %s  %5s ms  mem %s\n' "${round}" "$(( (end-start)/1000000 ))" "${usage}"
done

id="$(docker inspect -f '{{.Id}}' "${CT}")"
peak="$(cat "/sys/fs/cgroup/system.slice/docker-${id}.scope/memory.peak")"
echo
printf 'peak under the proposed limit: %s MiB of %s\n' \
  "$(( peak / 1048576 ))" "${LIMIT}"
printf 'oom kills during the run: %s\n' \
  "$(docker inspect -f '{{.State.OOMKilled}}' "${CT}")"
docker exec "${CT}" bash -c 'grep -iE "page cache|heap.max|heap.initial" /logs/debug.log | tail -4' \
  2>/dev/null | sed 's/^ *//' | sed 's/^/  /'
