# Brief ha-openclaw-runtime

## Project

projects/household-assistant

## Task

Stand up the OpenClaw runtime on the IONOS VPS that already runs SIQsermon, so Corey and Denise have a home to run in. This is the host and runtime layer only. Identity, scopes and tools belong to the household service that Phase 1 built and Phase 2 extends; do not reimplement any of that here.

The Overlord's words: he wants the assistants fully set up on the VPS with OpenClaw, everything running, and a clear list of what only he can finish. Your report is what that list gets written from, so it has to be precise about what is running, what is waiting, and why.

Phase 0 already measured this box and reserved the budget. Read what it landed on `origin/main` before you touch anything: `git -C <worktree> ls-tree -r --name-only origin/main` and the Phase 0 documents it lists. The assistant budget is what `docs/phase0/budget.md` declares, which is the only place that number lives, and every container must declare its own limit.

### What to build

1. **OpenClaw from a prebuilt, version-pinned image.** Never build the image on the box. Community reports and this box's headroom agree that a local build needs roughly 2 GB and the kernel kills it. Pin an exact version, never `latest`, and record the digest you pinned.
2. **State on disk, mounted.** The state directory lives outside the container and is mounted in, so an image upgrade never loses memory. Add it to the backup job Phase 0 established, and prove the backup captures it by restoring into a scratch location, exactly as Phase 0 rehearsed.
3. **Loopback only.** Admin and API surfaces bind to 127.0.0.1. No new public port, no firewall change, no Caddy change. Verify from OUTSIDE the box that the port set reachable from the internet is unchanged from before your work, and put the before and after in your report.
4. **Declared limits.** Memory and CPU limits on every container you add, inside the assistant budget `docs/phase0/budget.md` declares. Report the measured resident footprint at idle, not the declared ceiling.
5. **Survives a reboot.** Restart policy plus whatever the box uses for service supervision. Prove it by actually rebooting the box or by restarting the Docker daemon, then confirming both OpenClaw and SIQsermon come back healthy without a human.
6. **Memory backend stays the SQLite default.** No LanceDB, no Honcho, no plugin. The plan's decision, and it holds until recall quality is proven to be the bottleneck.
7. **The model backend.** Follow [The model backend](../../deploy/openclaw.md#the-model-backend) for the owner-approved routing, credentials and activation requirements.
   Do not sign anything up or create a new paid account.
   Report which backend is configured and which activation steps remain.

### What NOT to do

- Do not touch SIQsermon: not its containers, not its data, not `/etc/siqsermon/runtime.env`, not its Caddy configuration, not its ports. After every step that changes the host, confirm SIQsermon is still healthy and its site still answers.
- Do not reduce SIQsermon's resources further. Phase 0 already made that trade and it is settled.
- Do not create Telegram bots, do not accept a bot token through chat, and do not authorize any mailbox or calendar. Those are the Overlord's to do and they are Phase 2 and later.
- Do not print, log, echo or commit a credential.

## Acceptance criteria

- OpenClaw is running on the VPS from a pinned prebuilt image, and you name the version and digest in the report.
- `docs/deploy/openclaw.md` on a branch, explaining in plain language: how to reach it, how to restart it, where its state lives, what the limits are, how the backup covers it, and how to roll back to the previous pinned version.
- A reboot or daemon restart is actually performed, and both OpenClaw and SIQsermon come back healthy with no human step. Say which one you did.
- The externally reachable port set is unchanged. Show the before and after.
- Measured idle footprint reported for every container you added, with the total against the budget in `docs/phase0/budget.md`.
- A backup that includes the assistant state directory is taken and restored into a scratch location to prove it opens.
- A clear statement of the model backend the runtime is on and which owner activation steps remain in [the runbook](../../deploy/openclaw.md#what-only-the-overlord-can-finish).
- A section of the report titled "What only the Overlord can finish" listing every remaining action in the order he should do them.
- Delivered through the managed gate under this task's frozen policy with `cfo pipeline run`; if the gate refuses before launch or its review step fails on a reviewer usage limit, do not retry: notify `cfo notify ha-openclaw-runtime --blocked "<text>"` and stop.
- `cfo notify ha-openclaw-runtime --done --pr <url>` once the PR exists and every check is green.

## Constraints

- Never retry anything that fails with a quota or usage-limit error; report it.
- Never kill a process by image name; only pids you spawned.
- Never merge; merge authority stays with the CFO.
- No new paid account, no new subscription.
- If a step would reduce SIQsermon's availability for more than a few seconds, stop and notify instead of proceeding.

## Authentication

Services this task needs are declared in data\projects\household-assistant\auth.json.
Run `cfo auth projects/household-assistant --fix` before dispatch; add any service the task needs that the manifest does not list yet.

## Commits

Never name an AI product, company, model, agent, or assistant identity as a
commit co-author: not in a `Co-Authored-By` trailer, not anywhere else in a
commit message, and not in a pull request body.

## Delivery

kind: ship
mode: no-mistakes
