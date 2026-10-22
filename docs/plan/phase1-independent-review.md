# Review: PR 2 `feat/phase1-identity` (household-assistant Phase 1)

Reviewed: 17 September 2026.
Repository: `fpresta0607/household-assistant`.
Head SHA at start of review: `5e5ff23b960337c9a52c356dd77aee6101d05dcc`.
Head SHA at end of review: `5e5ff23b960337c9a52c356dd77aee6101d05dcc` (unchanged; no findings needed re-checking against a new head).
Mode: read-only.
Nothing was edited, committed or pushed in the authoring worktree.
Execution evidence comes from a throwaway clone at the head SHA under my scratchpad directory.

## Verdict

**Merge after named fixes.**
The isolation spine is real, not apparent: cross-person, private-to-group and impersonation guards were each removed in a throwaway clone and the leak tests went red every time (13, 5, 1 and 1 failures respectively), the envelope is HMAC-signed over every field, approvals bind to actor, route, action fingerprint and expiry and are spent once, no secret or real address is committed, no provider scope string exists yet, and CI genuinely ran ruff, mypy strict and 97 tests on the PR event.
The account model holds several accounts per person across Google, Microsoft and Apple with per-account mail switches and per-calendar availability and writable switches, and the fixtures exercise exactly the two-Gmail-plus-Outlook shape the Overlord required, so there is no data-model blocker.
Three majors stand between this and a clean inheritance by later phases: timestamp arguments are accepted as arbitrary strings and ordered lexically (a reminder due at 10:00 in a +02:00 offset is not returned as due until two hours late), the calendar write holds the process-wide database lock and an open transaction across the provider call (Gia's identity resolution measurably waited behind Franco's provider write), and the account grant that the PR says only the service can mint is an unsigned dataclass anyone in-process can construct.
Fix F1 before Phase 2 stores any reminder; resolve F2 and F3 before Phase 3 attaches a real provider, and correct the F3 claim in the docstring and README now so nobody builds on it.
No blockers.

## Findings

### F1 - Major - Timestamp tool arguments are unvalidated strings, stored verbatim and compared lexically

Files: `household/tools.py:73-78`, `household/tools.py:103-107`, `household/tools.py:239-242`, `household/store.py:223-229`, `household/service.py:384`, `household/providers.py:84`.

Claim: every `due_at`, `start` and `end` a model supplies is accepted as any string, persisted as-is, and then ordered or deduplicated by string comparison, so any non-UTC offset, or any non-timestamp, silently breaks reminder delivery and availability.

Evidence read:

```python
# tools.py:73-78
class ReminderCreateArgs(ToolParams):
    text: str
    due_at: str
    scope: str

# tools.py:239-242
    if annotation is str:
        if not isinstance(value, str):
            raise ArgumentInvalid(f"{spec_name}.{name} must be a string")
        return value

# store.py:223-229
    rows = cx.execute(
        "SELECT id, scope, text, due_at, delivered_at, author_person_id, created_at "
        f"FROM reminder WHERE scope IN ({_placeholders(scope_list)}) "
        "AND (? IS NULL OR due_at <= ?) "
        "ORDER BY due_at, rowid",
        (*scope_list, due_before, due_before),
    ).fetchall()

# service.py:384
                key = (event.uid, event.start, event.end)

# providers.py:84
        return [event for event in stored if event.start < end and event.end > start]
```

Failure scenario, reproduced by execution against the head SHA:

| Input | Result |
| --- | --- |
| `reminder_create` with `due_at="2026-09-18T10:00:00+02:00"` (08:00 UTC), then `reminder_list` with `due_before="2026-09-18T08:30:00+00:00"` | returned `[]`; the reminder is 30 minutes overdue and not due |
| event `09:00-10:00+02:00` (07:00-08:00 UTC), `calendar_availability` window `07:30-07:45+00:00` | `busy=[]`, `complete=True`; the mock reports free while busy |
| same uid, same instant, spelled `17:00:00+00:00` and `19:00:00+02:00` on two accounts | two busy intervals, not one; the plan's "one commitment, not two" dedup fails across providers |
| `reminder_create` with `due_at="tomorrow-ish"` | accepted and stored |

The plan calls reminder delivery "the single most important reliability property here".
The Phase 2 worker will select due reminders with exactly the `due_at <= ?` comparison at `store.py:226`.
Row 2 is the mock's own filter and real providers filter server-side, but rows 1, 3 and 4 are product code that Phases 2 and 3 inherit.

