#!/usr/bin/env bash
# Stand up (or re-converge) the OpenClaw gateway on the shared IONOS VPS.
#
# Idempotent: safe to re-run. It never re-onboards over an existing config and
# never regenerates an existing gateway token.
#
# Run as root on the box, from a checkout of this repository:
#   scripts/openclaw-install.sh
#
# It does not touch SIQsermon, the firewall, Caddy, or any published port other
# than the loopback-only 127.0.0.1:18789 the compose file declares.
set -euo pipefail

APP_DIR=/opt/household-assistant
ENV_DIR=/etc/household-assistant
ENV_FILE="${ENV_DIR}/openclaw.env"
STATE_ROOT=/var/lib/household-assistant
STATE_DIR="${STATE_ROOT}/openclaw"
SECRET_DIR="${STATE_ROOT}/openclaw-auth-secrets"
CODEX_DIR="${STATE_ROOT}/codex"
BIN_DIR="${STATE_ROOT}/bin"
# Denise's gateway: same shape, own state, own env file, own port (18790).
DENISE_ENV_FILE="${ENV_DIR}/openclaw-denise.env"
DENISE_STATE_DIR="${STATE_ROOT}/openclaw-denise"
DENISE_SECRET_DIR="${STATE_ROOT}/openclaw-denise-auth-secrets"
DENISE_CODEX_DIR="${STATE_ROOT}/codex-denise"
DENISE_BIN_DIR="${STATE_ROOT}/bin-denise"
# The image runs as the `node` user, uid/gid 1000.
OC_UID=1000
OC_GID=1000

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_src="${here}/../deploy/openclaw/docker-compose.yml"
[[ -f ${compose_src} ]] || { echo "missing ${compose_src}" >&2; exit 1; }

# The compose file is the single definition of the pin, so the image pulled
# here is always the image `compose up` starts, including after a rollback.
# Both gateways run the same pinned image, so this collapses the two `image:`
# lines to one. Without the de-duplication IMAGE holds both, and the pull fails
# with "invalid reference format" rather than saying what is wrong.
IMAGE="$(awk '$1=="image:"{print $2}' "${compose_src}" | sort -u)"
[[ $(wc -l <<<"${IMAGE}") -eq 1 ]] || {
  echo "services pin different images; pull and start would disagree:" >&2
  echo "${IMAGE}" >&2
  exit 1
}
[[ ${IMAGE} == *@sha256:* ]] || { echo "no pinned digest in ${compose_src}" >&2; exit 1; }

compose() { docker compose -f "${APP_DIR}/docker-compose.yml" "$@"; }

# --- directories -----------------------------------------------------------
install -d -m 0755 "${APP_DIR}" "${STATE_ROOT}"
install -d -m 0700 "${ENV_DIR}"
install -d -m 0700 "${STATE_DIR}" "${SECRET_DIR}" "${CODEX_DIR}" \
  "${DENISE_STATE_DIR}" "${DENISE_SECRET_DIR}" "${DENISE_CODEX_DIR}"
chown "${OC_UID}:${OC_GID}" "${STATE_DIR}" "${SECRET_DIR}" "${CODEX_DIR}" \
  "${DENISE_STATE_DIR}" "${DENISE_SECRET_DIR}" "${DENISE_CODEX_DIR}"
install -d -m 0755 "${BIN_DIR}" "${DENISE_BIN_DIR}"
install -m 0644 "${compose_src}" "${APP_DIR}/docker-compose.yml"

# --- gateway token ---------------------------------------------------------
# Generated here, stored at 0600, referenced from openclaw.json as an env ref
# so no plaintext token ever reaches the config file. Never printed.
if [[ ! -f ${ENV_FILE} ]]; then
  echo "generating a gateway token"
  umask 077
  token="$(openssl rand -hex 32)"
  [[ -n ${token} ]] || { echo "openssl produced an empty token" >&2; exit 1; }
  printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "${token}" > "${ENV_FILE}"
fi
chmod 600 "${ENV_FILE}"
if [[ ! -f ${DENISE_ENV_FILE} ]]; then
  echo "generating Denise's gateway token"
  umask 077
  token="$(openssl rand -hex 32)"
  [[ -n ${token} ]] || { echo "openssl produced an empty token" >&2; exit 1; }
  printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "${token}" > "${DENISE_ENV_FILE}"
fi
chmod 600 "${DENISE_ENV_FILE}"

# --- image -----------------------------------------------------------------
# Pulled by digest. Never built here: a source build wants ~6 GB and the whole
# assistant budget is 4,480 MiB.
echo "pulling ${IMAGE%%@*}"
docker pull --quiet "${IMAGE}" >/dev/null

# --- first-run onboarding --------------------------------------------------
if [[ -f ${STATE_DIR}/openclaw.json ]]; then
  echo "config already present, skipping onboarding"
else
  echo "onboarding (no model provider: --auth-choice skip)"
  compose run --rm --no-deps --entrypoint node openclaw-gateway \
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
    --no-install-daemon
fi
if [[ -f ${DENISE_STATE_DIR}/openclaw.json ]]; then
  echo "Denise's config already present, skipping onboarding"
else
  echo "onboarding Denise's gateway (no model provider: --auth-choice skip)"
  compose run --rm --no-deps --entrypoint node openclaw-denise \
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
    --no-install-daemon
fi

# --- workspace skills ------------------------------------------------------
# Both agents get the same skills. They live in the repository so that a
# re-run, or a fresh box, converges to them; a gateway that only ever had them
# hand-copied would lose them the next time this script ran.
#
# A running gateway picks a workspace skill up without a restart, so this step
# needs no recreate of its own. The `compose up` below recreates anyway when
# the compose file or an env file has changed.
skills_src="${here}/../deploy/openclaw/skills"
if [[ -d ${skills_src} ]]; then
  for workspace in "${STATE_DIR}/workspace" "${DENISE_STATE_DIR}/workspace"; do
    install -d -m 0700 "${workspace}"
    install -d -m 0700 "${workspace}/skills"
    cp -r "${skills_src}/." "${workspace}/skills/"
    chown "${OC_UID}:${OC_GID}" "${workspace}"
    chown -R "${OC_UID}:${OC_GID}" "${workspace}/skills"
  done
  echo "installed workspace skills: $(ls "${skills_src}" | tr '\n' ' ')"
fi

# --- household plugins -----------------------------------------------------
# OpenClaw plugins of the household's own, loaded into both gateways. A plugin
# runs inside the gateway process, so its code is root-owned here and the
# compose file mounts this directory read-only at /opt/household-plugins: the
# assistant can write its own state directory but never this. Each gateway
# loads a plugin once openclaw.json names it; openclaw-family-group.py apply
# does that for household-family-room.
#
# The directory is the mount itself, so what is inside it is replaced rather than
# the directory: a running container keeps the directory it was started with, and
# one deleted from under it would show that container nothing at all. Only the
# plugins the repository ships are replaced; PocketPiggies' per-gateway copies are
# its own installer's. A gateway keeps the plugin code it loaded until it restarts,
# so both restart below when the code changed.
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
  echo "household plugin code changed; restarting both gateways to load it"
  compose restart openclaw-gateway openclaw-denise
fi
compose ps
echo
echo "Corey's gateway is on http://127.0.0.1:18789/ and Denise's on http://127.0.0.1:18790/ (loopback only)"
