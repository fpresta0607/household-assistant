# Retiring Telegram

The Steward app is the household's only channel.
Telegram's channel was already switched off on both gateways when the app took over the family room; what was left is the code and config that still read Telegram's ids, and the services that worked around Telegram's limits.
This takes all of it out, one gateway at a time, and keeps PocketPiggies working with the grants Franco and Gia already have.

What changes for the family: nothing they use.
The family room, each person's thread, pictures, Speak and Talk, finance and the household note work as they did.
`/pocketpiggies` moves into each person's own thread in the app, and a new phone pairs with a setup link instead of `/app` in Telegram ([Pairing](#pairing-a-phone-from-now-on)).

## What goes

| What | Why it existed | Where it went |
| --- | --- | --- |
| household-family-room plugin | Kept what a bot could not see in The Fam; served `family_history` | `family_history` is household-app's, read from the app's own family room |
| household-speech plugin | Spoke replies as numbered Telegram voice notes | The app has Speak and Talk; household-app refuses speech tools in chat |
| household-job-mirror plugin | Copied scheduled posts from The Fam into the app | Reminders announce straight to the app |
| coordination relay (`household-coordination@`) | Carried requests between the two bots, which Telegram never shows each other | The household note's hand-offs and the app relay |
| `openclaw-family-group.py` | Kept The Fam's admission rules on both gateways | The family room's rules live in household-app |
| Telegram ids in household-memory, PocketPiggies and the household file | Named people by their Telegram accounts | Household person ids (`franco`, `gia`) |
| `channels.telegram` with the bot token, `plugins.entries.telegram` | The channel itself | Deleted from both configs |

## Before you start

Everything below runs as root on the box, from a checkout of this repository at the commit being rolled out.

1. Take the rollout backup of both gateways' state ([How the backup covers it](openclaw.md#how-the-backup-covers-it)) and the PocketPiggies baseline ([Install one gateway at a time](pocket-piggies.md#install-one-gateway-at-a-time)).
2. Note Franco's and Gia's Telegram ids from `/etc/household-assistant/household.json` (`telegram.franco`, `telegram.gia`).
   PocketPiggies registered Corey's and Denise's clients under those chats, so the key holders keep using them (step 3).
   They are not secrets, but they do not belong in a chat either.

## 1. The code

```
scripts/openclaw-install.sh
```

It replaces the household plugins in the mount and restarts both gateways.
From here until step 4, each gateway's log names a `family_history` tool conflict, since the family-room plugin and household-app both offer it until its config names only one; the first one loaded answers, and nothing else is affected.
The new household-memory plugin refuses its old Telegram-keyed config, so step 2 follows straight away.

## 2. Memory

```
python3 scripts/openclaw-memory.py apply --gateway corey --dry-run
python3 scripts/openclaw-memory.py apply --gateway corey
python3 scripts/openclaw-memory.py apply --gateway denise
python3 scripts/openclaw-memory.py check
```

`check` should say `keeps for franco (Franco), with gia (Gia)` on Corey and the reverse on Denise.
What was kept before stays kept and shown; nothing is migrated.

## 3. PocketPiggies, before anything takes Telegram's config away

The old PocketPiggies guard looks for Telegram's config and stops finance without it, so the new installer goes first, one gateway at a time:

```
python3 scripts/pocket-piggies-install.py corey --owner franco --telegram-id <Franco's id> --restart
```

