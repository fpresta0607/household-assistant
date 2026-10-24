#!/usr/bin/env bash
# Stand up (or re-converge) the household's OpenClaw gateways on its box, one for each
# member the household file names (scripts/household_file.py).
#
# Idempotent: safe to re-run. It never re-onboards over an existing config and
# never regenerates an existing gateway token.
#
# Run as root on the box, from a checkout of this repository:
#   scripts/openclaw-install.sh
#
# The first household's box, whose household file names no members, runs
# deploy/openclaw/docker-compose.yml as the repository holds it; every other box runs
# the compose file scripts/household-compose.py writes from its household file.
#
# It does not touch the firewall, Caddy, or any published port other than the
# loopback-only gateway ports the compose file declares.
set -euo pipefail

APP_DIR=/opt/household-assistant
ENV_DIR=/etc/household-assistant
STATE_ROOT=/var/lib/household-assistant
SCRIPTURE_DIR="${STATE_ROOT}/scripture"
# The image runs as the `node` user, uid/gid 1000.
OC_UID=1000
OC_GID=1000

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One line for each member: person, assistant, container, state name, port, state
# directory, env file, secrets, codex and bin directories.
members="$(python3 "${here}/household_file.py" members)" \
  || { echo "the household file cannot be read; nothing was changed" >&2; exit 1; }
containers=()
while IFS=$'\t' read -r _ _ container _; do containers+=("${container}"); done <<<"${members}"

if python3 "${here}/household_file.py" has-members; then
  compose_src="$(mktemp)"
  trap 'rm -f "${compose_src}"' EXIT
  python3 "${here}/household-compose.py" >"${compose_src}"
else
  compose_src="${here}/../deploy/openclaw/docker-compose.yml"
fi
[[ -s ${compose_src} ]] || { echo "missing ${compose_src}" >&2; exit 1; }

# The compose file is the single definition of the pin, so the image pulled
# here is always the image `compose up` starts, including after a rollback.
# Every gateway runs the same pinned image, so this collapses their image lines
# to one, and only the gateways' are read: Home Assistant pins an image of its own.
IMAGE="$(grep -oE 'openclaw/openclaw:[^"[:space:]]+' "${compose_src}" | sort -u)"
[[ -n ${IMAGE} && $(wc -l <<<"${IMAGE}") -eq 1 ]] || {
  echo "the gateways do not pin one image; pull and start would disagree:" >&2
  echo "${IMAGE}" >&2
  exit 1
}
[[ ${IMAGE} == *@sha256:* ]] || { echo "no pinned digest in ${compose_src}" >&2; exit 1; }

compose() { docker compose -f "${APP_DIR}/docker-compose.yml" "$@"; }

# --- directories -----------------------------------------------------------
install -d -m 0755 "${APP_DIR}" "${STATE_ROOT}"
install -d -m 0700 "${ENV_DIR}"
while IFS=$'\t' read -r _ _ _ _ _ state env_file secrets codex bin; do
  install -d -m 0700 "${state}" "${secrets}" "${codex}"
  chown "${OC_UID}:${OC_GID}" "${state}" "${secrets}" "${codex}"
  install -d -m 0755 "${bin}"
done <<<"${members}"
# The Bible the household-scripture plugin reads, mounted read-only into both gateways.
# scripts/scripture-build.py writes bible.sqlite here; root owns it, as it owns the plugins.
install -d -m 0755 -o root -g root "${SCRIPTURE_DIR}"
# Each gateway writes its half of the family room into household-app/share in its own
# state, and the other mounts that folder read-only (household-app's share.js and
# peer-link.js). It is made before compose starts either container, since docker would
# make a missing one as root, which the gateway could not write. It sits inside a directory
# the assistant controls, so it is made as the gateways' own user rather than as root, and
# anything but a plain folder in its place is refused.
while IFS=$'\t' read -r _ _ _ _ _ state _; do
  share="${state}/household-app/share"
  setpriv --reuid="${OC_UID}" --regid="${OC_GID}" --clear-groups \
    sh -c 'umask 077 && mkdir -p "$1"' sh "${share}"
  if [[ -L ${share} || ! -d ${share} ]]; then
    echo "refusing: ${share} is not a plain folder" >&2
    exit 1
  fi
done <<<"${members}"
install -m 0644 "${compose_src}" "${APP_DIR}/docker-compose.yml"

