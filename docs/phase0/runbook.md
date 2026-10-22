# Phase 0 - headroom on the shared VPS

Phase 0 installs no assistant code.
It makes room on the IONOS box that already runs SIQsermon, and proves the existing data is recoverable before anything else moves.

Every number here was measured on the box on 2026-09-17, not carried over from the brief.
The scripts in [`scripts/`](../../scripts) are the executable form of this runbook.
They run as root on the box and were copied there under `/var/tmp/ha-phase0/`.

The box as found, and as left:

| | before | after |
|---|---|---|
| OS | Ubuntu 26.04.1 LTS, x86_64 | unchanged |
| CPU | 6 vCPU | unchanged |
| RAM | 7,878 MiB | unchanged |
| swap | **none** | **4 GiB, swappiness 10** |
| disk | 7.9 GB of 232 GB used | 13 GB of 232 GB used |
| open ports | 22, 80, 443, ufw active | unchanged, verified |

---

## Step 1 - back up, and prove the backup opens

`scripts/siqsermon-backup.sh` writes to `/var/backups/siqsermon/<utc-timestamp>/`, outside `/opt/siqsermon`, mode 0700.
Since 2026-09-18 the same job and the same rehearsal also cover the OpenClaw assistant state, which is documented in [`../deploy/openclaw.md`](../deploy/openclaw.md#how-the-backup-covers-it); everything below is the SIQsermon half.

Neo4j Community has no online backup, so the dump is taken with the database stopped.
The alternative the brief rules out, copying files out from under a running store, deserves its reasoning stated: a running Neo4j is mid-transaction by definition, and a file-level copy of it can restore into a store that does not open.
Caddy is never touched, so port 443 stays up for the whole window.
Neo4j was down for 5 seconds.

Qdrant uses its own snapshot endpoint, and the copied file is checked against the SHA-256 Qdrant reports for the snapshot it just wrote.
Snapshots land in `/qdrant/snapshots`, which this stack does not mount as a volume, so the file comes out of the container layer rather than off the host.
The snapshot inside Qdrant is deleted afterwards: it is our artifact, not user data, and leaving it would make the live volume carry a second copy of the collection.

SQLite is copied with the `sqlite3` online backup API, which is consistent against a database being written concurrently, rather than with `cp`.

`/etc/siqsermon/runtime.env` is copied at mode 0600 and never read for any other purpose.
Its contents do not appear in any script output, log or pull request.

### What is stored

Location: `/var/backups/siqsermon/20260917T214003Z/`

| file | bytes | sha256 |
|---|---|---|
| `neo4j.dump` | 114,401,635 | `d9847a49d65ea37b2effc9c2b820a14fb46069542ccb8caa224a46c05cb04ef1` |
| `verses-8582615092884046-2026-09-17-21-40-37.snapshot` | 167,717,376 | `8c7712e5abe3406641588a5dc01e1d3f7ad19fece148278ec4ad5096fb4bad84` |
| `app_data.tar.gz` | 266,941,980 | `197deade68a19f98d953bcec38671d59baa01aba410c0237269bfb9c2d28ccc6` |
| `app.db` | 278,528 | `36e5f16b386716fba48d406669f4e829a7fc8e6a51f0adccabc46b3180e4ca06` |
| `runtime.env` | 1,288 | `aea12ad27074eeff24a0ddff987b1c8f4ed89385ca9249050a9bdf72c0fcb474` |
| `MANIFEST.tsv` | 306 | `d744c516630d5d2972d9312afd5ae2175100278dc317d16c90f211518dd80510` |
| `sqlite-counts.tsv` | 92 | `ad1b0b6e0514092dacafb9d7cd13acdf8abb62c55d9514670e250dcce200cad9` |

Total 524 MB.
`SHA256SUMS` in the same directory carries the list above.

### The rehearsal

`scripts/siqsermon-restore-rehearsal.sh` restores into throwaway volumes on a throwaway docker network with no published ports, so it involves no firewall or port change.
The temporary containers carry hard memory limits, because on a box that had no swap an unbounded rehearsal instance would itself have been a threat to the live databases.

A backup nobody has opened is not a backup, so this one was opened:

```
=== 0. stored bytes match the recorded checksums ===
  ./MANIFEST.tsv: OK
  ./app.db: OK
  ./app_data.tar.gz: OK
  ./neo4j.dump: OK
  ./runtime.env: OK
  ./sqlite-counts.tsv: OK
  ./verses-8582615092884046-2026-09-17-21-40-37.snapshot: OK

=== 1. neo4j: load the dump into a fresh store ===
PASS  neo4j nodes                        203648
PASS  neo4j relationships                960556
  label breakdown from the restored store:
    Book 66              Chapter 1189          Community 0
    Entity 150           Episodic 12           Event 450
    Lemma 14197          PeopleGroup 23        Person 3067
    Place 1274           Saga 0                TranslationRendering 152115
    Verse 31105

=== 2. qdrant: recover the collection from the snapshot at startup ===
PASS  qdrant verses points               31105
  a restored vector answers a real search:
    {"vid":1001001,"osis":"Gen.1.1","ref":"Genesis 1:1","book":"Genesis",
     "chapter":1,"verse":1,"translation":"BSB",
     "text":"In the beginning God created the heavens and the earth."}

=== 3. sqlite: open the backup copy and count ===
  integrity_check ok
  PASS  sqlite account_settings           2
  PASS  sqlite messages                   47
  PASS  sqlite planning_revisions         1
  PASS  sqlite projects                   6
  PASS  sqlite sermons                    12
  PASS  sqlite sqlite_sequence            4

=== 4. app_data archive extracts and carries the real files ===
  PASS  app_data/app.db
  PASS  app_data/BSB.json
  PASS  app_data/theographic-bible-metadata-master
  voice samples restored: 1
  sermon/presentation dirs: 5

=== 5. runtime.env restored, contents never printed ===
  bytes=1288 mode=600 keys=23

REHEARSAL PASSED
```

The counts match source exactly: 203,648 nodes, 960,556 relationships, 31,105 verse vectors, twelve sermons, six projects, one voice sample.
The brief said five projects; there are six, because one was created on the box after the brief was written.

Everything the rehearsal created was removed when it finished.

---

## Step 2 - swap

The box had none.
That matters more than it sounds: with no swap, a memory spike does not make the machine slow, it makes the kernel choose a process and kill it.
The OOM killer picks by resident size, and the largest resident process on this box is Neo4j.
So the pre-Phase-0 failure mode for a spike was Neo4j being killed mid-transaction, which is precisely how a database loses a write.

4 GiB of swap does not make the box bigger.
It converts that failure from a kill into a slowdown, which is recoverable and which monitoring can catch before it becomes data loss.

Swappiness is 10 rather than the default 60, because the intent is a safety net rather than a place to live.
At 10 the kernel reclaims page cache long before it pages out a database's anonymous memory, so swap stays empty in normal running and is there for the spike.

```
dd if=/dev/zero of=/swapfile bs=1M count=4096
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
printf 'vm.swappiness = 10\n' > /etc/sysctl.d/99-ha-phase0-swap.conf
sysctl --system
```

`dd` rather than `fallocate`, because a swap file has to be fully allocated and `fallocate` can leave unwritten extents that `swapon` refuses.
`/etc/fstab` was copied to `/etc/fstab.ha-phase0.bak` first.

### Proof that it persists

The box was not rebooted.
Rebooting a VPS that serves a live site is an outage, and there is a check that exercises the same code path without one.

Boot activates swap in two steps: `systemd-fstab-generator` turns each `swap` line in `/etc/fstab` into a `.swap` unit, and that unit calls `swapon`.
Both were exercised directly:

```
# systemctl daemon-reload                  <- re-runs the generator over /etc/fstab
# systemctl list-units --type=swap --all
  swapfile.swap loaded active active /swapfile
# systemctl is-enabled swapfile.swap
generated

# swapoff -a                               <- drop all swap, as if freshly booted
Swap:              0           0           0
# swapon -a                                <- the call the boot path makes
NAME      TYPE SIZE USED PRIO
/swapfile file   4G   0B   -1
```

The generated unit is the same artifact boot uses, and `swapon -a` reads the same `/etc/fstab`.
If the fstab line were wrong, both would have failed here.

---

## Step 3 - trim SIQsermon to its measured working set

Applied through SIQsermon's own repository and deploy path, never by hand on the box, so the next deploy does not undo it:
**[fpresta0607/SIQsermon#19](https://github.com/fpresta0607/SIQsermon/pull/19)**.

The full reasoning, the validation run and the per-container arithmetic are in [`measurements.md`](measurements.md).
In short: the stack declared 6,912 MiB of the box's 7,878 MiB and used about 1,850 MiB.

| container | peak working set | cgroup peak | old limit | new limit | freed |
|---|---|---|---|---|---|
| neo4j | 1,008 MiB | 1,244 MiB | 3,584M | 1,792M | 1,792 MiB |
| backend | 775 MiB | 985 MiB | 1,536M | 1,280M | 256 MiB |
| qdrant | 101 MiB | 551 MiB | 1,536M | 768M | 768 MiB |
| caddy | 20 MiB | 21 MiB | 256M | 128M | 128 MiB |
| **total** | **1,904 MiB** | | **6,912M** | **3,968M** | **2,944 MiB** |

Neo4j's heap and page cache move with its container limit in the same commit.
Lowering the container limit alone would have left the JVM believing it could still take 2g of heap plus 1g of page cache, so the kernel would have killed it at the new ceiling instead of the old one.
That is the whole point of the brief's warning, and it is why this is one change rather than four.

Merged as `abdaa9f` and deployed on 2026-09-17 at 22:14 UTC with SIQsermon's own `deploy.sh deploy`.
The smoke test passed inside the deploy, all four containers came up healthy, and the release symlink now points at `abdaa9fe13936bce867282bc792eeeeb77f492fb`.

The JVM actually took the new settings, which is the part that mattered:

```
-XX:InitialHeapSize=536870912      # was 536870912
-XX:MaxHeapSize=536870912          # was 2147483648
-XX:SoftMaxHeapSize=536870912      # was 2147483648
server.memory.pagecache.size=512.00MiB   # was 1.00GiB
```

### Does the live store behave like the throwaway one

A restored copy under synthetic load is not the live store under real traffic, so the same 22 minute window was re-run afterwards.
450 requests, every one a 200.

| | throwaway test predicted | live under the new limit |
|---|---|---|
| mean working set | 910.7 MiB | 904.9 MiB |
| cgroup peak | 1,406 MiB | 1,409 MiB |
| headroom under 1792M | 386 MiB | 383 MiB |
| OOM kills | 0 | 0 |

Within 3 MiB on the peak.
Peak working set is 1,011 MiB against the throwaway's steady 910.7, because live traffic is more varied than a scan loop, and that is still 78% of the limit.

---

## Step 4 - SIQsermon is unharmed

`scripts/siqsermon-verify.sh` run three times: after the backup, after the swap change, and after the deploy.
It checks the things a memory change would actually break, plus the things this phase must never have touched.
The run below is the last one, on the new limits.

```
=== containers ===
PASS  deploy-caddy-1 health            healthy      PASS  deploy-caddy-1 oom-killed    false
PASS  deploy-backend-1 health          healthy      PASS  deploy-backend-1 oom-killed  false
PASS  deploy-neo4j-1 health            healthy      PASS  deploy-neo4j-1 oom-killed    false
PASS  deploy-qdrant-1 health           healthy      PASS  deploy-qdrant-1 oom-killed   false

=== public endpoint and a real user path ===
TLS certificate: Let's Encrypt, valid to 15 Dec 2026, http/2, verify result 0
  GET    /health                                        200
  POST   /login                                         200
  GET    /session                                       200
  GET    /settings                                      200
  GET    /sermons                                       200
  GET    /projects                                      200
  busiest project id: 11 (12 messages)
  GET    /projects/11                                   200
  GET    /projects/11/messages                          200    11,724 bytes of conversation
  GET    /projects/11/application/messages              200

=== record counts still match the backup manifest ===
PASS  neo4j nodes                      203648
PASS  neo4j relationships              960556
PASS  qdrant verses points             31105
PASS  sqlite account_settings          2
PASS  sqlite messages                  47
PASS  sqlite planning_revisions        1
PASS  sqlite projects                  6
PASS  sqlite sermons                   12

=== nothing in the network path moved ===
PASS  ufw                              active
PASS  ufw rules                        22/tcp 80/tcp 443/tcp
PASS  published ports                  80 443
PASS  caddyfile                        4e2aa1f30a539bfad065cc1bdab3e3bc66f737dc752b6cad0f20e198d3937f26

=== swap ===
PASS  swap active                      /swapfile
PASS  swap size                        4G
PASS  swappiness                       10
PASS  swap unit generated from fstab   active

SIQSERMON VERIFIED
```

The Caddyfile hash is compared between the repository and the deployed release, so a hand edit on the box would show up here.
No port, firewall or DNS change occurred.

Zero OOM kills and zero restarts on all four containers across the whole post-deploy window.

### Memory, before and after

Both columns are peaks over an identical 22 minute load window, 450 requests, all 200.
Before is the stack as found; after is the same stack on the new limits.

| container | peak before | peak after | cgroup peak after | limit before | limit after | headroom | used |
|---|---|---|---|---|---|---|---|
| neo4j | 1,008 MiB | 1,011 MiB | 1,409 MiB | 3,584M | 1,792M | 383 MiB | 78% |
| backend | 775 MiB | 818 MiB | 1,032 MiB | 1,536M | 1,280M | 248 MiB | 80% |
| qdrant | 101 MiB | 107 MiB | 126 MiB | 1,536M | 768M | 642 MiB | 16% |
| caddy | 20 MiB | 15 MiB | 19 MiB | 256M | 128M | 109 MiB | 14% |
| **declared** | | | | **6,912M** | **3,968M** | | |
| host available | 5,342 MiB | 5,245 MiB | | | | | |
| swap | none | 4 GiB, 0 B used | | | | | |

Zero OOM kills and zero restarts on all four.

The working sets barely moved, which is the point: the stack was never using the memory it had reserved, so taking the reservation away changed the declaration and not the behaviour.

**The backend is the one to watch.**
At 80% of its limit it has the least room of the four, and behind those 248 MiB sit `/generate`, narration and slide rendering, which were not in the measured window.
The 2026-09-18 retune lowered it again, so the current ceiling and what to do if it starts getting OOM-killed are in [`budget.md`](budget.md#ceilings-are-set-from-the-measurement-with-file-cache-treated-as-reclaimable).
A backend OOM kill costs a request; it is not the data-loss failure this phase exists to prevent, because that one was Neo4j and Neo4j now sits at 78% with 383 MiB spare.

---

## Step 5 - the assistant budget

See [`budget.md`](budget.md), which is where the number lives.

---

## Rollback

Everything this phase changed on the box, and the exact command to undo it.
Nothing here is destructive to SIQsermon data.

### Swap

```
swapoff /swapfile
rm -f /swapfile
cp /etc/fstab.ha-phase0.bak /etc/fstab
rm -f /etc/sysctl.d/99-ha-phase0-swap.conf
sysctl --system
systemctl daemon-reload
```

Verify with `swapon --show` printing nothing and `sysctl -n vm.swappiness` printing 60.

### The limits change

Deployed. Roll back with:

```
/opt/siqsermon/current/deploy/deploy.sh rollback
```

That is SIQsermon's own rollback.
It relinks the previous release and brings the stack back up with every volume preserved.
Revert [SIQsermon#19](https://github.com/fpresta0607/SIQsermon/pull/19) afterwards, or the next deploy re-applies it.

**Superseded on 2026-09-18.**
[SIQsermon#20](https://github.com/fpresta0607/SIQsermon/pull/20) retuned these ceilings again, so a rollback now lands on the retuned limits rather than Phase 0's, and undoing Phase 0's limits means reverting both pull requests.
See [`budget.md`](budget.md#where-the-memory-came-from).

### The backup and the working files

These consume 524 MB and 4 GB respectively and are the only other things added:

```
rm -rf /var/backups/siqsermon/20260917T214003Z    # only once it is no longer wanted
rm -rf /var/tmp/ha-phase0
```

Do not remove the backup before the limits change has been deployed and verified.

### Restoring from the backup, if it ever comes to that

```
BK=/var/backups/siqsermon/20260917T214003Z
cd /opt/siqsermon/current/deploy
export RUNTIME_ENV_FILE=/etc/siqsermon/runtime.env
alias dc='docker compose --env-file /etc/siqsermon/runtime.env -f docker-compose.prod.yml'

# neo4j
dc stop neo4j
mkdir -p /var/tmp/restore && cp $BK/neo4j.dump /var/tmp/restore/ && chmod -R 755 /var/tmp/restore
docker run --rm -v deploy_neo4j_data:/data -v /var/tmp/restore:/backup:ro neo4j:5-community \
  neo4j-admin database load neo4j --from-path=/backup --overwrite-destination=true
dc up -d --wait neo4j

# qdrant
QIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' deploy-qdrant-1)
docker cp $BK/verses-*.snapshot deploy-qdrant-1:/qdrant/snapshots/verses/
curl -X PUT "http://$QIP:6333/collections/verses/snapshots/recover" \
  -H 'content-type: application/json' \
  -d '{"location":"file:///qdrant/snapshots/verses/<snapshot-name>"}'

# sqlite and the data volume
dc stop backend
docker cp $BK/app.db deploy-backend-1:/app/data/app.db
dc up -d --wait backend
```

`scripts/siqsermon-restore-rehearsal.sh` is the rehearsed version of the first three of those and has been run successfully against this backup.
