# OpenClaw on the shared VPS

This is the runtime layer only: the box, the container, its state, its limits, and its backup.
It describes the first household's box; another household's box is set up and kept current as [A new household's box](new-household.md) says, from the same scripts.
The [Phase 1 household service](../../README.md#phase-1---identity-and-privacy-spine) defines authenticated identity and scopes; the deployed gateways' family-room access and tool context are described in [What a family-room turn may use](#what-a-family-room-turn-may-use).

The initial deployment was verified on the IONOS box on 2026-09-18; later changes are dated in their sections.

| | |
|---|---|
| image | `openclaw/openclaw:2026.9.4` |
| digest | `sha256:cc596b846506a5f4cfcee111394a2725f375f01cca2ebb492a161fd1b747f101` |
| source revision | `3a9d69db306cd7f081e06254cb89c4bcc14a7107` |
| base image | `node:24-bookworm-slim` |
| container | `openclaw-gateway` |
| compose file | `/opt/household-assistant/docker-compose.yml` |
| reachable at | `http://127.0.0.1:18789/` on the box, and `https://household.example.ts.net:18789/` on the household tailnet; nowhere else |
| state | `/var/lib/household-assistant/openclaw`, 155 MB |
| limits | see [What the limits are](#what-the-limits-are) |
| measured idle | 309 MiB fresh, 416 MiB after 11 h |
| model backend | OpenRouter for everything once `openclaw-openrouter.py apply` has run, see [The model backend](#the-model-backend) |

---

## How to reach it

The gateway publishes on `127.0.0.1:18789` on the box, and `tailscale serve` carries that one port onto the household tailnet as HTTPS.
There is no public port, no firewall rule, no Caddy route and no Funnel for the gateway, and there is not meant to be one.
The one inbound rule the tailnet has is Tailscale's own UDP 41641, which carries only WireGuard between tailnet devices, see [Direct paths for the phones](#direct-paths-for-the-phones).
From the box:

```
curl -fsS http://127.0.0.1:18789/healthz
```

From any device signed in to the household tailnet, the Control UI is `https://household.example.ts.net:18789/`, and the Steward app pairs with `wss://household.example.ts.net:18789`.
Denise's gateway is the same name on port 18790.
Paste the gateway token into the Control UI's Settings.
The Steward app never sees it: it pairs from a single-use code, see [Pairing a phone](#pairing-a-phone).
The token lives in `/etc/household-assistant/openclaw.env` at mode 0600.
Read it on the box with `cat`; it is deliberately not in this document, not in the repository, and not in `openclaw.json`, which holds only an environment reference to it.

The token alone does not let a new browser or phone in.
Its first connect is answered `PAIRING_REQUIRED` with a request id, and the device waits until that request is approved on the box:

```
docker exec openclaw-gateway node dist/index.js devices list
docker exec openclaw-gateway node dist/index.js devices approve <request id>
```

### How the tailnet reaches it

Tailscale 1.102.4 is installed from Tailscale's apt repository and signed in as the machine `household` in the Overlord's tailnet.
Both gateways were published at 03:12 UTC on 2026-09-19 (tailscaled's journal), with no record in this repository until 2026-09-24; these are the commands that produce the configuration found on the box:

```
tailscale serve --bg --https=18789 http://127.0.0.1:18789
tailscale serve --bg --https=18790 http://127.0.0.1:18790
```

`--bg` keeps the configuration in tailscaled's own state, so it survives a restart of tailscaled or of the box.
HTTPS uses the tailnet's certificate for `household.example.ts.net`, which tailscaled obtains and renews itself.
`tailscale serve status` marks both entries `(tailnet only)`.
`tailscale funnel` is what would put them on the internet; it has never been run here, and `openclaw-verify.sh` fails if any funnel is on.

Each gateway's `gateway.controlUi.allowedOrigins` also lists its own tailnet address, which is what lets the Control UI load from it.

### Direct paths for the phones

A phone reaches the box directly over Tailscale only when its WireGuard packets can reach the box's UDP 41641.
Without that, a phone behind a strict or carrier NAT goes through one of Tailscale's relays on every connect, chat and call, which is slower.
The hosting provider's firewall policy, in front of the box, admits UDP 41641; on the box, Tailscale's own `ts-input` chain accepts it ahead of ufw's default deny.
ufw itself allows only 22, 80 and 443, which `openclaw-verify.sh` and `siqsermon-verify.sh` check.
Removing the provider's UDP 41641 rule sends the phones back to the relay, and nothing else on the box depends on it.
The provider-side steps and measurements are in the household's private ops notes.

### Why the gateway trusts the host as a proxy

`tailscale serve` is a reverse proxy, and it forwards each request with `X-Forwarded-For` naming the tailnet client.
The gateway refuses proxied traffic from an address it has not been told is a proxy.
With serve alone, every WebSocket upgrade over the tailnet was answered `403 proxy_attribution_required` while `/healthz` still answered 200, which is why the phone sat on "Connecting".

Every host-side connection reaches the container through docker-proxy, so the gateway sees it coming from the host's address on a bridge network: `172.18.0.1` on `deploy_default` while the gateways were on SIQsermon's network, or `172.19.0.1` on `household-assistant_default`, the gateways' own network, which docker maps the port through once they are off SIQsermon's (see [Retiring SIQsermon](siqsermon-retirement.md)).
Both gateways trust exactly those two addresses, set on 2026-09-24:

```
docker exec openclaw-gateway node dist/index.js config set gateway.trustedProxies '["172.18.0.1","172.19.0.1"]' --strict-json
docker exec openclaw-denise node dist/index.js config set gateway.trustedProxies '["172.18.0.1","172.19.0.1"]' --strict-json
```

It is a restart-class setting, and the gateway restarts itself in process: the container and its PID 1 stay up, and each gateway was ready again within four seconds.
Only the host can open a connection from those addresses.
The gateway then takes the client from the right-most untrusted entry of `X-Forwarded-For`, which is the one serve adds, and refuses a loopback claim, so a tailnet client is attributed by its own tailnet address, rate limited per address, and never treated as local.

**The cost.**
A host-side request with no forwarded header now comes from a trusted proxy that names no client, and the gateway refuses it as unattributable.
Two things changed because of that:

- The SSH port forward this section used to recommend no longer reaches the Control UI: the page and its WebSocket answer 403. Use the tailnet address above.
- `openclaw-verify.sh` runs its HTTP probes inside the container, where the caller is local. From the host, `startupz` and `readyz` now answer 403.

Nothing else on the box calls the gateway over HTTP.
The spend job and the `openclaw-*.py` scripts go through `docker exec`, which is loopback inside the container, and so does the container's own healthcheck.

If either network is ever recreated on a different subnet, the phone path fails closed with the same 403, and `openclaw-verify.sh` reports it on its `websocket over the tailnet` line.
Setting the new host address the same way brings it back.

### Rolling it back

Each gateway's config before the change is kept beside the live one as `openclaw.json.pre-tailnet-20260924T023948Z`.
To take both gateways off the tailnet and restore the SSH port forward:

```
tailscale serve --https=18789 off
tailscale serve --https=18790 off
docker exec openclaw-gateway node dist/index.js config unset gateway.trustedProxies
docker exec openclaw-denise node dist/index.js config unset gateway.trustedProxies
```

Each unset restarts that gateway in process again, as the set did.
`openclaw-verify.sh` then fails its `tailnet proxy` and `websocket over the tailnet` lines, which is the rollback being true: the phone can no longer reach the gateway.

### Why the container binds `lan` when the point is loopback

Inside a bridge-networked container, `127.0.0.1` is the container, not the host, so a gateway bound to container-loopback is unreachable even from the box itself.
The gateway therefore binds all interfaces **inside its own network namespace**, and privacy comes from the host-side publish being `127.0.0.1:18789:18789`.
Docker's port mapping is what decides who can connect, and it was told loopback.
Verified from outside the box, below.

---

## How to restart it

```
cd /opt/household-assistant
docker compose up -d --force-recreate --wait  # guarantee compose and env changes apply
docker compose up -d --wait                   # recreate services whose definitions changed
docker compose logs -f openclaw-gateway       # watch it
```

`docker compose restart` only restarts the process in the existing container.
It does not re-read `env_file` or the service definition, so use `up -d --force-recreate` when a compose or environment change must apply.

Health, the way the box checks it:

```
/var/tmp/ha-openclaw/scripts/openclaw-verify.sh
```

That script is `scripts/openclaw-verify.sh` in this repository.
The repository is the source of truth; the copies on the box under `/var/tmp/ha-openclaw/scripts/` and `/var/tmp/ha-phase0/` are staging, and `/var/tmp` is cleaned of old files, so re-copy from a checkout rather than trusting what is there.
Stage the whole `scripts/` directory, not `openclaw-verify.sh` alone: the verifier calls `openclaw-household-app.py`, `openclaw-openrouter.py`, `openclaw-speech.py` and `openclaw-pictures.py` for its household-app, model-backend, speech and pictures checks, and they import `gateway_config.py`.
It is read-only and checks the container is healthy, was not OOM-killed, is running the pinned digest, publishes on loopback only, has not changed the firewall, is served on the tailnet with no funnel and accepts a WebSocket there, answers all three HTTP probes from inside the container, still has its state mounted from disk, has no [recurring heartbeat](#the-heartbeat-is-off) enabled, runs [the household app's channel](#the-household-apps-family-room) for its person with nothing Telegram left, passes the [model-backend audit](#the-model-backend), speaks nothing unasked ([Speaking](#speaking)), makes pictures and videos only through [the pictures plugin](#pictures-and-videos), can import [the calendar skill's library](#icloud-through-apple-cal-anywhere), and is inside its declared limits.
It checks one gateway at a time, Corey's by default.
Three values name a gateway, so checking Denise's means setting all three:

```
CT=openclaw-denise PORT=18790 STATE=/var/lib/household-assistant/openclaw-denise \
  /var/tmp/ha-openclaw/scripts/openclaw-verify.sh
```

It then reads her own ceilings out of her own service block.
That scoping is why the script reads the compose file through `compose_value` rather than a bare `awk`: with two services in the file, an unscoped read returns both values joined and every comparison fails, which is what it did until this was fixed.

### After a reboot

Nothing to do.
The container carries `restart: unless-stopped` and `docker.service` is enabled at boot, which is exactly how the four SIQsermon containers already come back.
No systemd unit was added, because one would duplicate a restart policy that already works.

---

## Where its state lives

| path | what it is | owner |
|---|---|---|
| `/var/lib/household-assistant/openclaw` | config, the SQLite databases, the agent directories, the workspace | `1000:1000`, mode 0700 |
| `/var/lib/household-assistant/openclaw-auth-secrets` | the local key that recovers legacy encrypted OAuth credentials | `1000:1000`, mode 0700 |
| `/var/lib/household-assistant/codex` | the Codex harness's working state: goals, memories, queue, skills | `1000:1000`, mode 0700 |
| `/var/lib/household-assistant/bin` | binaries the bundled skills need, mounted at `~/.local/bin`; `gog` today | `root`, mode 0755 |
| `/var/lib/household-assistant/openclaw/pylocal` | the Python packages [the calendar skill](#icloud-through-apple-cal-anywhere) imports, inside the state directory so a recreated container and the backup both keep them | `1000:1000` |
| `/etc/household-assistant/openclaw.env` | the gateway token, the OpenRouter key, the gog keyring password, and until SIQsermon is retired the SIQsermon credentials its export reads | `root`, mode 0600 |
| `/etc/household-assistant/household.json` | the household's own identifiers, which the repository does not hold: its two members, each a person with their assistant and the container, state directory and port of that assistant's gateway; the approver who lets in a phone nobody linked; the box's tailnet name, the app's Google client, the shared calendar and the Bible edition the scripture cards link. Read by the installers through `load_household` in `household_file.py`, shaped like [`deploy/household.example.json`](../../deploy/household.example.json); a file written before it named its members is Franco with Corey and Gia with Denise, on the gateways below | `root`, mode 0600 |

All three state directories are bind-mounted into the container, so replacing the image never loses memory.
`1000:1000` is the `node` user the image runs as; the container does not run as root.

OpenClaw keeps everything authoritative in SQLite: one control-plane database under the state directory and one per agent.
The workspace lives inside the state directory rather than beside it, so a single mount and a single backup cover both.

Treat this directory as credentials.
The Codex OAuth token is a plaintext row in that SQLite, and the separate key directory does not encrypt it.

### The household plugins

The household's plugins are code that runs inside the gateway, so their files are not in the assistant's own state directory.
`scripts/openclaw-install.sh` copies `deploy/openclaw/plugins/` to `/opt/household-assistant/plugins/`, root-owned, and the compose file mounts that read-only at `/opt/household-plugins` in both containers.
It does that through `scripts/install-household-plugins.sh`, which replaces each household plugin the repository ships and touches nothing else there.
`pocket-piggies-corey` and `pocket-piggies-denise` are copies `scripts/pocket-piggies-install.py` makes in the same mount, so until 14 October, when the install still emptied the whole mount, running it would have deleted both.
A plugin the repository no longer ships stays in the mount until it is removed by hand, as household-family-room, household-speech and household-job-mirror do until [Retiring Telegram](retiring-telegram.md#7-what-is-left-on-the-box) removes them.
A plugin loads only once a gateway's config names it, as `openclaw-household-app.py apply` does for household-app, and naming one for the first time makes that gateway restart itself in process.
The same directory holds household-openrouter-video, which `openclaw-openrouter.py apply` names, and which `apply` refuses to name until the installer has put it there.
`apply` adds household-openrouter-video to an existing `plugins.allow` list while keeping its other entries.
It preserves video plugin policy blocks from `plugins.enabled` and `plugins.deny`.
`check` and `verdict` also report an allow list that excludes the video plugin before apply merges it.
The apply plan reports any remaining blocks for the operator to resolve.

---

## What the limits are

The total assistant allowance and its measurement belong to [docs/phase0/budget.md](../phase0/budget.md).
The current limits come from [the repository's Compose file](../../deploy/openclaw/docker-compose.yml).
The declared limits use the full memory allowance: the two gateways and, since 15 October, [Home Assistant](#home-assistant).

| container | declared memory | declared CPU | RSS pressure line |
|---|---|---|---|
| `openclaw-gateway` | 1,664 MiB | 2.50 | 832 MiB |
| `openclaw-denise` | 2,048 MiB | 1.50 | 1,024 MiB |
| `homeassistant` | 768 MiB | 0.50 | |

Corey gave 768 MiB of his 2,432 to Home Assistant on 15 October (CFO decision 1006981).
His new ceiling is still 600 MiB over the 1,058 MiB his longest run held, so the cost is the harmless pressure warning described under [the rebalance](#the-2026-10-05-rebalance), not a kill.

### Initial measurements, 2026-09-18

These readings describe Corey's gateway before Denise's container was added and before [the rebalance](#the-2026-10-05-rebalance):

| container | declared memory | declared CPU | measured idle | cgroup peak | idle against its own limit |
|---|---|---|---|---|---|
| `openclaw-gateway` | 3,072 MiB | 2.50 | **416 MiB** | 854 MiB | 14% |
| **total, 1 container** | **3,072 MiB** | **2.50** | **416 MiB** | 854 MiB | |
| **against the 4,480 MiB / 4 vCPU budget** | 69% declared | 63% declared | **9.3% used** | | |

The gateway was idle at 0.6% of one core, sampled on 2026-09-18 at 11:31Z after 11 hours of uptime: 351 MiB of anonymous memory and 205 MiB of reclaimable file cache.

These early idle readings do not establish the gateway's working set after days of uptime.
The same container measured at several uptimes:

| uptime | working set | anonymous | file cache |
|---|---|---|---|
| minutes after install | 292 MiB | | |
| 1 hour | 313 MiB | 287 MiB | 21 MiB |
| 11 hours | 416 MiB | 351 MiB | 205 MiB |
| **30 minutes, after a recreate** | **309 MiB** | **293 MiB** | **89 MiB** |

The last row is the same container after `docker compose up -d` replaced it, showing that memory use returned near its initial reading on recreation.
The historical table above uses the 416 MiB reading rather than the fresh-container reading; the later rebalance uses longer-running gateways.

Most of the growth is page cache the kernel is holding because nothing has asked for the memory, and it is released under pressure rather than OOM-killed for.
The anonymous half, which is the part that cannot be reclaimed, grew 64 MiB across those eleven hours: at 351 MiB it was 11% of the container's then-current ceiling.
The 854 MiB cgroup peak is cumulative since the container started and includes a brief periodic task that reached 69% of one core during sampling.
Reporting both matters: the declaration is what the kernel enforces, and measured use depends on workload and uptime.
A memory ceiling is a cap rather than a reservation, so unused memory stays available to the box.

Logging is capped at three 10 MB files, matching SIQsermon, so a chatty container cannot fill the disk.

### The 2026-10-05 rebalance

Denise's container took the 1,408 MiB set aside for the household service, on the assumption that a gateway idles well under 700 MiB.
After 16 days of uptime Corey's gateway process held 1,058 MiB of RSS and Denise's 903 MiB.
OpenClaw logs a memory-pressure warning whenever RSS passes half the container's limit, so Denise logged it every five minutes from her first day, 4,219 times, without ever being OOM-killed.
The current declarations above put each pressure line back above its gateway's observed RSS without changing the total budget.
If either gateway starts warning again, its RSS has grown past what this split allows for, and that is the figure to re-measure before moving the split again.

### Home Assistant

Home Assistant runs beside the gateways for the household's home control, and today only for the ecobee and Spotify.
Ecobee gives no new developer keys, and since 2026.3 Home Assistant's ecobee integration signs in with the ecobee.com account instead, which nothing else can.

- It is Home Assistant Container, the smallest supported install, with no add-ons, pinned by digest in the compose file as `homeassistant`.
- Its state is `/var/lib/household-assistant/homeassistant`, mounted as `/config`.
- It publishes `127.0.0.1:8123` only, and the gateways reach it on this stack's own network as `homeassistant:8123`, never on SIQsermon's.
- Its 768 MiB ceiling is an estimate, since Home Assistant publishes no memory figure for Container.
  It is measured for a week from 15 October, then set to its peak with margin, and what it does not use goes back to `openclaw-gateway`.

Taking it back is one step each way: `docker compose rm -sf homeassistant`, then `docker update --memory 2432m --memory-swap 4864m openclaw-gateway` live, with the compose file put back to match. Compose gives each container swap equal to its memory, so the swap figure is twice the limit, and the change itself was `--memory 1664m --memory-swap 3328m`.

### The deployed compose file is the ceiling, and it drifted once

On 2026-09-18 the gateway was running at 3,072 MiB and 2.50 vCPU while `/opt/household-assistant/docker-compose.yml` still declared 1,536 MiB and 1.50.
The budget rework had raised the live container with `docker update`, which takes effect immediately but writes nothing back to the file.
The container was therefore correct and the file that defines it was not, so the next `docker compose up -d` on that box, which is what this very document tells you to run to restart it or to roll it back, would have quietly halved the assistant's ceiling.

That is the same failure mode this phase closed for SIQsermon by merging its retune, and it was still open on the assistant side.
It was fixed by re-running `scripts/openclaw-install.sh`, which installs the repository's compose file over the deployed one and brings the container back up; the gateway was recreated and healthy in twelve seconds and SIQsermon was not touched.

**`openclaw-verify.sh` now asserts it.**
The check reads both ceilings out of the deployed compose file and compares them to what the container is actually running, so this drift fails verification instead of waiting for a restart to expose it:

```
PASS  memory ceiling                   3072MiB
PASS  cpu ceiling                      2.50
```

Both dimensions are asserted, because the drift was in both at once and a half-applied ceiling is what went wrong.

The rule this leaves behind: **`docker update` is for measuring, never for keeping.**
Anything meant to survive a restart goes in the compose file in this repository and reaches the box through the installer.

The image is 4.6 GB unpacked.
It was pulled, never built: a source build wants around 6 GB of RAM, which is more than the whole assistant budget, so the kernel would kill it.

---

## How the backup covers it

Two jobs share one definition of the assistant half, `scripts/household-backup-lib.sh`:

- **`scripts/household-backup.sh`, every night.** Both gateways' state, and the retired coordination relay's database on a box that still has it, then a restore drill of what it wrote, then the oldest backups pruned.
  It writes to `/var/backups/household-assistant/<utc-timestamp>/` at mode 0700.
  See [The nightly backup](#the-nightly-backup).
- **`scripts/siqsermon-backup.sh`, by hand.** The same assistant half together with SIQsermon's data.
  Run it as root.
  It writes to `/var/backups/siqsermon/<utc-timestamp>/` at mode 0700.
  It stops Neo4j for its dump, which is why it is not on a timer.

The assistant's step never copies the live `.sqlite` files.
A raw copy of a database being written is routinely torn, so the job runs `openclaw backup create --verify` in a one-shot container against the same mounted state, with the household plugins mounted read-only where the gateway has them.
That uses SQLite's online backup API and re-verifies the archive it wrote, which is the same guarantee the SIQsermon step already took for `app.db`.
Without the plugins OpenClaw calls the config invalid, since every config has named household plugins by path since 5 October, and refuses to archive at all: until 14 October no run could have archived either gateway.
The archive lands beside the SIQsermon artifacts, its name goes into `MANIFEST.tsv` as `openclaw_archive`, and its checksum goes into `SHA256SUMS`.
The Codex harness's directory is outside what `openclaw backup create` archives, so the job copies each of its SQLite files with the same online backup API, runs `integrity_check` on every copy, and packs them with `installation_id` and `skills/` into `codex-state.tar.gz`, recorded as `codex_archive`.
A failed copy fails the assistant step the same way a failed archive does.
If the assistant state is missing, or its archive fails, the job still completes the SIQsermon dump and the manifest, records `openclaw_archive` as `missing`, and exits non-zero.
SIQsermon's data is irreplaceable and never waits on the assistant; the rehearsal fails such a backup at step 6 rather than reporting green.

The coordination relay was retired with Telegram, and its database, `/var/lib/household-assistant/coordination/coordination.db`, sat outside both gateways, so `openclaw backup create` never sees it.
A box that ran the relay keeps the file, with the off switch's position and the planner's taste store in it, until someone removes it ([Retiring Telegram](retiring-telegram.md#7-what-is-left-on-the-box)), and while it is there the job still copies it on its own with the same online backup API, so a restore brings back what was there.
The copy is reopened, checked with `integrity_check`, and queried against `coordination_flag`, so a copy missing the off switch's table fails; an empty `coordination_flag` passes.
`MANIFEST.tsv` records the outcome as `coordination_archive`: the filename when it was copied, `none` when the box has no such file, and `missing` when the copy failed its own verification and was deleted rather than left behind to be hashed into `SHA256SUMS`.
A failed copy fails the assistant step the same way a failed archive does, so the job finishes the SIQsermon half and exits non-zero.

The assistant step runs after Neo4j is back up, so it does not lengthen the five-second Neo4j window Phase 0 measured.

### The nightly backup

`household-backup.timer` starts `household-backup.service` every night at 04:30 Chicago time, and a night missed while the box was down runs when it comes back.
The service runs `/opt/household-assistant/backup/household-backup.sh --keep 14`:

1. Each gateway through `openclaw backup create --verify`, its Codex directory through SQLite's online backup API, and the coordination database where there is one, as above.
2. `MANIFEST.tsv` and `SHA256SUMS`.
3. `household-restore-drill.sh` on what it just wrote: the checksums, then each gateway's archive through OpenClaw's own `backup restore` into a scratch directory under `/var/tmp`, both of its databases opened with `integrity_check`, its `openclaw.json`, `AGENTS.md`, `USER.md` and `household-memory/kept.json` found, its Codex archive read, and a coordination copy, when there is one, opened with its off switch's table queried.
4. Only when every archive was written and the drill passed: a `RESTORED` file, then the newest 14 backups marked `RESTORED` kept and older ones removed.
   A backup that failed is never counted toward the 14, and a failed run removes nothing.

A failed run fails the unit, so `systemctl --failed` and `journalctl -u household-backup.service` show it.
On 14 October a run took 161 seconds and 282 MB (Corey's archive 101 MB, Denise's 178 MB), so 14 backups come to about 4 GB.

The gateways it archives are the household file's members (`household_gateways` in the library), which on this box are Corey, recorded as `openclaw`, and Denise, as `denise`, as every backup before them was; installed without `household_file.py` beside it, the job archives those two.
The drill restores every gateway its backup's `MANIFEST.tsv` names.

To drill any backup by hand:

```
/opt/household-assistant/backup/household-restore-drill.sh /var/backups/household-assistant/<stamp>
```

To install or update it from a checkout copied to the box, as root:

```
install -d -m 0755 /opt/household-assistant/backup
install -m 0755 scripts/household-backup.sh scripts/household-restore-drill.sh /opt/household-assistant/backup/
install -m 0644 scripts/household-backup-lib.sh scripts/household_file.py /opt/household-assistant/backup/
install -m 0644 deploy/backup/household-backup.service deploy/backup/household-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl start household-backup.service    # one run now, drill included
systemctl enable --now household-backup.timer
```

To stop it, `systemctl disable --now household-backup.timer`.
The backups already taken stay where they are.

### The rehearsal

A backup nobody has opened is not a backup.
`scripts/siqsermon-restore-rehearsal.sh` gained a step 6 that restores the assistant archive into a scratch directory and opens it.
Run on the 2026-09-18 backup:

```
=== 6. assistant state restores into a scratch location and opens ===
  Backup archive restored to staging: /restore/out
  Verified archive: /archive/2026-09-18T00-23-03.799+00-00-openclaw-backup.tar.gz
  Archive root: 2026-09-18T00-23-03.799+00-00-openclaw-backup
  Archive entries restored: 51
  PASS  openclaw.sqlite integrity_check ok
  PASS  openclaw.sqlite tables 108
  PASS  restored openclaw.json
  PASS  restored workspace/IDENTITY.md
  PASS  restored workspace/AGENTS.md

REHEARSAL PASSED
```

`backup restore` verifies the manifest, the hardlinks, symlink containment and every SQLite database before it writes anything, refuses a target that is not empty, and stages files only.
It never touches live state, which is why this is safe to run on the live box.
Everything the rehearsal created was removed when it finished.

To actually restore for real: stop the gateway, move the restored state tree into place, run `openclaw doctor`, then start the gateway.
Restoring is time travel, and the restore output prints the consequences.

### The job is still called `siqsermon-backup.sh`

It backs up two things and is named after one.
Phase 0 named it and the Phase 0 runbook points at that path, so renaming it here would have been a change to SIQsermon's documented recovery path for no benefit this phase needed.
The script carries a `ponytail:` note saying to rename the root and the script together the next time something else has to change there.

---

## How to roll back to the previous pinned version

The image is pinned by digest in `deploy/openclaw/docker-compose.yml`.
Rolling back is editing one line and bringing the container back up; the state directory is untouched by an image change.

**Read the schema check below before you roll back.**
An image change is one line, but the database it opens is not: measured on 2026-09-18, the state 2026.9.4 has written is already a schema version beyond what 2026.9.3 can read.
The digests below are the pins; whether the state travels back to one of them is a separate question the check answers.

| version | digest |
|---|---|
| **2026.9.4** (deployed) | `sha256:cc596b846506a5f4cfcee111394a2725f375f01cca2ebb492a161fd1b747f101` |
| 2026.9.3 (previous stable) | `sha256:6cb72e1599b3b76e2ea3dcc2f4dd7f112247367fbecadfcdee8caa7423f4989b` |
| 2026.6.35 (`extended-stable`) | `sha256:e182383a604b50b11bdc48e9eca39e2c3089bef9f5606393bff07c7796e46883` |

```
# take a backup first: a downgrade cannot undo a schema migration
scripts/siqsermon-backup.sh

# then edit the one `image:` line in /opt/household-assistant/docker-compose.yml
# to the version and digest you are rolling back to, both of them together:
#   image: openclaw/openclaw:2026.9.3@sha256:6cb72e1599b3b76e2ea3dcc2f4dd7f112247367fbecadfcdee8caa7423f4989b

cd /opt/household-assistant
docker compose up -d --wait
```

Change the tag and the digest in the same edit.
Docker resolves the digest and ignores the tag, so leaving `2026.9.4` beside an older digest runs the older image while every `docker ps` and every reader of the file says otherwise.

Then make the same edit in this repository, or the next install run puts 2026.9.4 back.

**Before downgrading, check the state is readable by the older version.**
A newer gateway can migrate the database forward in a way an older one cannot read, and `database preflight` is the check for that.
It needs a consolidated database with no `-wal` or `-shm` sidecars, so point it at the copy inside the backup you just took rather than at the live file:

```
W=/var/tmp/oc-preflight
mkdir -p $W/archive $W/out
cp /var/backups/siqsermon/<stamp>/*-openclaw-backup.tar.gz $W/archive/

# chown AFTER the copy, or the archive lands root:root and the container,
# which runs as uid 1000, cannot read it.
chmod 700 $W $W/archive $W/out && chmod 600 $W/archive/*.tar.gz
chown -R 1000:1000 $W

docker run --rm -v $W/archive:/archive:ro -v $W/out:/restore \
  --entrypoint node openclaw/openclaw:2026.9.4 \
  dist/index.js backup restore /archive/<archive-name> --target /restore/out

# now ask the OLDER image whether it can read that schema
docker run --rm -v $W/out:/restore:ro --entrypoint node \
  openclaw/openclaw@sha256:<older-digest> \
  dist/index.js database preflight \
  /restore/out/<archive-root>/payload/posix/home/node/.openclaw/state/openclaw.sqlite
```

A healthy answer looks like `Database preflight: exact (found 17, target 17)`.
If it reports anything else, do not downgrade in place; restore the state from a backup taken on the older version instead.
Remove `$W` when you are done, and remember it holds credentials.

**Run against 2026.9.3 on 2026-09-18, this procedure answered `incompatible (found 17, target 16)`.**
So an in-place downgrade to 2026.9.3 does not work today: 2026.9.4 has already migrated the database a schema version past what 2026.9.3 can read.
Rolling back to it means restoring state from a backup taken while 2026.9.3 was running, and there is no such backup, because this box has only ever run 2026.9.4.
That is the honest state of the rollback path, and it is exactly what this check exists to tell you before you stop a healthy container rather than after.

If an upgrade leaves the container restarting rather than healthy, the documented repair is to run the same image once with doctor against the same mount:

```
docker run --rm -v /var/lib/household-assistant/openclaw:/home/node/.openclaw \
  openclaw/openclaw:2026.9.4 node dist/index.js doctor --fix
```

### Removing it entirely

```
cd /opt/household-assistant && docker compose down
rm -rf /opt/household-assistant /etc/household-assistant /var/lib/household-assistant
docker image rm openclaw/openclaw:2026.9.4
```

Nothing there is shared with SIQsermon.

---

## Home control

Corey and Denise reach the house through a home key holder on the host, the same shape as the PocketPiggies one: `household-home@corey` and `household-home@denise`, each under its own system user.
It holds the assistants' Home Assistant token and the living room Apple TV's pairing in `/var/lib/household-home/<persona>`, which no container mounts.
The gateway reaches it only through `home.sock` in its own state directory, which the instance drop-in binds at `/run/household-home`, and gets back what the house read back, never the token or the pairing.

The socket speaks MCP, and offers nine tools and nothing else (`household/home/server.py`):

| Tool | What it does | Its limit |
| --- | --- | --- |
| `home_status` | Reads the thermostat with its mode and what it holds, the music with what is playing and where and Spotify's devices, and the TV's power and volume. | |
| `home_thermostat` | Holds the house at one temperature on heat or cool, or between two on auto, in the mode the thermostat is already in. | 62 to 80°F, whole degrees, a range at least 5 apart, and a yes every time. |
| `home_volume` | Sets the TV's own volume, or steps it up or down by 10. | Never set above 70%, and a yes to raise it above 40%. |
| `home_music` | Pauses, resumes, skips or goes back. | Only for music playing on the TV. |
| `home_play` | Plays a track, album, artist or playlist on the living room TV. | Found by Spotify's own search from a query and its kind, or an `open.spotify.com` link. |
| `home_open_spotify` | Wakes the TV and opens its Spotify app. | |
| `home_youtube` | Wakes the TV and plays one YouTube video in the YouTube app. | A youtube.com or youtu.be link to one video, which the assistant finds with its web search when the person names or describes one. |
| `home_video` | Pauses, resumes, goes to the next or previous video, or seeks, in what plays on the TV. | Seeking up to 600 seconds either way, and only when what plays offers it. |
| `home_tv` | Turns the living room TV on or off. | |

These limits are the real ones: the Home Assistant user `steward` the token belongs to is not an admin, but Home Assistant lets any user control every entity, so the key holder is what keeps the assistants to the thermostat and the music.
A change the tool wants a yes for comes back as `needs_yes` with the question to ask, and goes through only when the assistant calls again with `confirmed` after the person said yes.
Every answer reads the device back afterwards, so the assistant reports what the house did, not what was asked.
A refusal carries a code and a reason in plain words, such as the TV not waking or Spotify never listing it, which the assistant passes on.
A connection is bounded in size, count and time, calls are limited to 30 a minute and changes to 10, one call runs at a time, and the journal records each call by its tool and outcome only.

The thermostat is set the way Home Assistant's ecobee integration and the ecobee itself take it:

- The integration's `climate.set_temperature` sets a range only on auto (`heat_cool`) and one temperature only on heat or cool, and ignores any `hvac_mode` passed with either. A range sent while the thermostat is on heat changes nothing and logs `Missing valid arguments for set_temperature`, so the key holder reads the mode first and asks for what that mode holds, and never changes the mode.
- On auto the ecobee keeps heat and cool at least 5°F apart, its heat/cool minimum, and spreads a narrower range around its middle. On 17 October 2026 Denise asked for 70 to 73 five times in seven seconds and got 69 to 74 back each time, and every range Home Assistant recorded from 15 October on was 5 or more apart, so the key holder refuses a range narrower than 5.
- After a set it compares what the thermostat holds with what was asked, and answers `thermostat_held_otherwise` with both when they differ, so the assistant says what the house did instead of asking again.
- An `off` or unavailable thermostat is left alone, with `thermostat_off` or `thermostat_unavailable`.

- Home Assistant is reached at `http://127.0.0.1:8123`, its loopback port on the host.
- The Apple TV is reached over the tailnet with pyatv's Companion protocol, addressed by hand, since discovery does not cross the tailnet: its tailnet address, its Companion port and a pairing made with a code the TV shows.
- The unit allows IP traffic only to loopback and the tailnet's `100.64.0.0/10`.
- Playing music needs the TV's Spotify app open, since Spotify lists the TV as a place to play only then, and drops it within a minute of the TV sleeping. `home_play` always wakes the TV, opens Spotify and waits up to half a minute for Spotify to list it, and plays nothing if it never shows. Waking counts only once the TV reports itself on. On 17 October 2026 a sleeping TV woke in about 6 seconds and Spotify listed it 2 seconds after the app opened, but a TV that had just fallen asleep ignored every wake for about 10 seconds, so the wake goes again every 3 seconds for up to 21 seconds.
- Pausing and skipping act only when Spotify is playing on the TV, so a song on someone's phone or in the car is left alone and the refusal says where it is playing.
- YouTube is opened with a `youtube://watch/<video id>` link over the Companion pairing, the form Home Assistant's Apple TV integration documents. The TV refuses a youtube.com web link with "Open URL failed", so the key holder takes any YouTube link and sends that form. The TV's media controls are what `home_video` uses and reads back: it offers Pause only while something plays, and skipping only when the video does. No key such as Select ever goes to YouTube, since on its "Who's watching?" screen one can choose watching signed out; a video that waits there is reported for the person to pick with the remote.
- Spotify lists the Apple TV as a device without volume control, always at 100%, and refuses to change it. The volume is the TV's own, set over the same Companion pairing. The TV takes a new level without announcing it, so the key holder reads it back on a fresh connection.

Home Assistant's Spotify device cache refreshes every five minutes, independently of playback.
`homeassistant.update_entity` refreshes playback alone, so it cannot discover a TV that just opened Spotify.
Home Assistant's own `play_media` also sends a song to whichever device Spotify lists first when nothing is playing.
The `household_home` custom integration holds three actions for one Spotify entity, all with that integration's OAuth credential, which never leaves Home Assistant:

- `household_home.refresh_spotify` refreshes the device cache without changing playback. The key holder calls it before checking readiness, including on `home_status`, whose music result includes `tv_ready`.
- `household_home.search_spotify` answers Spotify's first track, album, artist or playlist for a query. Spotify answers an app in development mode ten results at most and leaves out the playlists Spotify itself owns, and asking for one result ranks them differently, so it asks for ten and takes the first.
- `household_home.play_spotify` plays a Spotify uri on one device named as Spotify lists it, and succeeds only once Spotify's own playback reports that device playing that uri, since spotifyaio passes most of Spotify's refusals back as plain answers.

### Its files on the box

- `/opt/household-assistant/home/`: `household/home/*.py`, `home-keyholder.py`, and `venv/` with pyatv and what it needs from `deploy/home/requirements.txt`, installed with `--require-hashes --only-binary :all:`.
- `/etc/systemd/system/household-home@.service`, and the drop-in `household-home@<persona>.service.d/gateway.conf` with `BindPaths=<gateway state>/home:/run/household-home`.
- `<gateway state>/home/`, owned by the key holder and setgid 2750 to the gateway's group, so the gateway can connect to `home.sock` and cannot plant, rename or remove anything there. The key holder refuses to start on any other directory, and never replaces a file at the socket path that is not its own socket.
- `/var/lib/household-home/<persona>/`, mode 0700, owned by the key holder's user:
  - `config.json`: `{"hass": "http://127.0.0.1:8123", "entities": {"thermostat": "climate.thermostat", "spotify": "media_player.spotify_household", "tv_spotify_name": "<the TV's name in Spotify>"}, "tv": {"address": "<tailnet address>", "port": <Companion port>}}`.
  - `token`: the vault's `HA_ASSISTANTS_TOKEN`, moved by stdin, never on a command line.
  - `apple-tv-credentials`: the Companion pairing, one for the TV, written into each key holder's state.

The key holder refuses to start when `config.json` points Home Assistant anywhere but loopback, names no entity, or gives no port, and when the token is missing or empty.
It starts without the pairing, and until the pairing is there its TV steps answer `tv_not_paired` and the rest works.

The box's `python3` has no `ensurepip`, so the venv is made with `python3 -m venv --without-pip` and pip runs from its wheel, which `scripts/home-install.py` pins by URL and SHA-256.
To move pyatv to a new release, regenerate the lock where it will run:

```
uv pip compile --generate-hashes --python-version 3.14 --python-platform x86_64-manylinux_2_28 --only-binary :all: --no-header --no-annotate <(echo pyatv==<version>) -o deploy/home/requirements.txt
```

### Installing it, one gateway at a time

No gateway restarts: the gateway's state is already mounted, so the socket directory appears inside it, and nothing calls the socket until the household-app plugin with `household_home` is on the gateway.
As root on the box, from a checkout of main:

```
# 0. The rollout backup of both gateways' state, as for any rollout (Box backups).
# Install the household_home Spotify actions, then restart only Home Assistant.
python3 scripts/home-install.py install-ha
docker restart homeassistant
# 1. Corey's key holder. The token goes by stdin from the vault, never on a command line.
#    Prints the unit's state read back, and exits 1 unless it is active.
python3 scripts/home-install.py install corey --tv-address <tailnet address> --tv-port <Companion port> \
  --tv-spotify-name "<the TV in Spotify>" --thermostat-entity <climate entity> \
  --spotify-entity <media_player entity> --token-stdin
# 2. Denise's the same way.
# 3. The pairing, once, for both. The TV shows a code, which goes into
#    /run/household-home-pair/pin as its four digits. It waits 30 minutes for it.
/opt/household-assistant/home/venv/bin/python scripts/home-install.py pair \
  --tv-address <tailnet address> --tv-port <Companion port>
# 4. Read each unit back: active, and its journal says "serving" and nothing else.
systemctl is-active household-home@corey household-home@denise
journalctl -u household-home@corey -u household-home@denise -n 20 --no-pager
```

The TV's name in Spotify shows in `source_list` of `media_player.spotify_household` while Spotify is open on the TV. Running `install` again with the right `--tv-spotify-name` and no `--token-stdin` replaces the config and keeps the token.
The two Home Assistant entity ids name the household's own rooms and accounts, so they are given on every install and live only in the key holder's `config.json`; read them from there before installing again.

To take it back, for each persona:

```
systemctl disable --now household-home@<persona>.service
rm -r /etc/systemd/system/household-home@<persona>.service.d
shred -u /var/lib/household-home/<persona>/token /var/lib/household-home/<persona>/apple-tv-credentials
rm -r /var/lib/household-home/<persona> <gateway state>/home
userdel household-home-<persona>
```

Then `rm /etc/systemd/system/household-home@.service`, `systemctl daemon-reload` and `rm -r /opt/household-assistant/home`, and remove the pairing on the TV under Settings, Remotes and Devices.

---

## The memory backend

The builtin SQLite engine, which is the default, with chat transcripts named as a source and the household-memory plugin beside it.
No LanceDB and no Honcho.
On 14 October recall was shown to be the bottleneck, and [What a family member asks to keep](#what-a-family-member-asks-to-keep) is what was added.

Vector search needs an embedding provider, and both gateways get theirs from OpenRouter with the same `OPENROUTER_API_KEY` their models use.
Until 2026-10-05 Corey's embeddings rode on the Codex login; once that token expired, every memory sync failed (201 times in one week) and 18 of his 63 files went unindexed.
Denise never had a provider at all: her index was built keyword-only and her vector search was paused.

Each gateway's `openclaw.json` now carries this under `agents.entries.main.memory.search`:

```json
{
  "provider": "openai",
  "model": "openai/text-embedding-3-small",
  "remote": {
    "baseUrl": "https://openrouter.ai/api/v1",
    "apiKey": {
      "source": "env",
      "provider": "default",
      "id": "OPENROUTER_API_KEY"
    }
  }
}
```

- It sits on the agent entry because 2026.9.4 rejects both `agents.defaults.memorySearch` and `agents.defaults.memory` as unrecognized keys.
- `provider: "openai"` names OpenClaw's OpenAI-compatible embedding client, not an OpenAI account.
  It keeps the `openai/` prefix on the model whenever the base URL is not `api.openai.com`, which is the form OpenRouter expects.
- A hot reload does not always swap the provider inside a running memory manager.
  Corey's picked it up; Denise's watcher kept refusing to sync until her gateway restarted.
  Restart a gateway after changing this.
- After a provider change, rebuild the index with `docker exec <container> node dist/index.js memory status --index --agent main`.
  On 2026-10-05 it reported `Embeddings: ready` with every file indexed on both gateways.

`openclaw-openrouter.py apply` preserves these working agent settings and Corey's global `memory.search.provider: "none"`.
An agent's `memory.search` overrides the global default key by key, so the audit checks the effective endpoint even when the agent inherits its provider.
The migration changes a global default only when it would embed elsewhere, clears an agent override that would still embed elsewhere, and disables foreign embedding fallbacks without replacing a working OpenRouter endpoint.

### Why memory search stopped, 13 October

Each agent's `memory.search` also carries `"sources": ["memory", "sessions"]` and `"experimental": {"sessionMemory": true}`.
Without them, OpenClaw 2026.9.4 indexes chat transcripts only while "remember across conversations" is on, and that setting defaults to off as soon as `session.dmScope` is anything but `main` (`resolveRememberAcrossConversations`).
The Telegram family-group change on 13 October set `per-channel-peer`, which dropped transcripts from both indexes.
An index whose sources no longer match its settings pauses search until it is rebuilt, so from then on every `memory_search` answered "paused": 17 of 17 in the recall run on 14 October.
`scripts/openclaw-memory.py check` reports what each gateway indexes, worked out the way 2026.9.4 does it.

### What a family member asks to keep

On 14 October both assistants were asked 20 older facts from private chats and the Telegram family group, each in a throwaway session.
They found 18, but none through memory search, and 8 by grepping raw files with a shell, which the family room's tools do not allow.
The two misses were both things a family member had asked them to keep: one was never written down at all, the other only as a later decision.
Their instructions sent such a request to the day's note, which search ranks down by half every 30 days, and told them to remove outdated entries.
Nothing had been deleted: every chat since 18 September was still in each gateway's database.

After the rollout below, the same 20 questions found 20, with 26 tool calls where there had been 71 and no shell command where there had been 22, and memory search answered every time it was asked.
Both asks to keep that had been missed were answered from the kept list without a tool call.

`deploy/openclaw/plugins/household-memory` does three things in each turn's prompt-build hook, before the model answers, with no model call of its own:

- **Keep.** A message that asks to remember, keep track of, note, not forget or be reminded of something is kept as it was said, with who asked, when and in which chat.
  A question such as "do you remember..." is not kept.
  The rule is judged sentence by sentence, so a long voice note that asks about the past in one sentence is not kept for it.
- **Show.** Every turn starts with what was kept for that chat, newest first within 4,000 characters, with the items that share words with the message ahead of the rest.
  Kept in the owner's own thread, it is shown only there.
  Kept in the family room, it is shown there and in the owner's thread.
- **Find.** A question about the past gets the three best lines from that chat's own history, read from OpenClaw's transcript index.
  In the family room that is the room alone.
  In the owner's own thread it is every session linked to that thread, and the room.
  It matches any of the question's words and ranks lines by how many they share, where `sessions_search` needs every word.

In the owner's own thread the model also gets `recall`, whose only parameter is the words to look for, and `forget`, which marks a kept item done by its number.
A family-room turn the owner started, which runs in the owner's own session of the room, has them too.
The family room's tool list does not change: keeping and finding there need no tool.

The chats are the household app's: the owner's own thread is the private chat, and the family room the family group.
The plugin knows everyone by their household person id, `franco` or `gia`, as the app's channel does, from its config's `ownerPersonId` and `people`, which `openclaw-memory.py apply` writes; `check` prints whose requests each gateway keeps.
While the family used Telegram the config named people by their Telegram ids.
The plugin now refuses a config that still does, with one log line saying to run `openclaw-memory.py apply`, and chats held only on Telegram are no longer searched; what was kept from them stays kept and shown.

What is kept lives in `household-memory/kept.json` under each gateway's state directory, so [the nightly backup](#the-nightly-backup) archives it with the rest of the state, and its restore drill checks it came back.
Nothing removes a record: `forget` sets `doneAt` and keeps it, and past 2,000 records a new request is refused, with the assistant told to say so, rather than an old one dropped.
Each assistant keeps its own list; something told only to Denise in the family room is not in Corey's.

Each workspace's `AGENTS.md` says the same, under "Write It Down" and "Local notes": a request to remember is kept automatically and only needs confirming, and an older chat is found from the kept list and the added lines first, then `recall`, then `memory_search`, never by grepping files or copying a database.

#### Bringing it to the box, one gateway at a time

Do not use `scripts/openclaw-install.sh` for this: it restarts both gateways whenever plugin code changed.
From a checkout copied to the box, as root, Corey first and Denise only once Corey's checks pass:

```
persona=corey container=openclaw-gateway state=openclaw    # then: denise openclaw-denise openclaw-denise
stamp="$(date -u +%Y%m%dT%H%M%SZ)"; saved="/var/backups/household-memory-${stamp}-${persona}"
install -d -m 0700 "${saved}"

# 1. The state's files as root, each live database through SQLite's online backup API
#    inside the gateway (then integrity_check on the copy), and AGENTS.md.
tar --exclude='*.sqlite' --exclude='*.sqlite-wal' --exclude='*.sqlite-shm' --exclude='*.sqlite-journal' \
  --exclude='./pocketpiggies' -czf "${saved}/files.tar.gz" -C "/var/lib/household-assistant/${state}" .
#    openclaw-agent.sqlite and state/openclaw.sqlite: node:sqlite backup() to the container's /tmp, docker cp out
install -m 0600 "/var/lib/household-assistant/${state}/workspace/AGENTS.md" "${saved}/AGENTS.md"

# 2. The plugin's files, root-owned, into the read-only mount. Nothing loads them until a config names the plugin.
install -d -m 0755 -o root -g root /opt/household-assistant/plugins/household-memory
cp -r deploy/openclaw/plugins/household-memory/. /opt/household-assistant/plugins/household-memory/
chown -R root:root /opt/household-assistant/plugins/household-memory
chmod -R u=rwX,go=rX /opt/household-assistant/plugins/household-memory

# 3. Requests made before the plugin existed, kept once, before it is loaded (backfillKept in index.js).
# 4. The config, which restarts this gateway in process. Wait for healthy, at most three minutes.
python3 scripts/openclaw-memory.py apply --gateway "${persona}" --dry-run
python3 scripts/openclaw-memory.py apply --gateway "${persona}"

# 5. The two AGENTS.md lines above, then one index rebuild with transcripts in it.
docker exec "${container}" node dist/index.js memory status --index --agent main

# 6. PocketPiggies and the gateway, against the baseline taken before step 1.
python3 -I pp-rollout-check.py after "${persona}"
CT="${container}" scripts/openclaw-verify.sh    # with PORT and STATE for Denise
```

The PocketPiggies guard finds nothing to put back: the patch adds `recall` and `forget` ahead of the finance tools in `tools.alsoAllow` and leaves the channels and session keys alone, which `tests/test_openclaw_memory.py` checks against the installer's own policy.

#### Rolling it back

Each step keeps what it replaces.
To take one gateway back, as the gateway's own user like the other restores here:

```
docker exec "${container}" cp /home/node/.openclaw/openclaw.json.pre-memory-<stamp> /home/node/.openclaw/openclaw.json
install -m 0644 -o 1000 -g 1000 "${saved}/AGENTS.md" "/var/lib/household-assistant/${state}/workspace/AGENTS.md"
docker exec "${container}" node dist/index.js memory status --index --agent main
```

The restored config no longer names the plugin, so the gateway restarts without it.
It also no longer names transcripts as a source, which pauses search exactly as on 13 October until the index is rebuilt, so the rollback rebuilds it.
`kept.json` stays where it is, unread, so turning the plugin back on later loses nothing.
`files.tar.gz`, `agent.sqlite` and `state.sqlite` are the state as it was, for anything worse: stop the gateway, put them back owned by uid 1000, and start it again.

On 14 October `openclaw backup create` could not be used for this step, because it runs as the gateway's user and refused Corey's state: four root-owned `USER.md.bak*` files from 19 September sat in his workspace, one of them mode 0600.
They were given back to uid 1000 the same day, and `openclaw-verify.sh` now names anything in a gateway's state that `backup create` would refuse (`state the backup can read`): a file uid 1000 does not own, or an absolute link outside the directories it skips as regenerable.
The PocketPiggies socket directory is left out, since it belongs to its key holder.
The same day an empty virtualenv the assistant had made in Corey's workspace on 2 October, whose `python3` linked to `/usr/bin/python3`, was moved out of it into that day's backup folder.
Anything written into a state directory as root has to be handed back to uid 1000, as the memory rollback above does for `AGENTS.md`.

---

## The model backend

**OpenRouter, for everything, on both gateways.**
On 6 October the Overlord decided to close the household's OpenAI account and run the whole box on OpenRouter.
A gateway reaches a model provider in more places than its chat model, and each one left on OpenAI fails once the account closes.
`scripts/openclaw-openrouter.py` holds one policy for all of them and writes it to both gateways the same way:

| route | what can still reach OpenAI | what `apply` sets |
|---|---|---|
| chat chain, `agents.defaults.model` | a Codex primary or fallback, or a per-agent `model` | `openrouter/z-ai/glm-5.3-flash`, then `openrouter/z-ai/glm-5.3`, then `openrouter/deepseek/deepseek-v4-flash-0731`, on both, until a person picks their own assistant's first, second or third model in the app |
| other model slots | `pdfModel`, `voiceModel` or `heartbeat.model` naming another provider, or foreign per-agent `utilityModel`, `imageModel` and `mediaModels` overrides | cleared, so defaults follow the chat chain and agents inherit the corresponding default |
| completions that name no thinking level: session and thread titles, progress narration, session observation, meeting notes, and the dream diary | each runs on the utility model or memory-core's own, and on the chat primary when those are unset, which OpenRouter refuses (see below) | `utilityModel` and memory-core's `dreaming.model`: `openrouter/deepseek/deepseek-v4-flash-0731` |
| memory-search embeddings | an effective default or agent override that embeds elsewhere | see [The memory backend](#the-memory-backend) for the endpoint, inheritance and preservation rules |
| voice-note transcription | auto-detection, which picks OpenAI through a Codex sign-in or finds nothing | OpenRouter's `/audio/transcriptions` with `openai/whisper-large-v3-turbo` |
| understanding photos and video, `tools.media.models` | OpenClaw picks entries by capability, and 2026.9.4's OpenRouter provider covers photos and audio while only its direct Google provider describes video | only OpenRouter's entries are kept, including video through the household-openrouter-video plugin's `openrouter-video` provider with `google/gemini-2.5-flash`, and `check` reports foreign entries, disabled video understanding and CLI plugin loadability |
| a conversation pinned from a chat or the Control UI | a pin keeps its model whatever the default says | a pin to anything but OpenRouter is cleared through `sessions.patch` |
| photos the chat model is not handed itself: the image tool, and a photo the chat model cannot read | without an image model OpenClaw tries Anthropic, OpenAI and Google, never OpenRouter, and calls the image model with reasoning off, which `glm-5.3-flash` and `gemini-3.5-flash` refuse on OpenRouter | `imageModel`: `openrouter/openai/gpt-5.4-image-2`, OpenAI's newest image model and the owner's choice, then `openrouter/google/gemini-2.5-flash` |
| generated images, video and music | with nothing named, each tool picks whichever provider holds a key | `mediaModels`: `openrouter/openai/gpt-image-2.5-flare` for images, and OpenClaw's own OpenRouter defaults `openrouter/google/veo-3.1-fast` and `openrouter/google/lyria-3-pro-preview` for video and music, each kept when a phone picks another on OpenRouter ([Pictures and videos](#pictures-and-videos)) |
| a spoken reply | a root, agent, channel or account TTS provider override, or a credentialed fallback | `tts.provider`: `openrouter`, with Microsoft fallback disabled; scoped `provider` and `providers.microsoft.enabled` overrides are removed so they inherit those settings; the model, the voice and the automatic-reply setting are preserved, see [Speaking](#speaking) |
| web search | a foreign search provider, endpoint or credential selecting direct Perplexity transport | provider and settings are not written; auto-detection uses OpenRouter when its key is the only eligible search credential. Naming Perplexity requires its plugin. The audit reports foreign and unresolved routes for a person to change |

`check` runs `infer video providers` in a fresh CLI process inside each container.
It proves the configured video provider is loadable there, without invoking a model.
It does not prove the running gateway has registered the provider or completed its restart.
The pinned OpenClaw 3a9d69d source exposes no gateway RPC that reports registered video-understanding providers.

The same chain on both gateways is also what makes Denise and Corey equal by configuration; see [Why she reads as weaker even when she answers](#why-she-reads-as-weaker-even-when-she-answers).

**The last fallback is DeepSeek V4 Flash 0731, paid (#199).**
Until 17 October the chain ended on `deepseek/deepseek-v4-flash-0731:free`, which had left OpenRouter's model list by then, so a turn that fell past both GLMs had nowhere to go.
The chain now names the same model's paid id, at $0.0154 / $1.28 per million tokens in and out on 17 October: the household's turns are mostly prompt, which makes it the cheapest live model the chain could end on, and it is the same model the chain already ended on, so what this runbook measured of it still holds.
It takes tool calls, and its reasoning can be switched off.
`check`, `verdict` and the apply preflight read OpenRouter's public list and name any model in the chain it no longer lists, so `openclaw-verify.sh` fails the next time one goes.

**Completions that name no thinking level run on DeepSeek V4 Flash 0731 (#198, #204).**
memory-core's nightly diary narrative, generated session and thread titles, progress narration, session observation and meeting notes are completions that name no thinking level, and for those OpenClaw 2026.9.4 sends reasoning off, `{"effort": "none"}`.
OpenRouter refuses that with a 400, `Reasoning is mandatory for this endpoint and cannot be disabled.`, for every model its public list marks `reasoning.mandatory`, `glm-5.3-flash`, `glm-5.3` and `gemini-3.5-flash` among them, so from at least 15 October both diaries got the fallback entry every night and new sessions got no title.
A row in `models.providers.openrouter.models` mapping `thinkingLevelMap.off` to `low` does not help: for a model OpenRouter's live catalog lists, OpenClaw applies a configured row's limits but not its `thinkingLevelMap`, and the row resets the model to text-only input and zero cost; it was tried and taken back out on 17 October.
Such completions read one of two slots before falling to the chat primary: `agents.defaults.utilityModel` (titles, narration, observation, meeting notes) and memory-core's `dreaming.model` (the diary, with `subagent.allowModelOverride` and `subagent.allowedModels` pinned to it).
`apply` sets both to `openrouter/deepseek/deepseek-v4-flash-0731`, whose reasoning can be off, and `check` and `verdict` report either slot left elsewhere.
`openclaw infer model run --local --prompt <text> [--model <ref>]` takes the same no-thinking-level path, so it reproduces the refusal for any model with no message in a chat, and `openclaw cron run <the Memory Dreaming Promotion job>` runs the real diary.
`narrativesPending` in the sweep's summary counts the narratives a cron sweep queues, not failures, so it stays above 0 when they succeed.

Generated video costs far more per use than anything else here; the agent only reaches for it when someone asks for a video, and the credit limit on the key is what bounds it.

The previous model policy was checked on 6 October against the pinned 2026.9.4 image.
Its own `config patch` validated the whole patch, including on a running gateway, which reloaded it.
Its `memory index` sent embeddings to a fake OpenRouter with the OpenRouter key, its gateway transcribed voice notes through a fake OpenRouter STT endpoint, and its `sessions.patch` set and cleared a pin.
Those sandbox checks validated and loaded the photo, generation and speech routes without calling them.
`apply` was then run end to end against two scratch gateways, one shaped like Corey on Codex and one like Denise with a pinned conversation, and both ended on OpenRouter only.
After deployment of the branch's first version, `b51c6da`, both live gateways described a sent video, read a photo in a chat turn, used the configured image model for the image tool and image generation, and round-tripped speech.
`openclaw-verify.sh` passed 20 of 20 checks on both live gateways at that version, before review fixes `0076778`, `988f306` and `485827f`.
Those fixes reached the box on 9 October, when `openclaw-install.sh` was run from main at `7cd0827` and restarted both gateways onto the new plugin code.
Both plugins loaded without an error on each gateway, `infer video describe` described the kept test clip through `openrouter-video` on each, the family-group and model-backend checks passed, and `openclaw-verify.sh` passed 21 of 21 on both.
The plugins' own tests under `tests/js`, which CI runs through `tests/test_household_plugins.py`, passed 50 of 50 against that commit.
The plugin files from before are in `/var/backups/household-plugins-20261009T232032Z`.

Both containers need `OPENROUTER_API_KEY`, and `apply` refuses to write anything until each has it.
`check`, `verdict` and the apply preflight require that variable among the probed container environment names because the video plugin reads it directly.
An OpenRouter auth-profile credential does not satisfy the video plugin's requirement.
The key lives in the root-only env file beside the gateway token, never in the gateway's own state directory: the assistant can read that directory, and every backup archive carries it.
For a gateway whose env file lacks it, as root on the box:

```
grep -c '^OPENROUTER_API_KEY=' /etc/household-assistant/openclaw-denise.env   # 0 means missing
read -rs -p 'OpenRouter key: ' key; echo
printf 'OPENROUTER_API_KEY=%s\n' "$key" >> /etc/household-assistant/openclaw-denise.env; unset key
cd /opt/household-assistant && docker compose up -d --force-recreate openclaw-denise
```

`read -rs` keeps the key off the screen and out of shell history.
An env-file change reaches only a recreated container, and `docker compose restart` does not re-read it.
Never paste a key into a chat with either assistant: the transcript keeps it, and the backups keep the transcript.

Then, as root on the box, from a checkout.
This script imports `scripts/gateway_config.py`, as every `openclaw-*.py` script does, so a copy has to carry the whole `scripts/` directory, not one file:

```
python3 scripts/openclaw-openrouter.py check            # read-only: every route, the key, the pins
python3 scripts/openclaw-openrouter.py apply --dry-run  # both gateways validate; lists the pins it would clear
python3 scripts/openclaw-openrouter.py apply            # clear pins, back up and write both, rebuild memory
```

`apply` clears pins before it writes, because the memory change restarts each gateway in process for about a second and a half.
It rebuilds the memory index on each gateway whose config changed, since a new embedding provider pauses vector recall until the index is rebuilt.
A failed rebuild or a timeout is reported with the command to retry, and the other gateway is still processed.
Anything it cannot safely clear, a plugin's own model setting for instance, it lists for a person to change rather than guessing.
Its backups sit beside each live config as `openclaw.json.pre-openrouter-<UTC stamp>`; restore one by copying it over `openclaw.json` inside the container, as the gateway's own user, the way [the household app's rollback](#rolling-it-back-2) does, then rebuild the memory index.
`check` and the verifier's `verdict` both audit config and read container credential presence without printing values, including OpenAI-backed speech fallbacks and direct Perplexity search credentials.
`check` additionally reads effective model status, credential availability and session pins; `verdict` does not inspect those.
Resolve any remaining routes reported by `apply` before relying on a passing `check`.

Once `check` passes on both, sign out of OpenAI on each gateway before closing the account, so no forgotten route can reach it:

```
docker exec openclaw-gateway node dist/index.js models auth list --provider openai
docker exec openclaw-gateway node dist/index.js models auth logout <profile id from the list>
```

SIQsermon ran on this box too, and this repository cannot see its config.
The scripture skill's verse search went through SIQsermon's backend until the household-scripture plugin replaced it, so before the account closes, check whether SIQsermon itself calls OpenAI.
`grep -c '^OPENAI' /etc/siqsermon/runtime.env` counts the lines without printing any value.

### Why she reads as weaker even when she answers

Until the move to OpenRouter, Corey answered on `openai/gpt-5.6-luna` through Codex, and Denise on `openrouter/z-ai/glm-5.3-flash`, a small fast model.
The heartbeat measurement below is a fair picture of that gap: told to stay silent unless there was something to say, none of the 142 heartbeat turns Corey ran on Codex broke it, while on `glm-5.3-flash` at least 12 of Corey's 45 and 28 of Denise's 45 did.
A family-room turn is that same kind of judgement, when to speak, how much and to whom, so no setting of the room closes it; only the model does.

`openclaw-openrouter.py` puts both on one chain, so neither is the weaker one by configuration any more.
That chain starts on the same small fast model, though, so the two are now equally quick and equally loose.
To make one stronger, its person picks a larger model in the app's Settings, `z-ai/glm-5.3` for instance at $0.91 / $2.86 per million tokens against the flash model's $0.09 / $0.30.
That is the Overlord's call, and until item 3 it bills SIQsermon's key on every turn.
`apply` keeps any OpenRouter primary a gateway already has, so `CHAT_PRIMARY` is the primary only for a gateway whose primary is not on OpenRouter.

**Since 17 October each person also picks their own assistant's second and third text models in the app (Settings, Model, Second and Third), and the gateway answers with them in that order when the one before fails.**
- The phone signs `model.fallback.1` or `model.fallback.2` with a model id from the same OpenRouter list as the first, or an empty value for none, and the gateway writes them as `agents.defaults.model.fallbacks` and reads them back (`settings.js`).
  A cleared second lets the third move up, a model already in the chain is refused, and a fallback picked as the first leaves the fallbacks.
- `apply` keeps those fallbacks when each is a distinct model on OpenRouter's list and none is the primary; anything else gets the household's `CHAT_FALLBACKS` back, so a model OpenRouter delists is still repaired, and `check` and `verdict` report a delisted one.
- OpenClaw tries the fallbacks only for a session that follows the configured chain.
  A session pinned to a model with `/model`, a model picker or `sessions.patch` (`modelOverrideSource: user`) answers on that model alone, with no fallback and no Settings choice.
  On 17 October Corey's main session and five reminder sessions carried such a pin to GLM 5.3 Flash, left from the move off Codex, and the rollout of the second and third models cleared them with `sessions.patch` and a null model; Denise had none.
  `openclaw-openrouter.py check` lists any pin under `pinned`.
- Proved on Corey's container with `openclaw agent exec --config <a temporary copy>` and isolated state, no channel and nothing delivered: with the first model unknown, the second answered; with the first two unknown, the third answered.
  Run it with `OPENCLAW_CONFIG_PATH` set to the copy as well, or its log lines land in the gateway's own log file.

### Speaking

**Speech is asked for in the app, never sent: a person long-presses a message and chooses Speak, or talks with their assistant on a call (Talk), and the gateway speaks the words in an ElevenLabs voice through OpenRouter, under a daily ceiling.**
No chat tool makes a voice note, and nothing speaks a reply unasked.

- household-app makes all of it through its `household-app.speak` method (`speak.js`): a message someone chose Speak for, each sentence Talk says, and a voice's sample in Settings.
  It speaks at most 400 characters at once, through OpenClaw's own speech on the speech provider the gateway is configured with, for the household channel's account, so the phone never needs a key.
  The audio is kept in the app's media store, and the phone reads it like any other attachment.
- The model and the voice are the gateway's own: `tts.providers.openrouter.model` is `elevenlabs/eleven-v4-turbo`, and `tts.providers.openrouter.speakerVoice` is the voice picked in the app's Settings, one of the six ElevenLabs voices `settings.js` lists.
  On 10 October the voices were `will` for Corey and `jessica` for Denise.
- `channels.household.talkDailyCharacters` is the gateway's ceiling for a day, 20,000 characters, which `openclaw-household-app.py apply` writes only where a gateway has none, so a ceiling a person set stays.
  Every character asked for counts before the provider is called, so a call that fails after it was billed is still under the ceiling.
  Past it the method refuses with `Talk has reached today's limit of 20,000 characters. It starts again tomorrow.`
  The count is kept by day in `household-app/settings.sqlite` under the state directory, on the container's own day, which the compose file sets to US Central.
- OpenRouter's speech catalog, `https://openrouter.ai/api/v1/models?output_modalities=speech`, priced `elevenlabs/eleven-v4-turbo` at $0.00002 for each input character on 9 and 10 October, which is **two cents for each thousand characters**, so the ceiling is 40 cents a day for each assistant.
  OpenRouter's own limit on the key is still the outer bound, and everything on the key shares it.
  Each assistant's line on the Spend page includes what its voice cost this month ([The Spend page](#the-spend-page)).

`speak.js` reads the ceiling from the gateway's current config on every call.
To change it on one gateway, as root on the box:

```
docker exec openclaw-gateway node dist/index.js config set channels.household.talkDailyCharacters 40000 --strict-json
```

To change a voice, pick another in the app's Settings, or set `tts.providers.openrouter.speakerVoice` on the box, which the gateway reloads without a restart:

```
docker exec openclaw-gateway node dist/index.js config set tts.providers.openrouter.speakerVoice '"liam"' --strict-json
```

`openclaw-openrouter.py` leaves the model, the voice and `tts.auto` alone, and it reads a model under `tts.providers.openrouter` as OpenRouter's own.

#### Nothing else speaks

household-app's speech guard (`speech-guard.js`) closes every other way a turn could speak:

- OpenClaw's own `tts` tool is refused if a config ever hands it back to the model, and so is `speak`, should a config still name it, with the line `To hear a message in Steward, long-press it and choose Speak. For a conversation aloud, start a call.`
- `/tts` typed in a chat, `/tts on` included, is answered with that same line in the `before_dispatch` hook, which runs ahead of the built-in command, so the built-in `/tts on`, which would speak every reply with no ceiling, cannot be reached from a chat.
  That includes `/tts: on`, since OpenClaw takes a colon between a command and its words.
- Every turn is told to reply in text and not to call `speak` or `tts` (`REPLY_IN_TEXT`), since on 15 October, in the app, Corey planned a spoken answer to a request for a voice note.

With `tts.auto` off, nothing is spoken unless someone asks.
`tts.auto` set to `always`, `inbound` or `tagged`, at the root or under an agent, a channel or an account, calls the provider from the reply itself, around the app and its ceiling.
OpenClaw keeps one more switch outside `openclaw.json`: `settings/tts.json` under each state directory, which the built-in `/tts on` and a client's speech switch write, and which it reads ahead of `tts.auto`.
A chat can no longer write it; to clear one, delete the file as root.

`scripts/openclaw-speech.py` says, from each gateway's config, whether anything still speaks a reply nobody asked for:

```
python3 scripts/openclaw-speech.py check            # read-only: both gateways side by side
python3 scripts/openclaw-speech.py apply --dry-run  # both gateways validate the patch; nothing written
python3 scripts/openclaw-speech.py apply            # back up each config, write both, then check both
```

- `check` prints each gateway's daily ceiling and its verdict: `speech only when someone asks for it`, or each thing that could still speak unasked or unbounded, which is automatic speech anywhere in the config, a stored switch that speaks, `tts` or `speak` in `tools.alsoAllow`, or the retired household-speech plugin in `plugins.entries`, `plugins.load.paths` or `plugins.allow`.
- `apply` takes household-speech's entry, load path and allow entry out, and `speak` and `tts` out of `tools.alsoAllow`, and nothing else; `--gateway` writes one gateway.
  It refuses until household-app's speech guard is in the plugin mount, so `/tts` is answered once the old plugin goes.
  It leaves automatic speech and a stored switch for a person, because speech on request is the Overlord's rule to change.
  Each config it replaces is kept beside the live one as `openclaw.json.pre-speech-<UTC stamp>`.
- `openclaw-verify.sh` runs the same verdict on its `spoken replies` line, under "nothing speaks a reply unasked".

From 10 October each workspace's `AGENTS.md` carried a `**Speaking out loud:**` line under "Local notes" naming `speak`; no script writes `AGENTS.md`, and the guard refuses the tool whatever that line says.

**Before the app, the household-speech plugin spoke replies as Telegram voice notes.**
It was written after one spoken reply on 10 October reached the Overlord's chat as three unlabelled voice notes with its summary sent twice, and from then until Telegram was retired it handed the model a `speak` tool in place of `tts`, sent a long reply as numbered voice notes and held each assistant to 8,000 characters a reply and 25,000 a day.
It was removed with Telegram, the one channel its voice notes went to, and household-app's guard took over `/tts`.

### Pictures and videos

**Both assistants make a picture or a short video only when asked, through OpenRouter, and each person's pictures and videos have a daily limit on each gateway.**
On 17 October the Overlord asked for pictures in the Steward app, OpenRouter's GPT image model by default, and pickers for the text, image and video models in Settings.
OpenClaw's own `image_generate` and `video_generate` already reached OpenRouter, but its provider drops the `usage.cost` each answer carries, its request names nobody, and the model chooses the model and the count, so nothing could hold a day's spend.
The household-pictures plugin replaces both, and `openclaw-pictures.py apply` hands it to both gateways.

| setting | before | after `openclaw-pictures.py apply` |
|---|---|---|
| `tools.alsoAllow` | no `picture` or `video` | `picture` and `video` added |
| `tools.deny` | `codex`, `memory-wiki`, `onepassword` | `image_generate` and `video_generate` added |
| `plugins.entries.household-pictures.config` | not set | `pictureDayDollars` `2`, `videoDayDollars` `3` |
| the family room's list, `channels.household.familyTools` | `image_generate` and `video_generate` among them | `picture` and `video` in their place (`pocket-piggies-install.py`, then `openclaw-household-app.py apply`) |
| `agents.defaults.mediaModels.image` | `openrouter/openai/gpt-5.4-image-2` | `openrouter/openai/gpt-image-2.5-flare`, or the model picked in Settings |

- `picture` makes one picture from the model's description, with the photos a person sent to change or build on, by the image model chosen in Settings.
  The plugin sends it to the chat itself, and the app keeps it in the room at full size with its width and height.
  The tool's result is one line of text, so the model is handed no picture.
- `video` starts a job with the video model chosen in Settings and answers at once.
  The plugin asks OpenRouter every 5 seconds, for at most 15 minutes, and sends the video to the chat when it is made.
  A video still being made when the gateway restarts is lost.
- Each one's cost is OpenRouter's own `usage.cost`, kept for 62 days in `household-pictures/ledger.json` under the state directory and logged with who asked, never with what was asked for.
  Each assistant's line on the Spend page counts this month's total from that file.
- A person is counted by their app id, `franco` or `gia`.
- Past a person's day's limit the tool refuses in plain words.
  A video whose listed price would pass it is refused before it starts.
  A picture whose cost OpenRouter did not report closes that person's day, since spend that cannot be counted must not read as none.
- Only a person's turn in the app gets either tool: in the family room, for its two people, and in the owner's own thread, the turns `family_history` answers in.
  A scheduled run, a sub-agent or a gateway client gets neither.
- Settings lists the image models from `/api/v1/models?output_modalities=image` and the video models from `/api/v1/videos/models`, each read at most once an hour, and writes a pick to `agents.defaults.mediaModels`.
  `openclaw-openrouter.py apply` keeps a model picked there and names its default only for a slot with no OpenRouter model.
  Each row shows the model's price in the unit OpenRouter bills it by.
  An image model shows dollars a million image tokens, from `pricing.image_output`.
  A video model shows dollars a second at the size the `video` tool asks for, by the same rule as its cap estimate, or dollars a million video tokens when that is how it is billed.
  A model OpenRouter gives no price for says so.
- `openclaw-verify.sh` checks the plugin, its limits and both tool lists in its `pictures and videos` line.

PocketPiggies' plugin refuses finance when the family room's tool list names a tool its safe list lacks, and its guard rewrites the room's list on both gateways from the installed installer.
So the new list reached each gateway together with PocketPiggies code that knows `picture` and `video`, and each gateway was restarted onto that code straight after.

### Before the OpenRouter migration: Codex first, OpenRouter behind it

**Primary: Codex, on the Overlord's own subscription.**
On 18 September the gateway was signed in to OpenAI as `owner@example.com` with the device-code flow, from inside the running gateway container:

```
docker exec -it openclaw-gateway node dist/index.js models auth login \
  --provider openai --device-code --agent main
```

The login is an OAuth row in the auth store, `state/openclaw.sqlite`, and it expires; `models status` prints the expiry and the subscription's usage window.
No API key is involved.
API credit bought on the platform account does nothing for this login: subscription usage and API credit are separate meters.

The default model is `openai/gpt-5.6-luna`, set with `models set openai/gpt-5.6-luna`.

#### The fallback chain

When Codex reports its usage limit, the gateway falls through this list in order and returns to Codex on its own on the next turn:

| order | model | per 1M tokens, in / out |
|---|---|---|
| 1 | `openrouter/deepseek/deepseek-v4-flash-0731:free` | free |
| 2 | `openrouter/free` | free; OpenRouter's router over its free models |
| 3 | `openrouter/z-ai/glm-5.3-flash` | $0.09 / $0.30 |
| 4 | `openrouter/z-ai/glm-5.3` | $0.91 / $2.86 |

Added with `models fallbacks add <model>`, one per call; the gateway hot-reloads each change.
Failover is turn-local: a turn that fell to OpenRouter does not pin the next turn there.
Upstream documents it firing on rate limits and cooldown exhaustion, billing disables, auth failures, provider-busy errors, timeouts and unknown models.

OpenRouter authenticates from `OPENROUTER_API_KEY` in `/etc/household-assistant/openclaw.env`; `models status` shows it as `source=env` and no auth profile is needed.
That key was copied from SIQsermon's runtime env.
OpenRouter model calls and [memory embeddings](#the-memory-backend) share its balance.
A key issued for this project, with a credit limit set on the OpenRouter side, is on the Overlord's list below.

#### A login through `compose run` does not persist

The onboarding command this runbook used to recommend, `docker compose run --rm ... onboard`, starts a separate container.
A device-code login made that way left the auth store empty; the running gateway still reported no provider afterwards, and the cause was not traced.
Sign in inside the gateway container as above, which is verified to persist, and keep `/var/lib/household-assistant/codex` mounted so the Codex harness's working state survives a container replacement.

---

## Denise's gateway

Denise runs in her own container, `openclaw-denise`, from the same pinned image.
One container would let anything Corey can run read Gia's mail configuration, which the coordination design forbids; two containers on one box keep the administration central and the state apart.
Everything about it mirrors Corey's with a `-denise` suffix: state at `/var/lib/household-assistant/openclaw-denise`, secrets at `openclaw-denise-auth-secrets`, Codex state at `codex-denise`, binaries at `bin-denise` (holding `himalaya` for Gia's Yahoo mailbox over IMAP), env file `/etc/household-assistant/openclaw-denise.env`, and the loopback port `127.0.0.1:18790`.
Her CLI is `docker exec openclaw-denise node dist/index.js <command>`.
The backup job archives both gateways and records hers as `denise_archive` and `denise_codex_archive`.

From 19 September she answered on `openrouter/z-ai/glm-5.3-flash`, with the free DeepSeek model and then the OpenRouter free router behind it.
The free model was her primary until it was measured answering scripture from memory; see [It only works on a model that honours the skill catalog](#it-only-works-on-a-model-that-honours-the-skill-catalog).
After the migration, she and Corey use the policy in [The model backend](#the-model-backend).
Gia's Yahoo mailbox is connected read-only through the bundled `himalaya` skill: its account config lives at `/var/lib/household-assistant/openclaw-denise-himalaya/config.toml` (mounted at `~/.config/himalaya`), the app password is `YAHOO_APP_PASSWORD_GIA` in her env file read through `backend.auth.cmd`, and no send backend is configured on purpose.
Gia reaches her through the Steward app, as Franco reaches Corey; see [The channels](#the-channels).

---

## Scripture

Both assistants read the Bible through the `scripture` tool of the household-scripture plugin, never from the model's memory.
It replaced the SIQsermon skill on 24 October 2026: SIQsermon is no longer an app, and the only things the assistants still used it for were its functions, which now run in the gateway itself.

| | |
|---|---|
| plugin | `deploy/openclaw/plugins/household-scripture/`, loaded from `/opt/household-plugins/household-scripture` |
| tool | `scripture`: `ref` (with `card` for the app), `search` (by meaning), `study`, `sermons`, `plans`, `save` |
| the Bible | `/var/lib/household-assistant/scripture/bible.sqlite`, root-owned, mounted read-only at `/opt/household-scripture` |
| the archive | `household-scripture/archive.sqlite` in each gateway's state: the household's sermons and study plans, in the nightly backup |
| the skill | `deploy/openclaw/skills/scripture/SKILL.md`, which tells the model when to use the tool and how to hand the app a card |
| needs | nothing to sign in to; OpenRouter only for the meaning of a search question |

### What the Bible database holds

`scripts/scripture-build.py` writes it from public sources, once, with nothing to keep running:

- every verse of the Berean Standard Bible (public domain), the translation SIQsermon showed first, and the word index the tool falls back to;
- OpenBible.info's cross references (CC BY);
- each verse's Hebrew or Greek words with Strong's numbers, transliterations and glosses, from STEPBible's TAHOT and TAGNT (Tyndale House, Cambridge, CC BY 4.0), read at a pinned commit;
- with `--embed`, one meaning vector per verse from OpenRouter's `openai/text-embedding-3-small`, the model memory search uses, cut to 512 numbers.
  Embedding every verse costs a few cents, once.

```
# as root on the box
python3 scripts/scripture-build.py --embed --env-file /etc/household-assistant/openclaw.env
```

It writes to a temporary file, checks it, and moves it into place, so a running gateway never reads half a file; the tool opens the new file the next time a gateway starts.
`--embed-only` adds vectors to a database built without them.
Until the vectors exist, `search` matches words rather than meaning and says so.

### The card's link

A scripture card's **Open in Bible** link opens the edition the household reads, `bibleVersion` in `/etc/household-assistant/household.json`, whatever translation the card's text is.
`scripts/openclaw-scripture.py apply` writes it into each gateway's `plugins.entries.household-scripture.config.edition`, which the gateway takes in process; `check` reads both back.
The card still names the translation of its text, so a card with BSB verses can open the NIV.
`apply` refuses, and `check` reports, an edition the plugin cannot link: the `edition` enum in the plugin's manifest is the list.

### In the family room

`scripture` is on the family room's tool list, `FAMILY_TOOLS` in `openclaw-household-app.py`, and on PocketPiggies' list of tools safe in a group, so a Bible question in the room gets the Bible too.
The SIQsermon skill could not do that: it ran a script, and the room has no shell.

### Retiring SIQsermon

The order matters, because the export reads SIQsermon over its network and the new compose file takes the gateways off it.
[docs/deploy/siqsermon-retirement.md](siqsermon-retirement.md) has the commands.


## The calendars

**Each assistant reads and writes its person's iCloud calendars over CalDAV, and Corey's Google sign-ins have stopped working.**

### iCloud, through `apple-cal-anywhere`

Both workspaces carry the ClawHub skill `apple-cal-anywhere` 1.3.1 at `workspace/skills/apple-cal-anywhere/`.
It is one Python file that speaks CalDAV to `caldav.icloud.com` with an Apple app-specific password.

| | |
|---|---|
| the password | `APPLECAL_PASSWORD`, in each gateway's env file |
| the account | passed on every call as `--apple-id`, before the subcommand |
| what it can see | only the calendars Apple publishes over CalDAV; any other name answers 403 |
| what it imports | the Python package `requests`, which imports `urllib3`, `idna`, `certifi` and `charset_normalizer` |
| where those live | `pylocal/local/lib/python3.11/dist-packages`, inside each state directory |
| how Python finds them | `PYTHONPATH` in each env file, set to that directory as the container sees it under `/home/node/.openclaw` |

The image has no pip and is never rebuilt here, so the packages sit on the state mount, where a recreated container still finds them and the backup carries them.
`openclaw-install.sh` installs neither the packages nor `PYTHONPATH`.
Like `gog` and `himalaya`, they were put there by hand on 19 September, and a fresh box needs them again before either assistant can read a calendar.

**Corey's copy was half installed until 9 October.**
It held `requests` without `urllib3` or `idna`, so `import requests` failed under the container's own `PYTHONPATH`.
Corey worked around that by downloading pip and installing into `/tmp/pydeps`, and wrote the workaround into two of his own workshop skills, `icloud-caldav-connect` and `household-plan-check`, as an `export PYTHONPATH=/tmp/pydeps:...` to run first.
`/tmp` belongs to the container, so every recreate removed it, and the export hid the persistent copy as well.
Counted from his transcripts on 9 October, 28 of his 58 calls to the skill had ended in `Missing dependency: requests`, both of that day's among them.
Denise's copy was complete, and 53 of her 61 calls had succeeded.

What was done on the box that day:

- `urllib3` 2.8.0 and `idna` 3.20 were copied from Denise's `pylocal` into Corey's and owned `1000:1000`.
  Both are pure Python, and they are the versions her `requests` 2.34.2, the same as his, already runs with.
- The two workshop skills no longer set `PYTHONPATH`, and say why.
  The originals are in `/var/backups/household-skill-notes-20261009T221634Z`.
- `household-plan-check` had also written a day's start as `<day>T05:00:00Z`, which is local midnight only while daylight time lasts.
  It now uses `date -d '<day>' -Is`, which the container's `TZ` resolves in either season.
  Both forms returned the same 7 events for the following 14 days.

Afterwards the skill's `doctor`, `calendars list` and `events list` all answered on Corey's gateway with nothing but the container's environment.
`openclaw-verify.sh` now runs `import requests` inside the gateway it checks, on its `calendar library` line, and prints the missing module when that fails.

**A calendar command never sets `PYTHONPATH`.**
If the import fails, the repair is the packages under `pylocal`, not a second copy somewhere a rebuild removes.

The skill treats a time with no offset as UTC and prints every time in UTC.
The model converts to Central when it answers, which is where a wrong hour can still come from.

### Google, through `gog`

Corey's gateway holds two Google accounts in `gog` 0.40.0, a personal one authorized for `gmail` and a Workspace one for `calendar,gmail`, both on 19 September.
On 9 October neither could refresh: every call ended in `oauth2: "invalid_grant"`, `refresh token expired or revoked`.
Google Calendar and Gmail through Corey do not work until both are authorized again, and the personal account never had the calendar scope.

Why they expired is not established.
Two tokens issued the same day and both dead three weeks later is what a consent screen left in Testing produces, since Google expires those refresh tokens after seven days, but nobody has looked at the Google Cloud project.
If that is the cause, publishing the app is what stops it recurring.

Authorizing again is the account owner's to do; see [What only the Overlord can finish](#what-only-the-overlord-can-finish).
Corey's workshop skill `google-oauth-headless` records the listener flow dying four times on 3 and 4 October, because `gog` gives up after a few minutes and a callback pasted through Telegram arrived late.
`gog auth add` also has a two-step form with no listener to outlive, which has not been run here:

```
docker exec -it openclaw-gateway gog auth add <email> --services calendar,gmail --remote --step 1
# open the printed URL, approve, and copy the address the browser ends on
docker exec -it openclaw-gateway gog auth add <email> --services calendar,gmail --remote --step 2 --auth-url '<that address>'
docker exec openclaw-gateway gog auth list
```

On 15 October the cause was confirmed as far as the box can show it: `gog auth list --check` still finds the OAuth client (no `invalid_client`), and both refresh tokens fail with `invalid_grant`.
The client belongs to Google Cloud project `123456789012`, whose consent screen cannot be published until its Branding page names a home page and a privacy policy on an authorized domain.
Those are `https://www.siqstack.com/steward-ai` and `https://www.siqstack.com/steward-ai/privacy`, on a domain verified with Google, with no logo, since a logo sends the app to Google's review.

**Denise has Gia's own Google account the same way** (household decision of 15 October: Gia uses Google besides her Yahoo mail and iCloud).
Her container gets `GOG_HOME` and `GOG_KEYRING_BACKEND` like Corey's, `gog` in `bin-denise`, and in her `gog` directory only the OAuth client: `data/credentials.json` and the keyring entry that holds the client's secret, never any of Franco's tokens.
`gog` has no way to export a client's secret, so that entry is copied encrypted, and her env file carries the same `GOG_KEYRING_PASSWORD` value as Corey's to open it, moved on the box by root and never printed.
Each keyring still lives only in its own gateway's state, which the other container does not mount.

**A Google account connected from the Steward app** (household-app's `connector.connect`, PR 97) is kept by the gateway, not by `gog`: the household's iOS client has no secret, and `gog` refuses a client without one.
`deploy/openclaw/bin/gog` is installed as `gog` in each gateway's binary mount, with the real binary beside it as `gog-bin`.
When the gateway holds an in-app sign-in, the wrapper runs `household-app/google-token.mjs` and hands `gog` a fresh access token as `GOG_ACCESS_TOKEN` for that one run, which `gog` uses directly with no stored client or account (checked on Corey's gateway on 15 October).
Otherwise it runs `gog` exactly as installed, so the accounts signed in on the box keep working as before.

```
for bin in bin bin-denise; do
  dir=/var/lib/household-assistant/${bin}
  [ -f "${dir}/gog-bin" ] || mv "${dir}/gog" "${dir}/gog-bin"
  install -m 0755 deploy/openclaw/bin/gog "${dir}/gog"
  chown "$(stat -c %u:%g "${dir}")" "${dir}/gog" "${dir}/gog-bin"
done
```
Gia then signs in with the two-step form above on `openclaw-denise`, once the consent screen is published.

**Connectors in the app (build 14)** read back each linked account to the owner's own phone: its name, email, linked time, status and what the assistant can do with it in plain words, never a token, as the household decided on 15 October.
Each connector reads as connected, available, or unavailable with a reason, and a phone that asks with `include: ["unavailable"]` also gets the connectors its assistant lacks.
Earlier builds asked and listed them dimmed, such as Gia's Email on Franco's phone.
The build with the Contacts connector no longer asks, so each phone lists only what its own gateway has.
A phone can disconnect one account by its id or switch to another (`connect.js`).
Contacts is a connector of the phone's own: its switch, iOS's permission and every name it finds stay on the iPhone, and no gateway lists it or hears of it.
A Google account `gog` holds on the box is listed too and can be disconnected from the phone, which runs `gog auth remove`.
Notion signs in with a pasted internal integration token until the household's public Notion connection is registered.
Then `NOTION_OAUTH_CLIENT_ID`, `NOTION_OAUTH_CLIENT_SECRET` and `NOTION_OAUTH_REDIRECT_URI` go in each gateway's env file, and the app signs in through Notion with the code exchanged on the gateway (`notion-connect.js`).
Either way the token is kept sealed with the keyring password, and the plugin puts it in the gateway's environment as `NOTION_API_TOKEN`, where the bundled notion skill and the commands it runs read it.
Outlook signs in from the phone through the household's Microsoft app, the public client in Corey's env file (`MS_GRAPH_CLIENT_ID`, `MS_GRAPH_TENANT_ID`), whose mobile redirect `steward://connector/outlook` the Overlord added on 15 October, with PKCE and no secret (`microsoft-connect.js`).
The kept sign-in goes into `MS_GRAPH_REFRESH_TOKEN`, where the assistant already makes its Graph tokens from (USER.md), and the box's own comes back on a disconnect.
A typed sign-in from the phone (iCloud, Email) goes the same way, into the env names its skill already reads (`APPLECAL_PASSWORD`, `YAHOO_APP_PASSWORD_GIA`), and on a disconnect the value from the box's env file, if it had one, comes back. Scripture needs no sign-in.

---

## The channels

**The Steward app is the household's only channel: the household-app plugin's `household` channel, on both gateways.**
Franco talks to Corey and Gia to Denise in their own threads, and the four of them share the family room, The Fam; [The household app's family room](#the-household-apps-family-room) is how it works, and a phone pairs as [Pairing a phone](#pairing-a-phone) says.
Each person is the owner only on their own gateway, as `household:<person>` in `commands.ownerAllowFrom`.
No other chat channel is configured, and on both gateways the PocketPiggies guard switches one off again if it is ever switched on ([Who can reach finance](pocket-piggies.md#who-can-reach-finance)).

Telegram was the household's first channel, with a bot for each assistant and The Fam as a Telegram group, until the app replaced it.
`openclaw-household-app.py apply` deletes what it left in a gateway's config: `channels.telegram` with its bot token, the telegram plugin's entry, `telegram:` owners in `commands.ownerAllowFrom`, and the family-room and job-mirror plugins.
Its `check`, and the `household app` line of `openclaw-verify.sh`, fail while any of that remains.
[Retiring Telegram](retiring-telegram.md) has the order on the box, one gateway at a time, what is left to remove by hand, and how to roll it back.

---

## The household app's family room

The Steward AI app is its own OpenClaw channel, `household`, and the household's only one.
It carries two conversations on each gateway: the family room, The Fam, which Franco, Gia, Corey and Denise share, and each person's own thread with their assistant.
An assistant's post to the family lands in the family room, as [A post to The Fam goes to the family room](#a-post-to-the-fam-goes-to-the-family-room) says.
How Telegram was taken off both gateways, and what is left of it to remove by hand, is in [Retiring Telegram](retiring-telegram.md).

### How it works

- `deploy/openclaw/plugins/household-app` registers the channel.
  A phone talks to it through the plugin's `household-app.*` gateway methods over the connection it already pairs with, and hears about changes through the `plugin.household-app.changed` and `plugin.household-app.typing` events.
- Everything said in the app is kept in `household-app/room.sqlite` under the gateway's state, with attachments under `household-app/media/`, each named by its SHA-256.
- A reply that carries a file, such as a chart or a PDF the assistant made, is handed to the channel as soon as the assistant writes it: OpenClaw sends it as a block even with block streaming off, or as a tool's result, and leaves it out of the final that follows.
  The channel keeps a block as a reply like the final, a tool's result only when it carries a file, and never posts the same file twice in one turn.
  Until 22 October it kept finals only, so such a reply was lost whole, words and file, with nothing in any log: OpenClaw reports a delivery that answers nothing only at verbose level.
- A turn in the app is an ordinary channel turn: it carries who sent it, the family room's last twenty messages as group history, and the tools [What a family-room turn may use](#what-a-family-room-turn-may-use) gives it.
  In the family room an assistant answers only when a message names it, by name or emoji, or replies to one of its messages, and a voice note is heard first to find out, as [Voice notes in the app](#voice-notes-in-the-app) says.
- One assistant hands a request to the other by @mentioning it in the family room, `@Corey` or `@Denise`.
  The @mention, matched by `mentions.js` against the family room's name and the agent's own, starts one family-room turn with the family room's tools, whose sender is the other assistant, never a person, so PocketPiggies, the owner's thread and `household_location` stay out of reach.
  An assistant's old Telegram bot name still counts as its name, so `@Denise_the_woman_bot` mentions Denise, and whatever an assistant writes in the app says `@Denise` in its place, the mention a person's @ writes (`withAppMentions`): on 19 October Corey wrote the bot's name in the family room, which each assistant had learned to write on Telegram, and the phones showed it as written.
  The phones draw a bot written before that as `@Denise` too.
  Every family-room message such a turn writes is marked `handedOver`, its reply and a tool's post alike: the turn names each run OpenClaw starts for it, and the tool hooks say which run each tool call is.
  A handed-over message that @mentions or asks the first assistant by name may start one answer back, and everything that answer writes is marked `final` as well; a final message starts nothing, and neither does a family reminder's post, which is final from the start.
  Nor does a message ten minutes old or older, and one message starts at most one turn however often it arrives, so the two answer each other at most twice and never in a loop.
  Until 24 October a handed-over message started nothing, so an assistant asked a question back had no turn to answer it in.
  Any other message from the other assistant starts nothing.
- Whoever is typing in the family room, either person or either assistant, shows on every phone in it: a phone says its person is typing with `household-app.typing`, an assistant's turn says so while it runs, and each gateway puts its own side's typing in its outbox for the other.
  A stop is someone missing from the other side's list, which the receiving gateway tells its phones as a stop; until 19 October it told them nothing, so the dots stayed under a message just sent for up to 30 seconds.
  A typing is written to the outbox again only once less than half of its 30 seconds is left, so an assistant's turn, which OpenClaw keeps typing every four seconds, rewrites the outbox about every 16 seconds rather than every four.
- The two gateways share the family room with no relay between them ([The family room between the gateways](#the-family-room-between-the-gateways)): each writes its half into a share folder, and the other reads it straight from a read-only mount the moment it changes.
- Each person's family-room message is signed by the device key of the phone that sent it, and the other gateway keeps it only when one of that person's pinned phones signed it.
  So an assistant that writes into its own state cannot pass words off as its person's to the other assistant.
- A message in a person's own thread is signed the same way, with `direct` as its conversation, and their gateway keeps it, and starts a turn, only when one of that person's phones signed it.
  So neither an assistant nor a client holding a token with write scope can start the owner's own turn, where PocketPiggies answers on Corey's gateway.
  An app build from before this sends its own thread's messages unsigned, so the gateway change ships only after the app build that signs them is on every phone.
- Push goes through Apple once the push key is on the box.
  Apple sees only "New message"; who said what is sealed with AES-256-GCM under a key each phone hands its own gateway, and the phone's notification extension opens it.
- The Today card at the top of Chats is written by each person's own assistant with the plugin's `household_today` tool, in its owner's own turns only, never in the family room or a group (`today.js`).
  The `household-app:daily-brief` job writes it at 4:45 in the gateway's household time zone (America/Chicago in this deployment), before the phone's 5 AM morning reset, and at 16:45 for tonight and tomorrow morning, with the next things ahead and a verse for the day from the devotional, or one the assistant chooses with the scripture tool where there is none, as Denise does. It chooses a fresh verse immediately when a later devotional has not run yet.
  The phone opens the card on the first visit from 5 AM; an overnight visit cannot mark that morning read, and a verse arriving after a calendar-only card reopens it once.
  The plugin keeps only the newest card, which the phone reads with `household-app.today` and hears of through `plugin.household-app.today`, and keeps on the phone to show offline, picking what is still ahead by its own clock.
  Each card also writes the day's brief line, which the app builds from before the card still show.
  The daily snapshot shows at most the next three upcoming events, grouped by the phone's calendar day under Today or Tonight, Tomorrow, or a later weekday, with a matching calendar mark for each day (`AgendaDayView`).
  The folded banner uses the next event's day as its heading, and the full schedule keeps the day groups, including all-day entries and past events.
  Each event's helping line appears in the full schedule; VoiceOver also reads the next event's helping line on the card.
  Calendar marks follow the [app-wide appearance contract](../ios/appearance-themes.md#app-wide-contract).
- An assistant's answer carries a `did` list, one item for each change its run made, which the app shows as chips under the answer: an event added, moved, changed or deleted, a reminder set, moved, changed or deleted, the household cart changed, or an email drafted, with its title and when it is.
  The plugin reads each from the run's own tool calls as OpenClaw's `after_tool_call` hook reports them, a calendar or reminder the way `approval-asks.js` reads it to ask, and keeps only a call that worked; a read adds nothing (`did.js`).
  The turn names each run OpenClaw starts for it, as a handed-over turn does, so the list goes on that turn's reply, and a family-room reply's list crosses to the other gateway with it, which keeps only the items it can read.
- A voice call with a person's own assistant runs as ordinary messages in their own thread, and when it ends, the phone folds them into one call entry with `household-app.call.end`, signed like a message (`call-log.js`).
  Only that person's and their assistant's messages said while the call lasted fold; the entry keeps their words as text only, up to 50,000 characters, and the messages go with their reactions and read markers.
  A call never leaves the person's own thread, and the gateway drops it thirty days after it ended.
  Beside the signed fields the phone sends how the call came up, and the gateway writes one `call setup` line to its log: the build, whether CallKit took the call or the app ran it itself and why, the milliseconds from the tap to the gateway's link, to the sound iOS handed over and to connected, from the first words sent to the first words of the reply, and how long the call lasted with how many turns (`call-log.js`).
  It is numbers and the route only, so `docker logs openclaw-gateway | grep "call setup"` shows how long each phone's calls take to connect, and a call from a build that does not send it says `call setup not sent`.
- Once a day iOS hands the app what MetricKit measured of it: how many milliseconds of each second of scrolling hitched, and how many times and how long the app hung.
  The phone sends those figures and its build with `household-app.metrics.report`, and the gateway writes one `iPhone metrics` line to its log and keeps nothing (`phone-metrics.js`).
  The figures are numbers only, never anything anybody said, so `docker logs openclaw-gateway | grep "iPhone metrics"` compares one build with the next on a real phone.

Each person is the owner only on their own gateway: `household:<person>` is added to `commands.ownerAllowFrom`, and the other person's messages carry no command authority.


### The family room between the gateways

Each gateway's household-app plugin writes its half of the family room into `household-app/share/` in its own state: `outbox.json`, the entries its own person and its own assistant wrote in the room with the sign-ins, the cart's, the note's and the wishlist's steps and its side's typing, and `media/`, a hard link to each attachment those entries name (`share.js`).
Nothing else of its state is in the folder: the owner's own thread, its attachments, the stores and the settings stay where only that gateway reaches them.
The other gateway's container mounts that one folder read-only at `/opt/household-peer` (`docker-compose.yml`), and its plugin reads it the moment the folder's watch reports a change, and every two seconds as a backstop (`peer-link.js`).
It narrows what may cross exactly as the host relay did before it: only the other side's own person and own assistant in the family room, and the room's own photo; the sign-ins waiting there for its own person and its approver's approvals for this side's; and the steps its own assistant took.
A person's message counts only when that person's phone signed it, as before, and an attachment only when its bytes hash to its name.
Every read of the share opens the file without following a link, refuses anything but a regular file and is bounded, since the folder belongs to the other gateway.
What it has read is kept in `household-app/peer-cursor.json` in its own state, so a restart reads only what is new, and an outbox that starts over is read from its start, with what was already kept kept once.

`scripts/openclaw-install.sh` makes each share folder before compose starts either container, as the gateways' own user, since it sits inside a directory the assistant controls and docker would otherwise make a missing one as root, which the gateway could not write; anything but a plain folder there is refused.

Until 24 October `scripts/household-app-relay.py` carried the room from the host: a path unit started it when either outbox changed, it piped what was new into the other container with `docker exec` and a node script, and a timer ran it every fifteen seconds behind that.
A message took a second or two to cross, sometimes fifteen, and the rule for a question both assistants were asked waited twenty seconds for the other's claim because of it; with signs crossing at once it waits eight.
`scripts/household-app-install.sh` takes the relay's units off a box that still has them.
The plugin still takes a batch left as a file in its `household-app/inbox/`, which is how the relay delivered, for replaying one by hand.

#### Bringing it to the box

```
# 0. Back up both gateways' state, as for any rollout.
# 1. The plugin, the compose file with the two read-only mounts, and the share folders.
#    Recreates both gateways, which then write their shares and read each other's.
scripts/openclaw-install.sh
# 2. The relay's units, which have nothing left to carry, off the box.
scripts/household-app-install.sh
# 3. Both gateways, end to end.
scripts/openclaw-verify.sh
```

Send a message in the family room from one phone and watch it arrive on the other; the other assistant's typing should show at once.

### Voice notes in the app

A person's voice note in the app is heard once, on each gateway that answers to it, and its words do everything the note's words are needed for (`voice-notes.js`).

- OpenClaw 2026.9.4 reads a turn's attachments only from its own media folders (`media`, `workspace`, its temporary folder and a few more under the state directory), and the app keeps its media in `household-app/media/`, so OpenClaw never transcribed an app voice note for a turn.
  Until 17 October both assistants had worked round it with a skill of their own that ran faster-whisper on the box's CPU through `exec` for each note in the owner's thread, and in the family room, where `exec` is not allowed, a note that named an assistant reached it with no words.
- The plugin now hears each person's note itself, through the same OpenRouter speech-to-text (`openai/whisper-large-v3-turbo`) the gateway is set to, with the note's own mime, since its file is named by its hash alone.
- In the family room the note is heard before anything decides who answers, unless its typed words already name an assistant, and a spoken name counts as a typed one does: "Corey, what's for dinner?" said aloud is answered by Corey alone, the same note naming both is answered by both, and a note naming neither by nobody, exactly as for text.
- Speech-to-text writes a name as it sounds: on 17 October `whisper-large-v3-turbo` wrote a spoken "Corey," as "Cory." with or without a hint, and OpenClaw's OpenRouter provider passes no hint anyway.
  So a spoken name also counts in the spellings speech-to-text gives it (`isNameSpoken`): a k for a leading c, a doubled consonant, an ending in -ey, -y, -ie, -i or -ee, and -ce for -se, so Cory, Corie, Kori and Correy are Corey and Denice is Denise, while core, car and Dennis are neither.
  A typed name still counts only as written, by OpenClaw's own rule, and a name of more than one word only as typed.
- The turn reads the words as `[Audio transcript (machine-generated, untrusted)]: "…"`, the form OpenClaw's own channels use, and the note is marked heard, so OpenClaw never transcribes it a second time.
  A note in the owner's thread is heard the same way, so a spoken question is answered as fast as a typed one, with no `exec`.
- The words are kept once per message in `room.sqlite`, as an entry of kind `transcript`, so a later turn's family history shows `(voice note) …` in place of the audio, across restarts, and the owner's phone shows them under the note: what the assistant heard is what it answered to.
  A phone shows its own on-device words only for a note the gateway has no words for.
- The words never cross to the other gateway.
  Each gateway hears the family room's notes for itself, because words the other gateway wrote would be the other assistant's to put in a person's mouth, while the audio carries the person's phone signature.
  So a family note is heard twice in all, once on each gateway, and a note in an owner's thread once.
  OpenRouter lists `openai/whisper-large-v3-turbo` at $0.0002 a minute of audio through DeepInfra and $0.00067 through Groq on 17 October, so a half-minute family note heard on both gateways costs at most about $0.0007.
- A note that cannot be heard keeps nothing and logs `household-app: a voice note could not be heard: <reason>`; the turn still starts, with whatever words were typed beside it.
- An assistant's own spoken reply is never heard: it carries its own words.
- **A log said aloud is logged as said.** A turn whose message is a voice note it heard is also told (`VOICE_NOTE_INSTRUCTION`, after the family room's own instruction there) to answer it as the same words typed, and only when it plainly asks to log or keep something, to log what the note gives at once, in one call: a weigh-in, a reading or a dose as `household_note` `add` with `rows`, things to buy as `household_cart` `add` with `list`.
  A log is answered in one line saying what it logged, such as "logged 7 kittens, Day 17"; any other voice note gets the answer its words would get typed.
  How a voice note shows in the app does not change.
  A value speech-to-text made unclear is never guessed: its row goes in with `unsure` (what was heard), is not logged, and the answer carries `ask` with that row, so the one-line reply asks about it alone.
  `add` with rows answers `logged` ("3 rows under "Kitten weights", Wed, Oct 21"), and the cart's list answers `logged` ("3 items in the cart").
  It is an instruction and two tool fields: no model call or wait is added to the turn.

### Reading the family room's earlier messages

A family-room turn carries only the room's last twenty messages, so an assistant asked about something said earlier in the room could not find it.
household-app's `family_history` tool (`family-history.js`) reads the room's retained messages a page at a time, oldest first.

- It answers only a turn of one of the room's two people: in the family room, in its shared session or the owner's own session of it, and in the owner's own thread.
  The app names no chat of its own, so the turn's delivery target and its session must name the same place, and a web chat, a CLI run, a scheduled run or any other session gets no tool.
  It checks again on every read.
- It reads the family room's own messages in `household-app/room.sqlite`, every one, including those that never addressed an assistant, and never a private thread.
  A voice note reads as the words the gateway saved for it ([Voice notes in the app](#voice-notes-in-the-app)); the tool never opens or transcribes audio, and a note with no saved words says so.
  A photo, a video or a file is a placeholder.
- It is read-only, and the database and the room are fixed by the gateway; the model chooses only the page size, up to 50, and where to start.
  A page holds at most 2,000 characters of each message and about 20 KB in all.
- Each page says where the next one starts and when the oldest retained message is from.
- `openclaw-household-app.py apply` hands the tool over through `tools.alsoAllow` and keeps DMs per sender and groups per group, which is how the tool tells the owner's own thread from the room.

It moved here from the household-family-room plugin when Telegram was retired, keeping its name and its bounds; The Fam's Telegram transcript and that plugin's 24-hour record of the other assistant's posts went with Telegram.

### A post to The Fam goes to the family room

On 17 October Denise posted to The Fam with `conversations_send` from a turn in Gia's own app thread, and the app never showed it, because nothing copied a Telegram post into the family room.
Now the family room is the only place a post to the family goes (`family-posts.js`):

- household-app's `before_tool_call` hook sees each call to `message` before it runs, from any session.
- A `send` or `broadcast` whose targets all name the family, `family`, `fam` or `the fam`, bare or after `household:`, on the household channel or with no channel named, is sent to `household` and `family`, the family room, as this assistant's message.
  The target is the one the tool sends to, the first of `target`, `to` and `channelId` that holds anything, or each of a broadcast's `targets`.
- In the room it is any other post of this assistant's: it pushes the owner's phones under the family thread, it crosses to the other gateway, one that @mentions the other assistant hands it a request, and one a handed-over turn makes is marked `handedOver` and starts nothing.
- A call that names Telegram, as `channel: "telegram"` or `"tg"` or a target after `telegram:` or `tg:`, is refused with a line saying where to post, and nothing is sent; so is a post to the family that names an account other than the default.
- Every turn is told the same (`householdRoutingGuidance`): The Fam is the app's family room, a post to the family is `message` with `channel=household` and `target=family`, a message to the owner alone goes to their household id, and family facts go in the household note.

### What a family-room turn may use

A family-room turn the owner started, by a message one of their phones signed, is the owner's own and has every tool their own thread has; anyone else's family-room turn gets the family room's tool list, and each person's own thread keeps every tool.
The household decided the first on 17 October, so that a question asked of Corey or Denise in the family room works exactly as it does one to one, with the owner's private data answering there only when the owner asked.
The list is `FAMILY_TOOLS` in `scripts/openclaw-household-app.py`: `web_search`, `web_fetch`, `family_history`, `picture`, `video`, `household_location`, `household_cart`, `household_home`, `household_react`, `household_note` and `scripture`.
It must equal `GROUP_TOOLS` in `scripts/pocket-piggies-install.py`, whose guard keeps the same list there on a gateway with finance, and `SAFE_GROUP_TOOLS` in the PocketPiggies plugin ([Who can reach finance](pocket-piggies.md#who-can-reach-finance)).
So nobody else's family-room turn can run a shell, read or write files, read sessions or reach the PocketPiggies key holder, whatever text was pasted into the room.
Until 15 October the household channel set no group tool policy, so a family-room turn on either gateway ran with every tool, whoever asked.

- The plugin answers OpenClaw's group tool-policy question for the channel (`groups.resolveToolPolicy`, in `family-tools.js`).
  OpenClaw asks it only for a session whose key names a group, `agent:main:household:group:family`, and for a sub-agent that session starts; the owner's thread, `agent:main:household:direct:<person>`, is never asked about.
- The list is `channels.household.familyTools`, which `openclaw-household-app.py apply` writes from `FAMILY_TOOLS` every time it runs, and `check` reports a gateway whose list differs.
  While the household used Telegram, `apply` copied it from The Fam's Telegram allowlist instead.
- Without a list the room gets no tools at all, never every tool: OpenClaw 2026.9.4 reads an empty allow list as everything, so the plugin denies `*` instead, and the room still answers in words.
- The one exception is the owner, and it lives in a session of its own.
  household-app runs a family-room turn the owner's signed message starts in the owner's own session of the room, OpenClaw's per-sender form of it, `agent:main:household:group:family:sender:<owner>`; everyone else's family-room turns run in the room's shared session.
  No other sender's turn reads the owner's session, so what the owner's tools return there, finance figures, mail, recall or an exact location, never reaches the other person's turn or the other assistant's handover, and nobody else's message can be steered into a run of it.
  An independent review of the first version, which ran every sender's turn in the one shared session, found both of those holes.
- OpenClaw asks the adapter about each group the owner's session names, `family:sender:<owner>` first, and passes the turn's sender, which household-app names only once that person's phone signature checked out.
  For the owner's own group and the owner as sender the adapter answers with an empty deny list, a policy OpenClaw takes as restricting nothing, so the turn has the owner's own tools and never falls back to the room's list.
  Every turn in the room's shared session gets the list, the owner's included, and so do the other person, the other assistant's @mention handover, a gateway client's `chat.send` (which names its own client id), any run OpenClaw asks about with sender rules off (`senderPolicyMode: "never"`, a scheduled run), and an owner whose id is reserved, such as `cli` or `family`.
- The plugin's own tools follow the same rule (`isOwnersTurn` in `turn.js`): in the owner's own session of the room `household_today` and `household_brief` are offered, `household_cart` records an order, `household_location` reads a share made only with the assistant, and a calendar or reminder change waits for the owner's yes in their own thread, exactly as in that thread.
  PocketPiggies' finance tools and household-memory's `recall` and `forget` answer only that session too, and `family_history`, `picture` and `video` accept it beside the shared one.
- The phone follows the room's shared session for a reply as it streams, and, since the build after 19 October, the owner's own session of the room too, which every page names as `ownersFamilySession`, so the owner's own family-room replies stream into the room as theirs do.
  It is a field of its own, so a phone from before it, which reads `sessionKeys` as its two conversations, never meets a key that is not one.
  An older build still gets those replies whole, with the assistant typing until then.
  Two of one assistant's runs answering in the room at once, one in each session, share the room's one typing bubble and working line, and a kept reply, which carries no run, takes the place of either stream; the one still running then streams on from its next words.
- What the owner keeps private is reached in the family room only when they ask for it: household-memory still starts a family-room turn with the family's kept items alone, OpenClaw keeps `MEMORY.md` out of every group prompt, and each family-room turn is told whose it is, "Franco, your own person, wrote this in the family room, which Gia and Denise read too … share Franco's private things … only as far as their question asks", or for anyone else that the owner's private things are not theirs to hear.
- The room's recent words, the other person's and the other assistant's posts among them, reach the owner's own turn as its history, and that turn holds every tool.
  That is the same kind of exposure the owner's thread has to what `web_fetch` and the other tools bring back, now with the room's words added, and anyone else's turn still cannot reach a tool that could act on them.
- PocketPiggies refuses its finance tools whenever `channels.household` is configured, switched on or not, without a list made only of those tools for everyone else in the room.

This was run on 15 October through OpenClaw 2026.9.4's own group tool-policy resolver and tool matcher, with the plugin loaded as a channel: on main the family session allowed `exec`, `read`, `write`, `sessions_history` and the finance tools; with the change it allowed only the room's list, a sub-agent of it the same, a room with no list nothing, and the owner's thread every tool, even when a caller named the family room as its group.

The owner's own session was run the same way on 17 October, inside both gateways' containers with each one's live household config: the owner in their own session of the room got `{ deny: [] }` and `exec`, `read`, `pocketpiggies_read` and `recall`, as their thread does; the owner in the room's shared session, the other person, the other assistant's handover, a gateway client's `chat.send` naming the owner's session, the other person naming it, and a run with sender rules off in it each got the room's list, ten tools that day, and none of those.

- household-memory's search of older chats leaves the owner's own session out of every search but the owner's private view, since that session is linked to the room's conversation and its transcript holds the words written beside the owner's tool calls.
- A checklist tick and a person's reaction wait for the room's shared session, so the owner's next turn in their own session does not see them.

The room's list first reached the box on 15 October, one gateway at a time.
Today `openclaw-household-app.py apply` writes it with the rest of the channel ([Bringing it to the box](#bringing-it-to-the-box-one-gateway-at-a-time-1)), and this shows it on a gateway, the room's tools with no `exec` and the owner's thread with `exec`:

```
docker exec openclaw-gateway node dist/index.js gateway call tools.effective \
  --params '{"sessionKey":"agent:main:household:group:family"}' --json
docker exec openclaw-gateway node dist/index.js gateway call tools.effective \
  --params '{"sessionKey":"agent:main:household:direct:franco"}' --json
```

`tools.effective` reads a session that exists, so on a gateway where nobody has addressed its assistant in the family room yet it answers `unknown session key` until someone does.
The gateway log should show no `pocket-piggies: finance is off` line.

### Bringing it to the box, one gateway at a time

```
# run on the box on 15 October 2026, for the pairing update and again for the turn fix
# 0. Back up the gateway's state and take the PocketPiggies baseline (docs/deploy/pocket-piggies.md).
# 1. The plugin into the mount. No gateway loads it yet.
bash scripts/household-app-install.sh
# 2. Corey first: validate, then write. This restarts Corey's channels in process.
python3 scripts/openclaw-household-app.py apply --gateway corey --dry-run
python3 scripts/openclaw-household-app.py apply --gateway corey
# 3. Health within three minutes, the channel running, PocketPiggies again.
python3 scripts/openclaw-household-app.py check
# 4. Denise the same way, only once Corey's checks pass.
```

Both containers read the plugin from the one host mount, but each loads it only when it starts.
An update to a gateway that already runs the plugin therefore takes `docker restart <container>` after the install, one gateway at a time, and then `apply` if the config changed.
On 15 October each gateway was healthy again within 25 seconds of a restart.
On a gateway with PocketPiggies, `pocket-piggies-install.py` runs before `apply`, so its guard no longer looks for Telegram ([Retiring Telegram](retiring-telegram.md#3-pocketpiggies-before-anything-takes-telegrams-config-away)).

### Pairing a phone

Nobody types a host, a port or a token.
A person with a paired iPhone gets a setup link for another one on Account, **Pair a new iPhone**, which asks their gateway with `household-app.pair.code`.
A household's first iPhone, or one whose person has none left, gets its link from whoever runs the box, through `household-app.pair`, which needs `operator.admin`:

```
docker exec openclaw-gateway node dist/index.js gateway call household-app.pair --json --params "{}"
```

It prints `link` and `setupCode`; send the link to that person's phone and tap it there.
Use `openclaw-denise` for Gia's.
The owner can also send `/app` in their own thread in the app, and the reply leads with the same link, then the code alone to copy; `/app` refuses anyone OpenClaw does not count as the owner.
Until Telegram was retired, `/app` sent to an assistant on Telegram was how a phone paired.

The link is `https://<gateway tailnet address>/household-app/pair#<code>`.
The code is OpenClaw's own single-use bootstrap token, which the gateway forgets after ten minutes, with the gateway's tailnet address for phones, `channels.household.phoneUrl`, which `apply` writes, and the person it is for.
A tap on the link opens a page the plugin serves with no sign-in, which hands the code to the app as `steward://pair?code=`; the code rides after the `#`, which no browser sends, so the gateway never sees it in a request.
The app pairs at once as the person the code names, with no chooser, or the person pastes the code instead.
It connects as a mobile node; OpenClaw approves that connect by itself and hands the phone a chat-only operator token, never admin.

A phone paired this way speaks for its person in the family room at once.
Each gateway trusts the app phones in its own `devices list`, and tells the other gateway which those are in its outbox, so nobody pins keys by hand.
That is the same source `apply` pins from, without the hand step: a gateway that was itself compromised could vouch for a key of its own, which holds for pinning too, since the script reads the same list.
Keys pinned by `apply` still count, and `apply` still prints each phone by device id, name and approval date and never its key.

Account in the app lists its person's iPhones with `household-app.phones`, from the same `devices list`, by device id, name, model and when each last connected, never a key or a token.
It removes one of the others with `household-app.phones.remove`, and asks for a setup code for a new iPhone with `household-app.pair.code`, which answers with the code and its link.
Both are signed by one of the person's phones over `household-app/phone/v1` and share the settings replay guard.
A removal runs OpenClaw's own `devices remove` inside the gateway's container, the way the box runs it, which drops the phone's tokens and closes its connections.
The plugin then forgets the phone's push registration, and the next outbox it writes leaves its key out, so the other gateway stops believing it too, unless `apply` pinned that key, which stays until `apply` runs again.
A phone never removes itself this way, since Pair this iPhone again does that on the phone.

### Signing in with Apple

A phone can also pair with no setup link, by signing in with Apple.
The app asks its gateway for a nonce with `POST /household-app/apple/nonce`, signs in with Apple using that nonce's SHA-256, and sends Apple's identity token to `POST /household-app/apple/pair`.
These routes answer without a gateway token, since the phone has none yet, so the token is the proof: the plugin checks Apple's RS256 signature against Apple's published keys (read from `https://appleid.apple.com/auth/keys` at most once an hour), Apple as the issuer, `com.siqstack.stewardai` as the audience, the expiry, and a nonce this gateway issued in the last ten minutes, used once.
The gateway is served on the tailnet with no funnel, so only tailnet devices reach these routes, and the plugin takes 30 sign-in requests a minute at most and bodies of 16 KB at most.

Apple's stable user id is then looked up among the Apple IDs this gateway has linked to its person, never by email, since Apple can hide it.
A linked Apple ID gets the same single-use setup code a link carries, and the app pairs with it at once.
A phone already paired links its person's Apple ID with the `household-app.apple.link` method, so that person can later pair a new phone by signing in.

An Apple ID nobody linked waits, at most eight at a time and for a day at most, until the household's approver says yes from his own app.
`apply` names Franco as the approver on both gateways, as `channels.household.approver`.
His app lists the sign-ins waiting on both gateways through `household-app.apple.waiting`, since each gateway puts its own in its outbox, and approves one with `household-app.apple.approve`, signed by his phone's key.
The other gateway reads his approval from the first one's share and checks that signature against the keys of his phones it already believes for his family-room messages, which is the same boundary the room draws: a gateway that was itself compromised could vouch for a key of its own.
The waiting phone holds a ticket it was given with its wait, and `POST /household-app/apple/status` gives it the setup code once approved, once.

### Faces

Each person picks their own photo and their assistant's in the app, from Photos.
Either person may also set the family room's own photo, from its page in the app.
The phone uploads the photo like any attachment and names it with `household-app.avatar.set`, which takes only the phone's own person, that person's assistant or the family room (`family`), and only a JPEG or PNG of at most a megabyte.
The face is an `avatar` entry in the family room, one per participant and one for the room, with the newest kept, so it and its photo cross to the other gateway, and every page a phone reads lists each participant's face with the participants and the room's own photo as `familyAvatar`.
An entry crosses only when the side it comes from may say it: its own person's and its own assistant's, and the room's photo, which either side may change.

Either person may also change the family room's look from its page: the color of the ring round its face, and its appearance, Auto, where each phone keeps its own, or Custom, one chat background for both phones.
The phone sends each change with `household-app.look.set`, and a new room photo counts as one too.
Each change is a `look` entry in the family room, written as the person who made it, so it crosses like that person's messages, and it holds only what it changed.
Every page a phone reads gives the look as `familyLook`, each field as its newest change left it, so two people changing different things at once both keep their change, and Custom keeps the latest custom background whoever chose it.
A history page also lists the changes made among its messages as `looks`, which the app shows in the room as a line with its time, such as "Franco changed the group color".
An app from before this ignores both.

### Where a person is

Each person can share where their iPhone is with their own assistant, so it can say how far they are from home, when to leave, or what is nearby.
It is off until they turn it on, in the first run's Location step or in Settings, Location, and each person decides for their own iPhone.
They choose with whom, their own assistant only or the family room too, and for how long, an hour, until midnight or always, and they can pause or stop it there at any time.
Precise or approximate is their own switch in iOS, and every position carries its accuracy.

- The phone tells its own gateway and nobody else, through `household-app.location`.
  iOS wakes it only for a significant change or a visit, never as a stream, and it drops a move shorter than 200 metres or than its own accuracy, and sends nothing while paused.
  It looks up no address and draws no map, so nothing about it goes to Apple's servers.
- Each report is signed by the phone's device key, one line per field, as a message is, and the gateway keeps it only when one of the owner's paired phones signed it.
  So neither an assistant nor a client holding a write-scoped token can plant a position.
  A report signed more than five minutes from the gateway's clock, or no newer than the last one, is refused, so a share played back after a stop cannot bring the position back.
- The gateway keeps only the latest position, with its time and accuracy, and only in memory.
  It is never in `room.sqlite` or the outbox, so it never crosses to the other gateway and no backup copies it.
  It is forgotten when the phone says off, on a pause, a stop or a share whose time is up, at the share's end on the gateway's own clock, and when the channel stops or the gateway restarts, after which the phone says again when it next moves or opens.
- `household_location` is the assistant's one tool for it, read-only.
  It is offered in the owner's own thread, whose turn starts only from a message the owner's phone signed and names the owner as `requesterSenderId`, the same proof PocketPiggies takes.
  In the family room it answers only while the owner shares with the family, for a turn Franco or Gia started there, and it says the same thing whether the owner shares only with the assistant or not at all.
  Every other session, automations, sub-agents and a gateway client's `chat.send` get no tool.
  Its description tells the assistant to use the position only for what was asked, never to keep it or send it anywhere but the conversation, and to search by town or street rather than coordinates.
- Nothing runs in the background on the gateway: the tool reads the latest position when a turn asks for it.
- No position crosses between the gateways, so Corey knows only Franco's and Denise only Gia's, and asking Denise where Franco is gets no answer.
  Sharing across gateways is left out until the household needs it.

`apply` hands the tool to the model through `tools.alsoAllow`, ahead of the PocketPiggies tools so the finance guard finds nothing to move, and `check` reports a gateway without it.
The family room gets it because `household_location` is on the family room's tool list, `FAMILY_TOOLS`, which `apply` writes as `channels.household.familyTools`.
The household chose that on 15 October, since family sharing stays each person's own choice in the app.
The same list is `GROUP_TOOLS` in `scripts/pocket-piggies-install.py`, whose guard keeps it in the room, and `SAFE_GROUP_TOOLS` in the PocketPiggies plugin, without which finance turns itself off.
The tool reads no file and reaches no key holder, and in the family room it answers only while that person shares with the family.

### Maps in a conversation

A person can also show where they are to a conversation, as Messages does: from the composer's plus, once, or live for 15 minutes, an hour or until the end of the day.
That is a message, unlike the sharing above, so it is kept and crosses like one, and both people and both assistants in the family room see it.

- The map is a message whose `location` holds the place in whole millionths of a degree, its accuracy, when it was measured and, for a live one, when it ends.
  The phone signs it under its own version line, `household-app/map/v1`, with the place in the signed text, so a message signed without a place can never be given one ([`signature.js`](../../deploy/openclaw/plugins/household-app/signature.js)).
- While a live map lasts, the phone moves it with `household-app.location.live`, each update signed on its own, and a stop with no position ends it early ([`map-share.js`](../../deploy/openclaw/plugins/household-app/map-share.js)).
  The gateway keeps the newest update as one `live` entry per map, refuses one no newer than it, and takes none once the share has ended or stopped.
  It crosses like a reaction, and the other gateway takes it only with the person's phone signature and only if it was signed before the end.
- The assistant hears a map in its turn as OpenClaw writes any channel's shared location, `📍` or `🛰 Live location:` with the coordinates, and never its later moves.
  Nothing looks the place up on the gateway.
- An assistant's own small map in an answer is a `map` card ([the steward-cards skill](../../deploy/openclaw/skills/steward-cards/SKILL.md)), drawn by MapKit on the phone with the way there from the phone's own position, so the gateway sends no picture and never sees the route.
- A reminder by place is a `place-reminder` card.
  The person it is for taps Set on their own iPhone, which watches the place itself with `CLMonitor` and says it with a notification, so the place and the moment never come back to the gateway.
  When it would watch somebody else, such as "when Gia leaves work", it is a request in the family room that only her iPhone can answer, with `household-app.place.answer`, signed like a message and crossing as a `place` entry ([`place-consent.js`](../../deploy/openclaw/plugins/household-app/place-consent.js)).
  Her iPhone watches the place only after her yes, and when it happens it replies to the card in the family room, which starts the asking assistant's turn there.

### The household cart

Franco approved it on 15 October: one shopping cart that Corey and Denise both add to, a Check out that fills the buyer's own Amazon cart, and the order's progress from Amazon's emails.
Amazon has no API to fill a personal cart or place an order, and Amazon Business forbids household buying, so nothing here talks to Amazon.

- `household_cart` is the assistant's tool for it, in the owner's own thread and the family room, by the same turn proof as `household_location` (`turn.js`).
  An item is down for whoever asked, by the turn's signed sender, and no argument names a person.
  Automations, sub-agents and a gateway client's `chat.send` get no tool.
- Each gateway keeps every step either assistant took, add, remove, quantity and an order's status, in `household-app/cart.sqlite`.
  It publishes only its own steps in the outbox's `cart` section, they cross to the other gateway when they change, and the receiving plugin checks each one before keeping it: the other assistant's own, a known kind, an item for Franco or Gia with a sensible name and quantity, and an amazon.com product link or none.
  Both gateways replay the same steps in time order, so both show the same cart.
- A link is kept only as an amazon.com product page, reduced to `https://www.amazon.com/dp/<id>`.
  Check out is Amazon's Add to Cart form with every item that has one, which opens in the Amazon app on the phone and asks the person to add them, and the person pays there.
  On 15 October that form still answered, though Amazon no longer documents it: if it stops, each item still opens on its own page.
- Whoever checks out taps Ordered on the cart card, through `household-app.cart.ordered`, which needs the same write scope as a checklist tick.
  The gateway reads the items from the assistant's own message, never from the phone, orders those still in the cart, and answers at once with no turn: the conversation gets the cart as it now stands, and the owner's own thread gets the order, with no number.
  When an owner's Amazon mail does not come to the household, this tap is how their orders leave the cart.
- An order can also be recorded in the owner's own thread from the owner's own mail, with its number, its status, the email's time and the expected day, which is how Gia's will be followed.
  All of that stays in the buyer's gateway. Only "ordered", which takes the items out of the cart, and "delivered" cross to the other gateway.
- The plugin reads that mail itself, every 30 minutes, with no model, when `channels.household.orderMail` names the owner's Gmail: `{"account": "<the owner's Gmail>"}`.
  It asks gog, with `--readonly` so nothing is marked read, for amazon.com order mail of the last week, and takes the emails oldest first (`gmail-source.js`, `order-mail.js`).
  It believes an email only when Gmail's own `Authentication-Results` header, the topmost and stamped by mx.google.com, says DKIM passed for amazon.com, it has one From, To, Subject and Date each, its From is an amazon.com address, and its To is the owner's own (`amazon-mail.js`).
  So a header added above a genuine email, or someone else's genuine Amazon email sent on to the owner, does not count.
  A new order is the household's only when it links to items in the cart, or to items someone tapped Ordered, which it adopts, and only links before Amazon's recommendations count. Any other Amazon order is left alone.
  The first read, with no `household-app/order-mail-seen.json` yet, records the week it finds without posting. After that each step beyond where the order stood posts the order card in the owner's thread, and a delivery also posts one line in the family room, with no detail.
  No email text reaches an assistant or the log. A message that cannot be fetched three times is left.
  It is off on both gateways until an owner's Gmail with Amazon mail is connected. Once that is connected and a count shows Amazon mail in it, Denise's is turned on with `docker exec -i openclaw-denise node dist/index.js config patch --stdin`, given `{"channels":{"household":{"orderMail":{"account":"<her Gmail>"}}}}`.
- A gateway's cart steps ride along with every batch the other side reads, so one that lost `cart.sqlite` gets the other's back with the next one, though not its own.
- The cart holds at most 40 open items, and an item's name at most 120 characters.

The cards are the app's `cart` and `order` (`deploy/openclaw/skills/steward-cards/SKILL.md`).
`apply` hands the tool to the model through `tools.alsoAllow` beside `household_location`, and it is on the family room's list, so it is in `FAMILY_TOOLS`, `GROUP_TOOLS` and `SAFE_GROUP_TOOLS`.

#### Bringing it to the box, one gateway at a time

```
# 0. Back up the gateway's state and take the PocketPiggies baseline (docs/deploy/pocket-piggies.md).
# 1. The plugins into the mount. No gateway reloads yet.
bash scripts/household-app-install.sh
# 2. PocketPiggies' safe list and the room's list together, which restarts Corey onto both plugins.
#    The list must not name household_cart before finance's own list does, or finance turns off.
python3 scripts/pocket-piggies-install.py corey --owner franco --telegram-id 7100000001 --restart
# 3. The tool to the model and the room's list: validate, then write.
python3 scripts/openclaw-household-app.py apply --gateway corey --dry-run
python3 scripts/openclaw-household-app.py apply --gateway corey
python3 scripts/openclaw-household-app.py check
# 4. The proof: household_cart in both app sessions, no exec in the room, no finance-off line.
docker exec openclaw-gateway node dist/index.js gateway call tools.effective \
  --params '{"sessionKey":"agent:main:household:direct:franco"}' --json
docker exec openclaw-gateway node dist/index.js gateway call tools.effective \
  --params '{"sessionKey":"agent:main:household:group:family"}' --json
# 5. Denise the same way (openclaw-denise, gia, 7100000002), only once Corey's checks pass,
#    and before anyone uses the cart, since a step carried to a gateway without it is not sent again.
```

To take it back, put back the config `apply` saved and the plugin from before, as in [Rolling it back](#rolling-it-back-2).
The cart's steps stay in each gateway's `household-app/cart.sqlite` until it is deleted by hand.

### The household note

What the family keeps track of together, kitten weights, dates, lists, lives in one note that Corey and Denise both write and every app turn on both gateways starts with (`notes.js`, `note-tool.js`).

On 19 October Franco asked both assistants in the family room to put together the kitten weights they had saved, and Denise did not know the ones she had saved minutes before.
Gia had copied Corey's family-room post with the weights into her own thread, and Denise saved them there in a file in her workspace, through a skill she had written herself; the words "save" and "log" are not ones household-memory keeps, so nothing reached the kept list.
Franco's message in the family room started a turn in the room's shared session, which has the family room's tools, so no file reads, and starts with the family's kept items only ([What a family-room turn may use](#what-a-family-room-turn-may-use)).
So nothing an assistant saved in its owner's thread could reach that turn, by design, and nothing either assistant was asked to tell the other was ever more than a message in the room.

On 22 October it happened again, with the note in place.
Both assistants were offered `household_note` in every turn that evening and neither called it: the note held two steps, both from 19 October.
Gia gave Denise a weigh-in in her own thread and Denise edited the weight tracker file in her workspace; Corey wrote Franco's into his workspace memory by shell.
The `AGENTS.md` line of 19 October asked for the note "even when a skill or tracker file of yours keeps it too", so each file stayed the record and the note was a second copy to remember, and a litter's weigh-in was a table where the note held one sentence per line.
In the family room, where Denise's turns cannot read her files, the two "merged" by sending the same numbers into the room again.
So the note is now the record, shaped for what a family tracks: a line can be a row, with what it is about (`item`), the day it happened (`day`) and a date it is due (`due`), a whole weigh-in is one call, and every turn starts with what is overdue or due within a week.

It is also the ledger of promises.
Something asked in passing that a turn does not finish is a line with who will do it (`owner`, any of the four), whom it is for, and its due date when it has one, so a session restart or a busy evening drops nothing.
Every app turn on both gateways starts with the promises still open, this assistant's own first, and `done` closes one.

- **Where it lives.** Each gateway keeps every step either assistant took, adding, correcting or removing a line, in `household-app/notes.sqlite` under its state, beside `cart.sqlite`.
  It publishes only its own steps in the outbox's `notes` section, they cross to the other gateway when they change and with every batch after, and the receiving plugin checks each one: the other assistant's own, a known kind, a line for someone in the household, a topic of at most 60 characters and one line of words of at most 500, with no control or invisible characters, and a time at most five minutes ahead of its own clock, since a step from further ahead would sort after every correction made here.
  Both gateways replay the same steps in time order, so both notes agree, and a gateway that lost its file gets the other's steps back with the next delivery.
  The nightly backup carries it with the rest of each gateway's state.
- **Who reads it.** Every app turn starts with it.
  The family room's shared session, which the other assistant's handed-over turns run in and where neither person's private tools answer, starts with all of it.
  The owner's own thread and the owner's own session of the room hold every tool, a shell and finance among them, so they start only with the lines whose words, as they read now, this assistant wrote for its owner there, by the add or the latest correction, and only count the rest, not even naming their topics; the assistant reads those with `view` when they matter, as it reads anything else a tool brings back.
  A correction is a step of its own with whom it was for, and it counts only for the topic or the text it changes, so the other assistant's correction of a line, or one made in the other person's turn, moves the line out of the owner's turns, and tidying the topic of a line from elsewhere in the owner's turn does not bring its words in.
  So words written in a turn with fewer tools, or by the other assistant, never start a turn that can act on them, which is the [exposure](#what-a-family-room-turn-may-use) the room's own history already has in the owner's session, and no wider.
  Franco and Gia read it through either assistant, so it is the household's shared record: a line is written only for what someone asked to keep, track or share with the family, or to tell the other assistant, and never anyone's private things unless they ask to share them, which the tool's description says.
  Private requests stay where they were: household-memory's kept list, `MEMORY.md` and the workspace's files, none of which a family-room turn anyone else starts can read.
- **How it reads.** Lines are grouped by topic, the topic as its first line wrote it, its lines oldest first, each with its day (the day it happened when the line gives one), its item, who asked whom, and any correction.
  A line with a due date says whether it is due, overdue or done, and by whom it was marked done.
  A turn reads about 4,000 characters of it: first the promises still open, this assistant's own first and then by due date, and what else is overdue or due within a week, soonest first, from the lines that turn may show and using at most half of that; then the topics that share words with the message, then the most recently changed, a long topic's newest lines without those already listed, and the names of what was left out, which `view` shows.
  A `view` answers with at most 100 lines, newest topics first, and names the topics it left out, and `due` lists the open promises and every other open line overdue or due within a week, and counts the ones due later.
- **How a line is written and corrected.** `household_note` reads and changes the note in the owner's own thread and the family room by the same turn proof as `household_cart` (`turn.js`), with the line down for the turn's signed sender; its actions and accepted fields are defined in [note-tool.js](../../deploy/openclaw/plugins/household-app/note-tool.js).
  `add` requires a `topic` and takes one line or up to 20 `rows` under it, kept all together or not at all, each with its `text` and optionally its `item` (at most 60 characters), its `day`, its `due`, dates written YYYY-MM-DD, and its `owner`, by name.
  With `rows`, a top-level `day` supplies the date for rows without their own `day`; a row's date wins.
  Other line fields must be inside each row, not beside `rows`.
  Fields that do not belong to the selected action are rejected with an error naming the unexpected and accepted fields, and nothing is saved.
  Repair a failed call's arguments and retry; never claim it was saved or fall back to a private tracker.
  `promise` is an `add` under "Promises" unless it names a topic, owned by this assistant unless it names someone else.
  Either assistant corrects, marks done or removes any line by its id, on anyone's word, and the later of two corrections wins on both gateways.
  A correction can change any of a line's fields, and counts as new words for the owner's own turns when it changes the text or the item, never for a date.
  Nothing is deleted: a correction or a done is a later step, a line marked done stays in the note with when and by whom, and a removed line stays in the file.
  The receiving plugin takes a `done` step only for a line id and someone in the household, and a row only with its dates real days and its item one line of plain words.
  Assistant-to-assistant requests use [the assistants' direct line](#the-assistants-direct-line).
- The note holds at most 300 open lines; a new one past that is refused, and the assistant is told to remove ones that no longer matter.

Each workspace's `AGENTS.md` got two lines for it in the 19 October rollout, which a gateway rebuilt from scratch needs again, since `AGENTS.md` is the assistant's own file on the box and no script writes it.
The 22 October rollout replaced the first, whose "even when a skill or tracker file of yours keeps it too" let each assistant's own file stay the record.
Under "Write It Down", after the line about asks to remember (Corey's, with Franco and Gia, Denise and Corey swapped for Denise's):

> - Anything the family tracks or must agree on goes in the household note with `household_note`, and nowhere else: a log such as the kitten weigh-ins (one topic, one row per kitten with its day, a whole weigh-in in one `add` with `rows`), anything due such as a dose, a vet visit or a deadline (a line with `due`, marked `done` when it is), and facts you and Denise must both know, such as dates, church times or a code the family shares on purpose. Never keep family data in a file, tracker or skill of your own; if you have one, move what it holds into the note the next time it comes up and stop writing the file. Appointments still go on the calendar and things to buy in the household cart, never copied into the note. Whatever someone asks for in passing that you do not finish in that turn is a `promise` in the note, with who will do it and its due date, and you mark it `done` as soon as it is. Every app turn starts with the note, yours and Denise's, the family room's included, while your own files and private notes never reach a family-room turn someone else starts. Both people read it, so never put anyone's private things there unless they ask you to share them.

For "Handing a request to Denise", follow [the assistants' direct line](#the-assistants-direct-line).

`apply` hands the tool to the model through `tools.alsoAllow`, and it is on the family room's list, in `FAMILY_TOOLS`, `GROUP_TOOLS` and `SAFE_GROUP_TOOLS`, as the cart is.

#### Bringing it to the box, one gateway at a time

The steps are the cart's, under the box's rollout lock: `household-app-install.sh` for the plugins, `pocket-piggies-install.py --restart` for the safe list and the room's list together, `openclaw-household-app.py apply` for the tool and the room's list, then the proof with `tools.effective`, Corey first and Denise only once Corey's checks pass.
`notes.sqlite` is made the first time the channel starts on the new plugin.
While Denise still runs the old plugin, a line written on Corey reaches her file only with the next batch she reads of anything after her restart, a message, a read or a typing, since the steps ride along with every batch but are a batch of their own only when they change.

### The assistants' direct line

Before 22 October Denise had no way to reach Corey except a message in the family room, in front of everyone, and that evening Corey asked her twice in the room, by name, "Denise - anything on your side ...?", and she never answered: only an @mention handed her a turn.
The Overlord asked for a line between them that both parents can watch, so it is a handoff in the household note, never a hidden chat, and the [coordination design](../plan/coordination-between-assistants.md#a-watched-direct-line-22-october) records the decision.

- **A handoff.** `household_note` with `hand` writes a line for the other assistant to do (`owner` is that assistant), under "Handoffs" unless it names a topic, and it crosses like any step.
  The receiving gateway marks it `seen` as it arrives, a step of its own that crosses back, so the sender knows it landed with no model call and no message.
  A handoff under ten minutes old then starts one turn on the receiving gateway, in the direct line's own session, `agent:main:household:group:pair`, sent by the other assistant as a bot, told that both people read the line and that its person's private things are not the other assistant's to hear.
  That session is a group of the household channel, so it gets the family room's tools like any turn in the room's shared session (`family-tools.js`), and no household tool (`turn.js`), so it can neither run a shell or read finance nor hand anything back.
  It starts with the whole household note.
  Its final reply is kept as the handoff's `reply`, one line of at most 2,000 characters, and posts nothing: no room entry, no push, and a tool's post finds no conversation by that name.
  An older handoff, one that arrived after a restart, is marked seen and waits in the note as that assistant's to do.
- **What the sender sees.** Every turn of the sender's lists the handoff with the promises: who has it, `not seen yet` or `seen` with the time, and the reply with the time.
  In the owner's own thread and own session of the room, which hold every tool, the reply's words are the other gateway's, so the line says only that there is one and that `view` shows it.
- **The receiving gateway checks** that a `seen` or a `reply` is the other assistant's own step for a line written for it, with a reply of plain words within its bound; anything else changes nothing.
- **A question in the room by name.** The other assistant's family-room message that puts a question to this assistant by name, the name opening the question ("Denise - anything ...?", "Denise, did you ...?") or closing it ("Anything else, Denise?"), now hands a turn over like an @mention (`mentions.js`, `room.js`).
  A name in the middle of a question is talk about someone and a sentence that asks nothing hands over nothing.
  The bound is the @mention's: what a handed-over turn writes is marked and starts nothing on the other side, and only a message under ten minutes old starts a turn, so the two answer each other once and never loop.
  On the box, over the evening's family-room messages, the rule hands Denise exactly the two questions she never answered and nothing else.
- **What both people see.** `household-app.line` (read scope) answers every step either assistant took in the note as events, oldest first, newest page unless `before` (a step's time) is given, at most 200 a page, and whether there are more: rows added, corrected, done and removed, and each handoff handed, seen and answered.
  The gateway tells the phones `pair` with the line's last time whenever it moves, and every sync and history page carries `pair.lastAt`, so the family room shows quietly that the two are coordinating and opens the line.
  The Steward app shows it to both people as a group of its own, read-only, with its whole history.

### Who is on it, and one answer from the house

On 22 October Franco asked both assistants in the family room, by voice, twice, and both answered within five seconds each time, two inventories of the same thing.
Each gateway answered its own name, and nothing said which of them had it.

- **The rule.** A person's family-room message that asks both assistants, by @mention, by name typed or by name heard in a voice note, is answered by the asker's own assistant alone (`room.js`).
  Both gateways apply the same rule to the same signed message, so deciding takes no message between them, no model call and no wait, and a question for one assistant alone is that one's as before.
- **The claim.** The asker's assistant claims the question as its turn starts, a `claim` step in the household note with the message's id and whom it is for, so the other side and both phones see who took it, and its turn is told the other was asked too and leaves it to it, to give the one answer for both from the household note and what it knows, without saying it will check with the other.
- **The bound.** The other assistant stands down and waits 20 seconds for a sign of that answer: the other assistant's typing in the room (from up to five seconds before), its claim crossing, or a message of its own.
  With none, it takes the question over, a `took` step, and answers it, told the other was asked first and has not answered.
  The bound is kept in `notes.sqlite`'s own `stand_downs` table (the message id, how far back a sign counts, and the deadline), on that gateway alone and never in the outbox, and cleared once checked.
  A gateway that restarts inside it re-arms it as the channel starts, for what is left of the 20 seconds, and still takes the question over once; a sign kept before the restart, the other assistant's message or claim, still stops it, and one whose question is ten minutes old or more is let go.
- **The receiving gateway checks** that a `claim` names a message id and someone in the household, and a `took` a message id; the timeline shows each as `claimed` (with `for` and `message`) or `tookOver`.
- **One answer from both assistants' facts.** The answer comes from the household note, which holds what both assistants wrote.
  A request to remember made in the app's family room is still kept by household-memory on the gateway that heard it, which the other assistant never reads, so its confirmation now tells the assistant to add it to the household note as well.
  On the box on 22 October one such family item existed, on Denise's side, kept before this change.

### Family reminders from either assistant

Denise said a weekly reminder for the family "lives on Corey's side, not mine", and on 22 October it did: the family's recurring reminders were Corey's automations delivering to The Fam on Telegram, which a job mirror copied into the app, and Denise had none for the family.
A turn in the room's shared session, which anyone's question starts, has no automations tool, and must not: an automation runs later with every tool, so the room's words would start a run that can use a shell or read finance.

- **A reminder in the note.** `household_note` with `remind` keeps a family reminder as a line under "Reminders": its words, the day it next goes off (`due`), its time (`time`, HH:MM in the family's zone, which both containers run in) and how often it repeats (`every`: day, week or month, or never), owned by the assistant that took it.
  It is offered wherever the note's tool is, the room's shared session included, since nothing runs when it goes off but a post of its own words.
- **Who posts it.** Every 30 seconds, and as the channel starts, the owner's own gateway posts each reminder that came due into the family room as that assistant, `Reminder: <words>`, pushed time sensitive, and marked so that whoever it names, it starts no turn on the other side.
  It is moved on before it is posted, so a slow post can never post it twice: to its next day still to come when it repeats (a month keeps its day, or takes a shorter month's last day), or done when it does not.
  One missed by more than an hour, such as while that gateway was down, is moved on unposted.
  The wall-clock time holds across a change of the clocks.
- **What the other sees.** Every turn of both assistants lists the family reminders set, with when each next goes off and who posts it, and both phones' view of the line shows each one set and moved.
- **The receiving gateway checks** a reminder's time, repeat and due date on every step from the other side, and only the owner's gateway ever posts it.
- A reminder for one person alone stays an automation in that person's own chat, which since 22 October is their own thread in the app.
- **Existing family automations, mirrored read-only** (`automations.js`).
  Each gateway lists its own scheduler's jobs as OpenClaw reconciles it, whenever a job changes, and as the channel starts, and keeps one line under "Family automations" for each enabled job of the main agent that posts in the family room, delivered to `household:family`.
  A line holds the job's name and when it runs, never its prompt; it is corrected when either changes and removed with the job, and a restart with nothing changed takes no step.
  Every turn of both assistants lists them under "Family automations, which post on their own", with whose they are, and neither assistant's `household_note` can correct, finish or remove one (`automation_line`): it changes only with the job itself.

Each workspace's `AGENTS.md` gets one line for it under "Write It Down", after the household note's:

> - A reminder for the family, such as "remind us every Saturday at 4:40", is a `remind` in the household note, whoever asks and wherever, never an automation: your own gateway posts it in the family room when it comes due, and Denise sees it. A reminder for one person alone stays an automation in their own chat.

Each workspace's `AGENTS.md` gets one line for it under "Handing a request to Denise" (Corey's; Denise's with the names swapped), in place of the 19 October one:

> When Franco or Gia asks you to tell Denise something, or you need something from her side, hand it to her with `household_note` and `hand`, never as a message in the family room: her side marks it seen at once and answers in a turn of her own, and your turns show where it stands. Franco and Gia can read that line, so hand over only what the family shares. In the family room, when Denise puts a question to you by name, answer it once, in the room. When someone asks you both, the asker's own assistant answers for both and the other stays quiet; the turn says which you are.

### Prep packets

Corey asked for "pre-event prep, not just a reminder": a packet 48 hours out with the address, drive time from where the person will be, what to bring, any form to fill and the confirmation number in one place, for appointments, flights, school things and church events.

- `scripts/openclaw-scheduled-jobs.py apply --gateway <persona>` gives each gateway a scheduled job of its own, `household-app:prep-packets`, "Prep packets", the way `openclaw-household-app.py apply` gives it the Today card's: an isolated run of the main agent at 8:00 on the gateway's clock, announced to its person's own thread of the app (`household:<person>`).
- Each run reads the family's shared calendar (the household file's, in iCloud) and its person's own, for events starting 36 to 60 hours later that the person goes to, and sends one packet for each, saying plainly what it could not find.
  Those windows meet end to end, so each event is in exactly one day's run, 36 to 60 hours before it.
  A day with nothing coming ends with `NO_REPLY` and no message.
- Nothing is written to the household note: an appointment can be one person's own, and its packet goes to that person alone.
  Each assistant prepares its own person, so a family event gets one packet on each side.
- `check` reads both gateways' jobs, each `ok`, `missing`, `switched off`, or `changed:` with what differs from what apply writes; `apply` puts a changed one back and leaves a switched-off one off.
  `--dry-run` writes nothing.

### The Sunday digest

Corey's second list ranked it second: one message on Sunday night, about ten lines, read once, with the week's calendar, what is slipping, the litter's weight trend, the cart and the two or three things that need a decision.
It goes to each parent from that parent's own assistant.

- `scripts/openclaw-scheduled-jobs.py apply` also gives each gateway `household-app:sunday-digest`, "Sunday digest": an isolated run of the main agent at 19:00 on Sundays, which delivers nothing itself (`--no-deliver`).
- The run reads the family's shared calendar and its person's own for the coming week, and calls `household_digest` once with `events`, at most twelve, each its title and its start with the calendar's offset, or its day when all day, and `decide`, at most three things that need a decision (`digest.js`).
  The plugin draws the events as an agenda card (`agenda` in the steward-cards skill): each day a calendar mark, the month in three letters over the day's number, beside one row for each thing in bold with its time, as the Overlord asked for the day snapshot on 22 October.
  A run that cannot give starts gives `week` instead, at most four one-line events with their day and time, which the digest shows as lines, as before.
- A run has every tool, so it never reads words someone else wrote into the household note.
  The plugin itself adds those lines and posts the digest in its person's own thread: what is slipping (overdue lines and overdue promises, two named and a count), the trend of the most recently changed log whose topic says "weigh" (the latest weigh-in's count and average, and the change since the one before), how many items the cart holds, and the open promises, the first named.
  The tool answers the run with the number of lines alone.
- `household_digest` is offered in the turns `household_brief` is: a scheduled run, and the owner's own thread and own family-room session; never in the room's shared session.
  It joins the manifest's tools and `openclaw-household-app.py`'s `tools.alsoAllow`.

### The emergency card

Corey asked for one command that gives the vet, poison control, the pediatrician, the insurance details and the neighbor's number, readable out loud in a panic.

- The card's entries are household note lines under the topic "Emergency card" (`emergency.js`): one per contact, its item who it is (Vet, Poison control, Pediatrician, Insurance, Neighbor) and its words the name and number.
  Both assistants keep it current with `household_note`, as anything else the family shares, and the note tool's description tells them where it lives.
- `/emergency` answers at once with no model, wherever the gateway's own person types it in the app: "Emergency: call 911 first.", then one line per contact in that order, anything else after them.
  Poison control's public United States number is on the card until the family keeps one of its own, and an empty card says how to fill it.
  In the family room the asker's own assistant answers it, since the app gives commands to the owner alone.
- Asked in words or by voice, the assistant reads the topic and gives those lines; on a call every reply is spoken already.

### Gift and wishlist memory

Corey asked that something someone wants, said in passing, be kept with who and when, and handed over three weeks before a birthday or Christmas.
A gift for one parent must never reach that parent, and both parents read the household note and the assistants' line, so a wish goes in neither.

- `household_wish` (`wish-tool.js`) keeps a wish (`wish`: who and what, in their words) quietly, in the owner's own turns only: their thread and their own session of the family room.
  Its description tells the assistant never to say it kept one or for whom, and never to bring one up.
- Each gateway keeps the wishes it hands to its own person in `household-app/wishes.sqlite` (`wishes.js`), and where a wish goes depends on whom it is for:
  - A wish of the gateway's own person goes to the other gateway only, as a step of the outbox's `wishes` log, and is kept there for the other parent.
    The other side answers with a `seen` step, and the sending side then deletes the wish's step, so its words leave that person's own side once delivered.
  - A wish of the other parent is kept on this side for this gateway's own person, and never crosses.
  - Anyone else's, such as a child's, is kept on this side and sent to the other, so both parents get it.
- `birthday` keeps someone's birthday (MM-DD or YYYY-MM-DD) and it crosses to the other side, the later one winning; Christmas is 25 December for everyone.
- Every hour, and as the channel starts, each gateway posts its own person, with no model, the wishes of the last year of each person whose birthday or Christmas is 21 days away or less, once a year for each occasion: "Gia's birthday is in 21 days, Thu, Nov 12. Things Gia said they wanted:" and a line for each, with when it was said.
- `view` shows only the wishes kept for the owner, which are never the owner's own.
- The `wishes` log crosses beside the cart's and the note's (`STEP_LOGS` in `peer-link.js`), only the source assistant's own steps, and no phone is shown any of it.
- A wish of a person's own waits in that gateway's outbox until the other side has it, so a gateway that is down keeps it there longer; nothing in that gateway's turns, pages or line shows it.

### Document and deadline vault

Corey asked for passports, insurance policies, car registrations, warranties, subscriptions and licenses to be photographed once, with the assistant watching their dates and saying so thirty days out.

- `household_vault` (`vault-tool.js`) is offered in the owner's own thread alone, never in the family room, not even the owner's own session of it.
  The owner sends a photo, or a scan (the app sends it as a PDF), in their thread; the assistant reads the day the document expires or renews and calls `keep` with that message's id, what it is, its kind and the day.
  It asks rather than guess a day it cannot read.
- The picture never moves.
  The owner's thread is shared with nobody and the media store keeps its files on this gateway alone (`media.js`); the vault keeps only which of those files a document is, what it is and its day, in `household-app/vault.sqlite` (`vault.js`), and nothing of it is in the outbox.
  No log line names a document.
- The day goes into the household note as a line of the `Renewals` topic due on that day, such as "Franco's passport expires Sat, Mar 6, 2027", naming only the document and its day; with `isPrivate`, when the owner asks to keep it to themselves, there is no note line.
- Every hour, and as the channel starts, the gateway posts its owner, in their own thread and with no model, each document whose day is 30 days away or less, once for that day: "Your passport expires in 30 days, Mon, Dec 21, 2026. It is in your vault in Steward."
  A document kept, or renewed, with less than 30 days left is said in that turn's reply instead (the answer's `tell`), and nothing is posted on the day itself.
- `update` takes a renewed document's new day or a new photo and corrects its note line (adding it back if someone removed it); `remove` takes a document and its note line out; `view` lists what is kept, soonest first, with how many pictures each has and never their ids.

### A meal plan that builds the cart

Corey asked for the week's dinners proposed from what is in the kitchen and what is on sale, turned into the shopping list automatically.

- `household_meals` (`meals-tool.js`) is offered where the cart is: the owner's own thread and the family room.
- What is in the kitchen is the household note's: every open line of any topic about the kitchen, the pantry, the fridge or the freezer, such as "In the kitchen", one line per thing (its `item`, or its words). The tool tells the assistant to keep it there as people say what they have or used up.
- What is on sale is what the assistant finds for the family's usual store this week before it proposes, said beside each ingredient (`sale`).
- `propose` takes up to seven dinners with their ingredients and answers, from `meals.js`:
  - `have`: what the kitchen already has, by name;
  - `inCart`: what the cart already has;
  - `buy`: everything else, each item once with its quantities added across dinners;
  - `card`: a table card of the dinners, with what is on sale, for the reply.
- Two names are one item when their words match once each word is singular and any count or measure in front is dropped: "Tomatoes" and "tomato", "2 lb ground beef" and "Ground beef". Never a part of one: "rice" in the kitchen is no "rice vinegar".
- `accept` with the plan's id, only once someone says yes, puts the `buy` items in the household cart as they stand at that moment, down for whoever asked, and answers the cart card.
  A plan is accepted once, and a plan the cart has no room for (40 items) is refused whole and stays open.
- Proposed plans are kept in `household-app/meals.sqlite` for two weeks; only the cart's own steps cross to the other gateway.
- Placing the order stays the one-tap send (`household_send`'s order card), and nothing here orders anything.

### The house

- `household_home` is the assistant's tool for the thermostat, the music and the living room TV, in the owner's own thread and the family room, by the same turn proof as `household_location` (`turn.js`).
  Automations, sub-agents and a gateway client's `chat.send` get no tool.
- It names only actions: `status`, `thermostat`, `volume`, `music`, `play`, `open_spotify`, `youtube`, `video` and `tv`.
  The plugin turns each into one call to the home key holder on the host, over `~/.openclaw/home/home.sock` (`home-tool.js`, `home-client.js`), and passes back the one text block the key holder answers.
  The token, the TV's pairing and the limits stay with the key holder ([Home control](#home-control)).
- `confirmed` reaches the key holder as true only when the assistant passes exactly `true`.
  A change that needs a yes comes back as `needs_yes` with the question, and the tool tells the assistant to ask exactly that and call again only after the yes.
- Without the key holder the tool answers `home_unavailable`, and nothing else is affected.
- `apply` hands it to the model through `tools.alsoAllow`, and it is on the family room's list, in `FAMILY_TOOLS`, `GROUP_TOOLS` and `SAFE_GROUP_TOOLS`.

### Tapbacks

A long press on a message in the app offers the five tapbacks Messages has, ❤️ 👍 😂 ‼️ and ❓, and Reply; tapping your own again takes it back.
Each reaction shows as a small badge on the bubble's top corner, an assistant's the same as a person's.

- `household_react` is the assistant's tool for a tapback of its own, in the owner's own thread and the family room, by the same turn proof as `household_location` (`turn.js`).
  It takes a message id and one of the five, and reacts only to Franco's or Gia's message in the conversation its turn is in, never to an assistant's (`react-tool.js`, `room.js`).
  Its description tells the assistant to use it sparingly, only where a person naturally would, and never instead of answering.
- The turn already names the messages it can react to: OpenClaw 2026.9.4 gives the message being answered as `message_id` in the turn's conversation info, and starts each line of the family room's history with its message's `#id`.
- In the family room the tapback is an ordinary `reaction` entry by the assistant, which crosses like the owner's own.
  The receiving gateway keeps the other assistant's reaction only when it is one of the five and on a person's message.
- When Franco or Gia reacts to an assistant's message, or takes a reaction back, that assistant's gateway queues one line for its next turn in that conversation through OpenClaw's next-turn injection, as a checklist tick does: `Franco reacted ❤️ to your message: "<its first words>"`, and that it needs no answer.
  It never starts a turn, and a line not taken within a day is dropped (`tapbacks.js`).
- `apply` hands the tool to the model through `tools.alsoAllow`, and it is on the family room's list, in `FAMILY_TOOLS`, `GROUP_TOOLS` and `SAFE_GROUP_TOOLS`; it went to the box the way [the household cart](#bringing-it-to-the-box-one-gateway-at-a-time-2) did.

### A step that waits for a yes

When a step of the assistant's run waits for approval, OpenClaw hands the request to every channel that presents approvals natively, and the household channel is one.
It shows the request as a card in the owner's own thread, never in the family room, with Approve and Deny, and pushes it to the owner's phones like a message.
Only approvals from a turn in the app come there: by the turn's channel, or by the thread's session for a turn that names no channel.
The household channel sends no notice into any chat.

- The phone answers through `household-app.approval.answer`, signed by its device key over the approval's id and the decision, one line per field, as a message is.
  The gateway takes an answer only when one of the owner's paired phones signed it, only for a card it showed, and only with an answer that card offered.
  So neither an assistant nor a client holding a write-scoped token can approve for the owner.
- The gateway hands the answer to OpenClaw's `approval.resolve` as the owner, through the channel.
  OpenClaw checks the owner again through the channel's `authorizeActorAction`, which lets only the owner answer, and the first answer from any surface wins.
- Approve is `allow-once`, for that step only, and the app never offers `allow-always`.
- How a card ended, approved, denied or no longer waiting, is an `approval` entry in the owner's thread, kept once, and each page of that thread says it for its cards.
- In the owner's own thread, a step that changes a calendar or a reminder waits for the owner's yes.
  The plugin's own `before_tool_call` hook asks for it (`approval-asks.js`), only when the turn's requester is the household channel and its session is the owner's thread, and only for the scheduler tool and commands.
  So the family room, scheduled runs and every other session ask nothing more than before.
- A reminder asks when the scheduler tool adds, updates or removes a job, or a command runs OpenClaw's own `cron` or `automations` CLI to add, edit, enable, disable or remove one.
  OpenClaw 2026.9.4 names the tool `automations` and turns the model's `cron` into it before any hook sees the call.
- A calendar asks when a command runs gog's `calendar` commands or apple-cal-anywhere's `applecal.py` for anything but a read.
  Listing events, calendars, colors and free and busy times, and `doctor`, never ask, and a calendar command the hook does not know as a read asks.
  A skill that changes a calendar some other way, such as Outlook through `outlook-hack`, does not ask until the hook knows its commands.
- The card's title says what changes from the step's own parameters, such as "Add Movie night, Friday 16 October, 7 pm", in the gateway's time zone.
  Its description says which calendar or reminder: "On the Family calendar in iCloud.", or the reminder's name and what it says.
- It offers Approve once and Deny, and waits ten minutes, after which OpenClaw denies the step.
- Exec approvals set on the box still apply as before.
  There is no config to add: OpenClaw starts the channel's native approvals when the channel starts, and the hook is part of the plugin.

### One tap sends it

Corey could draft an email but never send one, so every message ended with the owner doing the last mile.
`household_send` (`send-tool.js`) takes a whole draft in one call: an `email` or a `booking` request by email (the address, the subject and every word), or the household cart's `order` (each item's price in dollars, from its page).

- It is offered only in the owner's own turns, their thread and their own session of the family room, and the plugin's `before_tool_call` asks the owner's yes for every call there and refuses it anywhere else.
- The yes is OpenClaw's plugin approval, shown as the card above, which freezes the call's parameters: it covers that one draft, and a changed draft is a new call and a new card.
  OpenClaw keeps 512 characters of a request's words, so the card carries the whole draft, found by the request's tool call: `approval.detail` is every word, and `approval.send` says its kind and where it goes, or an order's items and total.
- An email asks as a `message-send` to its one address; an order asks as a `payment` at its total, `critical`, and its title says the total before the tap, such as "Order 2 items, $28.97".
- The tool sends only when that call's own approval resolved `allow-once`, and only the draft whose hash the card showed, once: a denial, no answer, a changed draft and a second send are each refused (`not_approved`, `changed`).
- Email goes from the owner's own Gmail, the account `orderMail` names, through `gog gmail send` with no shell; a gateway with no `orderMail` offers only an order.
  Amazon has no way for anyone but the buyer to place an order, so an order's tap hands over the cart's checkout link with the total the owner approved, and the buyer pays there.
- A command's own Gmail send, `gog gmail send` or a draft's `send`, as a command's program, after variables it sets, or inside `sh -c`, is refused in every session, so mail goes out after a tap or not at all.
- The phone shows a send's card with where it goes or its total, every word with no line limit, and Approve named for what it does: Send, Book or Order.

### The Spend page

**The Spend page shows one month for the whole household, the same on both phones: one graph of the total by day, then a line each for Corey, Denise and Other use of the key, which add up to the total to the cent.**
On 17 October the Overlord found the page showing Corey's month as a few cents beside about $30 for October.
Three things made it so:

- The headline was OpenRouter's month for the one key both gateways share, while Corey's line was only Corey's answers from OpenClaw's own ledger (`usage.cost`), so the two could never agree and Denise had no line.
- OpenClaw keys that ledger to the prices in its config and throws it all away when one changes, then adds it up again only when asked.
  That morning's model changes did that, the phone's first ask at 16:30Z started the rebuild, and `usage.cost` answered from the few transcripts added up so far.
- About $9 of October's $32 is in neither assistant's ledger: what the gateways ask OpenRouter for outside a chat turn, such as pictures and videos before household-pictures kept their costs, transcription, titles and dreaming, and SIQsermon's backend, which holds the same key.

How it is counted now:

- `scripts/household-spend.py` runs on the host every ten minutes on the clock (`household-spend.timer`), so a reading lands on each Central midnight.
- It asks each gateway for `household-app.spend.figures`: the key's usage as OpenRouter reports it, with a short hash that tells keys apart, the assistant's name, and what its voice and its pictures and videos cost this month (`spend.js`).
  Then it asks for `usage.cost` for the month so far in the gateway's own days.
- It keeps every reading of the key's lifetime usage, with OpenRouter's own figures for the start of its UTC day, week and month, in `coordination/household-spend.json` under the state root, root-only.
- The month is Central's.
  Its total is the key's usage since the reading nearest midnight on the 1st, within one tick of it.
  A month that began before the job's first reading counts from OpenRouter's own start of its UTC month, the evening before in Central, so October 2026 is exactly OpenRouter's own October figure.
- Each day on the graph is the total by the end of that day, straight between readings where there is none at that hour, as there is none before 17 October.
- Each assistant's line is its answers, voice, pictures and videos.
  Other is the rest of the total.
- A ledger OpenClaw has not added up any of yet is not taken, and a month's answers never go down, so a rebuild after a price change can no longer show a few cents.
- The same month goes to both gateways through `spend-in.mjs`, which checks that the lines add up to the total and writes `household-app/spend.json` as the gateway's own user.
  `household-app.spend` answers with that file, and the phone keeps the last one, so the page opens at once.
- `journalctl -u household-spend` prints one line a run, such as `household-spend: October 32.56 = Corey 5.50 + Denise 17.75 + Other use of the key 9.31`.

### Rolling it back

`apply` keeps the config it replaces beside the live one as `openclaw.json.pre-household-app-<UTC stamp>`.
Copying it back inside the container, as the gateway's own user, takes the channel off that gateway:

```
docker exec openclaw-gateway cp /home/node/.openclaw/openclaw.json.pre-household-app-<stamp> \
  /home/node/.openclaw/openclaw.json
```

`systemctl disable --now household-spend.timer` stops the spend job.
What was said in the app stays in each gateway's `household-app/` directory until it is deleted by hand.

### Scheduled messages in the app

Every briefing and reminder on both gateways is an automation that announces to the app: its person's own thread, `household:<person>`, or the family room, `household:family`.
Until 15 October each announced to a Telegram chat, the owner's private chat or The Fam, and none reached the app.
From then the household-job-mirror plugin copied each run into the app, and on 22 October every job's delivery was moved to the same people in the app, changing nothing else about it; the mirror went with Telegram.

- A reminder someone made, one-time or recurring, "every Monday, bins out" included, is pushed Time Sensitive while it runs (`interruption-level: time-sensitive`, `createReminderPushes` in `automations.js`), so it gets through a Focus.
  A reminder is a job with no declaration key that announces to the app.
  A job our scripts install carries a declaration key, such as `household-app:daily-brief`, and is pushed as any message is.
- The app declares the Time Sensitive Notifications entitlement, which its App ID needs before a signed build.
- A family reminder either assistant takes is a `remind` line in the household note, which the owner's gateway posts itself ([Family reminders from either assistant](#family-reminders-from-either-assistant)).

---

## The heartbeat is off

Both gateways run with `agents.defaults.heartbeat.every` set to `0m`, since 25 September.

The heartbeat is OpenClaw's built-in monitor.
Until it was turned off, every 30 minutes it ran a model turn in the agent's main session, with that session's whole history, and delivered the model's answer to the owner's Telegram DM unless the answer was the silent `NO_REPLY`.
Nobody configured it: it is on out of the box, and neither gateway has a heartbeat checklist for it to follow.

**It was the source of the unprompted messages.**
Each one was matched to a heartbeat run.
From 21 September, as far back as `cron runs` keeps history, the pattern is the same every time: the run starts at the gateway's fixed half-hour slot, `[telegram] outbound send ok` follows a few seconds later, and the run's `finished` entry lands a few milliseconds after the send.
The two sets of images on 20 September were matched through the session transcript instead.
The coordination relay, since retired, was not involved: its last crossing was on 21 September, every exchange it ever carried was opened by a person, and the planner's timer was disabled.

| gateway | when (CDT) | messages | what the heartbeat turn did |
|---|---|---|---|
| Corey | 20 Sep 05:27 and 08:05 | two sets of images | one turn generated images, and a later one created a one-shot job that sent more |
| Corey | 22 Sep 13:25 to 23 Sep 08:25 | 14 | failed on the Codex usage limit, and each failure notice was delivered |
| Corey | 23 Sep 09:25, then 25 Sep 07:55 to 16:55 | 9 | answered on `z-ai/glm-5.3-flash` with `ok` or a paragraph instead of `NO_REPLY` |
| Denise | 21 Sep 14:18 to 25 Sep 16:18, at night as well | 20 | answered on `z-ai/glm-5.3-flash` with `ok` or a paragraph instead of `NO_REPLY` |

The model decides whether a heartbeat stays silent.
None of the 142 heartbeat turns Corey ran on Codex between 18 and 23 September sent anything.
On 25 September (UTC), until the change, at least 12 of Corey's 45 heartbeat turns and 28 of Denise's 45 answered on `z-ai/glm-5.3-flash` with something other than `NO_REPLY`.
OpenClaw held back an answer that repeated the one before it, which is why a run of `ok` replies reached a DM once rather than every half hour.
The failure notices during the Codex cooldown have a second cause: Corey's main session carries a user model override (`modelOverrideSource: user`), which turns the configured fallbacks off for that session, so the heartbeat could not fall through to OpenRouter.
The same override takes precedence over the default model, so `models set` alone will not move his main session back to Codex when the cooldown ends.

Turning off only the recurring cadence was chosen over a stricter model, quiet hours or `target: "none"`, because it removes the turn rather than depending on a model's compliance, and it keeps everything that was meant to be sent:

- Reminders are automations with their own schedule and their own delivery, and none of them waits for a heartbeat.
  `openclaw cron list --all` shows each one.
- A background task or command that finishes still wakes the session once to report: OpenClaw's heartbeat documentation says `0m` stops only the recurring cadence and leaves those event wakes in place.
  That path was not exercised here.
- The heartbeat's own automation stays listed, disabled, with its scratch kept.

The change, one command per gateway, applied without a restart (`[reload] config hot reload applied`, `[heartbeat] disabled`):

```
docker exec openclaw-gateway node dist/index.js config set agents.defaults.heartbeat.every '"0m"' --strict-json
docker exec openclaw-denise node dist/index.js config set agents.defaults.heartbeat.every '"0m"' --strict-json
```

`openclaw-verify.sh` passed for both gateways immediately before and after.
A one-time test reminder built exactly like the household's own (an agent turn in the main session, `wakeMode` now, announced to Telegram, deleted after it runs) fired on time and was delivered, and no heartbeat ran or sent across the next two half-hour slots on either gateway.

**`openclaw-verify.sh` now asserts it:**

```
PASS  recurring heartbeat              off
```

It reads the scheduler rather than `openclaw.json`, because a heartbeat block under `agents.entries`, a restore from a backup taken before 25 September and a fresh onboarding each bring the heartbeat back without touching this setting.

### Rolling it back

Each gateway's config before the change is kept beside the live one as `openclaw.json.pre-heartbeat-off-20260925T2233Z`.
Both configs, their rotated `.bak` files and an online copy of each gateway's `state/openclaw.sqlite` are in `/var/backups/household-assistant/heartbeat-off-20260925T2233Z/`.

```
docker exec openclaw-gateway node dist/index.js config unset agents.defaults.heartbeat.every
docker exec openclaw-denise node dist/index.js config unset agents.defaults.heartbeat.every
```

Each unset hot-reloads the same way, and the 30-minute heartbeat comes back.
Before turning it back on, give it something to check (a checklist in its monitor scratch, `openclaw cron scratch <job id> --set`) and a `heartbeat.model` that has been measured returning `NO_REPLY`, the way the scripture skill's models were measured.

---

## What was proved, and how

### The externally reachable port set did not change

Scanned from a machine on the public internet, not from the box: all of 1-1024 plus every port this work could plausibly have opened, 1,051 ports in total.

| | scan | open |
|---|---|---|
| before any change | 2026-09-18 00:14:33Z | **22, 80, 443** |
| after installing OpenClaw | 2026-09-18 00:21:59Z | **22, 80, 443** |
| after the daemon restart | 2026-09-18 00:30:38Z | **22, 80, 443** |

18789 was in every scan and was closed in every scan.
No firewall rule, no Caddy configuration and no published SIQsermon port was touched, and `ufw` still allows exactly 22, 80 and 443.

### It answers on the tailnet and nowhere else

Run on 2026-09-24 from `sermon`, a Windows machine on the household tailnet:

| request | answer |
|---|---|
| `GET https://household.example.ts.net:18789/healthz` | 200, certificate verified |
| WebSocket upgrade over the tailnet, before `trustedProxies` | 403 `proxy_attribution_required` |
| the same, after | 101 |
| the app's first-pairing connect, with a wrong token | `AUTH_TOKEN_MISMATCH` |
| the same, with the gateway token | `PAIRING_REQUIRED`, with a request id |
| the same, over plain `ws://` | no connection; the port speaks only TLS |
| Denise's gateway on 18790, with her gateway token | `PAIRING_REQUIRED`, with a request id |

The connect was replayed with a throwaway Ed25519 key signing the same v3 payload the app signs.
The token was piped from the box into the probe's standard input and was never printed or written to disk.
Both probe requests were rejected on the box straight afterwards with `devices reject`, and `devices list` then showed no pending request and no new paired device on either gateway.
The gateway's log attributes those connections to the machine's tailnet address (`fwd=<the machine's tailnet address>`), not to the host.

From the same machine over its Wi-Fi route to the public address, 22, 80 and 443 are open and 18789 and 18790 are closed.
The box has no public IPv6 address.
The tailnet name does not exist in public DNS: over DNS-over-HTTPS, dns.google and Cloudflare both answer NXDOMAIN, so only a device on the tailnet can resolve it.
On the box, tailscaled listens on the tailnet addresses only, Tailscale's `ts-input` chain accepts traffic from `tailscale0` alone ahead of ufw's default deny, and `ufw` still allows exactly 22, 80 and 443.

`openclaw-verify.sh` for both gateways and `siqsermon-verify.sh` were run before the change at 02:33Z and after it at 02:48Z.
All three verified both times with the same PASS lines, and the second run added the new tailnet lines.
The coordination tick ran throughout with no errors, and Corey's Telegram polling resumed after his in-process restart.
SIQsermon was not touched.

### It comes back on its own

The Docker daemon was restarted, not the box.
A reboot of a VPS serving a live site is a longer outage than a daemon restart, and the daemon restart exercises the same restart-policy path that a boot uses.

```
restart issued 00:25:26.483Z
daemon back    00:25:38.441Z

00:25:43Z  deploy-backend-1  Up 6 seconds (healthy)
           deploy-caddy-1    Up 6 seconds (healthy)
           deploy-neo4j-1    Up 6 seconds (health: starting)
           deploy-qdrant-1   Up 6 seconds (healthy)
           openclaw-gateway  Up 6 seconds (health: starting)
00:25:53Z  all five healthy
```

Sixteen seconds from daemon start to all five containers healthy, with no human step.

**It cost SIQsermon 15.9 seconds of public downtime.**
Measured from outside the box by polling `https://<site>/health` every 400 ms: last 200 at `00:25:25.071Z`, first 200 again at `00:25:40.955Z`, with connection refused for the first ten seconds and 502 for the last six while Caddy came up ahead of the backend.

That is longer than the "few seconds" the task's own constraint allows, and it was spent knowingly, because the task also requires that a reboot or daemon restart actually be performed and the daemon restart is the cheaper of the two.
It was taken at 00:25 UTC.
There is no way to prove unattended recovery without stopping something, and this is the smallest stop that proves it.

### SIQsermon is unharmed

`scripts/siqsermon-verify.sh` was run three times: before any change, after the install, and after the daemon restart.
All three passed, with the same record counts, the same Caddyfile hash, the same firewall rules, and zero OOM kills:

```
PASS  neo4j nodes                      203648
PASS  neo4j relationships              960556
PASS  qdrant verses points             31105
PASS  sqlite projects                  6
PASS  sqlite sermons                   12
PASS  ufw rules                        22/tcp 80/tcp 443/tcp
PASS  published ports                  80 443
PASS  caddyfile                        4e2aa1f30a539bfad065cc1bdab3e3bc66f737dc752b6cad0f20e198d3937f26
SIQSERMON VERIFIED
```

Host memory after all of it: 2,568 MiB used of 7,878, 5,310 MiB available, swap 4 GiB with 0 B used.

---

## Bringing the box up to this

The model backend and the household on the app alone reach the box in one pass, as root, in this order.
Each step is idempotent, so a step that fails can be fixed and the pass run again from there.

```
# 0. From a machine with this repository: copy it to the box, which has no GitHub access.
git fetch origin main
git archive origin/main | ssh root@<box> \
  'rm -rf /var/tmp/household && mkdir -p /var/tmp/household && tar -x -C /var/tmp/household'
ssh root@<box>
cd /var/tmp/household

# 1. The OpenRouter key, in each env file that lacks it. Typed, never pasted into a chat.
for env in /etc/household-assistant/openclaw.env /etc/household-assistant/openclaw-denise.env; do
  grep -q '^OPENROUTER_API_KEY=.' "$env" && continue
  read -rs -p "OpenRouter key for $env: " key; echo
  printf 'OPENROUTER_API_KEY=%s\n' "$key" >> "$env"; unset key
done

# 2. The compose file, the household plugins and their read-only mount. Recreates both
#    containers, which is also what makes them read the env files again.
scripts/openclaw-install.sh

# 3. Every model route on both gateways to OpenRouter.
python3 scripts/openclaw-openrouter.py apply

# 4. The app's spend job. Then memory, PocketPiggies, the app's channel and speech,
#    one gateway at a time, Corey first, in the order of docs/deploy/retiring-telegram.md, steps 2 to 5.
bash scripts/household-app-install.sh

# 5. Both gateways, end to end.
scripts/openclaw-verify.sh
CT=openclaw-denise PORT=18790 STATE=/var/lib/household-assistant/openclaw-denise scripts/openclaw-verify.sh
```

Then, in the app, the checks in [Retiring Telegram](retiring-telegram.md#6-verify): a finance answer in Franco's own thread, the family history read in the family room, and a picture in each thread.

## What only the Overlord can finish

Nothing on this list is engineering work that was left undone.
The SIQsermon retune that funds [the assistant budget](../phase0/budget.md) is already durable: [SIQsermon#20](https://github.com/fpresta0607/SIQsermon/pull/20) merged on 2026-09-18, so a `deploy.sh deploy` or `deploy.sh rollback` restores the retuned ceilings rather than the old ones.

In the order to do them.

1. **Bring the box up to this branch, then close the OpenAI account.**
   Decided 6 October: everything on OpenRouter.
   The pass is in [Bringing the box up to this](#bringing-the-box-up-to-this); only he can type the OpenRouter key.
   Before closing the account, sign out of OpenAI on both gateways and check that SIQsermon does not call it; see [The model backend](#the-model-backend).
   Codex served Corey from 18 September until then.

2. **Keep the approved model policy on both assistants.**
   The chain is defined in [The model backend](#the-model-backend).
   Changing the primary is a separate decision; see [Why she reads as weaker even when she answers](#why-she-reads-as-weaker-even-when-she-answers).

3. **Issue an OpenRouter key for this project, with a credit limit, and store it** in the `household-assistant` scope, not the shared one:
   `cfo auth store --project household-assistant OPENROUTER_API_KEY` and paste the value at the prompt.
   Do not paste a key into a chat window; that command reads it from stdin and never echoes it.
   See [The fallback chain](#the-fallback-chain) for the current key's source and usage.

4. **Keep the OpenRouter balance funded.**
   With OpenAI gone, chat, memory recall and voice notes all stop together when the key runs dry, so set the credit limit and an alert on the OpenRouter side.

5. **Finish retiring Telegram.**
   What is left on the box once both gateways run on the app alone, and the two bots themselves, are in [Retiring Telegram](retiring-telegram.md#7-what-is-left-on-the-box).

6. **Authorize OAuth access to mail and calendars.**
   Those consents require the account owner's approval and were deliberately left alone.
   Both of Corey's Google sign-ins have since stopped refreshing and need authorizing again; see [Google, through `gog`](#google-through-gog).
   See [Denise's gateway](#denises-gateway) for her existing mailbox connection.

7. **Decide whether SIQsermon's backup should run on a schedule too.**
   Both gateways have been backed up every night since 14 October, keeping 14 (see [The nightly backup](#the-nightly-backup)).
   SIQsermon's half is still a script run by hand, and its newest archive is from 18 September.
   A timer for it would stop Neo4j for its dump every night, which is his call for a live product.

8. **The Control UI is reachable without an SSH tunnel, from his tailnet devices only.**
   It is `https://household.example.ts.net:18789/`; see [How to reach it](#how-to-reach-it).
   Making it reachable from anywhere else would still mean a Caddy route, a public port, and authentication he trusts on a box that already serves a live site, so that stays a deliberate decision rather than a convenience.

Nothing on this list is blocked by anything except him.