Fix: in `parse_arguments`, give timestamp fields a distinct type (a `NewType` or an annotated marker) that `_coerce` parses with `datetime.fromisoformat`, rejects when `tzinfo` is None, and normalizes to UTC `isoformat()` before the value reaches the store, the dedup key, or a provider.
Add one test per contract with a non-UTC offset.

### F2 - Major - The calendar write runs inside the open write transaction and under the process-wide lock

Files: `household/service.py:440-463`, `household/db.py:38-47`.

Claim: `_calendar_event_create` calls the provider while holding `Database.write()`, so every other database user in the process, including identity resolution for the other person's messages, blocks for the full duration of the provider call, and a provider success followed by a commit failure leaves the approval granted with the event already created.

Evidence read:

```python
# service.py:445-463
        grant, _ = self._writable_calendar(envelope, params.calendar_id)
        resource = {"title": params.title, "start": params.start, "end": params.end}
        with self._database.write() as cx:
            approvals.consume_approval(
                cx,
                envelope=envelope,
                approval_id=params.approval_id,
                ...
            )
            return self._providers.calendar.create_event(
                grant,
                calendar_id=params.calendar_id,
                ...
            )

# db.py:38-47
    def write(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                yield self._connection
            except BaseException:
                self._connection.execute("ROLLBACK")
                raise
            self._connection.execute("COMMIT")
```

`db.py:26-28` states that readers take the same lock as the writer, so `IdentityResolver.resolve` (`identity.py:247`) and every read in the service queue behind it.

Failure scenario, reproduced by execution: with the mock's `create_event` delayed 2.0 seconds in one thread, Gia's `resolver.resolve` plus `memory_search` in another thread waited 1.80 seconds.
In Phase 3 the same code path calls Microsoft Graph or Google; a 30 second HTTP timeout, or a hung socket with no timeout, stalls the Telegram poller, the reminder worker and the sync worker for that long, and the plan places all three in this one process on one database.
Second order: if the provider returns success and `COMMIT` then raises, the transaction rolls back to `granted` while the remote event exists; a retry consumes the approval again and books it twice.

Fix: never hold `Database.write()` across provider I/O.
Consume the approval in its own transaction (or move it to an `executing` state), call the provider with no lock held, then record the provider uid in a second transaction.
On provider failure leave the approval consumed so a fresh proposal is required, which is the fail-closed direction the plan wants.

### F3 - Major - `AccountGrant` is an unsigned dataclass; "only the service can mint" is documentation, not enforcement

Files: `household/providers.py:5-7`, `household/providers.py:18-24`, `household/providers.py:83`, `household/providers.py:119-120`, `README.md` ("Every provider entry point takes an account grant the service mints, never a bare account id."), `tests/test_leaks.py:295-299`, `tests/test_leaks.py:314-316`, `tests/test_leaks.py:350-354`.

Claim: providers trust `grant.account_id` blindly, and nothing ties a grant to the envelope, the actor, or the issuer, so the boundary the PR describes at the provider layer does not exist; the only real boundary is the service registry one layer up.

Evidence read:

```python
# providers.py:5-7
provider here takes a bare account id. It takes an :class:`AccountGrant`, which only
the household service can mint, and only for an account the envelope's actor owns.

# providers.py:18-24
@dataclass(frozen=True, slots=True)
class AccountGrant:
    """Proof that an authenticated actor owns this account. Minted by the service only."""
    account_id: str
    person_id: str
    envelope_id: str

# providers.py:119-120
    def inbox(self, grant: AccountGrant, *, limit: int) -> list[ProviderMailMessage]:
        return self._inboxes.get(grant.account_id, [])[:limit]

# tests/test_leaks.py:314-316 (the leak test itself mints a grant outside the service)
    gia_grant = AccountGrant(
        account_id=GIA_GMAIL, person_id="gia", envelope_id=franco.envelope_id
    )
```

Failure scenario, reproduced by execution: `AccountGrant(account_id=GIA_GMAIL, person_id="franco", envelope_id=<franco's envelope>)` passed to `providers.mail.inbox` returned Gia's message `Gia private result`.
The same reach through `service.call(franco, "mail_draft", {"account_id": GIA_GMAIL, ...})` was refused with `NotAuthorized`, which is the refutation I tried: today the only product-code minter is `HouseholdService._grant_for_account` (`service.py:203-222`) and a model cannot construct Python objects, so this is not exploitable from the tool surface at this head.
It becomes load-bearing in Phase 3 and 4, when providers hold per-account tokens keyed by `account_id`, and in Phase 2, when a sync worker with no envelope has to mint grants itself; from then on anything that can build the dataclass can read any mailbox.

