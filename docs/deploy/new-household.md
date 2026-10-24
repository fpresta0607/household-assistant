# A new household's box

Every household runs its own assistants on a server it rents and owns, with its own OpenRouter key paying for what they say.
Nobody else's assistant, and nobody who publishes the app, can read what is said on it.
This is how a household that is not the first one sets that server up, connects its phones, and keeps it current.
The first household's box is described in [OpenClaw on the shared VPS](openclaw.md); both run the same scripts.

## What the household needs first

- **A server.** Any provider's virtual server running **Ubuntu 24.04 LTS** with **4 GB of memory** or more and 40 GB of disk; the first household's box has 8 GB, shared with other services.
  Root access over SSH is all the setup asks for.
- **A tailnet.** A free [Tailscale](https://tailscale.com) account, which the phones and the server join, so the assistants are never on the internet.
  In its admin console, under **DNS**, turn on **MagicDNS** and **HTTPS Certificates**: each assistant is reached at an HTTPS address on the tailnet, and the box cannot get its certificate without them.
- **An OpenRouter key.** An [OpenRouter](https://openrouter.ai) account with credit, and a key made for the household at openrouter.ai/keys.
  Give the key a monthly limit: it is the most the assistants can spend.
- **Two iPhones** with Steward AI and the Tailscale app, one for each adult.

## Setting the box up

Sign in to the server as root and run:

```
apt-get update && apt-get install -y git
git clone https://github.com/fpresta0607/household-assistant.git /opt/household-assistant/src
/opt/household-assistant/src/scripts/new-household.sh
```

`new-household.sh` does, in order, skipping what is already done when it is run again:

1. **Checks the box**: Ubuntu, and enough memory for two assistants.
2. **Installs** Docker, Python, git, jq, ufw and qrencode from Ubuntu, and Tailscale from Tailscale's own repository.
3. **Joins the tailnet.** `tailscale up` prints a link; open it on a device signed in to the household's Tailscale account.
4. **Closes the box** to everything from the internet but SSH, with ufw.
   The phones come in over the tailnet, which Tailscale's own rules admit.
5. **Asks the household's answers** (`household-setup.py`): both adults' first names, what each one's assistant is called, who lets in a phone that signed in with Apple, the Bible the household reads, and the time zone, offering the box's own.
   It writes them to `/etc/household-assistant/household.json`, which only root can read, shaped like [`deploy/household.new.example.json`](../../deploy/household.new.example.json).
   Then it asks for the OpenRouter key, which is typed or pasted there and never shown, and puts it in each assistant's env file.
   Keys and passwords are never sent in a chat, an email or a ticket, to anyone.
6. **Converges the box** (`household-converge.sh`), which is what every update runs too:
   - each assistant's gateway, in a container of its own with its own state, from the compose file `household-compose.py` writes from the household file;
   - the Bible, built once from its public-domain sources;
   - every model route to OpenRouter;
   - each assistant's memory, the household app, scripture, speech and pictures;
   - each gateway's address on the tailnet, with `tailscale serve`, and its trust in that proxy;
   - the nightly backup, with a restore drill of every backup it takes;
   - and `openclaw-verify.sh` on each gateway, which fails the whole pass if any check fails.

The setup takes about fifteen minutes, most of it Docker pulling the gateway's image.
To answer the questions again, delete `/etc/household-assistant/household.json` and run `new-household.sh` again.
For a new OpenRouter key, run `python3 scripts/household-setup.py --key-only` and then `scripts/household-converge.sh`.

## Connecting the phones

On each adult's iPhone:

1. Install **Tailscale**, sign in to the household's tailnet, and leave it connected.
2. Install **Steward AI**.
3. On the box, make that person's setup link:

   ```
   cd /opt/household-assistant/src
   python3 scripts/household-pair.py <their first name>
   ```

   It prints a link, and a code the phone's camera can open.
   Open it on that person's phone, within ten minutes; it works once, and whoever opens it is paired as that person.

A person with a paired iPhone makes the link for a new one in the app, on Account, **Pair a new iPhone**.

## Notifications

A phone is told about a new message through Apple, and only the app's publisher holds the key Apple asks for.
So a household's box sends each notification through the publisher's push relay, already sealed with a key only that phone has: the relay, like Apple, sees that there is a new message and nothing of what it says.
The household's box signs what it sends with a key of its own, made on the box; the public half goes to the publisher once, who adds the household to the relay.
[The push relay](push-relay.md) has both sides of that.

Until the household is added, everything works but the phones are not notified.

## Keeping the box current

The box can keep itself current from the repository, taking only the releases the publisher signed: it backs up first, converges to the release, and rolls back if the release does not verify.
[Updates](updates.md) says how to turn it on, pause it, and roll back by hand.

## Connections

Each adult connects their own accounts in the app, under **Connectors**: Google mail and calendar, Microsoft, Notion, and others.
PocketPiggies, for the family's budget, is optional and connects the same way once the household's PocketPiggies account is linked ([PocketPiggies on the box](pocket-piggies.md)).

## What differs from the first household's box

- The first household's box also runs Home Assistant, its mailbox reader and a web site, and its household file names no members, so its compose file is [`deploy/openclaw/docker-compose.yml`](../../deploy/openclaw/docker-compose.yml) as the repository holds it.
  Every other box's compose file is written from its household file, and `household-converge.sh` refuses to run on the first household's box, which is brought up to a release by hand.
- A new household's gateways share a network on `172.31.240.0/24`, so the address each gateway trusts as its tailnet proxy, `172.31.240.1`, is fixed (`openclaw-tailnet.py`).
- Its verification expects nothing listening to the internet and only SSH through ufw, and skips the first household's iCloud calendar library: a new household's calendars come through the app.
- The scheduled jobs that read a shared iCloud calendar (`openclaw-scheduled-jobs.py`) are not set up; they need `sharedCalendar` in the household file.

## When something is wrong

- `scripts/household-converge.sh` again is always safe, and says which step stopped it.
- `scripts/openclaw-verify.sh` with `CT`, `PORT` and `STATE` set for one gateway, as `household-converge.sh` runs it, checks just that one.
  `python3 scripts/household_file.py members` lists each gateway's container, port and state.
- A phone that stays on "Connecting" is usually off the tailnet: open Tailscale on it.
- `journalctl -u household-backup.service` shows the last backup; backups are in `/var/backups/household-assistant/`.
  They are on the same box, so copy them somewhere else now and then.
