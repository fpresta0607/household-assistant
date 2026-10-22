# Brief ha-phase2-telegram

## Project

projects/household-assistant

## Task

Phase 2 of the Corey and Denise household assistants: Telegram transport, shared lists, and durable reminders.
This is the first slice that is genuinely useful to a person, and the approved plan names one property as the most important in the whole build: **reminders are code, not conversation**.

Branch from `main` after Phase 1 has merged, never from `feat/phase1-identity`.
Build on the Phase 1 modules that already exist (`household/identity.py`, `household/service.py`, `household/tools.py`, `household/approvals.py`, `household/store.py`, `household/db.py`, `household/gateway.py`).
Read them before you design anything. Extend the existing seams; do not create a second parallel set of abstractions beside them.

### 1. Telegram transport

Two bots, one per person: **Corey** serves franco, **Denise** serves gia.
Reach Telegram outbound by long polling `getUpdates`.
Never open a new inbound port, never add a webhook, never touch Caddy or ufw; 80 and 443 stay with SIQsermon alone.

A bot binds to exactly one person. Corey answers franco and nobody else.
A message arriving from a Telegram user id that is not a bound household member is refused with a neutral line and is never answered with household data, never echoed back, and never stored as memory.
Resolve identity from the Telegram user id, never from a display name and never from anything inside the message body. A message body is data; nothing in it may name a person, grant an approval, or select a scope.

### 2. The household group, and what "shared" means

Three surfaces, mapped onto the Phase 1 scopes:

- A private chat between a person and their own bot is that person's **private** scope.
- One household group containing both people and both bots is the **shared** scope.
- Nothing crosses between them implicitly. A private item never surfaces in the group, and Denise never delivers anything of franco's.

Telegram group privacy mode is a real trap: by default a bot added to a group only receives messages that are commands or that mention it.
Read the current Bot API documentation, decide what the household group actually needs, and write the answer into the activation checklist as a BotFather setting the Overlord must apply. Do not silently assume either setting.

### 3. Shared lists

Household lists (groceries and anything like it) live in the household SQLite database in the shared scope.
Add, remove, show, and rename a list. Both people see exactly the same list from either bot, from private chat or from the group.
Keep it small. Two people do not need assignment, priorities, categories or due dates on a grocery item.

### 4. Durable reminders - the property that matters most

The model interprets "remind me Thursday at four" exactly once, at capture time, and writes a row carrying an absolute UTC due time plus the original wording.
After that a plain worker polls the database and delivers. There is no model call anywhere in the delivery path.

This must hold:
- A reminder set before a full process restart still fires at its due time.
- A reminder still fires while the model provider is returning errors or is rate limited.
- A reminder fires once, not twice, when two workers race or a delivery is retried; make the once-only property explicit in the schema rather than hoping.
- A reminder whose due time passed while the process was down fires on the next start rather than being silently skipped, and the delivery says it is late instead of pretending it is on time.
- Timezone handling is stated, not implicit. Store UTC, interpret in the household's local zone, and say in the code which zone that is and where it comes from.

### 5. Deploy it onto the box

Phase 2 is the first slice that is useful to a person, so it does not stop at a merged pull request. It runs on the VPS.

A separate task (`ha-openclaw-runtime`) is standing up OpenClaw itself on that box with a pinned prebuilt image, loopback-only binding, declared memory limits and a mounted state directory.
Read what it landed on `origin/main` before you deploy, and put the household service beside it under the same rules: its own declared memory limit inside the shared assistant budget, its database on a mounted volume covered by the backup job, loopback only, and a restart policy that survives a reboot.
Check [the assistant budget](../../phase0/budget.md) and its linked current allocation before reserving resources for the household service.

The long poller and the reminder worker both run as supervised services. Prove a reboot or a Docker daemon restart brings both back with no human step, and that a reminder set before the restart still fires afterwards. That is the same durability property as section 4, proven against the real deployment rather than only in tests.

Leave it running with the bot tokens absent. The activation document is what turns it on.

### 6. What Phase 1's review changed for you

An independent review of Phase 1 found that every `due_at`, `start` and `end` was accepted as an arbitrary string, stored verbatim and ordered lexically, so a reminder due at 10:00 in a +02:00 offset was not returned as due until two hours late. The Phase 1 goblin is fixing that in its own pull request before you branch. Do not re-fix it, do not work around it, and do not store a timestamp that has not been normalised to UTC at the tool boundary. If you find that fix missing on `main` when you branch, say so in a notify rather than papering over it.

