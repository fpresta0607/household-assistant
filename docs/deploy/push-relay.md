# The push relay

Every household's phones are told about a new message through Apple's push service, and Apple takes a notification for the Steward app only from someone holding the app's push key, the `.p8` from the publisher's Apple developer account.
That key can notify any phone that installed the app, whichever household it belongs to, so it never goes on a household's box.
The first household's box holds it because it is the publisher's own (`HOUSEHOLD_APNS_*` in each gateway's env file, [docs/deploy/openclaw.md](openclaw.md)).
Every other household's box notifies its phones through the publisher's push relay instead, which holds the key and passes each household's notifications on.

The code is in [`deploy/push-relay`](../../deploy/push-relay): `relay.mjs` decides, `server.mjs` serves it on loopback, `admin.mjs` keeps the list of households it lets in.
It sends with household-app's own [`apple-push.js`](../../deploy/openclaw/plugins/household-app/apple-push.js), the same code a box with the key sends with, so the two cannot drift.

## What the relay sees, and what it cannot

A gateway seals who said what for each phone, under a key that phone made and handed only to its own gateway, before anything leaves the box ([`push.js`](../../deploy/openclaw/plugins/household-app/push.js)).
So the relay sees exactly what Apple sees:

- the phone's push token and whether it is a development or a production build;
- the plain alert, always "Steward AI" and "New message";
- the conversation's kind (`family`, `direct`), which stacks notifications on the phone;
- whether it is a reminder, which may break through a Focus;
- the message's id, which Apple uses to replace a notification rather than repeat it;
- the sealed part, which only the phone opens.

It never sees a word anyone said, who said it, or a name, and it logs only which household sent a request and what became of it.

The relay lets a request through only when all of these hold, so a household can make it say "New message" to the phones that registered with its own gateways and nothing else:

- The household is in the relay's households file, and its key signed the request: who it is, the time, and the body's hash, with Ed25519.
- It was signed within five minutes of the relay's clock, and the relay has not had the same signature before, so a request someone captured cannot be sent again.
- The household has not used up its share: a bucket of 60 requests that fills again at 120 a minute (`PUSH_RELAY_PER_MINUTE`), one notification per phone, so one household cannot spend Apple's patience for the others.
- The body is exactly the shape `push.js` builds: the plain alert, the app's sound, mutable content, a conversation and its category, optionally time sensitive, and a sealed part of a bounded size. A badge, a silent push, a different alert or anything beside them is refused.

Apple's answer goes back to the gateway as Apple gave it, so a gateway still forgets a phone Apple says is gone.
A refusal of the relay's own never counts as a phone being gone.

If a household's box is taken over, whoever holds it can send its own phones "New message" until the publisher removes its key.
If the relay is taken over, whoever holds it has the app's push key, can send any app user a notification, and sees the tokens and timing above, never the words.
That is why the relay is the publisher's alone, and why the key stays on it.

## Setting up the relay

On the publisher's own box, a small Linux server with Node 22 or newer at `/usr/bin/node` (NodeSource's packages put it there), from a checkout of this repository, as root:

```
scripts/push-relay-install.sh
```

It copies the relay's code to `/opt/push-relay/release`, in the repository's own layout so that its import of `apple-push.js` works there as in a checkout, installs `push-relay.service`, makes `/etc/push-relay/households.json` with nobody in it, and makes `/etc/push-relay/push-relay.env` from [the example](../../deploy/push-relay/push-relay.env.example), root-only.
It does not start the relay while that file still holds the example's placeholder key.

The key goes in on the box itself, never through a chat or the repository.
Copy the `.p8` Apple let you download to the box (for example with `scp`), then, with your own key id and team id:

```
settings=/etc/push-relay/push-relay.env
sed -i -e 's/^APNS_KEY_ID=.*/APNS_KEY_ID=ABC123DEFG/' -e 's/^APNS_TEAM_ID=.*/APNS_TEAM_ID=TEAM123456/' "$settings"
key="$(awk 'NF { sub(/\r$/, ""); printf "%s\\n", $0 }' /root/AuthKey_ABC123DEFG.p8)"
sed -i '/^APNS_PRIVATE_KEY=/d' "$settings"
printf 'APNS_PRIVATE_KEY=%s\n' "${key%\\n}" >> "$settings"; unset key
shred -u /root/AuthKey_ABC123DEFG.p8
systemctl enable --now push-relay
curl -s http://127.0.0.1:8787/healthz     # {"ok":true}
```

