# The assistant half of a backup, shared by siqsermon-backup.sh, which takes it with
# SIQsermon's data when run by hand, and household-backup.sh, which takes it alone every
# night. Sourced, never run: the caller sets `dest`, the backup directory, and
# `openclaw_failed=0`, and reads back what each function records for its manifest.

OPENCLAW_STATE=/var/lib/household-assistant/openclaw
OPENCLAW_COMPOSE=/opt/household-assistant/docker-compose.yml
OPENCLAW_SECRETS=/var/lib/household-assistant/openclaw-auth-secrets
OPENCLAW_CODEX=/var/lib/household-assistant/codex
DENISE_STATE=/var/lib/household-assistant/openclaw-denise
DENISE_SECRETS=/var/lib/household-assistant/openclaw-denise-auth-secrets
DENISE_CODEX=/var/lib/household-assistant/codex-denise
COORDINATION_DB=/var/lib/household-assistant/coordination/coordination.db
# The gateways' pinned image, as the compose file names it, quoted or not.
GATEWAY_IMAGE='openclaw/openclaw:[^"[:space:]]+'
# The household plugins, which each config names by their path in the container.
# Without them OpenClaw calls the config invalid and `backup create` refuses, so the
# archive container gets them read-only where the gateway has them.
PLUGINS=/opt/household-assistant/plugins

# household_gateways: one tab-separated line for each gateway the household file names:
# its label, container, state, secrets and codex directories. The label names the
# gateway's archives in the manifest: the first household's Corey is `openclaw` and Denise
# `denise`, as every backup before this called them, and any other gateway is named by
# its assistant. Installed without household_file.py beside it, as the first household's
# backup directory was, it lists those two.
household_gateways() {
  local here members assistant container state_name state secrets codex label
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ ! -f ${here}/household_file.py ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' openclaw openclaw-gateway "${OPENCLAW_STATE}" "${OPENCLAW_SECRETS}" "${OPENCLAW_CODEX}"
    printf '%s\t%s\t%s\t%s\t%s\n' denise openclaw-denise "${DENISE_STATE}" "${DENISE_SECRETS}" "${DENISE_CODEX}"
    return
  fi
  members="$(python3 "${here}/household_file.py" members)" || return 1
  while IFS=$'\t' read -r _ assistant container state_name _ state _ secrets codex _; do
    # A label is also a shell variable's name, so an assistant's hyphens become underscores.
    label="${assistant//-/_}"
    [[ ${state_name} == openclaw ]] && label=openclaw
    printf '%s\t%s\t%s\t%s\t%s\n' "${label}" "${container}" "${state}" "${secrets}" "${codex}"
  done <<<"${members}"
}

# The files a restored gateway is checked for. A gateway that is new may not have them all
# yet: OpenClaw writes USER.md only into a brand-new workspace, and household-memory writes
# kept.json the first time someone asks an assistant to keep something. So each backup
# records which of them its gateway had, and the drill asks for exactly those.
DRILL_FILES="openclaw.json workspace/AGENTS.md workspace/USER.md household-memory/kept.json"

# drill_files <recorded>: what the drill asks one restored gateway for, from the files its
# backup recorded: those and always openclaw.json, or all of them for a backup taken
# before the files were recorded.
drill_files() {
  local files=$1
  case ${files} in
    '') files="${DRILL_FILES}" ;;
    none) files="" ;;
  esac
  if [[ " ${files} " != *" openclaw.json "* ]]; then files="openclaw.json${files:+ ${files}}"; fi
  printf '%s\n' "${files}"
}

# --- assistant state -------------------------------------------------------
# OpenClaw keeps everything in SQLite, which must never be backed up by copying
# the live files: a raw copy of a database being written is routinely torn.
# `openclaw backup create` uses SQLite's online backup API and re-verifies the
# archive it wrote. Nothing here aborts the caller: an assistant that is missing,
# half-installed or failing to archive is recorded in the manifest, sets
# `openclaw_failed`, and is reported by the caller's exit code at the very end.
#
# Every gateway has the same shape, so one function archives each: the OpenClaw state through `backup create`, then the Codex
# harness directory beside it, which `backup create` does not cover, through the
# same online backup API with an integrity_check on every copy.