# --- gateway token ---------------------------------------------------------
# Generated here, stored at 0600, referenced from openclaw.json as an env ref
# so no plaintext token ever reaches the config file. Never printed.
# A household's setup may have written the env file first, with its OpenRouter key, so
# what is looked for is the token, not the file.
while IFS=$'\t' read -r _ assistant _ _ _ _ env_file _; do
  if ! grep -q '^OPENCLAW_GATEWAY_TOKEN=.' "${env_file}" 2>/dev/null; then
    echo "generating ${assistant}'s gateway token"
    token="$(openssl rand -hex 32)"
    [[ -n ${token} ]] || { echo "openssl produced an empty token" >&2; exit 1; }
    (umask 077 && printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "${token}" >>"${env_file}")
  fi
  chmod 600 "${env_file}"
done <<<"${members}"

# --- image -----------------------------------------------------------------
# Pulled by digest. Never built here: a source build wants ~6 GB and the whole
# assistant budget is 4,480 MiB.
echo "pulling ${IMAGE%%@*}"
docker pull --quiet "${IMAGE}" >/dev/null

# --- first-run onboarding --------------------------------------------------
while IFS=$'\t' read -r _ assistant container _ _ state _; do
  if [[ -f ${state}/openclaw.json ]]; then
    echo "${assistant}'s config already present, skipping onboarding"
    continue
  fi
  echo "onboarding ${assistant}'s gateway (no model provider: --auth-choice skip)"
  compose run --rm --no-deps --entrypoint node "${container}" \
    dist/index.js onboard \
    --non-interactive --accept-risk --skip-health \
    --mode local \
    --auth-choice skip \
    --secret-input-mode ref \
    --gateway-auth token \
    --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
    --gateway-bind lan \
    --gateway-port 18789 \
    --skip-channels \
    --skip-skills \
    --skip-search \
    --no-install-daemon </dev/null
done <<<"${members}"

# --- workspace skills ------------------------------------------------------
# Every agent gets the same skills. They live in the repository so that a
# re-run, or a fresh box, converges to them; a gateway that only ever had them
# hand-copied would lose them the next time this script ran.
#
# A running gateway picks a workspace skill up without a restart, so this step
# needs no recreate of its own. The `compose up` below recreates anyway when
# the compose file or an env file has changed.
#
# Each skill the repository ships is replaced whole, so a file a new version
# dropped goes with the old one (the scripture skill's SIQsermon client did).
# Skills an assistant wrote itself, which the repository does not ship, stay.
skills_src="${here}/../deploy/openclaw/skills"
if [[ -d ${skills_src} ]]; then
  while IFS=$'\t' read -r _ _ _ _ _ state _; do
    workspace="${state}/workspace"
    install -d -m 0700 "${workspace}"
    install -d -m 0700 "${workspace}/skills"
    for skill in "${skills_src}"/*/; do
      name="$(basename "${skill}")"
      rm -rf "${workspace:?}/skills/${name:?}"
      cp -r "${skill%/}" "${workspace}/skills/${name}"
    done
    chown "${OC_UID}:${OC_GID}" "${workspace}"
    chown -R "${OC_UID}:${OC_GID}" "${workspace}/skills"
  done <<<"${members}"
  echo "installed workspace skills: $(ls "${skills_src}" | tr '\n' ' ')"
fi

# --- household plugins -----------------------------------------------------
# OpenClaw plugins of the household's own, loaded into every gateway. A plugin
# runs inside the gateway process, so its code is root-owned here and the
# compose file mounts this directory read-only at /opt/household-plugins: the
# assistant can write its own state directory but never this. Each gateway
# loads a plugin once openclaw.json names it; openclaw-household-app.py apply
# does that for household-app.
#
# The directory is the mount itself, so what is inside it is replaced rather than
# the directory: a running container keeps the directory it was started with, and
# one deleted from under it would show that container nothing at all. Only the
# plugins the repository ships are replaced; PocketPiggies' per-gateway copies are
# its own installer's. A gateway keeps the plugin code it loaded until it restarts,
# so every gateway restarts below when the code changed.
PLUGIN_DIR="${APP_DIR}/plugins"
plugins_src="${here}/../deploy/openclaw/plugins"
plugins_digest() { (cd "${PLUGIN_DIR}" 2>/dev/null && find . -type f -exec sha256sum {} + | sort | sha256sum) || true; }
plugins_before="$(plugins_digest)"
if [[ -d ${plugins_src} ]]; then
  install -d -m 0755 -o root -g root "${PLUGIN_DIR}"
  "${here}/install-household-plugins.sh" "${plugins_src}" "${PLUGIN_DIR}"
fi
plugins_after="$(plugins_digest)"

# --- start -----------------------------------------------------------------
compose up -d --wait
if [[ ${plugins_before} != "${plugins_after}" ]]; then
  echo "household plugin code changed; restarting the gateways to load it"
  compose restart "${containers[@]}"
fi
compose ps
echo
while IFS=$'\t' read -r _ assistant _ _ port _; do
  echo "${assistant}'s gateway is on http://127.0.0.1:${port}/ (loopback only)"
done <<<"${members}"
