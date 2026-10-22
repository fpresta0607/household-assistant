<!-- The build plan the Overlord reviewed over four rounds and approved on 2026-09-17.
     Converted from the Lavish review artifact. This is the specification the phases implement. -->

Corey & Denise — build plan

-

-

CFO build plan · 17 September 2026

# Corey & Denise

Two household assistants on the VPS you already own, reachable from Telegram, sharing one calendar and one grocery list, keeping two private memories properly apart. They also read and write SIQsermon as you and as Gia. Revised 17 September after your review. Annotate anything you still disagree with.

## What is actually on the box

Measured read-only just now over SSH, not assumed. This is the constraint everything else has to fit inside.

### Host

- Ubuntu 26.04.1 LTS, x86_64, 6 vCPU

- 7,878 MB RAM · 5,320 MB available right now

- 232 GB disk, 7.9 GB used (4%)

- No swap configured

- Open ports: 22, 443, 80 only. ufw active.

- No Node, no Postgres, no OpenClaw installed

### SIQsermon, running

             |
 | Container | Using | Limit

 | neo4j | 959 MiB | 3,584 MiB

 | backend | 762 MiB | 1,536 MiB

 | qdrant | 99 MiB | 1,536 MiB

 | caddy | 12 MiB | 256 MiB

 | total | 1.8 GiB | 6.75 GiB

        Your ruling: OpenClaw gets the larger share. The assistants are the thing you use every day, so they get more room than SIQsermon, and SIQsermon does not grow beyond what it has. Practically that means trimming reservations rather than buying a bigger box: SIQsermon's limits reserve 6.75 of 7.7 GiB while using 1.8 GiB, so Neo4j's 3.5 GiB comes down toward its real working set and the freed space becomes the assistants' budget. A swap file goes in because a box with no swap kills a process outright instead of slowing down, and a verified backup goes in because resource contention is acceptable and data loss is not.

        Keep only the last two or three sermons per account, on your word. You offered to delete older SIQsermon data to keep things light. Held as an option, not done yet, and here is the honest accounting of what it buys. The heavy tenants are Neo4j, which holds the 203,648-node Bible graph rather than your sermons, and Qdrant, which holds 31,105 verse vectors. Both are Bible content, not history: pruning sermons barely touches them. Your twelve sermons, five projects and forty-one messages live in a SQLite file measured in megabytes. So retention would free very little memory and would permanently lose the preaching history the app uses to vary illustrations and build on past series. My recommendation is not to prune. If the box gets tight, trimming Neo4j's reservation frees gigabytes and costs nothing. Say the word and I will still do it.

## The shape

Franco ──┐                        ┌── Corey  (bot identity)
         ├── Telegram ── gateway ─┤
Gia ─────┘                        └── Denise (bot identity)
                                        │
                         ┌──────────────┴───────────────┐
                         │  household service (one API) │
                         │  identity · scopes · approval │
                         └──┬────────┬────────┬──────────┘
                            │        │        │
                       memory   reminders   lists      calendars ── Google API
                       (3 scopes) (durable   (shared)   Gmail    ── iCloud CalDAV
                                   worker)                       ── read-only adapter
                            │
                       SQLite (WAL) — one datastore, one worker
                            │
              SIQsermon backend  ── read AND write, first class
              (franco / gia accounts already exist there)
              keeps its OWN preaching memory — never merged

### One gateway, two faces

OpenClaw runs once, centrally administered by you. Corey and Denise are two bot identities on it, not two installations. Gia never touches a server, an env file, or a console.

### The sender decides "my"

Identity comes from authenticated Telegram metadata, never from text. Gia asking Corey a question gets Gia's context wearing Corey's voice. It cannot reach into your private memory, because the split happens before the prompt is assembled.

### SQLite, not a stack

OpenClaw's own default is SQLite, and there is no Postgres on the box to reuse. SQLite with write-ahead logging, one worker, real migrations. No Redis, no vector database, no broker, no plugin engines.

## Accounts: several per person, mixed providers

Your review corrected the original brief, which assumed one Gmail each. You actually have two Gmail accounts and at least one Outlook account to monitor, and that Outlook carries a calendar too. That is not a detail; it changes the data model, so it is stated here rather than discovered in Phase 4.

### The model

person (franco, gia)
  └── account  (many per person)
        ├─ provider   google | microsoft | apple
        ├─ address    the real mailbox
        ├─ mail       monitored? digest? drafts?
        └─ calendars  (many per account)
              ├─ counts toward availability?
              ├─ writable?
              └─ last successful sync

An account belongs to exactly one person. Nothing is shared between you and Gia by accident, and each account is authorized by its own owner.