# archive_assistant <label> <container> <state> <secrets> <codex>
# Sets <label>_archive and <label>_codex_archive for the manifest.
archive_assistant() {
  local label=$1 container=$2 state=$3 secrets=$4 codex=$5
  local archive=none codex_out=missing image found staging file had=""
  for file in ${DRILL_FILES}; do
    if [[ -s ${state}/${file} ]]; then had="${had:+${had} }${file}"; fi
  done
  printf -v "${label}_files" '%s' "${had:-none}"
  # "Installed" is decided by the state directory as much as by the compose
  # file: the state is the irreplaceable half, so its presence alone is enough
  # to require a backup.
  if [[ ! -f ${OPENCLAW_COMPOSE} && ! -e ${state} ]]; then
    echo "${label}: not installed, skipping"
  elif [[ ! -f ${state}/openclaw.json ]]; then
    echo "${label}: installed but ${state}/openclaw.json is missing" >&2
    archive=missing
    openclaw_failed=1
  else
    echo "archiving ${label} state"
    # The gateway may be stopped mid-upgrade and the compose file may be gone
    # entirely, so try the container, then the compose file, and record a
    # failure rather than aborting when neither can name an image.
    image="$(docker inspect -f '{{.Config.Image}}' "${container}" 2>/dev/null || true)"
    if [[ -z ${image} && -f ${OPENCLAW_COMPOSE} ]]; then
      image="$(grep -oE "${GATEWAY_IMAGE}" "${OPENCLAW_COMPOSE}" | head -n 1 || true)"
    fi
    [[ -n ${image} ]] \
      || echo "${label}: no image, the gateway is gone and no compose file names one" >&2
    if [[ -n ${image} ]] && mkdir -p "${dest}/${label}" && chown 1000:1000 "${dest}/${label}" \
      && docker run --rm --memory 512m --cpus 1.0 \
      -e HOME=/home/node -e OPENCLAW_HOME=/home/node \
      -e OPENCLAW_STATE_DIR=/home/node/.openclaw \
      -e OPENCLAW_CONFIG_DIR=/home/node/.openclaw \
      -e OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json \
      -e OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace \
      -v "${state}":/home/node/.openclaw \
      -v "${secrets}":/home/node/.config/openclaw \
      -v "${PLUGINS}":/opt/household-plugins:ro \
      -v "${dest}/${label}":/backup \
      --entrypoint node "${image}" \
      dist/index.js backup create --output /backup --verify; then
      found="$(find "${dest}/${label}" -maxdepth 1 -name '*.tar.gz' -print -quit || true)"
      if [[ -n ${found} ]] && mv "${found}" "${dest}/${label}-${found##*/}"; then
        archive="${label}-${found##*/}"
      else
        echo "${label}: no archive to record" >&2
        archive=missing
        openclaw_failed=1
      fi
    else
      echo "${label}: backup create failed" >&2
      archive=missing
      openclaw_failed=1
    fi
    rm -rf "${dest}/${label}"
  fi
  if [[ -d ${codex} ]]; then
    staging="${dest}/${label}-codex"
    mkdir -p "${staging}"
    if python3 - "${codex}" "${staging}" <<'PY'
import pathlib, shutil, sqlite3, sys
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for db in sorted(src.glob("*.sqlite")):
    live = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    copy = sqlite3.connect(out / db.name)
    live.backup(copy)
    live.close()
    copy.close()
    check = sqlite3.connect(out / db.name)
    verdict = check.execute("pragma integrity_check").fetchone()[0]
    check.close()
    if verdict != "ok":
        sys.exit(f"{db.name}: integrity_check returned {verdict}")
for name in ("installation_id", "skills"):
    path = src / name
    if path.is_dir():
        shutil.copytree(path, out / name)
    elif path.is_file():
        shutil.copy2(path, out / name)
PY
    then
      if tar -C "${dest}" -czf "${dest}/${label}-codex-state.tar.gz" "${label}-codex"; then
        codex_out="${label}-codex-state.tar.gz"
      else
        echo "${label}: codex state archive failed" >&2
        openclaw_failed=1
      fi
    else
      echo "${label}: codex state backup failed" >&2
      openclaw_failed=1
    fi
    rm -rf "${staging}"
  fi
  printf -v "${label}_archive" '%s' "${archive}"
  printf -v "${label}_codex_archive" '%s' "${codex_out}"
}

