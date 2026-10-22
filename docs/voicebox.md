# Voicebox

Voicebox is the household assistant's local speech.
It runs on a Mac, under launchd, listening on loopback, and it turns text into audio without any part of a household conversation leaving the house.

**It has no host today.**
It needs a Mac that stays on in the house, and there is none: the app is built on GitHub's Macs, which are lent for one job and wiped, so they cannot keep a service running.
Until a Mac arrives, the gateways speak through the household-speech plugin on OpenRouter, as [`deploy/openclaw.md`](deploy/openclaw.md) describes under Speaking, and nothing waits on Voicebox.
Everything below is ready for the day a Mac arrives, and none of it has run on one.

**Nothing in this document has been run on Apple hardware, except where a block says otherwise.**
Every command block is labelled.

---

## What Voicebox is here

A note on the word, because it matters for reading the rest of this.

In this repository, **Voicebox is the managed local speech service**: the launchd job, the loopback HTTP endpoint, the health check and the logging policy in `services/voicebox/` and `scripts/macos/voicebox-*.sh`.
Which **synthesis engine** it drives is a separate question, and it is deliberately left open, because the brief is explicit that the engine is chosen from measurements rather than from reputation.
So the service ships with an engine table and no default, and `voicebox-benchmark.sh` is how the default gets picked.

If "Voicebox" was meant to name a specific third-party engine rather than this service, nothing here needs restructuring: that engine becomes one more row in the engine table and one more row in the benchmark, and the service, the launchd job and the health endpoint are unchanged.
This reading is flagged in the pull request so the owner can correct it cheaply.

Two things are not open to interpretation and are enforced in code:

- **No paid service is ever a fallback.** There is no cloud speech provider in the engine table, no credential anywhere in the service, and no code path that reaches the network. Voicebox makes no outbound connection at all.
- **It is never exposed.** The service refuses to bind a wildcard address outright, refuses a non-private address outright, and binds a private address only when explicitly told to. `voicebox-health.sh` re-checks the real listening socket from the kernel rather than trusting the setting that produced it.

---

## Install and update

```bash
# not yet run on Apple hardware
./scripts/macos/voicebox-install.sh --dry-run    # every file it would write
./scripts/macos/voicebox-install.sh
```

Rerunning the installer **is** the update: it copies the current service over the installed one, rewrites the launchd job description, and reloads it.
There is no separate update script, because there is no separate update.

Everything it writes is inside the invoking user's home directory:

| path | what |
|---|---|
| `~/Library/Application Support/Voicebox/voicebox.py` | the service |
| `~/Library/Logs/Voicebox/` | the two log files |
| `~/Library/LaunchAgents/com.example.householdassistant.voicebox.plist` | the launchd job |

It asks for no password, needs no `sudo`, and stores no credential, because Voicebox has none.

A user agent rather than a system daemon, for two reasons: speech synthesis needs the logged-in user's audio session, and a user agent is not reachable by anything that has not already logged in as that user.

The launchd label keeps the `com.example` prefix deliberately, even though the bundle identifiers now use the registered `com.siqstack` prefix.
The label is the runtime identity of an installed launchd job rather than a placeholder waiting to be replaced: renaming it orphans any job already loaded under the old label, so changing it is its own task, with an unload under the old label before a load under the new one.

---

## Start, stop, restart, status, logs

One script with a verb, because each of these is the same `launchctl` call and six files that each wrap one command is six files to keep in step.

```bash
# not yet run on Apple hardware
./scripts/macos/voicebox-start.sh              # start (the default verb)
./scripts/macos/voicebox-start.sh stop         # stop; it stays installed
./scripts/macos/voicebox-start.sh restart      # kill and let launchd bring it back
./scripts/macos/voicebox-start.sh status       # what launchd thinks, plus the health endpoint
./scripts/macos/voicebox-start.sh logs         # the last 50 lines of both logs
```

Update is `voicebox-install.sh`, above.

### Automatic restart

The launchd job sets `KeepAlive` to true, so launchd restarts the service whenever it exits, for any reason, including a crash and including a reboot.
`ThrottleInterval` is 10 seconds, which keeps a crash loop from becoming a busy loop.

```bash
# not yet run on Apple hardware
# Prove the restart rather than trusting it: note the pid, kill it, watch a new one appear.
./scripts/macos/voicebox-health.sh
kill "$(launchctl print "gui/$(id -u)/com.example.householdassistant.voicebox" | sed -n 's/^[[:space:]]*pid = \([0-9]*\).*/\1/p' | head -1)"
sleep 12
./scripts/macos/voicebox-health.sh
```

Only a pid that came from launchd's own record of this job is killed.
Nothing here kills by process name.

---

## Health

```bash
# not yet run on Apple hardware
./scripts/macos/voicebox-health.sh
curl -s http://127.0.0.1:8787/health
```

