#!/usr/bin/env bash
# Set up a new household's box: a fresh Ubuntu server the household rents and owns, with
# both adults' assistants on it, reached by their phones over the household's own tailnet.
#
# Run as root on the box, from a checkout of this repository:
#   git clone https://github.com/fpresta0607/household-assistant.git /opt/household-assistant/src
#   /opt/household-assistant/src/scripts/new-household.sh
#
# It installs what the box needs from Ubuntu's own packages (Docker, Python, git, jq, ufw,
# qrencode) and Tailscale from Tailscale's, signs the box in to the household's tailnet,
# lets in nothing from the internet but SSH, asks the household's answers once
# (household-setup.py), and converges the box (household-converge.sh). Run again, it skips
# what is already done. docs/deploy/new-household.md walks through it.
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

# --- the box -----------------------------------------------------------------
. /etc/os-release
if [[ ${ID:-} != ubuntu ]]; then
  echo "this is ${PRETTY_NAME:-not Ubuntu}; the setup is written for Ubuntu 24.04 LTS" >&2
  exit 1
fi
[[ ${VERSION_ID:-} == 24.04 ]] || echo "note: written for Ubuntu 24.04 LTS, and this is ${VERSION_ID:-unknown}"
memory_mib=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
if (( memory_mib < 3500 )); then
  echo "the box has ${memory_mib} MiB of memory; two assistants need a box with 4 GB or more" >&2
  exit 1
fi

step "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-v2 git jq curl openssl python3 ufw qrencode \
  ca-certificates >/dev/null
systemctl enable --now docker >/dev/null

step "Tailscale"
if ! command -v tailscale >/dev/null; then
  # Tailscale's own installer adds its signed apt repository for this release of Ubuntu.
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if ! tailscale status --self >/dev/null 2>&1; then
  echo "Sign the box in to your household's tailnet: open the link below on a phone or"
  echo "computer signed in to Tailscale as the household's owner."
  tailscale up
fi
echo "on the tailnet as $(tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//')"

step "the firewall: SSH from the internet, nothing else"
# The phones reach the assistants over the tailnet, which Tailscale's own rules admit ahead
# of ufw's, so the only port the internet needs is SSH, for whoever runs the box.
ufw allow OpenSSH >/dev/null
ufw --force enable >/dev/null
ufw status | sed -n '1,6p'

step "the household's answers"
python3 "${here}/household-setup.py"

step "the box, to this checkout"
"${here}/household-converge.sh"

cat <<'NEXT'

The box is up. What is left:

  1. Install Tailscale on each adult's iPhone and sign it in to the household's tailnet.
  2. Install Steward AI on each iPhone.
  3. For each adult, make a setup link and open it on their iPhone:
       python3 scripts/household-pair.py <their first name>

docs/deploy/new-household.md has the rest: connecting mail and calendars, and keeping the
box current.
NEXT