It copies the new plugin, writes the new policy (every chat channel but the app switched off, the family room's tool list, the plugin keyed by `franco`), installs the new key holder and guard, and restarts Corey and his key holder.
`--telegram-id` keeps the key holder speaking for Franco's Telegram chat, which is what PocketPiggies registered Corey's client with and binds any grant made through it to, so linking works with PocketPiggies as it is and a connection already made keeps reading ([Bindings](pocketpiggies-server.md#bindings)).

Ask Corey for a balance in Franco's own thread before going on.
Then Denise:

```
python3 scripts/pocket-piggies-install.py denise --owner gia --telegram-id <Gia's id> --restart
```

## 4. The app's config, and what Telegram left in it

```
python3 scripts/openclaw-household-app.py apply --gateway corey --dry-run
python3 scripts/openclaw-household-app.py apply --gateway corey
python3 scripts/openclaw-household-app.py check
python3 scripts/openclaw-household-app.py apply --gateway denise
```

`apply` deletes `channels.telegram` with its bot token, `plugins.entries.telegram`, the family-room and job-mirror plugins' entries and load paths, and the `telegram:` owners in `commands.ownerAllowFrom`, hands the assistant `family_history`, and writes the family room's tool list.
The gateway restarts onto the new plugin list.
Each run prints where it saved the config it replaced.

## 5. Speech

```
python3 scripts/openclaw-speech.py apply --dry-run
python3 scripts/openclaw-speech.py apply
```

It takes the household-speech plugin's entry and load path out, and `speak` and `tts` out of `tools.alsoAllow`, and refuses until household-app's speech guard is installed (step 1), so `/tts on` never reaches OpenClaw's own command.
`check` afterwards should say `speech only when someone asks for it` on both.

## 6. Verify

```
scripts/openclaw-verify.sh
```

On both gateways, read `household app`, `spoken replies` and `pictures and videos`: each should be `ok`.
Then, in the app:

- In Franco's thread: "How much is left in groceries?" answers with a PocketPiggies card, and `/pocketpiggies status` says the connection is saved.
- In the family room: "@Corey what did we decide about Saturday?" reads the family history.
- In each thread, ask for a picture.

## 7. What is left on the box

Only once step 6 passes, since a gateway refuses a config that names a plugin whose folder is gone:

```
rm -rf /opt/household-assistant/plugins/household-family-room \
       /opt/household-assistant/plugins/household-speech \
       /opt/household-assistant/plugins/household-job-mirror
```

The coordination relay, if its timers are still there:

```
systemctl disable --now household-coordination@tick.timer household-coordination@plan.timer
systemctl stop household-coordination@tick.service household-coordination@plan.service
rm -f /etc/systemd/system/household-coordination@.service \
      /etc/systemd/system/household-coordination@tick.timer \
      /etc/systemd/system/household-coordination@plan.timer
systemctl daemon-reload && systemctl reset-failed
rm -rf /opt/household-assistant/coordination
rm -f /var/lib/household-assistant/coordination/family-room.json
```

Keep `/var/lib/household-assistant/coordination/` itself: the app relay and the spend job write there.
`coordination.db` is Franco's call; the nightly backup copies it while it exists and records `none` once it is gone.

In both workspaces, `/var/lib/household-assistant/openclaw/workspace` and `/var/lib/household-assistant/openclaw-denise/workspace`, remove `skills/coordinate/` and `coordination-outbox/`.

Take `TELEGRAM_BOT_TOKEN` out of both env files, the way [The model backend](openclaw.md#the-model-backend) edits them, and `familyGroup` and `telegram` out of the household file; nothing reads them any more.

The bots themselves: once a week has passed with nothing missing, delete both in BotFather (`/deletebot`), which also ends their tokens.

## Pairing a phone from now on

`/app` in Telegram is gone.

- A person with a paired iPhone gets a setup link for another one on Account, **Pair a new iPhone**.
- A household's first iPhone, or one whose person has none left, gets its link from whoever runs the box:

  ```
  docker exec openclaw-gateway node dist/index.js gateway call household-app.pair --json --params "{}"
  ```

  It prints `link` and `setupCode`, both good once for ten minutes; send the link to that person's phone and tap it there.
  Use `openclaw-denise` for Gia's.
- Sign in with Apple still works for an Apple ID that was linked before, and a new one still waits for Franco to let it in.

## Rolling back

Each step saved what it replaced:

- Steps 2, 4 and 5 print the path of the config they replaced, `openclaw.json.pre-memory-<time>`, `pre-household-app-` and `pre-speech-` in the gateway's state directory.
  Copy it back over `openclaw.json`, keeping its owner and mode 0600, and `docker restart` that gateway.
- Step 3: `python3 scripts/pocket-piggies-install.py <persona> --owner <person> --rollback --restart` stops finance on that gateway; the backup of the previous config and plugin is the newest folder in `/opt/household-assistant/pocket-piggies-backups`.
- Step 1: check out the previous commit and run `scripts/openclaw-install.sh` again.

Telegram itself comes back only with the pre-step-4 config and the previous commit's code; the bot tokens stay valid until the bots are deleted in step 7.
