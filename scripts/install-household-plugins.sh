#!/usr/bin/env bash
# The household's own OpenClaw plugins, from the repository into the plugin mount.
#
# Each plugin the repository ships is replaced whole, so a file a new version dropped
# goes with the old one. Nothing else in the mount is touched: pocket-piggies-corey
# and pocket-piggies-denise are copies scripts/pocket-piggies-install.py makes there,
# one per gateway, and the repository's pocket-piggies directory is its source, which
# no gateway loads. Until 14 October openclaw-install.sh emptied the whole mount here
# instead, which would have deleted both copies.
#
# The mount is a directory the containers were started with, so it is never replaced
# itself, only what is inside it.
#
# usage: install-household-plugins.sh <repository plugins directory> <mount>
set -euo pipefail

source="${1:?usage: install-household-plugins.sh <source> <mount>}"
mount="${2:?usage: install-household-plugins.sh <source> <mount>}"
# Root owns the plugin code, so a gateway that can write its own state never can this.
owner="${PLUGIN_OWNER:-root:root}"

install -d -m 0755 "${mount}"
for plugin in "${source}"/*/; do
  name="$(basename "${plugin}")"
  [[ ${name} == pocket-piggies ]] && continue
  rm -rf "${mount:?}/${name}"
  cp -r "${plugin%/}" "${mount}/${name}"
  chown -R "${owner}" "${mount}/${name}"
  chmod -R u=rwX,go=rX "${mount}/${name}"
  echo "installed household plugin ${name}"
done
