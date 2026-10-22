#!/usr/bin/env bash
# Drive SIQsermon over its public TLS endpoint like a real user, so the
# working-set measurement sees loaded state rather than an idle process, and
# so step 4's "a login succeeds, a project loads with its conversation" is
# checked against the same path a browser takes.
#
# Credentials come out of runtime.env inside a subshell and are never echoed;
# only status codes and response sizes are printed.
set -euo pipefail

RUNTIME_ENV=/etc/siqsermon/runtime.env
# The site's public address, from the box's runtime.env or the caller.
SITE="${SITE:-$(sed -n 's/^SITE=//p' "${RUNTIME_ENV}" 2>/dev/null)}"
[[ -n "${SITE}" ]] || { echo "set SITE to the site's https address" >&2; exit 2; }
jar="$(mktemp)"
trap 'rm -f "${jar}"' EXIT

req() { # req <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}" out
  if [[ -n "${body}" ]]; then
    out="$(curl -sS -o /tmp/ha-body.$$ -w '%{http_code} %{size_download} %{time_total}' \
      -b "${jar}" -c "${jar}" -X "${method}" -H 'content-type: application/json' \
      -d "${body}" "${SITE}${path}")"
  else
    out="$(curl -sS -o /tmp/ha-body.$$ -w '%{http_code} %{size_download} %{time_total}' \
      -b "${jar}" -c "${jar}" -X "${method}" "${SITE}${path}")"
  fi
  printf '  %-6s %-46s %s\n' "${method}" "${path}" "${out}"
  echo "${out%% *}" > /tmp/ha-code.$$
}

echo "TLS certificate:"
curl -sS -o /dev/null -w '  issuer=%{ssl_verify_result} http=%{http_version} code=%{http_code}\n' \
  "${SITE}/health"
echo "  chain: $(echo | openssl s_client -connect "${SITE#https://}:443" -servername "${SITE#https://}" 2>/dev/null | openssl x509 -noout -issuer -dates | tr '\n' ' ')"

echo "unauthenticated health:"
req GET /health

echo "login:"
# Subshell so the credentials never outlive the one curl that needs them.
login_code="$(
  # Read the line rather than sourcing the file: it is docker env_file format,
  # not shell, and sourcing it would both misparse values and run them.
  entry="$(sed -n 's/^AUTH_USERS=//p' "${RUNTIME_ENV}" | head -1)"
  entry="${entry%%,*}"
  user="${entry%%:*}"
  pass="${entry#*:}"
  curl -sS -o /dev/null -w '%{http_code}' -c "${jar}" \
    -X POST -H 'content-type: application/json' \
    -d "$(jq -nc --arg u "${user}" --arg p "${pass}" '{username:$u,password:$p}')" \
    "${SITE}/login"
)"
echo "  POST   /login                                         ${login_code}"
[[ "${login_code}" == "200" ]] || { echo "login failed" >&2; exit 1; }

echo "session and listings:"
req GET /session
req GET /settings
req GET /sermons
req GET /projects

# The busiest project, so "loads with its conversation" means something.
pid="$(jq -r '.projects | max_by(.message_count) | .id' /tmp/ha-body.$$)"
echo "busiest project id: ${pid} ($(jq -r --argjson p "${pid}" '.projects[] | select(.id==$p) | "\(.message_count) messages"' /tmp/ha-body.$$))"
echo "project detail and conversation:"
req GET "/projects/${pid}"
req GET "/projects/${pid}/messages"
req GET "/projects/${pid}/application/messages"

echo "retrieval (embedding + qdrant + neo4j anchor lookup):"
while IFS= read -r topic; do
  req POST /search "$(jq -nc --arg t "${topic}" '{topic:$t}')"
done <<'TOPICS'
the shepherd leads me beside still waters
paul writes to the church at corinth about love
faith without works is dead
the prodigal son returns to his father
bearing one another's burdens in the body of christ
the fear of the lord is the beginning of wisdom
TOPICS

rm -f /tmp/ha-body.$$ /tmp/ha-code.$$
echo "exercise complete"
