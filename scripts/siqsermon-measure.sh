#!/usr/bin/env bash
# Measure every container on the box under the same load Phase 0 used, so a
# ceiling can be set from a measurement rather than from a guess.
#
# The load is Phase 0's exactly: 30 iterations of siqsermon-exercise.sh with a
# 30 second gap, 15 requests each, 450 requests over about 22 minutes. Do not
# change it, or a before and an after stop being comparable.
#
# Sampling is 5 seconds rather than Phase 0's 20, because CPU peaks here are
# short and sharp and a 20 second tick misses them. Sampling rate is not part
# of the load.
#
# Usage: siqsermon-measure.sh <label>          # e.g. before, after
# Writes /var/tmp/ha-retune/<label>/ and prints a summary table.
set -euo pipefail

label="${1:?usage: siqsermon-measure.sh <label>}"
[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

EXERCISE=/var/tmp/ha-phase0/siqsermon-exercise.sh
OUT="/var/tmp/ha-retune/${label}"
CONTAINERS="deploy-neo4j-1 deploy-backend-1 deploy-qdrant-1 deploy-caddy-1 openclaw-gateway"
ITERATIONS=30
GAP=30

[[ -x ${EXERCISE} ]] || { echo "missing ${EXERCISE}" >&2; exit 1; }
rm -rf "${OUT}" && mkdir -p "${OUT}"

# Returns nothing when the container is absent, rather than a well-formed path
# that does not exist. Every reader below runs after a 22 minute load window, so
# a container that is not on this box has to cost one row of the report, never
# the whole report.
cgdir() {
  local id
  id="$(docker inspect -f '{{.Id}}' "$1" 2>/dev/null || true)"
  [[ -n ${id} ]] || return 0
  echo "/sys/fs/cgroup/system.slice/docker-${id}.scope"
}

# Read one cgroup file, or print 0 when the container or the file is gone.
cgval() { [[ -n $1 ]] && cat "$1/$2" 2>/dev/null || echo 0; }

# Pull one field out of cpu.stat the same safe way.
cgstat() { cgval "$1" cpu.stat | awk -v k="$2" '$1==k{print $2}'; }

present=""
for c in ${CONTAINERS}; do
  if [[ -n "$(cgdir "${c}")" ]]; then
    present="${present} ${c}"
  else
    echo "  note: ${c} is not on this box, leaving it out of the report" \
      | tee -a "${OUT}/notes.txt"
  fi
done
CONTAINERS="${present# }"
[[ -n ${CONTAINERS} ]] || { echo "none of the listed containers exist" >&2; exit 1; }

# cgroup v2 allows resetting memory.peak on this kernel; if it ever stops
# being writable the starting value is recorded so the delta is still visible.
echo "resetting cgroup peaks"
for c in ${CONTAINERS}; do
  d="$(cgdir "${c}")"
  printf '%s\t%s\n' "${c}" "$(cgval "${d}" memory.peak)" >> "${OUT}/peak-at-start.tsv"
  # CFS throttling is cumulative per container and cannot be reset, so record
  # it at both ends and report the delta. A ceiling set at the measured peak
  # throttles the very burst that produced that peak, which is how a CPU limit
  # turns into user-visible latency.
  printf '%s\t%s\t%s\n' "${c}" \
    "$(cgstat "${d}" nr_throttled)" \
    "$(cgstat "${d}" throttled_usec)" >> "${OUT}/throttle-at-start.tsv"
  echo 0 > "${d}/memory.peak" 2>/dev/null \
    || echo "  note: ${c} memory.peak is not resettable, peak is cumulative" | tee -a "${OUT}/notes.txt"
done

sampler() {
  while true; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    docker stats --no-stream --format '{{.Name}};{{.MemUsage}};{{.CPUPerc}}' 2>/dev/null \
      | sed "s|^|${ts};|" >> "${OUT}/samples.tsv" || true
    free -m | awk -v t="${ts}" '/^Mem:/{print t";HOST-mem;"$3"MiB used;"$7"MiB avail"}' \
      >> "${OUT}/samples.tsv" || true
    swapon --show=USED --noheadings --bytes | awk -v t="${ts}" '{print t";HOST-swap;"$1}' \
      >> "${OUT}/samples.tsv" || true
    sleep 5
  done
}
sampler & sampler_pid=$!
# Only ever kill the pid this script spawned.
trap 'kill "${sampler_pid}" 2>/dev/null || true' EXIT

echo "load: ${ITERATIONS} iterations, ${GAP}s apart, starting $(date -u +%H:%M:%SZ)"
for i in $(seq 1 "${ITERATIONS}"); do
  "${EXERCISE}" >> "${OUT}/load.log" 2>&1 || echo "iteration ${i} FAILED" >> "${OUT}/load.log"
  echo "--- run ${i} done $(date -u +%H:%M:%SZ) ---" >> "${OUT}/load.log"
  [[ ${i} -lt ${ITERATIONS} ]] && sleep "${GAP}"
done
echo "load complete $(date -u +%H:%M:%SZ)"

kill "${sampler_pid}" 2>/dev/null || true
trap - EXIT
sleep 1

for c in ${CONTAINERS}; do
  d="$(cgdir "${c}")"
  printf '%s\t%s\t%s\n' "${c}" "$(cgval "${d}" memory.peak)" "$(cgval "${d}" memory.max)" \
    >> "${OUT}/peak-at-end.tsv"
done

echo
echo "=== ${label}: per container over the load window ==="
printf '%-20s %-12s %-12s %-12s %-10s %-10s %-10s\n' \
  container peak_ws mean_ws cgroup_peak mem_limit peak_cpu mean_cpu
for c in ${CONTAINERS}; do
  # docker stats prints MemUsage as "123.4MiB / 1.5GiB"; take the left side.
  awk -F';' -v c="${c}" '
    $2==c {
      split($3, m, " / "); v=m[1]
      n=v+0; u=v; sub(/^[0-9.]+/, "", u)
      if (u=="GiB") n*=1024; else if (u=="KiB") n/=1024; else if (u=="B") n/=1048576
      if (n>pw) pw=n; sw+=n; k++
    }
    END {
      if (k==0) { printf "%-20s %s\n", c, "no samples"; exit }
      printf "%-20s %-12s %-12s", c, sprintf("%.0fMiB", pw), sprintf("%.0fMiB", sw/k)
    }' "${OUT}/samples.tsv"
  d="$(cgdir "${c}")"
  # cgroup v2 writes the literal "max" into memory.max for a container with no
  # declared ceiling, which is exactly the anomaly this report exists to
  # surface, so it has to reach the table rather than an arithmetic expansion.
  # A cgroup that vanished mid-window reads as unreadable rather than as a
  # measured zero, which is a different and far more alarming thing to report.
  if [[ -n ${d} && -r ${d}/memory.peak ]]; then
    peak="$(( $(cgval "${d}" memory.peak) / 1048576 ))MiB"
    limit="$(cgval "${d}" memory.max)"
    if [[ ${limit} =~ ^[0-9]+$ ]]; then limit="$(( limit / 1048576 ))MiB"; fi
  else
    peak=unreadable
    limit=unreadable
  fi
  printf ' %-12s %-10s' "${peak}" "${limit}"
  awk -F';' -v c="${c}" '
    $2==c { cpu=$4+0; if (cpu>pc) pc=cpu; sc+=cpu; k++ }
    END { if (k) printf " %-10s %-10s\n", sprintf("%.0f%%", pc), sprintf("%.1f%%", sc/k); else print "" }
  ' "${OUT}/samples.tsv"
done

echo
echo "=== ${label}: cpu throttling over the window ==="
printf '%-20s %-16s %-18s\n' container throttled_times throttled_seconds
for c in ${CONTAINERS}; do
  d="$(cgdir "${c}")"
  n0="$(awk -v c="${c}" -F'\t' '$1==c{print $2}' "${OUT}/throttle-at-start.tsv")"
  u0="$(awk -v c="${c}" -F'\t' '$1==c{print $3}' "${OUT}/throttle-at-start.tsv")"
  n1="$(cgstat "${d}" nr_throttled)"
  u1="$(cgstat "${d}" throttled_usec)"
  # cpu.stat is per cgroup and the cgroup is recreated when a container
  # restarts, which zeroes every counter in it at once. Either one reading
  # below its start value means none of them can be subtracted.
  if [[ ${n1:-0} -lt ${n0:-0} || ${u1:-0} -lt ${u0:-0} ]]; then
    printf '%-20s %-16s %-18s\n' "${c}" "${n1:-0} since reset" \
      "$(awk -v a="${u1:-0}" 'BEGIN{printf "%.1f since reset", a/1000000}')"
  else
    printf '%-20s %-16s %-18s\n' "${c}" "$(( ${n1:-0} - ${n0:-0} ))" \
      "$(awk -v a="${u1}" -v b="${u0}" 'BEGIN{printf "%.1f", (a-b)/1000000}')"
  fi
done

echo
echo "=== ${label}: host ==="
awk -F';' '$2=="HOST-mem"{gsub(/MiB used/,"",$3); gsub(/MiB avail/,"",$4);
  if ($3+0>pu) pu=$3+0; if (mn==0 || $4+0<mn) mn=$4+0}
  END {printf "peak used %dMiB, least available %dMiB\n", pu, mn}' "${OUT}/samples.tsv"