Fix: either sign the grant (HMAC through `EnvelopeIssuer` over `account_id`, `person_id`, `envelope_id` and an expiry) and verify it at every provider entry point, or state plainly that providers are an in-process convention and remove the "only the service can mint" claim from `providers.py`, the README and the PR description.
Decide before Phase 3 lands a real token.
Correct the wording now.

### F4 - Minor - The "native tool bypass" leak class is only partially provable here, and its tests pin the mock's keying

Files: `tests/test_leaks.py:265-269`, `tests/test_leaks.py:300-305`, `tests/test_leaks.py:317-325`, `tests/test_leaks.py:355-357`.

Claim: the tests under "a native tool bypassing a scoped one" prove that the household registry has no native tool and that the mock keys storage by account, not that a model driving OpenClaw cannot reach around the scoped tools, because OpenClaw's native tool surface and its own memory index are not in this repository.

Evidence read:

```python
# tests/test_leaks.py:265-269
def test_there_is_no_unscoped_tool_to_fall_back_to(household: Household) -> None:
    franco = franco_envelope(household)
    for native in ("sql_query", "shell", "memory_search_all", "read_file"):
        with pytest.raises(ToolUnknown):
            household.service.call(franco, native, {})

    # tests/test_leaks.py:300-305
    assert (
        household.providers.calendar.events(
            franco_grant, calendar_id=CAL_GIA, start="2026-09-18", end="2026-09-19"
        )
        == []
    )
```

Refutation attempted: mutating `providers.py:83` to ignore `grant.account_id` made `test_a_calendar_grant_only_ever_reaches_the_account_it_names` fail, so the test is not vacuous; it detects a regression in the mock's dictionary lookup.
It is partial: the protection the acceptance criterion names lives in Phase 2's OpenClaw tool allowlist, which does not exist yet.

Failure scenario: Phase 2 wires the bots to OpenClaw with its default tool set enabled; the model uses OpenClaw's own file or shell tool to read the SQLite file directly; every test in this section still passes.

Fix: nothing to change in this PR.
Record that the native-bypass criterion is deferred to Phase 2, and add there a test that each bot's tool set is exactly the 17 registered names and that OpenClaw's native tools are disabled for both bots.

### F5 - Minor - `Database.write()` commits outside the try and rolls back unconditionally

File: `household/db.py:38-47`.

Claim: a write that SQLite auto-rolls back (documented for `SQLITE_FULL`, `SQLITE_IOERR`, `SQLITE_NOMEM`, `SQLITE_BUSY`, `SQLITE_INTERRUPT`) makes the handler's explicit `ROLLBACK` raise `cannot rollback - no transaction is active`, replacing the real error; and a `COMMIT` that raises leaves the connection inside a transaction, so every later `BEGIN IMMEDIATE` fails until the process restarts.

Evidence read: quoted under F2 above (`db.py:38-47`); `COMMIT` on line 47 is after the `try` block, and `ROLLBACK` on line 45 has no `in_transaction` guard.

Failure scenario: the disk fills during an `INSERT INTO memory` on the shared box; the operator sees "cannot rollback" rather than "database or disk is full".
I did not reproduce a failing `COMMIT`; the auto-rollback behaviour is SQLite documentation, so treat the masking half as likely and the stuck-connection half as uncertain.

Fix: guard `ROLLBACK` with `if self._connection.in_transaction`, and move `COMMIT` inside the `try` so a failed commit also rolls back and re-raises.

## Lens 1 - Plan fidelity

Present and matching the plan: two people and two personas seeded as four distinct identities (`identity.py:305-315`), fail-closed enrollment and route approval (`identity.py:246-283`), three memory scopes enforced by `CHECK` constraints in `0002_household.sql`, a signed envelope minted before any retrieval, 17 typed tool contracts with a reserved-argument list, approvals bound to action version, actor, route, destination and expiry, and mock calendar, mail and messaging providers.
Nothing is stubbed; there is no `TODO`, `NotImplementedError` or placeholder.
Four `ponytail:` markers name deliberate ceilings: process-scoped signing secret (`identity.py:144`), readers sharing the writer lock (`db.py:26`), the caller naming the tool while the model is mocked (`gateway.py:38`), and a DDL-only migration splitter (`db.py:96`).

