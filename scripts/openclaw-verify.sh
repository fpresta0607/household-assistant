#!/usr/bin/env bash
# Is the OpenClaw gateway healthy, private, and inside its declared limits?
#
# Run as root on the box. Read-only: it changes nothing.
set -euo pipefail

# The three values that name one gateway. Two gateways run on this box from
# the same image, so checking Denise's means setting all three, not just CT:
# CT=openclaw-denise PORT=18790 STATE=/var/lib/household-assistant/openclaw-denise
CT=${CT:-openclaw-gateway}
PORT=${PORT:-18789}
STATE=${STATE:-/var/lib/household-assistant/openclaw}
# The uid the gateway runs as inside its container, which owns everything in its state.
STATE_OWNER=${STATE_OWNER:-1000}
# The deployed compose file is the single definition of the pin: a rollback
# edits that one `image:` line, so read the expected digest back out of it.
COMPOSE=${COMPOSE:-/opt/household-assistant/docker-compose.yml}
# Where the kernel publishes the container's own cgroup, read for the footprint.
CGROUP=${CGROUP:-/sys/fs/cgroup/system.slice}
# What else the box may show the world. The first household's box also serves its web
# sites through Caddy on 80 and 443; a box that holds only the household's gateways
# listens to the world on nothing and lets in only SSH, and household-converge.sh says so.
WORLD_PORTS=${WORLD_PORTS-80 443}
UFW_RULES=${UFW_RULES-22/tcp 80/tcp 443/tcp}
# The first household's calendar skill imports requests from pylocal in the state; a box
# whose household connects its calendars through the app sets this to skip.
CALENDAR_LIBRARY=${CALENDAR_LIBRARY:-required}
[[ -f ${COMPOSE} ]] || { echo "missing ${COMPOSE}" >&2; exit 1; }

# Two gateway services share that file, so every read of it has to be scoped
# to the one being checked. Unscoped, an `awk '$1=="image:"'` returns both
# services' values as one newline-joined string and every comparison below
# fails, which is the same defect openclaw-install.sh carried until Denise's
# gateway made it visible. A service block starts at its two-space header and
# ends at the next line that is not indented deeper.
compose_value() {
  awk -v svc="  ${CT}:" -v key="$1" '
    $0 == svc { inside = 1; next }
    /^[^ ]/ || /^  [^ #]/ { inside = 0 }
    inside && $1 == key { gsub(/"/, "", $2); print $2; exit }
  ' "${COMPOSE}"
}

fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'PASS  %-32s %s\n' "$1" "$3"
          else printf 'FAIL  %-32s expected %s, got %s\n' "$1" "$2" "$3"; fail=1; fi }

echo "=== container ==="
check "health"         healthy "$(docker inspect -f '{{.State.Health.Status}}' "${CT}")"
check "oom-killed"     false   "$(docker inspect -f '{{.State.OOMKilled}}' "${CT}")"
check "restart policy" unless-stopped \
  "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${CT}")"
check "image digest"   "$(compose_value image: | cut -d@ -f2)" \
  "$(docker inspect -f '{{index .RepoDigests 0}}' "$(docker inspect -f '{{.Image}}' "${CT}")" | cut -d@ -f2)"
check "docker enabled at boot" enabled "$(systemctl is-enabled docker.service)"

echo
echo "=== loopback only ==="
# The published port must be bound to 127.0.0.1, never 0.0.0.0 or [::].
check "published bindings" "127.0.0.1:${PORT}" \
  "$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "${CT}" | tr -s ' ' | sed 's/ $//')"
check "no new world-listener" "${WORLD_PORTS}" \
  "$(docker ps --format '{{.Ports}}' | grep -oE '(0\.0\.0\.0|\[::\]):[0-9]+' | sed -E 's/.*://' | sort -un | tr '\n' ' ' | sed 's/ $//')"
check "ufw rules unchanged" "${UFW_RULES}" \
  "$(ufw status | awk '/ALLOW/ {print $1}' | sort -uV | tr '\n' ' ' | sed 's/ $//')"

echo
echo "=== tailnet only ==="
# `tailscale serve` is the one path off the box: HTTPS on the tailnet name,
# proxied to the loopback port above. Funnel would put it on the internet, and
# nothing on this box is meant to be funnelled, so any funnel at all fails,
# including one recorded under a foreground `tailscale funnel` session.
tailnet_host="$(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')" || true
serve="$(tailscale serve status --json 2>/dev/null)" || serve='{}'
check "tailscale funnel" off \
  "$(jq -r 'if ([.. | objects | .AllowFunnel // {} | .[]] | any) then "on" else "off" end' <<<"${serve}")"
check "tailnet proxy" "http://127.0.0.1:${PORT}" \
  "$(jq -r --arg h "${tailnet_host}:${PORT}" '.Web[$h].Handlers["/"].Proxy // "none"' <<<"${serve}")"
# The phone's path end to end: serve, the tailnet certificate, and
# gateway.trustedProxies, without which the gateway answers a proxied upgrade
# with 403 proxy_attribution_required. The socket stays open after the 101, so
# curl always ends on its timeout; the status code is still written.
code="$(curl -s -o /dev/null --http1.1 --max-time 3 -w '%{http_code}' \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://${tailnet_host}:${PORT}/")" || true
check "websocket over the tailnet" 101 "${code}"

