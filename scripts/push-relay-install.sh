#!/usr/bin/env bash
# Install the app publisher's push relay on the publisher's own box, as root, from a
# checkout of this repository. Idempotent: run it again after a change and it replaces
# the code in place and restarts the relay. docs/deploy/push-relay.md.
#
#   scripts/push-relay-install.sh
#
# The relay's code is deploy/push-relay and household-app's apple-push.js, which it sends
# with. Both are copied into /opt/push-relay/release in the repository's own layout, so the
# import that works in a checkout works there. What it does NOT do: write the Apple key.
# The env file is made from the example only when there is none, and the relay is started
# only once its key is in it.
set -euo pipefail

RELEASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The roots it writes, overridable so the tests can run it against a throwaway tree.
PUSH_RELAY_CODE="${PUSH_RELAY_CODE-/opt/push-relay/release}"
PUSH_RELAY_ETC="${PUSH_RELAY_ETC-/etc/push-relay}"
PUSH_RELAY_UNITS="${PUSH_RELAY_UNITS-/etc/systemd/system}"
# The node the unit runs.
PUSH_RELAY_NODE="${PUSH_RELAY_NODE-/usr/bin/node}"

for root in "${PUSH_RELAY_CODE}" "${PUSH_RELAY_ETC}" "${PUSH_RELAY_UNITS}"; do
  case "${root}" in
    /*) ;;
    *)
      echo "refusing to install: '${root}' is not an absolute path" >&2
      exit 2
      ;;
  esac
  # The code root is replaced with rm -rf, so the root itself and anything too shallow
  # are refused after canonicalising.
  canonical="$(realpath -m -- "${root}" | tr -s '/')"
  depth="$(printf '%s' "${canonical}" | tr -cd '/' | wc -c)"
  if [[ "${canonical}" == "/" || ${depth} -lt 2 ]]; then
    echo "refusing to install: '${root}' resolves to '${canonical}'," \
      "which is the filesystem root or too shallow to run rm -rf under" >&2
    exit 2
  fi
done

node_major="$("${PUSH_RELAY_NODE}" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if (( node_major < 22 )); then
  echo "the relay wants Node 22 or newer at ${PUSH_RELAY_NODE}; found ${node_major}" >&2
  exit 1
fi

echo "==> the relay's code into ${PUSH_RELAY_CODE}"
rm -rf "${PUSH_RELAY_CODE:?}"
install -d -m 0755 "${PUSH_RELAY_CODE}/deploy/push-relay" "${PUSH_RELAY_CODE}/deploy/openclaw/plugins/household-app"
for file in relay.mjs server.mjs admin.mjs; do
  install -m 0644 "${RELEASE}/deploy/push-relay/${file}" "${PUSH_RELAY_CODE}/deploy/push-relay/${file}"
done
install -m 0644 "${RELEASE}/deploy/openclaw/plugins/household-app/apple-push.js" \
  "${PUSH_RELAY_CODE}/deploy/openclaw/plugins/household-app/apple-push.js"

echo "==> its settings in ${PUSH_RELAY_ETC}"
# The households file holds public keys only and the relay's own user reads it; the env
# file holds the Apple key and only root reads it, before the relay drops to that user.
install -d -m 0755 "${PUSH_RELAY_ETC}"
if [[ ! -f ${PUSH_RELAY_ETC}/push-relay.env ]]; then
  install -m 0600 "${RELEASE}/deploy/push-relay/push-relay.env.example" "${PUSH_RELAY_ETC}/push-relay.env"
  echo "    made ${PUSH_RELAY_ETC}/push-relay.env from the example: write the app's Apple key into it"
fi
chmod 0600 "${PUSH_RELAY_ETC}/push-relay.env"
if [[ ! -f ${PUSH_RELAY_ETC}/households.json ]]; then
  printf '{\n  "households": {}\n}\n' > "${PUSH_RELAY_ETC}/households.json"
fi
chmod 0644 "${PUSH_RELAY_ETC}/households.json"

echo "==> the systemd unit"
install -d -m 0755 "${PUSH_RELAY_UNITS}"
install -m 0644 "${RELEASE}/deploy/push-relay/push-relay.service" "${PUSH_RELAY_UNITS}/push-relay.service"
systemctl daemon-reload
if grep -q '^APNS_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\\n\.\.\.' "${PUSH_RELAY_ETC}/push-relay.env"; then
  echo
  echo "The relay is installed but not started: ${PUSH_RELAY_ETC}/push-relay.env still holds"
  echo "the example's placeholder key. Write the real one, then: systemctl enable --now push-relay"
  exit 0
fi
systemctl enable push-relay.service
systemctl restart push-relay.service
echo
echo "The relay is running on loopback. Let a household in with:"
echo "  node ${PUSH_RELAY_CODE}/deploy/push-relay/admin.mjs add <household> <public key>"