awk -F';' '$2=="HOST-swap"{if ($3+0>s) s=$3+0}
  END {printf "peak swap used %d B\n", s}' "${OUT}/samples.tsv"

echo
echo "=== ${label}: request outcomes ==="
# Only the timed request lines: "METHOD path CODE BYTES SECONDS". The login
# line prints a bare status code with no timing, and counting it as a latency
# is how a p95 of "200.000 seconds" appears in a table.
timed() { awk 'NF==5 && ($1=="GET" || $1=="POST")' "${OUT}/load.log"; }
pct() { sort -n | awk '
  {a[NR]=$1; s+=$1}
  END {if (!NR) {print "  no samples"; exit}
       printf "  n=%d mean=%.3f p50=%.3f p95=%.3f max=%.3f\n",
       NR, s/NR, a[int(NR*0.50)?int(NR*0.50):1], a[int(NR*0.95)?int(NR*0.95):1], a[NR]}'; }

timed | wc -l | sed 's/^/timed requests: /'
echo "status codes:"
timed | awk '{print $3}' | sort | uniq -c | awk '{printf "  http %s: %s\n", $2, $1}'
echo "latency seconds, all timed requests:"
timed | awk '{print $5}' | pct
echo "latency seconds, POST /search only (embedding + qdrant + neo4j):"
timed | awk '$1=="POST" && $2=="/search"{print $5}' | pct
echo "latency seconds, POST /search excluding the first iteration (cold start):"
awk 'f && NF==5 && $1=="POST" && $2=="/search"{print $5} /^--- run 1 done/{f=1}' \
  "${OUT}/load.log" | pct

echo
echo "=== ${label}: restarts and oom kills ==="
for c in ${CONTAINERS}; do
  printf '  %-20s restarts=%s oom=%s health=%s\n' "${c}" \
    "$(docker inspect -f '{{.RestartCount}}' "${c}")" \
    "$(docker inspect -f '{{.State.OOMKilled}}' "${c}")" \
    "$(docker inspect -f '{{.State.Health.Status}}' "${c}")"
done
echo
echo "raw samples: ${OUT}/samples.tsv"
