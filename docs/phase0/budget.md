# The assistant budget

This number is the input to every later phase.
It is the answer to "how big can Corey and Denise be", and every phase after this one has to fit inside it.

## Memory: 4,480 MiB

Revised 2026-09-18.
The Overlord ruled that OpenClaw is the purpose of this box and SIQsermon is the guest, so the split now favours the assistants heavily.

```
  7,878 MiB   total RAM on the box
- 2,624 MiB   SIQsermon's declared ceiling, retuned to its measured working set
-   768 MiB   the host itself: kernel, systemd, sshd, the docker daemon
              (measured at 742 MiB under load on 2026-09-18; 768 is that rounded up)
= 4,486 MiB   available
= 4,480 MiB   the budget
```

4,480 MiB is the **sum of every assistant container's memory limit**, not a per-container figure.
The [OpenClaw deployment guide](../deploy/openclaw.md#what-the-limits-are) records the current allocation and whether any allowance remains for another container.

The previous figure was 3,072 MiB against a SIQsermon ceiling of 3,968 MiB.
The 1,344 MiB difference did not come from deleting anything.
It came from retuning, and the section below is the evidence.

## CPU: 4 vCPU sustained

The box has 6 vCPU.
SIQsermon's ceilings still sum to 5.00, and the [two gateways](../deploy/openclaw.md#what-the-limits-are) declare the full assistant CPU budget.
The combined ceilings exceed the box's physical cores.
That over-subscription is deliberate and it is not a mistake in the arithmetic.

`cpus` is a CFS quota, not a reservation.
It takes nothing while a container is idle, so lowering one frees no capacity for anybody else; the only thing it can do is throttle a burst.
This phase tried lowering SIQsermon's CPU ceilings to its measured peaks and reverted it, because the measurement showed exactly that and nothing else.
See [CPU ceilings were tried and reverted](#cpu-ceilings-were-tried-and-reverted).

SIQsermon's mean draw across a 22 minute load window is under 7% of one core.
The assistants have the box's CPU in practice.

---

## Where the memory came from

Nothing was pruned.
The graph is still 203,648 nodes and 960,556 relationships, the collection is still 31,105 verse vectors, and there are still twelve sermons and six projects.
That was never where the memory was: the Bible graph and the verse vectors are the store, and twelve sermons are rounding error against them.
Deleting the Overlord's preaching memory would have cost him the thing the app is for and freed almost nothing.

The memory was in the JVM's reservation, and it came back by retuning it.

### The lever was Neo4j's heap, not its page cache

Two settings, and only one of them was actually holding memory.

**Heap.** Initial and max were both 512m, which means the JVM commits the whole heap at startup and keeps it resident whether or not it is used.
Under the load window the JVM peaked at 291 MiB used.
Dropping max to 384m keeps a 1.3x margin over the loaded peak and hands back the difference immediately.

**Page cache.** 512m was allocated against a store that is 101 MB on disk, and Neo4j only ever touched about 101 MB of it.
So that allowance was freeing nothing today.
Lowering it to 256m is still 2.5x the store, and unlike 512m it bounds the worst case if the graph grows.

Together those dropped Neo4j's anonymous memory from 909 MiB to 779 MiB.

### Ceilings are set from the measurement, with file cache treated as reclaimable

A container's memory divides into anonymous memory, which is the process and cannot be reclaimed, and file cache, which the kernel drops under pressure rather than OOM-killing for.
Phase 0 set ceilings above the whole figure.
This phase sets them above the anonymous floor with a margin, and lets the file cache live in whatever is left.

That is why Neo4j's cgroup peak sits at exactly its 1,024 MiB ceiling and that is not distress: 779 MiB of it is the process and the rest is cache the kernel is holding because it can, and will release the moment anything needs it.
Zero OOM kills and zero restarts across three full load windows.

| container | declared before | declared after | anon at peak | freed |
|---|---|---|---|---|
| neo4j | 1,792M | **1,024M** | 779 MiB | 768 MiB |
| backend | 1,280M | **1,024M** | 532 MiB | 256 MiB |
| qdrant | 768M | **512M** | 18 MiB | 256 MiB |
| caddy | 128M | **64M** | 14 MiB | 64 MiB |
| **total** | **3,968M** | **2,624M** | | **1,344 MiB** |

Qdrant's ceiling is not set by serving searches, which costs it 18 MiB.
It is set by the backup: writing a snapshot pulls the whole collection through page cache and the cgroup reached 443 MiB.
That memory is reclaimable, but backups are meant to be routine, so 512M keeps the snapshot path comfortable instead of making it thrash reclaim.

**The backend is still the one to watch.**
It has the least room relative to what it does, and the generation and narration paths are still not in the measured window.
If it starts getting OOM-killed, the fix is to measure a full generation run and raise it, taking the difference back off the assistant budget.
A backend OOM kill costs a request; it is not the data-loss failure Phase 0 existed to prevent.

---

## Before and after, measured

Three full runs of the identical load Phase 0 used: 30 iterations of the real user path over the public TLS endpoint, 450 requests, about 22 minutes each.
`scripts/siqsermon-measure.sh` is that measurement.

### Memory and CPU per container

| container | declared ceiling | | peak working set | | cgroup peak | | peak CPU | |
|---|---|---|---|---|---|---|---|---|
| | before | after | before | after | before | after | before | after |
| neo4j | 1,792M | **1,024M** | 944 MiB | **798 MiB** | 1,139 MiB | 1,024 MiB | 199% | 48% |
| backend | 1,280M | **1,024M** | 598 MiB | **602 MiB** | 966 MiB | 966 MiB | 102% | 110% |
| qdrant | 768M | **512M** | 26 MiB | **29 MiB** | 443 MiB | 443 MiB | 5% | 5% |
| caddy | 128M | **64M** | 16 MiB | **17 MiB** | 24 MiB | 25 MiB | 4% | 4% |
| openclaw-gateway | 1,536M | **3,072M** | 364 MiB | **424 MiB** | 556 MiB | 556 MiB | 121% | 127% |

Host peak used fell from 2,697 MiB to 2,612 MiB.
Swap stayed at 0 B used through all three windows, which is what Phase 0 intended it for: a safety net, not a place to live.

Neo4j's peak CPU falling from 199% to 48% is not a throttle.
It is a smaller heap doing less garbage collection for the same work.

A caveat on the cgroup peak column: `memory.peak` is cumulative for a container that has not been recreated, and on this kernel resetting it only clamps it to current usage.
The peak working set column is a genuine per-window measurement from 5 second sampling, and it is what the ceilings are set from.

### SIQsermon did not get slower

`POST /search` is the path a user actually waits on: it embeds the query, searches Qdrant and looks up anchors in Neo4j.

| | before | after |
|---|---|---|
| mean | 0.231 s | **0.198 s** |
| p50 | 0.222 s | **0.195 s** |
| p95 | 0.304 s | **0.238 s** |
| max | 0.453 s | **0.276 s** |
| requests | 419 of 420 returned 200 | **420 of 420 returned 200** |

Steady state, excluding the first iteration, which is a cold start in both runs.
The retuned stack is measurably **faster**, not slower, and the most likely reason is the same one that shows up in the CPU column: a 384m heap collects less garbage than a 512m one, and the store still fits the page cache.

The single 500 in the before run was the very first `/search` of the window, against a Neo4j that had just restarted, followed by one 5.3 second search while the path warmed up.
It did not recur.

### CPU ceilings were tried and reverted

The first attempt also lowered every SIQsermon CPU ceiling to its observed peak: backend 1.50 to 1.00, qdrant 1.00 to 0.25, caddy 0.50 to 0.25.
That was a mistake and the measurement caught it.

| | backend at 1.00 | backend at 1.50 |
|---|---|---|
| CFS throttled | 449 times, 41.9 s | 111 times, 5.8 s |
| `/search` p50 | 0.280 s | 0.195 s |
| `/search` p95 | 0.402 s | 0.238 s |

A ceiling set at the measured peak throttles the exact burst that produced that peak.
Because a quota reserves nothing, that throttling bought the assistants no memory and no cores; it only made the app slower.
The CPU ceilings are back where Phase 0 left them and the memory retune is kept, which is the combination in the table above.

The lesson generalises and is worth stating: **memory is the scarce resource on this box, CPU is not.**
Set memory ceilings tightly from measurement. Leave CPU ceilings generous.

---

## How this was made safe

- A fresh verified backup was taken **before** anything was retuned: `/var/backups/siqsermon/20260918T004352Z`, restored into a scratch location and opened, counts matching exactly. The rollback path is that backup plus `deploy.sh rollback`.
- Three of the four containers changed ceiling with `docker update`, which takes effect on a running container. Only Neo4j was recreated, because only its JVM settings changed.
- Neo4j was unavailable for 26 seconds during that recreate. The public site never dropped a request: an external poller at 400 ms intervals recorded 92 consecutive 200s across the whole window, because Caddy and the backend were never touched.
- The retune is durable. It is live on `/opt/siqsermon/current/deploy/docker-compose.prod.yml`, and it is also in the SIQsermon repository: [fpresta0607/SIQsermon#20](https://github.com/fpresta0607/SIQsermon/pull/20) merged on 2026-09-18 at `74241ec`. A `deploy.sh deploy` or `deploy.sh rollback` now restores the retuned ceilings rather than the old ones, so the 4,480 MiB assistant budget survives a redeploy. Verified against the merged file: the four ceilings read 64M, 1024M, 1024M and 512M, with a 384m Neo4j heap and a 256m page cache.

## What a later phase must not undo

- Every assistant container declares `deploy.resources.limits.memory`. Without one, a runaway assistant exhausts the box, and the kernel's OOM killer chooses globally by resident size, which means it kills Neo4j rather than the assistant.
- The sum of those declarations is 4,480 MiB. It is a sum, not a per-container allowance.
- SIQsermon's data is not a memory lever and never was. If more memory is needed, measure and retune; do not prune.
- Do not lower a `cpus` ceiling to free capacity. It does not work, and the measurement above is what happens when you try.
- Do not keep a ceiling with `docker update`. It changes the running container and writes nothing back, so the next `docker compose up -d` silently restores whatever the file says. The assistant's ceiling drifted exactly this way on 2026-09-18 and is described in [docs/deploy/openclaw.md](../deploy/openclaw.md#the-deployed-compose-file-is-the-ceiling-and-it-drifted-once). A ceiling lives in the compose file in this repository, and reaches the box through the installer.
