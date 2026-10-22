#!/usr/bin/env bash
#
# Measure the candidate speech engines and print a table.
#
# The default engine for Voicebox is not chosen in this repository, and it is
# not chosen from reputation. It is chosen from what this script measures on
# the actual Mac. Every engine speaks the same fixed phrase, which lives in
# services/voicebox/voicebox.py so that there is exactly one copy of it and
# two runs stay comparable.
#
# Measured, per engine:
#
#   cold start   the first synthesis in a fresh process, which is what the
#                first sentence of the morning actually costs
#   warm         the median of the runs after that
#   RTF          real-time factor: synthesis seconds per second of audio
#                produced. Below 1.0 is faster than speech; lower is better.
#   peak memory  maximum resident set size of the synthesis process tree.
#                That tree includes the small python3 wrapper, so read the
#                figure as an upper bound on the engine rather than as the
#                engine exactly.
#   output       bytes of audio written
#   arch         native arm64, or an x86_64-only binary running under Rosetta,
#                which is the difference between a fair measurement and a
#                misleading one
#
# Assumes: macOS. An engine that is not installed is reported as not usable
#          and skipped, rather than failing the run; this table is meant to be
#          useful before anything has been installed as well as after.
# Changes: writes wav files into a temporary directory and deletes them on
#          exit unless --keep. Installs nothing, changes no setting, and does
#          not touch the running Voicebox agent.
#
# Usage:
#   voicebox-benchmark.sh [--runs N] [--engine NAME]... [--keep] [--help]
#
# NOT YET RUN ON APPLE HARDWARE. Neither the timings nor the per-engine
# command lines have been exercised against a real engine. Treat the first run
# on the Mac as part of the measurement, and check each engine's arguments
# against the version you installed.

set -euo pipefail

# shellcheck source=scripts/macos/lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

runs=5
keep=0
selected=""
while [ "$#" -gt 0 ]; do
  case "${1}" in
    -h|--help)
      cat <<'TEXT'
voicebox-benchmark.sh - measure the candidate speech engines and print a table.

  --runs N        syntheses per engine, default 5. The first is the cold start
                  and the rest give the warm median.
  --engine NAME   measure only this engine; repeatable. The default is every
                  engine in the table.
  --keep          leave the wav files behind, and say where
  --help          this text

Reads the fixed phrase and the engine table from services/voicebox/voicebox.py.
Installs nothing and changes nothing.
TEXT
      exit 0
      ;;
    --runs) runs="${2:?--runs needs a number}"; shift 2 ;;
    --engine) selected="${selected} ${2:?--engine needs a name}"; shift 2 ;;
    --keep) keep=1; shift ;;
    *) ha_die "unknown argument ${1}. Try --help." ;;
  esac
done

case "${runs}" in
  ''|*[!0-9]*) ha_die "--runs must be a whole number, got ${runs}" ;;
esac
[ "${runs}" -ge 2 ] || ha_die "--runs must be at least 2: one cold run and one warm run"

ha_require_macos
ha_need python3 "It ships with the Xcode command line tools."
ha_need afinfo "It is a macOS built-in; if it is missing, so is CoreAudio."

root="$(ha_repo_root)"
service="${root}/services/voicebox/voicebox.py"
phrase="$(python3 "${service}" phrase)"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/voicebox-bench.XXXXXX")"
cleanup() { if [ "${keep}" != "1" ]; then rm -rf "${workdir}"; fi; }
trap cleanup EXIT INT TERM

if [ -n "${selected}" ]; then
  engines="${selected}"
else
  engines="$(python3 "${service}" engines |
               python3 -c 'import json, sys; print(" ".join(sorted(json.load(sys.stdin))))')"
fi