### What this forces

- Microsoft Graph becomes first class, not an afterthought, for both your Outlook mail and its calendar. Google API for the two Gmail accounts. iCloud CalDAV only if a calendar on the phone turns out to be genuinely iCloud-backed.

- Availability is a union across every account you mark as counting. One busy hour in the Outlook calendar makes you busy, even if Gmail looks clear.

- The same event can appear twice. A meeting invited to two of your addresses is one commitment, not two. Deduplicate by provider identity, never by matching title and time, because two real events can share both.

- Per-account switches. Each account says whether it is monitored for mail, whether it contributes to availability, and whether anything may be written to it. A work mailbox you only want read is a setting, not a fork in the code.

I need the actual inventory from you. Which two Gmail addresses, which Outlook address, whether that Outlook is a personal account or a work tenant (a work tenant may have an administrator who must approve the app), and which of Gia's accounts matter. Write them on this page or tell me in chat and I will fold them into the activation checklist. Until then the plan carries the shape but not the values.

## Build order

A working vertical slice before any optional feature. Each phase is one goblin, one branch, one pull request, verified before the next starts. Nothing in an earlier phase depends on a credential from a later one.

       |
 | # | Phase | What proves it works | Needs from you

           | 0
           | Make room, assistants firsttrim SIQsermon reservations, add swap, back up, restore rehearsal, prebuilt image
           | Assistants hold the larger budget; SIQsermon still healthy; a backup opens in a scratch location
           | nothing

           | 1
           | Identity and privacy spinepeople, personas, scopes, approval, tool contracts, mock providers
           | Leak tests fail closed: cross-person, private-to-group, native tool bypass, delegation
           | nothing

           | 2
           | Telegram, lists, remindersthe first genuinely useful slice
           | Both of you message both bots; one shared list; a reminder survives a restart and a model outage
           | 2 bot tokens; both of you say hello

           | 3
           | Calendars, every accountGoogle API, Microsoft Graph, iCloud CalDAV where real; union availability with dedup
           | iPhone-made event visible to the assistant; assistant event appears on both phones; an event invited to two of your addresses counts once
           | one authorization per account

           | 4
           | Mail, read-only firsttwo Gmail plus Outlook, separate grants, one digest per person
           | Every inbox refreshes independently and survives one being revoked; injection tests cannot trigger a send or a cross-account read
           | each account authorized by its owner

           | 5
           | Proactive planningdaily brief, weekend look-ahead, approvals
           | One proposal, two approvals, one event, revalidated before the write
           | agree the schedule and quiet hours

           | 6
           | SIQsermon adapternon-blocking, off by default
           | Bible lookup works; no household data touches the public app's path
           | nothing

           | 7
           | iMessageoptional, your Mac, only when you ask
           | Reported separately; its absence never fails the Linux release
           | explicit go-ahead

## Decisions I am making, and why

### SQLite, and OpenClaw agrees

You asked what OpenClaw itself recommends. I read their memory documentation rather than guessing: SQLite is their default storage backend, described as working out of the box with keyword search, vector similarity and hybrid search. Memory itself lives as Markdown in the agent workspace and SQLite indexes it for retrieval. Postgres is not their recommendation. They do support pluggable engines, Honcho for cross-session memory and LanceDB for embeddings, both as separate plugin installs, and neither earns its keep for two people on a box with this much memory left.

So the two align: OpenClaw's own memory stays on its SQLite default, and the household service keeps its scoped records, reminders and lists in its own SQLite database with write-ahead logging, foreign keys and migrations. Two files, one backup job, no server process, no Postgres added to the box.

Source: docs.openclaw.ai/concepts/memory, read 17 September 2026. Reverify at implementation time; their schema and defaults can move.

### Long polling, no new public port

Telegram is reached outbound. Nothing new is exposed, ufw stays as it is, and Caddy keeps 80 and 443 for SIQsermon alone. Admin interfaces bind to loopback.

### Apple Calendar stays your interface

We do not migrate anything to Google. We discover which provider actually backs each calendar you see on the phone, and talk to that provider. A read-only subscription gets marked read-only rather than pretended into a two-way sync.

### Reminders are code, not conversation

The model interprets "remind me Thursday" once. After that a plain worker delivers it. If the model is rate limited or the server restarts, your reminders still fire. That is the single most important reliability property here.

### What people actually run, and what it says for us

You asked what the community recommends. The consistent advice: keep the built-in SQLite backend until recall quality is proven to be the bottleneck, and only then reach for a plugin. LanceDB is the usual next step for large stores with auto-recall and auto-capture; Honcho is about user modelling rather than general memory, so it answers a different question. There is an open proposal for a dual SQLite-plus-LanceDB design with importance scoring and time decay, aimed at assistants with months of accumulated history. None of that is a two-person household on day one.