`voicebox-health.sh` checks three things and exits non-zero if any fails:

1. launchd has the agent loaded and running, and reports its pid.
2. `GET /health` answers `ok`.
3. Every TCP socket that pid is listening on is loopback or a private address.

The third is the one worth having a script for.
A service that speaks household conversation must never be reachable from outside the machine, and the way that goes wrong is quiet: an edited setting, a restored backup, a copied plist.
So the check reads the actual socket table rather than the configuration that produced it.

### The endpoint

`GET /health` returns JSON and an HTTP status that means something:

| status | HTTP | what |
|---|---|---|
| `ok` | 200 | an engine is chosen, its command line is complete, and its binary is on PATH |
| `no-engine` | 503 | no engine has been chosen yet; run the benchmark |
| `unknown-engine` | 503 | `VOICEBOX_ENGINE` names something not in the table |
| `engine-missing` | 503 | the engine is chosen but its binary is not installed |
| `engine-misconfigured` | 503 | the engine needs a setting the service was not given, such as `VOICEBOX_PIPER_MODEL` |

`engine-missing` and `engine-misconfigured` carry a `detail` naming the binary or the variable; the other two do not, because the status is already the whole answer.
`engine-misconfigured` is there because the alternative is worse than a red line: an engine whose command line still has an unfilled `${VOICEBOX_PIPER_MODEL}` in it has a binary on PATH, so a health check that only looks for the binary reports `ok` while every single `/speak` fails.

`POST /speak` takes `{"text": "..."}` and returns `audio/wav`.
It rejects a body that is not JSON, a missing or non-string `text`, an empty `text`, and anything longer than `VOICEBOX_MAX_CHARS` (2000 by default), each with a 400 or a 413 rather than a guess.
With no engine chosen it answers 503 and says so, rather than falling back to anything.

There is nothing else.
No other path, no other method, no configuration endpoint, no shutdown endpoint.

### Logging

The access log records the shape of a request and never its content.
A synthesis logs the number of characters and the engine used; it does not log the text.
Household conversation passes through this process, and a log file is a file that gets copied into a backup, mailed to someone debugging, or read over a shoulder.

Both log files land in `~/Library/Logs/Voicebox/`.
Volume is roughly one line per request, so this grows slowly; if it ever needs bounding, truncate them while the service is stopped:

```bash
# not yet run on Apple hardware
./scripts/macos/voicebox-start.sh stop
: > ~/Library/Logs/Voicebox/voicebox.out.log
: > ~/Library/Logs/Voicebox/voicebox.err.log
./scripts/macos/voicebox-start.sh
```

---

## Network posture

| | |
|---|---|
| default bind | `127.0.0.1:8787` |
| wildcard (`0.0.0.0`, `::`) | **refused**, always, by the service itself |
| a public address | **refused**, always |
| a private address (RFC 1918) | refused unless `VOICEBOX_ALLOW_PRIVATE=1` is set deliberately |
| outbound connections | none, ever |
| credentials | none, ever |

The private address is architecture, not a loophole.
The Linux VPS is the caller that will matter: the design has it reaching Voicebox on the Mac across the private network, so a service that could only ever bind loopback would have to be reopened later to allow the one caller it is being built for.
Read that as the design's intent rather than as a description of this machine today.
Nothing on this branch sets that path up, the VPS does not call Voicebox yet, and the task that connects them owns that work.
Until then the default is loopback, it takes `VOICEBOX_ALLOW_PRIVATE=1` to go further, and a wildcard or public address is refused whatever anyone sets.

The refusal lives in `is_bindable_host` in `services/voicebox/voicebox.py` and is asserted by the self-check, so it cannot quietly stop being true:

```bash
# verified on Windows on 2026-09-17
python3 services/voicebox/voicebox.py selfcheck
```

`tests/test_voicebox.py` runs that same self-check from the Python suite, and `ci.yml` runs the suite on every pull request with no path filter, so a change that weakens the bind policy fails a pull request whether or not it touched a path `ios-ci.yml` watches.

Nothing in this repository opens a port on a router, adds a firewall rule, or configures a tunnel.
If the phones ever need to reach Voicebox rather than the VPS, that is a design decision with its own task, and it goes through the private network, not the internet.

---

## Choosing the engine

The default engine is not chosen here, and not chosen from reputation.
It is chosen from what `voicebox-benchmark.sh` measures on the actual Mac.

```bash
# not yet run on Apple hardware
./scripts/macos/voicebox-benchmark.sh
./scripts/macos/voicebox-benchmark.sh --runs 9 --engine say --engine piper --keep
```

Every engine speaks the same fixed phrase:

> Good morning. I have reviewed your schedule and you have about an hour free before your next appointment.