Keep the `.p8` itself somewhere offline as well; Apple lets you download it once.

The relay listens on `127.0.0.1:8787` only.
The households' boxes reach it over HTTPS, and the plugin refuses any other address, so put HTTPS in front of it, either way:

- **Tailscale Funnel**, if the publisher's box is on Tailscale: `tailscale funnel --bg 8787` publishes it at `https://<box>.<tailnet>.ts.net/` with a certificate Tailscale keeps, with no port opened on the box. Households need nothing of the publisher's tailnet for it.
- **A reverse proxy**, such as Caddy with a name of your own: `push.example.com { reverse_proxy 127.0.0.1:8787 }`.

That address, with no path, is the relay's `url` below.

After a change to the relay's code, run `scripts/push-relay-install.sh` again from the new checkout; it restarts the relay.
Its log is `journalctl -u push-relay`.

## Letting a household in

On the household's box, as root, once its gateways are installed (`scripts/openclaw-install.sh` makes their env files):

1. Name the relay in the household file, `/etc/household-assistant/household.json`, with the household's own name, lower-case letters, digits and dashes, as in [`deploy/household.new.example.json`](../../deploy/household.new.example.json):

   ```json
   "pushRelay": { "url": "https://push.example.com", "household": "marina-steve" }
   ```

2. Make the household's key:

   ```
   python3 scripts/household-push-key.py
   ```

   It makes an Ed25519 key with openssl, once, and puts it in both gateways' env files as `HOUSEHOLD_PUSH_RELAY_KEY`, the same key in each, root-only.
   It never prints the private half.
   It prints one line, the public half, which is safe to send the publisher any way at all:

   ```
   household marina-steve key MCowBQYDK2VwAyEA...
   ```

3. The publisher lets the household in, on the relay's box:

   ```
   node /opt/push-relay/release/deploy/push-relay/admin.mjs add marina-steve MCowBQYDK2VwAyEA...
   ```

   The relay reads its households file again on its next request; nothing restarts.
   `admin.mjs list` shows who is let in, each with its key's fingerprint.

4. Back on the household's box, make the gateways again so they read the key, and name the relay in each gateway's channel:

   ```
   scripts/openclaw-install.sh
   python3 scripts/openclaw-household-app.py apply --gateway <first assistant>
   python3 scripts/openclaw-household-app.py apply --gateway <second assistant>
   ```

   `apply` writes `channels.household.push.relay` from the household file, and `check` reports a gateway whose channel does not name it.

Each gateway asks the relay once, as its channel starts, whether it lets the household in, and says so in its log:

```
docker logs <container> 2>&1 | grep 'push relay'
# household-app: phones are notified through the push relay at https://push.example.com
```

`does not let in marina-steve yet` there means step 3 has not happened, or was done with another key.

## Changing or taking back a key

**A household's key**, if its box was rebuilt or the key may have been seen: on the household's box, delete the `HOUSEHOLD_PUSH_RELAY_KEY=` line from both gateways' env files, run `python3 scripts/household-push-key.py` again for a new key, and send the new line.
The publisher runs `admin.mjs add <household> <new key> --replace`, and the household runs `scripts/openclaw-install.sh` so the gateways read it.
Phones go unnotified between the two steps, and nothing else is lost.

**Taking a household out**: `admin.mjs remove <household>`.
Its gateways' next requests are refused, their phones stop being notified, and their logs say so.

**The app's push key**: make a new key in Apple's developer account, write it into `/etc/push-relay/push-relay.env` as above, `systemctl restart push-relay`, then revoke the old key at Apple.
No household's box changes.

## A box that holds the Apple key

A gateway with `HOUSEHOLD_APNS_KEY_ID`, `HOUSEHOLD_APNS_TEAM_ID` and `HOUSEHOLD_APNS_PRIVATE_KEY` in its environment sends to Apple itself, whatever its channel says of a relay.
The first household's box does, and nothing on it changes.
A gateway with neither key notifies no phone and says so once in its log, as before.