Account data model: `account` (`0001_identity.sql:35-45`) holds `person_id`, `provider CHECK IN ('google','microsoft','apple')`, `address`, `mail_monitored`, `mail_digest`, `mail_writable`, `mail_last_sync_at`, with `UNIQUE (provider, address)`; `calendar` (`0001_identity.sql:47-55`) holds `account_id`, `counts_toward_availability`, `writable`, `last_sync_at`.
That carries several accounts per person across mixed providers with the per-account and per-calendar switches the plan diagrams.
`tests/conftest.py:132-211` builds Franco with two Google accounts and one Microsoft account carrying a calendar, and `test_the_digest_covers_every_monitored_account_of_the_actor` and `test_availability_is_a_union_across_every_counting_account` span all three.
Not a blocker.
Phases 3 and 4 will need to add a credential reference per account and the provider's own calendar id per calendar; forward-only migrations allow that.
Phase 5's "two approvals, one event" is not representable yet (one actor per approval); that is Phase 5's extension, not a Phase 1 gap.

Present but nominally later-phase: union availability with dedup (Phase 3), mail digest and draft (Phase 4), and the calendar write path (Phase 3 and 5) are implemented as thin handlers over the mocks.
They fit "tool contracts, mock providers" and are what the leak tests exercise, so I do not count them as scope creep.

## Lens 2 - Do the leak tests prove isolation

| Leak class | Tests | Mutation applied in throwaway clone | Result |
| --- | --- | --- | --- |
| Cross-person | `test_leaks.py:66-148` (5 tests), with a positive control that Franco finds his own record at lines 75-77 and 208-212 | `search_memory` scope filter removed (`store.py:120-123`) | 5 tests red |
| Cross-person write | `test_a_person_cannot_write_into_the_other_persons_scope` | `_require_scope` removed from `_memory_write` (`service.py:245`) | 1 test red |
| Private to group | `test_leaks.py:154-259` (6 tests), positive controls at 175-177, 208-212, 249-251 | group routes given every scope and capability (`identity.py:288-292`) | 13 tests red across `test_leaks`, `test_identity`, `test_approvals` |
| Native tool bypass | `test_leaks.py:265-357` (4 tests) | mock calendar keyed by calendar only (`providers.py:83`) | 1 test red; partial, see F4 |
| Delegation and impersonation | `test_leaks.py:363-464`: unknown sender, unapproved route, other person's direct route, forwarded header plus display name plus claimed id, six reserved argument names, tampered envelope | covered by the group mutation (forwarded-message test went red) and by signature verification at `identity.py:213-216` | non-vacuous |
| Approval route binding | `test_a_generic_yes_in_the_wrong_chat_cannot_grant_it` | route check removed from `_require_binding` (`approvals.py:148-151`) | 1 test red |

Shapes hunted and not found: no assertion runs against an empty fixture (every `== []` for the other person sits next to a `!= []` or exact-match control for the owner); the store's empty-scope early returns (`store.py:115`, `161`, `220`, `280`) are unreachable from the resolver, which always adds `household_shared`; every refusal is raised before the query or insert (`_require_scope` at `service.py:245`, `269`, `296`, `320`, `336`; ownership joins at `store.py:401-462`); `_approval_status` loads the record before the actor check (`service.py:533-535`) but never returns it, so nothing crosses to the caller.
All 97 tests pass at the head SHA in my clone and in CI.

## Lens 3 - Security and credentials

Secrets: none committed.
Scan of the full tree for key, token, password, private-key, cloud-key and bearer patterns found only the test fixture secrets `b"test-secret"` (`conftest.py:75`) and `b"someone-elses-secret"` (`test_identity.py:90`), which are test-only inputs to the HMAC issuer, and every address is under `example.com` or `example-outlook.com`.
GitGuardian's check on the PR is green.
`.gitignore` excludes `*.db`, `*.db-wal`, `*.db-shm` and `.venv/`.

Provider scope strings: none exist in Phase 1; nothing asks for mail write, send or delete, and the mail provider exposes `inbox` and `draft` only (`providers.py:119-138`).

