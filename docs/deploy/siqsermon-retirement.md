# Retiring SIQsermon

SIQsermon is no longer an app.
The one thing the household still used it for was its functions, the assistants' scripture: verse lookup, search by meaning, cross references, word studies, and the household's own sermons and study plans.
Those now run in the gateways themselves, in the household-scripture plugin ([Scripture](openclaw.md#scripture)), so SIQsermon's four containers can stop.

What it gives back: about 1.8 GB of memory SIQsermon was using and 2.6 GB it had reserved, ports 80 and 443 and Caddy, which nothing else uses, and an OpenRouter key that only the assistants hold, so the Spend page is the whole bill.

## The order, and why

The export reads SIQsermon's backend over SIQsermon's own network, `deploy_default`, from inside Corey's gateway.
The new compose file takes both gateways off that network.
So the export comes first, then the install, then the stop.

Everything below runs as root on the box, from a checkout of this repository at the commit being rolled out.

### 1. The last backup, and the sermons out

```
scripts/siqsermon-retire.sh export
```

It runs `siqsermon-backup.sh`, which stops Neo4j for its dump and starts it again, then reads every sermon and study plan through SIQsermon's backend from inside `openclaw-gateway`, as the gateway's own user, and writes them to both gateways' `household-scripture/import/`.
Each gateway keeps them the first time its `scripture` tool is used, once, and moves the files to `import/done/`.

### 2. The Bible

```
python3 scripts/scripture-build.py --embed --env-file /etc/household-assistant/openclaw.env
```

It reaches bereanbible.com, a.openbible.info, raw.githubusercontent.com and openrouter.ai, and writes `/var/lib/household-assistant/scripture/bible.sqlite`.
It prints how many verses, cross references and words it read; the BSB has about 31,100 verses, and a source that gives far fewer is refused with nothing written.

### 3. The plugin, the skill and the compose file

```
scripts/openclaw-install.sh
```

It installs the household-scripture plugin into the plugin mount, replaces the scripture skill's folder in both workspaces, which takes the old SIQsermon client away, creates `/var/lib/household-assistant/scripture`, and installs the compose file without SIQsermon's network and with the Bible mounted read-only.
Both gateways are recreated.

### 4. The phones still reach the gateways

```
scripts/openclaw-verify.sh
```

Read its `websocket over the tailnet` line on both gateways.
Off SIQsermon's network, docker maps the published ports through the gateways' own network, whose host address both gateways already trust (`172.19.0.1`, [Why the gateway trusts the host as a proxy](openclaw.md#why-the-gateway-trusts-the-host-as-a-proxy)).
If that network sits on another subnet on this box, the line fails with `403 proxy_attribution_required` and the phones sit on Connecting.
Then trust the address it does have, on both gateways:

```
gw="$(docker network inspect household-assistant_default -f '{{(index .IPAM.Config 0).Gateway}}')"
docker exec openclaw-gateway node dist/index.js config set gateway.trustedProxies "[\"${gw}\"]" --strict-json
docker exec openclaw-denise node dist/index.js config set gateway.trustedProxies "[\"${gw}\"]" --strict-json
```

### 5. Each gateway reads the Bible through the plugin

```
python3 scripts/openclaw-scripture.py apply --gateway corey --dry-run
python3 scripts/openclaw-scripture.py apply --gateway corey
python3 scripts/openclaw-scripture.py apply --gateway denise
python3 scripts/openclaw-scripture.py check
```

`apply` loads the plugin, sets the household's edition for the cards' links, hands the assistant the `scripture` tool, and takes away the SIQsermon skill's old variable.
The gateway takes it in process.

### 6. The family room gets it too

`scripture` joined the list of tools safe in a group, so the family room can read the Bible as well.
The lists move together, PocketPiggies' first, one gateway at a time, each with its owner's Telegram id from the household file:

```
python3 scripts/pocket-piggies-install.py corey --telegram-id <Franco's id> --restart
python3 scripts/openclaw-household-app.py apply --gateway corey
python3 scripts/pocket-piggies-install.py denise --telegram-id <Gia's id> --restart
python3 scripts/openclaw-household-app.py apply --gateway denise
```

### 7. Ask

In each person's own thread: "What does John 3:16 say?" should answer with a scripture card whose **Open in Bible** opens the household's edition, and "list our sermons" should list what SIQsermon held.
In the family room, ask one assistant by name for a verse.

### 8. Stop SIQsermon

```
scripts/siqsermon-retire.sh stop
```

It refuses unless both gateways pass `openclaw-scripture.py check` and neither is still on `deploy_default`, then runs SIQsermon's own `docker compose down`.
Its files stay in `/opt/siqsermon` and `/etc/siqsermon`, and its last backup is the newest folder in `/var/backups/siqsermon`.

### 9. Afterwards

- Take `SIQSERMON_USERNAME` and `SIQSERMON_PASSWORD` out of both env files; nothing reads them any more.
- Change the OpenRouter key, since `/etc/siqsermon/runtime.env` holds a copy of it: make a new key in OpenRouter, put it in both env files the way [The model backend](openclaw.md#the-model-backend) says, recreate both gateways, and delete the old key.
- The memory SIQsermon held is free: the assistant budget in [docs/phase0/budget.md](../phase0/budget.md) can be raised the next time a ceiling is measured.

## Rolling back

Before step 8 nothing is gone: put the previous compose file back from the previous checkout and run `docker compose up -d` in `/opt/household-assistant`, which puts both gateways back on `deploy_default`, and set the old skill back with `git checkout <previous> -- deploy/openclaw/skills/scripture` and `scripts/openclaw-install.sh`.
After step 8, `docker compose --env-file /etc/siqsermon/runtime.env -f docker-compose.prod.yml up -d` in `/opt/siqsermon/current/deploy` brings SIQsermon back with its data; `siqsermon-restore-rehearsal.sh` restores from the last backup if its volumes are gone.