That phrase lives in `services/voicebox/voicebox.py` as `PREVIEW_PHRASE`, and every document, script and benchmark reads it from there, so two runs weeks apart stay comparable.
The self-check asserts it has not been reworded.

The table has one row per engine and these columns:

| column | what it means |
|---|---|
| cold start | first synthesis in a fresh process: what the first sentence of the morning costs |
| warm median | the median of the runs after that |
| RTF | real-time factor, synthesis seconds per second of audio. Below 1.0 is faster than speech; lower is better |
| peak memory | maximum resident set of the synthesis process tree, which includes the small python3 wrapper, so read it as an upper bound |
| output bytes | size of the wav |
| Apple Silicon | native arm64, or an x86_64-only binary running under Rosetta |

An engine that is not installed is reported as not usable and skipped, so the table is useful before anything has been installed as well as after.

Then set it and reinstall:

```bash
# not yet run on Apple hardware
VOICEBOX_ENGINE=<the-name-from-the-first-column> ./scripts/macos/voicebox-install.sh
./scripts/macos/voicebox-health.sh
```

### The engine table

Three candidates ship in `DEFAULT_ENGINES`, and none of them is a recommendation:

| engine | needs | note |
|---|---|---|
| `say` | nothing | macOS built-in, always present, the baseline every other engine has to beat |
| `piper` | `piper` on PATH and `VOICEBOX_PIPER_MODEL` pointing at a `.onnx` voice | a neural engine that runs locally |
| `espeak-ng` | `espeak-ng` on PATH | formant synthesis: fast, tiny, and it sounds like it |

The command line for every engine except `say` is written from its documented interface and **has not been run against a real install**.
Check each against the version actually installed.
A fourth candidate is a fourth row in `DEFAULT_ENGINES`, and nothing else.

An engine that takes the phrase on its command line takes it as the last element, with a bare `--` immediately before it.
The phrase comes from a request, so without that separator a sentence beginning with a dash is read by the engine as an option, and `say --input-file=/etc/passwd` would synthesise a file nobody asked for and hand it back as audio.
The self-check holds every row to it, so a fourth candidate cannot quietly reintroduce it.
That `say` honours `--` is its documented option parsing and, like the rest of the table, **has not been run on Apple hardware**; if it turns out not to, the row moves to `stdin` as `piper` and `espeak-ng` already do.

An engine that needs a setting needs it under launchd as well as in the shell the benchmark ran in, so set it when you install:

```bash
# not yet run on Apple hardware
VOICEBOX_ENGINE=piper VOICEBOX_PIPER_MODEL=~/voices/en_US.onnx ./scripts/macos/voicebox-install.sh
```

The installer writes every `VOICEBOX_` variable that is set when it runs into the job description, and leaves out the ones that are not, so an engine is never handed an empty string where it expects a path.
If one is missing, `/health` says `engine-misconfigured` and names it rather than reporting `ok` and failing every request.

---

## Settings

What the service itself reads from its environment:

| variable | default | what |
|---|---|---|
| `VOICEBOX_HOST` | `127.0.0.1` | bind address, subject to the refusals above |
| `VOICEBOX_PORT` | `8787` | bind port |
| `VOICEBOX_ENGINE` | unset | the chosen engine; unset means `/speak` refuses |
| `VOICEBOX_ALLOW_PRIVATE` | unset | `1` permits binding an RFC 1918 address, which is how the VPS will reach the Mac once that task connects them; unset and unused today |
| `VOICEBOX_MAX_CHARS` | `2000` | longest accepted request |
| `VOICEBOX_PIPER_MODEL` | unset | path to a piper voice, if piper is the engine |

What the installer reads, and writes into the job description as the two variables above:

| variable | default | what |
|---|---|---|
| `HA_VOICEBOX_HOST` | `127.0.0.1` | becomes `VOICEBOX_HOST` in the job description |
| `HA_VOICEBOX_PORT` | `8787` | becomes `VOICEBOX_PORT` in the job description |

Host and port are the two the installer decides.
Setting `VOICEBOX_PORT=9000` on the installer's command line does nothing, because the installer overwrites it from `HA_VOICEBOX_PORT`; `HA_VOICEBOX_PORT=9000 ./scripts/macos/voicebox-install.sh` is the line that moves the port.
Every other `VOICEBOX_` variable set when the installer runs is carried into the job description as it stands, and the installer prints the names it wrote on every run, so changing one means rerunning the installer.

The launchd job description is the only record of what the service runs with.
Nothing else is read at any point, so there is no settings file to edit: changing a setting means rerunning `voicebox-install.sh` with it set, and `voicebox-start.sh status` shows what is live.

---

## Related

- [`apple-activation-checklist.md`](apple-activation-checklist.md) - the ordered list of what the owner does
