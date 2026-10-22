# household-assistant

The household assistant for Corey and Denise.
It shares an IONOS VPS with SIQsermon.

## Phase 0 - headroom

Phase 0 installs no assistant code.
It makes room on the shared box and proves SIQsermon's data is recoverable first.

- [docs/phase0/runbook.md](docs/phase0/runbook.md) - what was done, what was verified, and how to undo it
- [docs/phase0/measurements.md](docs/phase0/measurements.md) - how the limits were arrived at
- [docs/phase0/budget.md](docs/phase0/budget.md) - how much of the box the assistant gets

## The OpenClaw runtime

The host and container layer the assistants run inside.
The Phase 1 household service below defines authenticated identity and scopes.
The deployed gateways use their own integrations under the [family-group policy](docs/deploy/openclaw.md#the-family-group).

- [docs/deploy/openclaw.md](docs/deploy/openclaw.md) - how to reach it, restart it, back it up and roll it back, why its heartbeat is off so neither assistant messages anyone unasked, why everything runs on OpenRouter, who can reach each assistant in the family group, how every voice note reaches them and how they see each other there, and what only the Overlord can finish
- [scripts/openclaw-family-group.py](scripts/openclaw-family-group.py) - what each gateway does with a message or a voice note in the family group, and the one entry that makes the two the same
- [scripts/openclaw-openrouter.py](scripts/openclaw-openrouter.py) - audits and applies the routes in [The model backend](docs/deploy/openclaw.md#the-model-backend) on both gateways
- [scripts/openclaw-speech.py](scripts/openclaw-speech.py) - audits and applies how a spoken reply is made on both gateways, see [Speaking](docs/deploy/openclaw.md#speaking)
- [deploy/openclaw/plugins/household-family-room/](deploy/openclaw/plugins/household-family-room) - the OpenClaw plugin that gives each assistant what it cannot see or hear of the family group: voice notes that did not name it, what photos and videos there showed, and the other assistant's posts
- [deploy/openclaw/plugins/household-openrouter-video/](deploy/openclaw/plugins/household-openrouter-video) - the OpenClaw plugin that describes a video someone sends either assistant through OpenRouter, which OpenClaw's own OpenRouter provider cannot
- [deploy/openclaw/plugins/household-speech/](deploy/openclaw/plugins/household-speech) - the OpenClaw plugin that speaks a reply as numbered voice notes, each made and sent once, under a ceiling for one reply and for one day
- [deploy/openclaw/plugins/household-app/](deploy/openclaw/plugins/household-app) - the Steward AI app as its own OpenClaw channel: the family room both people and both assistants share, and each person's thread with their assistant, carried between the gateways by [scripts/household-app-relay.py](scripts/household-app-relay.py); see [The household app's family room](docs/deploy/openclaw.md#the-household-apps-family-room)

The scripts in [scripts/](scripts) are the executable form of both runbooks.
They run as root on the box.

PocketPiggies connects through a private Telegram consent button and a host key holder that answers MCP over a Unix socket: [installation and verification](docs/deploy/pocket-piggies.md).
Only Corey reads Franco's account and only Denise reads Gia's, read-only, after the corresponding owner's consent.
Each owner's private chat keeps every tool; the credential stays in the key holder, and the family group runs without tools that could reach it.

## Phase 1 - identity and privacy spine

Phase 1 is the spine every later phase hangs from: who is speaking, what they may see, what a tool may do on their behalf, and how an approval is bound.
It runs locally against mocked providers, and it needs no credential from anyone.

People are `franco` and `gia`.
Bot personas are `corey` and `denise`.
These are four separate identities: a human is never a persona, and a persona is never a channel.
The authenticated sender decides what "my" means, so Gia addressing Corey gets Gia's authorized context wearing Corey's voice and cannot reach Franco's private context.

- [household/identity.py](household/identity.py) - people, personas, enrollment, routes, and the signed identity envelope
- [household/service.py](household/service.py) - the one authenticated API over memory, tasks, reminders, lists, calendars, mail, approvals and integration health
- [household/tools.py](household/tools.py) - the typed tool contracts, and the only tool names the service will dispatch
- [household/approvals.py](household/approvals.py) - an approval bound to one action version, actor, route, destination and expiry
- [household/store.py](household/store.py) and [household/migrations/](household/migrations) - the scoped SQLite datastore
- [tests/test_leaks.py](tests/test_leaks.py) - the leak tests, each written so the permissive behaviour fails it

Run the checks:

```
python -m venv .venv
.venv/Scripts/python.exe -m pip install -e ".[dev]"
.venv/Scripts/python.exe -m ruff format --check .
.venv/Scripts/python.exe -m ruff check .
.venv/Scripts/python.exe -m mypy
.venv/Scripts/python.exe -m pytest
```

### What a later phase must not undo

These guarantees apply to the Phase 1 household service.
The deployed OpenClaw gateways follow the owner-authorized exception described in [The family group](docs/deploy/openclaw.md#the-family-group).

- Identity is resolved from authenticated channel metadata only, and the default is to refuse.
  A display name, a message body, a forwarded header and a model-supplied id are all ignored on purpose.
- The memory scopes are split into the identity envelope before anything is retrieved, not by asking a model to keep a secret.
  A group route never carries a private scope, for anyone.
  A direct route has exactly one member, so the private scope it carries is read by that person alone.
- A group route also never carries a capability that reaches one person's mail, calendars, account addresses or approvals.
  Both people read the household group, so those tools answer only in the conversation the account's owner is alone in.
- The actor and the scopes come from the envelope.
  A tool argument that names a person or a scope set is refused, and no tool contract may declare one.
- Delegation narrows an envelope and never widens it.
  The actor, the persona, the route and the expiry are carried through untouched, so a sub-task cannot escalate the person it acts for.
- Calendar windows and reminder times are compared as timezone-aware instants, never as text.
  A naive timestamp is refused at the tool boundary, and a reminder's due time is stored in UTC.
- An approval binds to an action version, an actor, a route, a destination and an expiry, and it is spent once.
  A message body is data: nothing reads one for an instruction, an approval or an identity.
- Granting an approval is not a tool.
  A yes arrives as an authenticated message through `Gateway.approve`, so the loop that proposes a write cannot mint the yes that spends it.
- Every provider entry point takes an account grant rather than a bare account id.
  In Phase 1 that grant is an in-process convention the service mints after checking ownership, not a verified token.
  It must be signed and verified before Phase 3 gives a provider a real credential.
- Storage is SQLite with write-ahead logging, foreign keys, forward-only migrations and one controlled writer.

### The memory budget still binds

[docs/phase0/budget.md](docs/phase0/budget.md) owns the shared assistant allowance and links to the current allocation.
Every container any later phase adds must declare `deploy.resources.limits.memory`.
Without one, a runaway assistant exhausts the box and the kernel's OOM killer chooses globally by resident size, which means it kills SIQsermon's Neo4j rather than the assistant.

## The group surface - Corey and Denise coordinating

Telegram never delivers one bot's messages to another, so the two assistants reach each other through a relay on the host rather than through the group itself.
Every word one says to the other is posted in the family group first, verbatim, so there is no channel Franco and Gia cannot read.
The relay is a `systemd` timer outside both containers, which is where the turn cap, the stop word and the off switch live.

- [docs/plan/coordination-between-assistants.md](docs/plan/coordination-between-assistants.md) - the design, the rules it enforces, what the planner may propose from, and the emergency control that does not go through Telegram
- [docs/deploy/openclaw.md](docs/deploy/openclaw.md) - how to install it, where its state lives, the `!coordination off` switch, and the household clock

The code those documents describe:

- [household/coordination.py](household/coordination.py) - the turn, the two-message cap, the stop word and the off switch
- [household/openclaw.py](household/openclaw.py) - the only two sinks a crossing has: the family group, and the peer's gateway
- [household/family_room.py](household/family_room.py) - each assistant's own posts in the group, handed to the other as context, and nothing that was not posted there
- [household/planner.py](household/planner.py) - the proactive date planner over the shared calendar, its two taste inputs and its research budget
- [scripts/coordination-daemon.py](scripts/coordination-daemon.py) - the `tick` and `plan` runs the timers in [deploy/coordination/](deploy/coordination) call
- [deploy/openclaw/skills/coordinate/](deploy/openclaw/skills/coordinate) - the skill both assistants get, and the four results it can print

## The iPhone app - built on GitHub's Macs

There is no Mac of our own.
The owner chose GitHub's hosted Macs on 14 October 2026, with a cap of 5 dollars a day, so the iOS app is built, tested, signed and sent to TestFlight on a Mac GitHub lends for one job and wipes afterwards.
Every Mac run is started by hand, stops at a timeout, and reports what it cost.
Memory, reminders, calendar state, lists, authentication and assistant logic stay on the VPS, behind the Phase 1 spine above.

- [docs/apple-activation-checklist.md](docs/apple-activation-checklist.md) - **start here**: everything only the owner can do, in order, from Windows
- [docs/testflight.md](docs/testflight.md) - the one click to TestFlight, the secrets, and what each run costs
- [docs/apple-signing.md](docs/apple-signing.md) - team, identifiers, capabilities, the certificate and the profiles
- [docs/voicebox.md](docs/voicebox.md) - the local speech service, which waits for a Mac

The code those documents describe:

- [apps/ios/](apps/ios) - the Steward AI app: a native OpenClaw gateway client, as a text XcodeGen spec
- [scripts/ios-cloud.py](scripts/ios-cloud.py) - one command from any computer: a preview, a rehearsal or a TestFlight build, and its cost
- [scripts/macos/](scripts/macos) - the scripts GitHub's Mac runs, and Voicebox's
- [services/voicebox/](services/voicebox) - the speech service itself