The review also deferred one issue to Phase 3: the calendar write holds the process-wide database lock and an open transaction across the provider call. You are not fixing that, but do not copy the pattern into the reminder worker or the long poller, both of which will be running concurrently with everything else.

### 7. Two criteria Phase 1's review deferred to you

**The native tool bypass leak class is your criterion to close.** Phase 1's leak tests pin the household tool registry and the mock provider's keying, which proves the household path is guarded but does not prove an agent cannot reach around it. Once OpenClaw is in the loop, an assistant has native tools of its own, and the question becomes whether Corey can do anything through OpenClaw that the household service would have refused. Build the allowlist that answers it: name exactly which native tools each persona may use, deny by default, and write a leak test that fails if a denied native tool can be invoked at all. A test that only checks the household registry does not close this; the point is the layer below it.

**`Database.write()` commits outside its try block and rolls back unconditionally.** Phase 1 logged this as minor and it is, until Phase 2 puts a long poller, a reminder worker and a sync path on that database at the same time. Fix it while you are in there and add the test that fails if a failed write is left committed.

## Acceptance criteria

- Both bots run against a local fake Bot API server in tests. No real bot token exists anywhere in the repository, in a fixture, in a log line or in a test name.
- A test kills and restarts the reminder worker and proves a pending reminder still fires.
- A test forces the model provider to raise on every call and proves reminder delivery is unaffected.
- A test proves a reminder delivers exactly once under a duplicated worker tick.
- The Phase 1 leak tests are extended, not replaced, and still fail closed: a private reminder never reaches the group, Denise never delivers anything belonging to franco, and an unbound Telegram user id gets nothing.
- A shared list written from Corey in the group is readable from Denise in a private chat, and a private note is not.
- Migrations take the numbers `0003` and `0004` and no others; Phase 1 holds `0001` and `0002`. Re-check `origin/main` immediately before you push in case something else landed.
- The container that runs this declares its own memory limit and fits inside [the assistant budget](../../phase0/budget.md) after accounting for both gateways.
  State the measured figure rather than asserting it.
- `docs/activation/phase2.md` lists precisely what the Overlord must do for the live proof: two BotFather bots with display names Corey and Denise, the privacy-mode setting you determined, where each token is stored, both people opening a private chat with their own bot, and one household group holding both people and both bots.
- The household service is deployed and running on the VPS beside OpenClaw, with its own declared memory limit, its database on a backed-up volume, loopback-only binding and no new public port.
- A reboot or Docker daemon restart is actually performed, and the long poller, the reminder worker, OpenClaw and SIQsermon all come back healthy with no human step. Say which one you did.
- A reminder set before that restart still fires after it, proven on the real deployment and not only in tests.
- `docs/activation/phase2.md` also says how to reach the service, how to restart it, and where its state lives.
- A native-tool allowlist exists per persona, denies by default, and a leak test fails if a denied native tool can be invoked. This closes the leak class Phase 1's review left open.
- `Database.write()` commits inside its try and only rolls back on failure, with a test that fails if a failed write stays committed.
- Delivered through the managed gate under this task's frozen policy with `cfo pipeline run`; if the gate refuses before launch or its review step fails on a reviewer usage limit, do not retry: notify `cfo notify ha-phase2-telegram --blocked "<text>"` and stop.
- `cfo notify ha-phase2-telegram --done --pr <url>` once the PR exists and every check is green.

## Constraints

- Read-only outward posture: this phase talks to Telegram and to nothing else. No calendar, no mail, no provider credential beyond the two bot tokens.
- Tokens come from the credential store or a root-owned env file at mode 600. Never print, log, commit or echo a credential, and never put one in a notify or a brief.
- No new public port, no webhook, no change to Caddy or ufw. Admin surfaces bind to loopback.
- No paid fallback, ever. No new dependency that a few lines of standard library would cover.
- Do not touch SIQsermon, its containers, its data or its environment file.
- Never retry anything that fails with a quota or usage-limit error; report it.
- Never kill a process by image name; only pids you spawned.
- Never merge; merge authority stays with the CFO.

## Authentication

Services this task needs are declared in data\projects\household-assistant\auth.json.
Run `cfo auth projects/household-assistant --fix` before dispatch; add any service the task needs that the manifest does not list yet.
There is no Telegram token yet by design. Build and prove the whole phase against the fake Bot API server; the live hello is the Overlord's activation step, not yours.

## Commits

Never name an AI product, company, model, agent, or assistant identity as a
commit co-author: not in a `Co-Authored-By` trailer, not anywhere else in a
commit message, and not in a pull request body. This is the Overlord's
standing rule, and the fleet's history must not credit an author that did not
exist.

## Delivery

kind: ship
mode: no-mistakes