# --- the retired coordination relay's state --------------------------------
# Not part of either gateway, because it deliberately lived outside both of them,
# so `openclaw backup create` never sees it.
#
# The relay that wrote it was retired with Telegram, so a new box never has this
# file and skips it below, which is a clean backup. A box that ran the relay keeps
# the database until someone removes it, with the off switch's position and the
# planner's taste store in it, and while it is there it is still copied, so a
# restore brings back what was there.
#
# Copied through SQLite's online backup API rather than by cp, because a plain copy
# of a database something might still have open can be torn. That is the same
# mechanism `openclaw backup create` uses above; the box has no sqlite3 binary, so it
# is python3.
archive_coordination() {
coordination_archive=none
if [[ -f ${COORDINATION_DB} ]]; then
  echo "archiving the coordination relay state"
  if python3 - "${COORDINATION_DB}" "${dest}/coordination.db" <<'PYBACKUP'; then
import sqlite3
import sys

source, target = sys.argv[1], sys.argv[2]
live = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
copy = sqlite3.connect(target)
live.backup(copy)
live.close()
copy.close()

# Re-opened and checked, the same as the codex databases above. A copy that did not
# raise is not a copy that is readable, and the whole point of this file is to be
# opened on the worst day somebody has. Verifying it by hand once and leaving the job
# unverified would be a check that ran on the day nobody needed it.
check = sqlite3.connect(target)
# Depending on where the damage is, and on the SQLite build, the pragma either reports
# the damage as its result or raises on it; both are the same verdict and have to read
# the same way. Unhandled, the raising form leaves a bare `database disk image is
# malformed` traceback naming neither the file nor the check.
try:
    verdict = check.execute("pragma integrity_check").fetchone()[0]
except sqlite3.DatabaseError as error:
    verdict = str(error)
# Before the select below, because SQLite raises that same bare error on the next
# statement once it has seen a torn page.
if verdict != "ok":
    sys.exit(f"coordination.db: integrity_check returned {verdict}")
# The select is the check. It raises and exits non-zero when coordination_flag is not
# in the copy, which is the table the off switch lives in and the reason this file is
# archived at all. Counting its rows proves nothing on its own: zero rows is the
# ordinary state before anyone has ever typed `!coordination off`, and it must pass.
check.execute("select count(*) from coordination_flag").fetchone()
check.close()
PYBACKUP
    chmod 600 "${dest}/coordination.db"
    coordination_archive=coordination.db
  else
    echo "coordination: the relay state could not be copied" >&2
    # The destination exists from the moment sqlite3.connect opened it, so a copy that
    # failed its own verification leaves a torn file behind. Left there it would be
    # hashed into SHA256SUMS and sit in the restore directory looking like a backup. The
    # WAL sidecars go with it: sys.exit leaves the checkpoint to interpreter shutdown,
    # so the shell rather than python is what makes their absence certain.
    rm -f "${dest}/coordination.db" "${dest}/coordination.db-wal" "${dest}/coordination.db-shm"
    coordination_archive=missing
    openclaw_failed=1
  fi
else
  echo "coordination: not installed, skipping"
fi
}
