# Brief ha-phase1-identity

## Project

projects/household-assistant

## Task

Phase 1 of the Corey and Denise build, from the plan the Overlord approved on 2026-09-17. This phase builds the spine every later phase hangs from: who is speaking, what they may see, what a tool may do on their behalf, and how an approval is bound. It ships with mocked providers and needs no credential from anyone, which is why it runs now.

Phase 0 is merged: read `docs/phase0/budget.md` in this repository first. It is binding, and it is the only place the assistant budget is written down. **Every container this project ever adds must declare its own memory limit**, because without one the kernel picks the largest resident process globally and that is SIQsermon's Neo4j.

Read the approved plan at `.lavish/household-assistants-plan.html` in the CFO home before designing anything. The rulings that bind you:

- People are `franco` and `gia`. Bot personas are `corey` and `denise`. These are four separate identities: a human is never a persona, and a persona is never a channel.
- **The authenticated sender decides what "my" means**, never text, never a display name, never a model-supplied id. Gia addressing Corey gets Gia's authorized context wearing Corey's voice, and cannot reach Franco's private context. The reverse likewise.
- Memory scopes are `franco_private`, `gia_private`, `household_shared`. The split happens **before prompt assembly**, not by asking a model to keep a secret.
- A person has **many accounts**, each with a provider (`google`, `microsoft`, `apple`), each carrying mail and/or calendars, each authorized by its owner. Franco has two Gmail accounts and at least one Outlook with a calendar. Model it that way now even though no account is connected yet.
- SIQsermon is reachable later as a peer that the assistants read and write as `franco` and `gia`, and **its memory never merges with household memory** in either direction. Leave the seam, build nothing of it here.

Build:

1. **Identity and routing.** Canonical people, personas, channel-independent principals, and enrollment. Only enrolled senders and the approved household group are accepted; an unknown sender gets no data and no tools. Resolution is from authenticated channel metadata with a fail-closed default.
2. **The scoped household service.** One authenticated API holding memory, tasks, reminders, lists, calendar and mail operations, approvals and integration health. Authorization is enforced at the service and the datastore, not in a prompt. The gateway reaches it through a trusted identity envelope; the actor and scopes come from that envelope and never from a model argument. Delegation preserves the original actor and its capabilities.
3. **Typed tool contracts**, the set named in the plan, against **mock providers** for calendar, mail and messaging. Real adapters come in later phases; this phase proves the shape and the boundaries.
4. **Approvals that bind.** An approval binds to a specific action version, actor, resource, destination and expiry. A generic yes in the wrong chat, a different person's callback, an email's contents, or a changed proposal cannot authorize anything, and a replay is harmless.
5. **Storage.** SQLite with write-ahead logging, foreign keys, migrations, transactions and one controlled writer, matching OpenClaw's own default. No Postgres, no Redis, no vector database, no broker.

The tests are the deliverable as much as the code. Leak tests must fail closed and be written so the wrong behaviour fails them: cross-person retrieval, private context reaching a group route, a native tool bypassing a scoped one, delegation escalating an actor, an unknown sender, a forwarded message claiming to be someone, and an approval that is expired, replayed, from the wrong person, or for a changed action.

## Acceptance criteria

- Every leak test above fails closed, each written so the old permissive behaviour fails it.
- The service refuses an actor supplied as a tool argument, proven by test.
- Storage is SQLite with migrations that run forward cleanly on an empty database and on one with data.
- Any container defined declares a memory limit; the sum stays inside the Phase 0 budget, stated in the PR.
- Lint, typecheck and the full suite green with output read, not exit codes.
- Managed gate run from the worktree (`no-mistakes axi run`, reviewer is Claude). If any gate step dies on a quota or usage-credit error, do NOT retry and do NOT park: verify locally with output read, push, open the PR so CI runs, and notify done naming the substitution.
- One PR against main, CI green; open it, do not merge.
- `cfo notify ha-phase1-identity --done --pr <url>` naming what a later phase must not undo.

## Constraints

- Do not touch the VPS, SIQsermon, or any real account; this phase is local and mocked.
- Do not install OpenClaw or run it against a real model; the model is mocked here and its entitlement is unverified.
- Never request or store a real credential.
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