Approval binding, each checked at `approvals.py:135-207`: not replayable (`consume_approval` requires `state == granted` and the update is guarded with `AND state = ?`, `approvals.py:191-206`; `grant_approval` requires `pending`, line 165); not transferable to another action (the fingerprint is recomputed from the write's arguments at consume time, lines 193-202, and covers tool, actor, destination, title, start, end); not satisfiable by the wrong person (actor check, lines 143-147, and `Gateway.approve` resolves the sender from channel metadata, `gateway.py:44-51`); not satisfiable from the group (`APPROVAL_GRANT` is excluded from group capabilities, `identity.py:70-81`, checked at `service.py:517`); does not outlive a change to the calendar (`_writable_calendar` re-checks ownership and `writable` immediately before the write, `service.py:445`); expires at grant and at consume (line 152).
Granting is not a tool (`tools.py:151-169` has no `approval_grant`; `test_no_tool_can_grant_an_approval`).

Identity from arguments: `RESERVED_ARGUMENT_NAMES` is refused before the tool is even looked up (`service.py:128-133`), and the registry builder rejects any contract declaring one (`tools.py:172-183`).
The envelope is HMAC-SHA256 over every field with `hmac.compare_digest` (`identity.py:198-216`); `test_every_signed_field_is_covered_by_the_signature` tampers each field.

Injection surface: provider content reaches the caller only as `MailSummary.preview = body[:120]` (`service.py:490`); no code reads a body for an instruction, approval or identity, and `test_an_email_cannot_authorize_anything` pins that.
The real adversarial surface is the model in Phase 2 and Phase 4, as the plan says.

SQL: every value is parameterized; the only interpolation is the placeholder count in `_placeholders` and the pragma name in `Database.pragma` (`db.py:51`), which only tests call and no tool argument reaches.

Error text: `ApprovalInvalid` messages carry the owning person's id and the route id (`approvals.py:144-150`); reaching them requires a valid unguessable approval id, and in a two-person household they disclose nothing new, but Phase 2 should keep refusal text out of the group route.
No logging exists in the package.

## Lens 4 - Will it run on the box

SQLite: `PRAGMA journal_mode = WAL`, `foreign_keys = ON`, `busy_timeout = 5000` set at connect (`db.py:29-31`); one connection with `check_same_thread=False` guarded by an `RLock` for reads and writes (`db.py:24-36`); every write inside `BEGIN IMMEDIATE`.
Migrations sorted by filename, recorded in `schema_migration` inside the same transaction as the DDL (`db.py:81-89`), idempotent on rerun (`test_running_migrations_again_changes_nothing`), and the splitter refuses procedural blocks.
Concurrency: writes are serialized by the lock and eight threads writing 160 rows pass; the cost is that a slow provider call under the lock blocks everything (F2).
The lock is process-local, so the "one controlled writer" promise holds only while poller, reminder worker and sync worker share one process, which the plan intends.
Two processes running `migrate` concurrently would race on `CREATE TABLE`; single process assumed.
Budget: this PR defines no container and no long-lived process, so nothing can exceed the assistant budget in `docs/phase0/budget.md`; the README records that every later container must declare `deploy.resources.limits.memory`.
Restart: approvals, routes, enrollments, accounts, memory, tasks, reminders and lists all live in the SQLite file; envelopes are 5-minute re-minted tokens and the signing secret is per process, which is fine for that lifetime; mock provider state is in-memory by design.
CI: `.github/workflows/ci.yml` runs on `pull_request` and pushes to `main`, with four separate `run:` steps (`pip install -e ".[dev]"`, `ruff check .`, `mypy`, `pytest`); each non-zero exit fails the job, pytest exits 5 on zero tests collected, and a missing binary exits 127.
The workflow fired on this PR (run 35287350351, event `pull_request`) and its log shows `All checks passed!`, `Success: no issues found in 19 source files` and `97 passed in 2.31s`, so the gate is real.
Tool versions float (`ruff>=0.6`, `mypy>=1.11`, `pytest>=8.3`), which can turn the gate red on a tool release rather than on code; an operations note, not a finding.

## Notes, not findings

- `_calendar_availability` treats a calendar as current whenever `last_sync_at` is non-null (`service.py:369-373`); a calendar that synced once days ago is not reported stale. Phase 3 owns the freshness rule the plan describes ("reports uncertainty with the last successful sync time").
- Group routes take the persona from `addressed_persona_id` (`identity.py:277-281`), which is authentic only if it means "the bot whose token received the update"; Phase 2 must wire it that way and must account for Telegram group privacy mode.
- The `MockMessagingProvider` has no destination argument by design; `test_a_reply_can_only_go_back_to_the_route_it_came_from` pins the mock, and Phase 2's Telegram sender must keep that shape.

## Method

Read every file on the branch from `origin/feat/phase1-identity` at the head SHA (25 changed files, 4186 additions) and the approved plan.
Cloned the repository at the head SHA into my scratchpad and ran `ruff check .` (clean), `mypy` strict (19 files, clean) and `pytest` (97 passed).
Wrote and ran a proof script for F1, F2 and F3 whose outputs are quoted above.
Ran five mutations (group permissive, scope filter removed, write-scope check removed, mock keyed by calendar only, approval route check removed), each followed by `git checkout -- <file>`, and recorded which tests failed.
Scanned the tree for secret, address and mail-scope patterns without printing any value.
Fetched CI run 35287350351's log to confirm the gate executed each step.
Re-fetched the PR head at the end; it had not moved.