The operational advice is more useful to us: pin an exact version rather than latest, mount the state directory, bind ports to loopback only, set explicit memory and CPU limits, and expect roughly 1 to 2 cores and 1 to 2 GB for a healthy install. One warning matches our box exactly: building the image locally needs about 2 GB and the kernel kills it otherwise, so we use the prebuilt image.

Sources read 17 September 2026: betterclaw.io memory-plugin comparison, lancedb.com OpenClaw memory post, openclaw issue 65679, learnopenclaw.com deployment, qubittool.com Docker guide. Community posts, not vendor documentation; treat as direction, verify at build time.

### Two memories, kept apart on purpose

Your ruling: the household assistants do not adopt SIQsermon's memory. SIQsermon keeps its own preaching memory, the graph that lets it vary illustrations and build on past series, because that memory serves sermon work and nothing else. The assistants keep their own three scopes for household life. Corey can read and write your study data in the app, and can say "you preached on patience in August" by asking the app, but the app's memory never merges into household memory and household memory never leaks into sermon prompts. One system, two memories, each where it belongs.

### The assistants get real access to SIQsermon

Not a narrow read-only lookup. Corey and Denise read and write its backend: your projects, conversations, study plans, sermons and the preaching-memory graph. The fit is already there, because the app has exactly two accounts, franco and gia, so each assistant acts as its own person rather than as a shared service identity. The one line that stays drawn is the app's public users: they never see household data, and household mail and credentials never enter the app's data path.

### Model routing

The deployed gateways follow the owner-approved policy in [The model backend](../deploy/openclaw.md#the-model-backend).
Phases 0 through 2 of the household service are built and tested against mock providers.

## What only you can do

Collected in one place so you do it once, not in six interruptions. Nothing here blocks Phase 0 or 1.

       |
 | Needed | Where | Blocks

 | Two Telegram bots created, display names Corey and Denise | BotFather | Phase 2

 | Both of you open a private chat with the relevant bot | Telegram | Phase 2

 | One household group containing you, Gia, and both bots | Telegram | Phase 2

 | Calendar authorization, each person for their own accounts | Google consent · Apple app-specific password | Phase 3

 | Mail authorization, once per monitored mailbox | Google consent · Microsoft consent | Phase 4

 | Project-scoped, funded model key | [runtime activation](../deploy/openclaw.md#what-only-the-overlord-can-finish) | gateway model calls

 | Agreement on quiet hours and how much initiative is welcome | the two of you | Phase 5

Tokens and passwords never come through chat. Each gets stored in the credential store directly, the same way the SIQsermon secrets are held now.

## What this will not do

Gateway routing and fallbacks follow [The model backend](../deploy/openclaw.md#the-model-backend).
If the model backend is unavailable, model work pauses visibly and reminders keep firing.
Nothing buys API credit, a hosted database, a search service or a relay on its own.

No autonomous sending or spending. Drafts, not sent mail. Proposals, not bookings. No reservations, no purchases, no inviting third parties.

No pretending about isolation. You administer the server, so you can read everything on it. The boundary here keeps the assistants from crossing between your context and Gia's; it is not hardened multi-tenancy and will never be described as such.

No touching SIQsermon's trust boundary. Its public users never reach your household data, and your household data never enters its public path. The adapter ships disabled if its code cannot be inspected safely.

## The four things most likely to go wrong

-

        1. Memory pressure with no swap kills something at random. You accepted that SIQsermon may lose; the danger is the kernel choosing for us mid-write. A swap file and sane limits in Phase 0 make the outcome deliberate rather than arbitrary, and a verified backup means the worst case costs a restart, not your sermon history.

-

        2. A calendar read fails and the assistant calls you free. Silence is never treated as availability. An incomplete or stale read reports uncertainty with the last successful sync time, and availability is rechecked immediately before any event is created.

-

        3. An email tells the assistant what to do. Every message body, attachment and calendar description is treated as data, never instruction. The summarizing path has no shell, no secrets, no outbound mail and no access to the other person's data, and adversarial tests ship with it.

-

        4. Google's test-mode grants expire after seven days. That turns a working demo into a dead integration a week later. The publishing requirement gets handled up front rather than discovered, and the status is reported honestly if it is not.

How to respond: annotate anything here directly, or queue a prompt. Tell me to change the phase order, cut something, or push back on a decision. Nothing is dispatched until you say go, and when you do, Phase 0 and Phase 1 start immediately because neither needs anything from you.
