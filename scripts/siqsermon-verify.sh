#!/usr/bin/env bash
# Step 4: is SIQsermon unharmed?
#
# Checks the things that would actually be broken by a memory change: the
# public endpoint over TLS, all four containers healthy, a real login, a
# project loading with its conversation, and the record counts still matching
# the backup manifest. Also re-reads ports and firewall, which this phase must
# never have touched.
#
# Usage: siqsermon-verify.sh /var/backups/siqsermon/<stamp>
set -euo pipefail

src="${1:?usage: siqsermon-verify.sh <backup-dir>}"
fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'PASS  %-32s %s\n' "$1" "$3"
          else printf 'FAIL  %-32s expected %s, got %s\n' "$1" "$2" "$3"; fail=1; fi }

echo "=== containers ==="
for c in deploy-caddy-1 deploy-backend-1 deploy-neo4j-1 deploy-qdrant-1; do
  check "${c} health" healthy "$(docker inspect -f '{{.State.Health.Status}}' "${c}")"
  check "${c} oom-killed" false "$(docker inspect -f '{{.State.OOMKilled}}' "${c}")"
done

echo
echo "=== memory per container ==="
printf '%-20s %-14s %-12s %-12s\n' container working_set cgroup_peak limit
for c in deploy-neo4j-1 deploy-backend-1 deploy-qdrant-1 deploy-caddy-1; do
  id="$(docker inspect -f '{{.Id}}' "${c}")"
  d="/sys/fs/cgroup/system.slice/docker-${id}.scope"
  printf '%-20s %-14s %-12s %-12s\n' "${c}" \
    "$(docker stats --no-stream --format '{{.MemUsage}}' "${c}" | cut -d' ' -f1)" \
    "$(( $(cat "${d}/memory.peak") / 1048576 ))MiB" \
    "$(( $(cat "${d}/memory.max") / 1048576 ))MiB"
done

echo
echo "=== public endpoint and a real user path ==="
/var/tmp/ha-phase0/siqsermon-exercise.sh | sed -n '1,/^retrieval/p;$p'

echo
echo "=== record counts still match the backup manifest ==="
qip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' deploy-qdrant-1)"
cy() { docker exec deploy-neo4j-1 bash -c \
  "cypher-shell -u neo4j -p \"\${NEO4J_AUTH#*/}\" --format plain \"$1\"" | tail -n +2; }
want() { awk -F'\t' -v k="$1" '$1==k{print $2}' "${src}/MANIFEST.tsv"; }
check "neo4j nodes"         "$(want neo4j_nodes)"          "$(cy 'MATCH (n) RETURN count(n);')"
check "neo4j relationships" "$(want neo4j_relationships)"  "$(cy 'MATCH ()-[r]->() RETURN count(r);')"
check "qdrant verses points" "$(want qdrant_verses_points)" \
  "$(curl -sf "http://${qip}:6333/collections/verses" | jq -r '.result.points_count')"
for t in account_settings messages planning_revisions projects sermons; do
  check "sqlite ${t}" "$(want "sqlite_${t}")" \
    "$(docker exec deploy-backend-1 python -c "import sqlite3;print(sqlite3.connect('/app/data/app.db').execute('select count(*) from \"${t}\"').fetchone()[0])")"
done

echo
echo "=== nothing in the network path moved ==="
check "ufw" active "$(ufw status | awk 'NR==1{print $2}')"
check "ufw rules" "22/tcp 80/tcp 443/tcp" \
  "$(ufw status | awk '/ALLOW/ {print $1}' | sort -uV | tr '\n' ' ' | sed 's/ $//')"
check "published ports" "80 443" \
  "$(docker ps --format '{{.Ports}}' | grep -oE '(0\.0\.0\.0|\[::\]):[0-9]+' | sed -E 's/.*://' | sort -un | tr '\n' ' ' | sed 's/ $//')"
check "caddyfile" "$(sha256sum /opt/siqsermon/repository/deploy/Caddyfile | cut -d' ' -f1)" \
  "$(sha256sum /opt/siqsermon/current/deploy/Caddyfile | cut -d' ' -f1)"

echo
echo "=== swap ==="
check "swap active" "/swapfile" "$(swapon --show=NAME --noheadings)"
check "swap size" "4G" "$(swapon --show=SIZE --noheadings)"
check "swappiness" "10" "$(sysctl -n vm.swappiness)"
check "swap unit generated from fstab" "active" "$(systemctl is-active swapfile.swap)"

echo
[[ ${fail} -eq 0 ]] && echo "SIQSERMON VERIFIED" || { echo "VERIFICATION FAILED"; exit 1; }
