# Brief ha-phase1-review

## Project

projects/household-assistant

## Task

Review pull request 2 (`feat/phase1-identity`, the identity and privacy spine of the Corey and Denise household assistants) and report. This is a **read-only review**. You write no code in this repository, you open no pull request, and you change nothing on the branch.

The Overlord asked for this review by name, on top of the managed gate the authoring goblin already ran, because Phase 1 is the layer every later phase trusts. If the isolation guarantees here are only apparently true, Phases 2 through 7 inherit the hole and nobody finds it until real mail and real calendars are attached.

The approved build plan is the CFO's review page for the household assistants, with a plain-text flattening beside it. Read the plan before the code.

### How to read the code without disturbing anything

Another goblin currently owns the `feat/phase1-identity` worktree and may still be pushing to it.

- Diff: `gh pr diff 2 --repo fpresta0607/household-assistant`
- A file: `git -C <your worktree> show origin/feat/phase1-identity:household/identity.py`
- Listing: `git -C <your worktree> ls-tree -r --name-only origin/feat/phase1-identity`
- Checks: `gh pr checks 2 --repo fpresta0607/household-assistant`

Record the head SHA you reviewed at the start and again at the end. If it moved, say so in the report and say which findings you re-checked against the new head.

You may create a throwaway clone under your own worktree and run the test suite there if you want to prove a claim by execution. Never check out, reset, commit, push or edit inside the authoring goblin's worktree, and never install anything into it.

### Four lenses. Work all four.

**1. Plan fidelity.** Compare the PR against what the plan says Phase 1 must deliver: people, personas, scopes, approval, tool contracts, mock providers, proven by leak tests that fail closed across cross-person, private-to-group, native tool bypass and delegation. Is anything required missing or stubbed? Is anything present that belongs to a later phase? Most important: does the account data model actually carry what Phases 3 and 4 will need, namely several accounts per person across Google, Microsoft and Apple, with per-account switches for monitored, counts-toward-availability and writable. The Overlord corrected the original one-mailbox-per-person assumption explicitly, so a schema that cannot hold two Gmail accounts plus an Outlook account for one person is a blocker.

**2. Do the leak tests actually prove isolation.** This is the heaviest lens. For each of the four leak classes, establish whether the test would genuinely fail if the protection were removed. Mentally delete the guard and ask what the assertion does then. Hunt for these shapes, each of which has cost this fleet real time before:
- a check whose premise silently stopped holding, so it passes while testing nothing: a path that does not exist, a fixture whose collection is empty, a filter applied to something already empty;
- an empty or zero baseline chosen as the conservative default when an empty set in fact satisfies every assertion permissively;
- an assertion on an exception type or message where the data had already crossed the boundary before the raise;
- a test that exercises the service layer while the real bypass risk sits a layer below it, so the native tool path is never covered at all.
Quote the exact assertion for every vacuous or partial test you find.

**3. Security and credentials.** Any secret, token, password or real address committed anywhere, tests and fixtures included. Whether the approval binding is sound: an approval must not be replayable, must not transfer to a different action, must not be satisfiable by the wrong person, and must not outlive a change to the thing it approved, since Phase 5 depends on revalidating immediately before a write. Whether any provider scope string anywhere asks for mail write, send or delete permission, which is forbidden outright. The injection surface: provider-supplied content that can reach a tool call, and whether a tool can be invoked carrying a person identity the requester does not hold. String-concatenated SQL. Whether an error path or a log line can emit a credential or another person's content.

**4. Will it run correctly on the box.** SQLite configured as promised, with write-ahead logging, foreign keys enforced, ordered idempotent migrations. Concurrency: a Telegram long poller, a reminder worker and a sync worker will all touch this database, so look for a missing busy timeout, a connection shared across threads, a transaction held open across an await, and whether writes are serialized. Anything that would exceed or ignore the assistant budget in `docs/phase0/budget.md`, or a container shipped without its own declared memory limit. State that survives a restart. And whether the CI workflow would actually go red on a real failure: this fleet has been burned by a gate that passed because a binary was missing, and by a new repository whose workflows registered but never fired.

## Acceptance criteria

- A report in the fleet's reports folder, written outside any worktree so cleanup cannot destroy it. Do not leave the only copy inside your worktree.
- Every finding carries: severity (blocker, major or minor), file and line, the claim in one sentence, the code you actually read quoted as evidence, a concrete failure scenario with inputs, and a suggested fix.
- Before you report a finding, try to refute it yourself: check whether a guard elsewhere already prevents the scenario, whether callers can actually reach that code, and whether you have read the cited lines rather than inferred them. Drop anything you cannot stand behind. When genuinely uncertain, say uncertain rather than asserting.
- No finding is a style preference. An empty findings list is a good and acceptable answer if the work is sound; do not pad.
- A one-paragraph verdict at the top: merge as is, merge after named fixes, or do not merge, with the reason.
- `cfo notify ha-phase1-review --done` carrying the verdict and every blocker in the notify text itself, since that text is what the CFO acts on. No credential in the notify.

## Constraints

- Read-only. No edit, commit, push, branch change or dependency install inside the authoring goblin's worktree. No merge.
- Do not touch SIQsermon, its containers, its data or `/etc/siqsermon/runtime.env`.
- Never print, log or quote a credential, even one you find committed; report its location and kind, never its value.
- Never retry anything that fails with a quota or usage-limit error; report it.
- Never kill a process by image name; only pids you spawned.

## Authentication

Services this task needs are declared in data\projects\household-assistant\auth.json.
Run `cfo auth projects/household-assistant --fix` before dispatch.

## Commits

Never name an AI product, company, model, agent, or assistant identity as a
commit co-author: not in a `Co-Authored-By` trailer, not anywhere else in a
commit message, and not in a pull request body.

## Delivery

kind: report
mode: local-only
