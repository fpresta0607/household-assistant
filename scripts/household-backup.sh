#!/usr/bin/env bash
# Every night: both gateways' state and the coordination relay's database, each
# through SQLite's online backup API, then a restore drill of what was written, then
# the oldest backups beyond the newest --keep complete ones removed.
#
# siqsermon-backup.sh takes the same assistant half together with SIQsermon's data,
# but SIQsermon's half stops Neo4j, so that one stays a job run by hand. Until
# 14 October nothing ran either on a schedule, and the newest archive was from
# 18 September.
#
# Writes to /var/backups/household-assistant/<utc-timestamp>/. Run as root on the box,
# by household-backup.service, from the directory household-backup-lib.sh and
# household-restore-drill.sh are installed in.
#
# usage: household-backup.sh [--keep N]
set -euo pipefail

BACKUP_ROOT=${BACKUP_ROOT:-/var/backups/household-assistant}
keep=14
if [[ ${1:-} == --keep ]]; then keep="${2:?--keep needs a number}"; fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=household-backup-lib.sh
source "${here}/household-backup-lib.sh"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${BACKUP_ROOT}/${stamp}"
mkdir -p "${dest}"
chmod 700 "${BACKUP_ROOT}" "${dest}"
echo "backup destination ${dest}"

openclaw_failed=0
archive_assistant openclaw openclaw-gateway "${OPENCLAW_STATE}" "${OPENCLAW_SECRETS}" "${OPENCLAW_CODEX}"
archive_assistant denise openclaw-denise "${DENISE_STATE}" "${DENISE_SECRETS}" "${DENISE_CODEX}"
archive_coordination

cat > "${dest}/MANIFEST.tsv" <<EOF
taken_at_utc	${stamp}
openclaw_archive	${openclaw_archive}
codex_archive	${openclaw_codex_archive}
denise_archive	${denise_archive}
denise_codex_archive	${denise_codex_archive}
coordination_archive	${coordination_archive}
EOF
( cd "${dest}" && sha256sum ./* > "${dest}.sums" && mv "${dest}.sums" SHA256SUMS && chmod 600 SHA256SUMS )
ls -l "${dest}"

# A backup nobody has opened is a hope. The drill restores each archive into a scratch
# directory, through OpenClaw's own `backup restore`, and reads it back.
drill_failed=0
"${here}/household-restore-drill.sh" "${dest}" || drill_failed=1

if [[ ${openclaw_failed} -ne 0 || ${drill_failed} -ne 0 ]]; then
  echo "backup ${dest} is incomplete or did not restore, so nothing older was removed" >&2
  exit 1
fi
# Written outside SHA256SUMS, after the drill, so it says the backup was opened and read.
echo "DRILL PASSED $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${dest}/RESTORED"

# Only after a backup that restored. Only backups marked RESTORED count toward what is
# kept, and only directories named by this script's stamp are ever touched.
python3 - "${BACKUP_ROOT}" "${keep}" <<'PRUNE'
import re
import shutil
import sys
from pathlib import Path

root, keep = Path(sys.argv[1]), sys.argv[2]
if not keep.isdigit() or int(keep) < 1:
    sys.exit(f"--keep must be a whole number of backups, 1 or more, not {keep!r}")
stamped = sorted(
    (path for path in root.iterdir() if path.is_dir() and re.fullmatch(r"\d{8}T\d{6}Z", path.name)),
    key=lambda path: path.name,
    reverse=True,
)
complete = [path for path in stamped if (path / "RESTORED").is_file()]
kept = complete[: int(keep)]
if kept:
    oldest_kept = kept[-1].name
    for path in stamped:
        # Beyond what is kept: older complete ones, and unfinished ones older than the
        # oldest kept. An unfinished one newer than that may be a run still writing.
        if path not in kept and (path in complete or path.name < oldest_kept):
            shutil.rmtree(path)
            print(f"removed {path.name}")
PRUNE
echo "backup complete: ${dest}"