# One synthesis. Prints the engine's own seconds=, bytes= and binary= lines,
# or nothing at all with a non-zero status when the engine cannot run.
synth_once() {
  python3 "${service}" synth --engine "$1" --out "$2" --text "${phrase}" 2>"$3"
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

median() {
  sort -n | python3 -c '
import sys
values = [float(line) for line in sys.stdin if line.strip()]
if not values:
    print("-")
else:
    middle = len(values) // 2
    print("%.3f" % (values[middle] if len(values) % 2 else (values[middle - 1] + values[middle]) / 2))
'
}

ha_head "benchmark"
ha_log "machine   $(sw_vers -productVersion) on $(uname -m)"
ha_log "runs      ${runs} per engine"
ha_log "phrase    ${phrase}"
ha_log "output    ${workdir}"

rows=""
for engine in ${engines}; do
  out="${workdir}/${engine}.wav"
  err="${workdir}/${engine}.err"

  # The cold run is also the availability check: an engine that is not
  # installed fails here, and nothing has warmed a cache before it.
  if ! result="$(synth_once "${engine}" "${out}" "${err}")"; then
    reason="$(tail -1 "${err}" 2>/dev/null || true)"
    ha_warn "${engine}: ${reason:-did not run}"
    rows="${rows}| ${engine} | - | - | - | - | - | not usable: ${reason:-unknown} |
"
    continue
  fi
  cold="$(field "${result}" seconds)"
  bytes="$(field "${result}" bytes)"
  binary="$(field "${result}" binary)"

  warm_samples=""
  index=1
  while [ "${index}" -lt "${runs}" ]; do
    rm -f "${out}"
    warm_samples="${warm_samples}$(field "$(synth_once "${engine}" "${out}" "${err}")" seconds)
"
    index=$((index + 1))
  done
  warm="$(printf '%s' "${warm_samples}" | median)"

  # Audio duration straight from CoreAudio, for the real-time factor.
  duration="$(afinfo "${out}" 2>/dev/null |
                sed -n 's/.*estimated duration: \([0-9.]*\) sec.*/\1/p' | head -1)"
  if [ -n "${duration}" ] && [ "${warm}" != "-" ]; then
    rtf="$(python3 -c "print('%.2f' % (${warm} / ${duration}) if ${duration} > 0 else '-')")"
  else
    rtf="-"
    duration="unknown"
  fi

  # Peak resident set size, from the BSD time built into macOS.
  peak="-"
  timing="${workdir}/${engine}.time"
  if /usr/bin/time -l python3 "${service}" synth \
       --engine "${engine}" --out "${out}" --text "${phrase}" >/dev/null 2>"${timing}"; then
    peak_bytes="$(sed -n 's/^ *\([0-9][0-9]*\) *maximum resident set size.*/\1/p' "${timing}" | head -1)"
    if [ -n "${peak_bytes}" ]; then
      peak="$(python3 -c "print('%.1f MiB' % (${peak_bytes} / 1048576))")"
    fi
  fi

  # An engine with only an x86_64 slice runs under Rosetta. That is both
  # slower and a reason to prefer something else, so it goes in the table.
  arch="unknown"
  if [ -n "${binary}" ]; then
    slices="$(lipo -archs "${binary}" 2>/dev/null || file -b "${binary}" 2>/dev/null || true)"
    case "${slices}" in
      *arm64*) arch="native arm64" ;;
      *x86_64*) arch="x86_64 only, Rosetta" ;;
      *) arch="${slices:-unknown}" ;;
    esac
  fi

  rows="${rows}| ${engine} | ${cold} | ${warm} | ${rtf} | ${peak} | ${bytes} | ${arch} |
"
  ha_ok "${engine}: cold ${cold}s, warm ${warm}s, ${duration}s of audio"
done

echo
echo "### Voicebox engine benchmark"
echo
echo "Machine: $(sw_vers -productName) $(sw_vers -productVersion) on $(uname -m)."
echo "Runs: ${runs} per engine, the first of each cold."
echo "Phrase: \"${phrase}\""
echo
echo "| engine | cold start (s) | warm median (s) | RTF | peak memory | output bytes | Apple Silicon |"
echo "|---|---|---|---|---|---|---|"
printf '%s' "${rows}"
echo
echo "Lower is better in every numeric column. Choose the engine from this table"
echo "rather than from reputation, then rerun voicebox-install.sh with"
echo "VOICEBOX_ENGINE set to the name in the first column."

if [ "${keep}" = "1" ]; then
  ha_log "audio kept in ${workdir}"
fi
