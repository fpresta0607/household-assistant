# Phase 0 measurements

How the numbers in the [runbook](runbook.md) were arrived at.
Everything here is from the box on 2026-09-17.

## How it was measured

One idle sample is not a working set, so the stack was sampled every 20 seconds for 45 minutes, 22 of which were under continuous real traffic.
The load was `scripts/siqsermon-exercise.sh` run 30 times at 30 second intervals against the public TLS endpoint: login, session, settings, sermon list, project list, the busiest project with its twelve messages, and six retrieval queries that go through the embedding provider, Qdrant and Neo4j.

450 requests, every single one a 200.

Two different numbers are reported per container and they answer different questions.

`working set` is what `docker stats` reports, which is the cgroup's `memory.current` minus inactive file cache.
It is the memory the container is actually using.

`cgroup peak` is `memory.peak`, the all-time high water mark since the container started, and it includes reclaimable file cache.
It is higher, and it is the number to size against for anything that does heavy file IO, because that is the shape a spike takes.

## What came back

| container | peak working set | mean working set | cgroup peak | peak CPU |
|---|---|---|---|---|
| neo4j | 1,008.0 MiB | 908.8 MiB | 1,243.8 MiB | 198.6% |
| backend | 775.4 MiB | 763.3 MiB | 984.8 MiB | 75.3% |
| qdrant | 101.5 MiB | 77.4 MiB | 550.7 MiB | 4.5% |
| caddy | 19.9 MiB | 14.5 MiB | 20.9 MiB | 4.1% |

Qdrant's cgroup peak of 550.7 MiB is not search traffic.
It is what writing a snapshot costs, and it is treated as the real peak because backups are meant to be routine rather than exceptional.

## The sizing rule

A round number pulled from the air is not a limit, it is a guess with a unit on it.
Each limit here is the larger of two numbers, rounded up to the next 64 MiB:

- **1.5 times the observed peak.** Covers a busier day than the one measured.
- **1.25 times the analytic worst case.** Covers what the process is *configured* to be able to take, which for a JVM is a very different number from what it has taken.

For three of the four containers the first number wins, because nothing constrains their growth but demand.
For Neo4j the second wins, and that is the interesting case.

## Neo4j

Neo4j's memory is configured, not demanded.
It was set to a 2g maximum heap and a 1g page cache, so its ceiling was about 3.4 GiB regardless of what the data needed, and the 3,584M container limit was sized to that configuration rather than to the graph.

What the graph actually needs:

```
store on disk                 /data/databases/neo4j     101 MB
transaction logs              /data/transactions/neo4j  514 MB   (streamed, not cached)
heap in use                   G1 total 524288K, used 220435K
metaspace                     committed 129920K
configured page cache         1.00 GiB
configured heap max           2.00 GiB
```

The store is 101 MB.
The heap has never held more than 220 MiB.
`neo4j-admin server memory-recommendation --memory=2g` returns `heap 512m / pagecache 512m` for this store, which is a useful second opinion rather than the reason.

New settings:

- **heap 512m, initial and max equal.** 2.3 times the observed peak use. Equal initial and max means the resident floor is predictable and G1 does not resize under load, which matters when the container limit is close behind.
- **page cache 512m.** About five times the store, so the whole graph stays resident with room for it to grow several times over before this needs revisiting.

Analytic worst case: 512 heap + 512 page cache + about 160 MiB metaspace and code cache + about 120 MiB of threads, direct buffers and JVM overhead, which is roughly 1,304 MiB.
Times 1.25 is 1,630, and 1.5 times the 1,008 MiB observed peak is 1,512.
The larger, rounded up, is **1,792M**.

### The validation

`scripts/neo4j-limit-validation.sh` starts a throwaway Neo4j on a restored copy of the real store with exactly these settings under `--memory 1792m`, then makes it do the worst thing it will ever do: load 614 MiB of store and then run whole-graph scans repeatedly.

```
loading the real store into a throwaway volume
  Done: 100 files, 614.5MiB processed in 1.611 seconds.
starting neo4j with heap=512m pagecache=512m under --memory 1792m
the store opens and the data is all there:
  nodes         203648
  relationships 960556
the query shapes the retrieval path uses, repeated to warm the page cache:
  round 1  13060 ms  mem 908.8MiB / 1.75GiB
  round 2  11474 ms  mem 909.8MiB / 1.75GiB
  round 3  10897 ms  mem 910.7MiB / 1.75GiB

peak under the proposed limit: 1406 MiB of 1792m
oom kills during the run: false
```

386 MiB spare under the heaviest thing it can be asked to do, and the working set settles at 910 MiB, within a rounding error of what production shows.

### Did the prediction hold on the live store

