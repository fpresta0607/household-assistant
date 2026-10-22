# Brief ha-phase0-headroom

## Project

projects/household-assistant

## Task

Phase 0 of the Corey and Denise build, approved by the Overlord on 2026-09-17 from the plan at `.lavish/household-assistants-plan.html` in the CFO home. This phase makes room on the shared VPS and proves the existing data is recoverable. It installs no assistant code.

The box is the IONOS VPS reached through the `ionos` service in the auth manifest (IONOS_HOST, IONOS_SSH_USER, IONOS_SSH_KEY_PATH). It also runs SIQsermon. Measured facts, verified read-only on 2026-09-17, which you should re-verify rather than trust:

- Ubuntu 26.04.1 LTS, x86_64, 6 vCPU, 7,878 MB RAM, 5,320 MB available, 232 GB disk with 7.9 GB used, **no swap**.
- SIQsermon Compose stack under `/opt/siqsermon/current/deploy`: neo4j using 959 MiB against a 3,584 MiB limit, backend 762 MiB against 1,536 MiB, qdrant 99 MiB against 1,536 MiB, caddy 12 MiB against 256 MiB. Declared limits reserve 6.75 GiB of 7.7 GiB while the stack actually uses 1.8 GiB.
- Ports open to the world: 22, 80, 443 only, ufw active.

**The Overlord's ruling, and the order it implies.** The assistants get the larger share of the box; SIQsermon does not grow beyond what it has and is the one that yields under pressure. Resource contention is acceptable. **Data loss is not**: his 203,648 Neo4j nodes, 31,105 verse vectors, twelve sermons, five projects and voice sample cannot be recreated.

Do these in order, and stop and notify if any step's verification fails:

1. **Back up first, and prove the backup.** Take a database-consistent backup of the SIQsermon stack: Neo4j (use its own dump or a consistent offline copy, not a file copy of a running store), Qdrant (its snapshot mechanism), the SQLite application database, the data volume and `/etc/siqsermon/runtime.env`. Store it on the box outside `/opt/siqsermon` and record sizes and checksums. Then **rehearse the restore in a separate temporary location** and prove it opens: node and relationship counts equal to source for Neo4j, collection point count for Qdrant, and table row counts for the SQLite database. A backup nobody has opened is not a backup.
2. **Add swap.** A 4 GB swap file with a conservative swappiness, persisted across reboot. Reason it out loud in the PR: with no swap the kernel kills a process outright under pressure rather than slowing down, which is how a database loses a write.
3. **Trim SIQsermon's reservations to fit its real working set**, leaving headroom for the assistants. Measure first, then choose limits with a stated margin over observed peak rather than a round number pulled from the air; watch it for long enough to see a real working set, not one idle sample. Neo4j's heap and page-cache settings must agree with its new container limit, or lowering the container limit just moves the kill. Apply through the repository's compose file and its own deploy path, never by hand on the box, so the next deploy does not undo it.
4. **Verify SIQsermon is unharmed.** Its health endpoint answers over TLS, all four containers healthy, a login succeeds, a project loads with its conversation, and the counts from step 1 still match. Record before and after memory for each container.
5. **Record the assistant budget.** State plainly how much memory and CPU is now available for the household assistant, and what happens if it exceeds that. This number is the input to every later phase.

Anything you change on the box must be reversible, and the PR body must carry the exact rollback commands.

## Acceptance criteria

- A verified backup exists with a proven restore rehearsal, counts matching source, and its location and checksums recorded.
- Swap is active and persists across a reboot, proven by rebooting or by an equivalent check you name.
- SIQsermon's limits reflect its measured working set, applied through its repository and deploy path, with Neo4j's internal memory settings consistent with the new limit.
- SIQsermon passes its own health checks after every change; no port, firewall or DNS change occurred.
- The remaining budget for the assistants is stated as a number.
- One PR against main in this repository carrying the runbook, the measurements and the rollback; open it, do not merge.
- `cfo notify ha-phase0-headroom --done --pr <url>` with the before and after table and the assistant budget.

## Constraints

- Never delete SIQsermon data. The Overlord raised pruning old sermons; the CFO ruled against it because the memory is held by Bible content rather than history. Do not prune anything.
- Never touch ports 80 or 443, the firewall, DNS, or the Caddy configuration.
- Never run a blanket docker prune; it would destroy volumes on a shared box.
- Never print a secret; `/etc/siqsermon/runtime.env` is read for backup only and its contents never appear in output, logs or the PR.
- Never kill a process by image name; only pids you spawned.
- Never retry anything that fails with a quota or usage-limit error; report it.
- Never merge; merge authority stays with the CFO.

## Authentication

Services this task needs are declared in data\projects\household-assistant\auth.json.
Run `cfo auth projects/household-assistant --fix` before dispatch; add any service the task needs that the manifest does not list yet.

## Commits

Never name an AI product, company, model, agent, or assistant identity as a
commit co-author: not in a `Co-Authored-By` trailer, not anywhere else in a
commit message, and not in a pull request body. This is the Overlord's
standing rule, and the fleet's history must not credit an author that did not
exist.

## Delivery

kind: ship
mode: direct-PR