echo
echo "=== http probes inside the container ==="
# From inside, the gateway sees a direct local caller. From the host it would
# not: trustedProxies names the host's bridge addresses, so a host request
# with no forwarded header is refused as unattributable (startupz and readyz
# answer 403). Inside the container the port is always 18789.
for probe in healthz startupz readyz; do
  code="$(docker exec "${CT}" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18789/${probe}")" || code=000
  check "GET /${probe}" 200 "${code}"
done

echo
echo "=== state is on disk, outside the container ==="
check "state mounted" "${STATE}" \
  "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/node/.openclaw"}}{{.Source}}{{end}}{{end}}' "${CT}")"
# `openclaw backup create` runs as uid 1000, like the gateway, and refuses the whole
# state over one thing it cannot archive. On 14 October that was four USER.md.bak files
# root had left in Corey's workspace on 19 September, then an empty virtualenv there
# whose python3 linked to /usr/bin/python3, since the archive takes no absolute link.
# Left out: the directories it skips as regenerable, and the PocketPiggies and home
# socket directories, which belong to their key holders on purpose and which the gateway's
# group can read, so the archive takes them.
unarchivable="$(find "${STATE}" -mindepth 1 \
  \( -path "${STATE}/pocketpiggies" -o -path "${STATE}/home" -o -path "${STATE}/npm" -o -path "${STATE}/plugin-skills" \
     -o -path "${STATE}/tmp" -o -path "${STATE}/tools" -o -path "${STATE}/agents/*/agent/codex-home/tmp" \) -prune \
  -o \( ! -uid "${STATE_OWNER}" -o -lname '/*' \) -printf '%P\n' | awk 'NR <= 5' | paste -sd ' ' -)"
check "state the backup can read" none "${unarchivable:-none}"
printf '      config %s, agent dbs %s, state size %s\n' \
  "$([[ -f ${STATE}/openclaw.json ]] && echo present || echo MISSING)" \
  "$(find "${STATE}" -name '*.sqlite' | wc -l)" \
  "$(du -sh /var/lib/household-assistant | cut -f1)"

echo
echo "=== model backend ==="
# No provider means no credential and no possible spend. Print the key names,
# never a value.
printf '      models section in openclaw.json: %s\n' \
  "$(jq -r 'if has("models") then (.models.providers // {} | keys | join(",")) else "absent" end' \
     "${STATE}/openclaw.json")"

echo
echo "=== nothing messages a person unasked ==="
# The heartbeat is a model turn every 30 minutes that delivers anything but a
# silent NO_REPLY to the owner, and until 25 September both gateways used it to
# send messages nobody asked for. Read the scheduler rather than openclaw.json:
# a heartbeat block under agents.entries, a restored backup and a fresh
# onboarding all bring it back without touching agents.defaults.
heartbeats="$(docker exec "${CT}" node dist/index.js cron list --all --json 2>/dev/null \
  | jq -r '[.jobs[] | select(.payload.kind == "heartbeat" and .enabled)] | length')" \
  || heartbeats=""
case ${heartbeats} in
  0) heartbeat=off ;;
  '' | *[!0-9]*) heartbeat=unreadable ;;
  *) heartbeat="on (${heartbeats} enabled)" ;;
esac
check "recurring heartbeat" off "${heartbeat}"

echo
echo "=== the household reaches its assistant ==="
# The app is the household's only channel. Its verdict checks the owner, the family
# room's tools, the tools the assistant is handed and that nothing Telegram left remains.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check "household app" ok \
  "$(python3 "${here}/openclaw-household-app.py" verdict --container "${CT}" --state "${STATE}" 2>&1)"

echo
echo "=== nothing still routes to OpenAI ==="
# The household's OpenAI account is closing, and a chat chain, a model slot, memory
# embeddings or voice-note transcription left on it fails once it does. This audits
# config and container credential presence; effective models and pins need `check`.
check "openrouter only" ok \
  "$(python3 "${here}/openclaw-openrouter.py" verdict --container "${CT}" --state "${STATE}" 2>&1)"

echo
echo "=== nothing speaks a reply unasked ==="
# Speech is Speak and Talk in the app, under a daily ceiling, and nothing else. This
# audits config: no automatic speech, no OpenClaw tts tool handed to the assistant, and
# nothing left of the retired household-speech plugin; see docs/deploy/openclaw.md,
# "Speaking".
check "spoken replies" ok \
  "$(python3 "${here}/openclaw-speech.py" verdict --container "${CT}" --state "${STATE}" 2>&1)"

echo
echo "=== a picture or a video goes through the pictures plugin ==="
# OpenClaw's own image_generate and video_generate drop the cost of each request, so each
# gateway makes pictures and videos through the household-pictures plugin and its daily
# ceilings for each person. This audits config: the plugin, the ceilings, and the tools
# the assistant is handed and denied.
check "pictures and videos" ok \
  "$(python3 "${here}/openclaw-pictures.py" verdict --container "${CT}" --state "${STATE}" 2>&1)"

echo
echo "=== the calendar skill can load ==="
# apple-cal-anywhere needs the Python package requests, and the image carries neither
# it nor pip: it sits with its own dependencies under pylocal in the state mount, and
# PYTHONPATH in the env file points there. Until 9 October Corey's copy held requests
# without urllib3 or idna, so every calendar read died on this import. The last line
# of a failed import names the module that is missing.
if [[ ${CALENDAR_LIBRARY} == skip ]]; then
  printf 'SKIP  %-32s %s\n' "calendar library" "this household's calendars come through the app"
else
  library="$(docker exec "${CT}" python3 -c 'import requests; print("ok")' 2>&1 | tail -n 1)" || true
  check "calendar library" ok "${library:-unreadable}"
fi

echo
echo "=== footprint against the declared limit ==="
id="$(docker inspect -f '{{.Id}}' "${CT}" 2>/dev/null || true)"
d="${CGROUP}/docker-${id}.scope"
if [[ -r ${d}/memory.peak ]]; then
  # cgroup v2 writes the literal "max" into memory.max and cpu.max when the
  # container was started without that limit, which is the very thing this
  # section checks, so it has to print rather than reach an arithmetic
  # expansion, where it is a fatal error under set -u.
  limit="$(cat "${d}/memory.max" 2>/dev/null || echo unreadable)"
  if [[ ${limit} =~ ^[0-9]+$ ]]; then limit="$(( limit / 1048576 ))MiB"; fi
  # Same single-source read as the digest check: the deployed compose file is
  # where the ceiling is declared, and a gateway running without one is what
  # the whole assistant budget rests on not happening.
  declared="$(compose_value memory:)"
  if [[ -n ${declared} ]]; then declared="${declared%M}MiB"; else declared="a declared ceiling"; fi
  check "memory ceiling" "${declared}" "${limit}"
  # The compose file quotes cpus as a decimal string and the cgroup expresses it
  # as a quota over a period, so both sides are rendered to two decimals before
  # they are compared.
  cpus="$(awk '{if ($1 ~ /^[0-9]+$/) printf "%.2f", $1/$2; else print $1}' "${d}/cpu.max")"
  declared_cpus="$(compose_value cpus:)"
  if [[ ${declared_cpus:-0} != 0 ]]; then declared_cpus="$(printf '%.2f' "${declared_cpus}")"; fi
  check "cpu ceiling" "${declared_cpus:-a declared ceiling}" "${cpus}"
  printf '%-20s %-14s %-12s %-12s %-8s\n' container working_set cgroup_peak limit cpus
  printf '%-20s %-14s %-12s %-12s %-8s\n' "${CT}" \
    "$(docker stats --no-stream --format '{{.MemUsage}}' "${CT}" | cut -d' ' -f1)" \
    "$(( $(cat "${d}/memory.peak") / 1048576 ))MiB" \
    "${limit}" \
    "${cpus}"
else
  echo "      no cgroup to read: the container is not running"
fi

echo
[[ ${fail} -eq 0 ]] && echo "OPENCLAW VERIFIED" || { echo "VERIFICATION FAILED"; exit 1; }