A restored copy under synthetic load is not the live store under real traffic, so after the deploy the identical 22 minute window was re-run against the real thing.

| | throwaway test | live under the new limit |
|---|---|---|
| mean working set | 910.7 MiB | 904.9 MiB |
| peak working set | 910.7 MiB | 1,011.0 MiB |
| cgroup peak | 1,406 MiB | 1,409 MiB |
| headroom under 1792M | 386 MiB | 383 MiB |
| OOM kills | 0 | 0 |
| restarts | 0 | 0 |

Three MiB apart on the peak.
The one place they differ is peak working set, 1,011 MiB against the throwaway's flat 910.7, because real traffic touches a wider spread of the graph than a scan loop does.
That is still 78% of the limit, and it is 3 MiB above what the same container peaked at *before* the change, which is the expected result: the memory was never the problem, the reservation was.

## Backend

775.4 MiB working set, 984.8 MiB including file cache, and no configured ceiling of its own: it is Python, so a leak ends in an OOM kill rather than a `MemoryError`.

1.5 times 775.4 is 1,163.
1.25 times 984.8 is 1,231.
The larger, rounded up, is **1,280M**.

This is the smallest trim of the four and deliberately so.
The measured window covered the read and retrieval paths.
It did **not** cover `/generate`, narration or slide rendering, which are the heavy ones.
Before cutting this further, someone should measure a full generation plus narration run.
Naming that gap is more useful than pretending the number covers it.

**After the deploy this turned out to be the tightest of the four.**
Over the post-deploy window it peaked at 818 MiB working set and 1,032 MiB cgroup, which is 80% of the 1,280M limit and 248 MiB of headroom.
The rule predicted 1.24x realized margin and delivered 1.24x, so the arithmetic was right, but it leaves the backend with the least room on the box and the unmeasured heavy paths sit behind exactly those 248 MiB.
If it starts getting OOM-killed, raise it to 1408M and take 128 MiB back off the assistant budget, or measure a generation run and find what is holding the memory.
That failure costs a request rather than data, and Neo4j, which is the one that would have cost data, now sits at 78% with 383 MiB spare.

## Qdrant

101.5 MiB serving searches, 550.7 MiB while writing a snapshot.

1.5 times 101.5 is 152.
1.25 times 550.7 is 688.
The larger, rounded up, is **768M**.

Independently validated during the restore rehearsal: a Qdrant started under `--memory 768m` recovered the full 31,105 point collection from the snapshot and answered searches, which is the heaviest startup path it has.

After the deploy it peaked at 126 MiB, 16% of the limit.
That gap is not slack, it is the snapshot path being paid for in advance.

## Caddy

19.9 MiB working set, 20.9 MiB cgroup peak, and it is a reverse proxy with no state.
1.25 times 20.9 is 26, so the rule alone would allow something absurd.
**128M** is six times the peak and still frees 128 MiB of the reservation.
The rule sets a floor here, not the answer.

## CPU

CPU ceilings are left exactly as they are, and that is a decision rather than an oversight.

`deploy.resources.limits.cpus` is a CFS quota.
It is a ceiling, not a reservation, so SIQsermon's declared 5.00 vCPU takes nothing from a neighbour while SIQsermon is idle, and SIQsermon is idle almost always: its mean draw across the whole window was under 0.1 vCPU.

Neo4j does briefly reach 198.6% during retrieval, which means it is already hitting its 2.00 ceiling.
Lowering it would make SIQsermon's retrieval measurably slower while making no memory available to anything else.

The second reason is honesty: the heavy generation paths were not in the measured window, so any CPU number chosen now would be exactly the round number pulled from the air that the brief warns against.

The assistants get their share through memory limits, which cap what SIQsermon can take, and through the kernel's own time-slicing, which is fair by default.

## Sum

| | declared before | declared after | freed |
|---|---|---|---|
| neo4j | 3,584M | 1,792M | 1,792 MiB |
| backend | 1,536M | 1,280M | 256 MiB |
| qdrant | 1,536M | 768M | 768 MiB |
| caddy | 256M | 128M | 128 MiB |
| **total** | **6,912M** | **3,968M** | **2,944 MiB** |

A stack that used about 1,850 MiB was holding a claim on 6,912 MiB of a 7,878 MiB box.
That claim was not protecting anything, because it was never close to being used.

Measured again after the deploy, the whole stack peaks at 2,586 MiB of cgroup usage against its new 3,968 MiB declaration.
The remaining 1,382 MiB is the margin doing its job rather than reservation going to waste.

**Superseded on 2026-09-18.**
These ceilings were retuned again, down to 2,624M in total, and [`budget.md`](budget.md#where-the-memory-came-from) is where the current declarations and the measurement behind them live.
Everything above is the Phase 0 measurement and the ceilings it set.
