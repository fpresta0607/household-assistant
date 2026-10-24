# Updates a household's box takes by itself

A household that runs its own box keeps it current without anyone logging in: once a night the box fetches the publisher's releases, installs the newest one the publisher signed, and puts itself back when that release fails.
The publisher is whoever cuts releases of this repository; the box trusts their signing key and nothing else, not the repository, not GitHub and not whoever can push to either.

Franco's box does not update itself.
Its rollouts stay the hand rollouts of [the gateway runbook](openclaw.md), one gateway at a time, unless Franco chooses otherwise and runs `install` below on it.

## What the box does each night

`household-update.timer` starts `household-update.service` once a night, at a time between two and four in the morning on the box's clock that each box picks for itself and keeps.
The service runs `/opt/household-assistant/update/household-update.py run` ([`scripts/household-update.py`](../../scripts/household-update.py)), which:

1. Fetches the publisher's release tags into the box's own mirror of the repository.
   A tag removed there is removed here too.
2. Picks the newest release newer than the one in use.
   A release is an annotated tag named for the day it was cut, `v2026.10.24`, with a number after it when a day has more than one, `v2026.10.24.2`.
   It is refused unless its SSH signature is from a key in `/etc/household-assistant/allowed_signers`, and unless the name signed inside the tag is the tag's own name, so an old signed release pushed again under a newer name is refused.
   A release older than the one in use is never installed, and one that failed on this box is never tried again; a newer one is.
   Each refusal is a line in the journal.
3. Checks out exactly the commit the signed tag names into `/opt/household-assistant/releases/<tag>`.
4. Takes the rollout lock, `/run/household-assistant/rollout.lock`, so it never runs while someone rolls out by hand.
   A run that finds the lock held leaves the box alone and exits 75, which the service counts as a success; the next night's run tries again.
5. Runs the nightly backup, `scripts/household-backup.sh`, from the release in use, with its restore drill ([The nightly backup](openclaw.md#the-nightly-backup)).
   A backup that fails or does not restore stops the update before anything changes.
6. Keeps a copy of `/opt/household-assistant/docker-compose.yml` and of each gateway's `openclaw.json`, the gateways named in [the household file](openclaw.md#where-its-state-lives), in `/var/lib/household-assistant/update/snapshot/`.
   A config with a link in its place is not copied: the gateways' folders are their assistants' to write, and a root process copying a link's target back would hand the assistant whatever it pointed at.
7. Converges the box with the new release's `scripts/household-converge.sh`, which installs the gateways, plugins and configs and checks every gateway.
8. When that passes, points `/opt/household-assistant/current` at the new release in one step, replaces the updater the timer runs and its units with the new release's own, and removes releases beyond the newest three, keeping the one in use and the one before it.
   A new updater that does not even start is not put in place, so the next night's run still can.
9. When it fails, puts the copies back as they were, with their owners and modes, converges the box again with the release it was on, and records the failed tag so it is never tried again.
   A config the failed release wrote where there was none is left in place, since removing a gateway's first config would take the gateway down.
   When converging back fails too, the record says so and the box needs a person.

The release's backup and converge run with `HOUSEHOLD_ROLLOUT_LOCKED=1` in their environment, so a script that takes the rollout lock itself when run by hand knows the updater already holds it.

### What is where

| Path | What it holds |
| --- | --- |
| `/etc/household-assistant/allowed_signers` | whom the box trusts to sign a release, put there once by `install`; no release changes it |
| `/opt/household-assistant/repo.git` | the box's mirror of the publisher's release tags |
| `/opt/household-assistant/releases/<tag>/` | each release's files, with `.household-release.json` naming its tag and commit |
| `/opt/household-assistant/current` | the release in use |
| `/opt/household-assistant/update/` | the updater the timer runs, `household-update.py` with `household_file.py` beside it |
| `/var/lib/household-assistant/update/state.json` | the release in use, the one before it, the last attempt and how it went, the last error and the releases never to try again |
| `/var/lib/household-assistant/update/snapshot/` | the copies the last update kept, root-only |
| `/etc/systemd/system/household-update.{service,timer}` | [`deploy/update/`](../../deploy/update) |

## Signing a release, on the publisher's side

Make a signing key once, on the publisher's own machine, with a passphrase; it never goes to a box or into the repository:

```
ssh-keygen -t ed25519 -C "household-assistant releases" -f ~/.ssh/household-release
git config gpg.format ssh
git config user.signingkey ~/.ssh/household-release.pub
```

Put its public half in `deploy/update/allowed_signers`, shaped like [`allowed_signers.example`](../../deploy/update/allowed_signers.example): a principal, the namespace, then the public key exactly as `~/.ssh/household-release.pub` holds it.

```
releases@example.com namespaces="git" ssh-ed25519 AAAAC3Nza... household-assistant releases
```

A box takes that file when it is set up, and only then, so publishing it in the repository changes nothing on a box that already has one.
More than one line trusts more than one key, which is how a key is rotated: add the new key, have each box take the file with `install --replace-signers`, then sign with the new key.

Cut a release from a commit whose checks passed, then push the tag:

```
git tag -s v2026.10.24 -m "v2026.10.24"
git -c gpg.ssh.allowedSignersFile=deploy/update/allowed_signers verify-tag v2026.10.24
git push origin v2026.10.24
```

`verify-tag` must print `Good "git" signature for releases@example.com`; a box checks the same thing.
A release cannot be taken back: a box that installed it keeps it until a newer one comes, and deleting the tag only stops boxes that have not taken it yet.
A bad release is fixed by cutting a newer one, `v2026.10.24.2` the same day.

## Setting a box up for it

The box must be able to fetch the repository: a public repository needs nothing more, and a private one needs a read-only deploy key on the box, added to the repository on GitHub, whose path `install` takes with `--deploy-key`.
`ssh-keygen` must be on the box, which Ubuntu's `openssh-client` provides.

From a checkout of the repository, as root:

```
python3 scripts/household-update.py install \
  --remote https://github.com/fpresta0607/household-assistant.git \
  --signers deploy/update/allowed_signers
python3 /opt/household-assistant/update/household-update.py run
```

`install` puts the signers file, the mirror, the updater and its units in place and starts the timer, and installs no release.
The first `run` installs the newest signed release onto the box from nothing, so the box only ever runs what the publisher signed.
`install` again with the same signers changes nothing; with other signers it refuses unless told `--replace-signers`.

## Watching it

```
python3 /opt/household-assistant/update/household-update.py status
journalctl -u household-update.service --since yesterday
python3 /opt/household-assistant/update/household-update.py run --dry-run
```

`status` reads only the record: the release in use, the one before it, when it last looked, the last attempt and how it went, the releases never to try again and the last error.
`--dry-run` fetches and says which release it would install, and installs nothing.

## Pausing it

```
systemctl disable --now household-update.timer
systemctl enable --now household-update.timer
```

The first stops the nightly runs and the second starts them again.
A rollout by hand holds the updater off while it runs when it takes the same lock:

```
mkdir -p /run/household-assistant
flock /run/household-assistant/rollout.lock /opt/household-assistant/current/scripts/household-converge.sh
```

## Rolling back by hand

The updater rolls back a release that fails its own checks.
A release that passed them and still misbehaves is rolled back by hand, under the lock, to any release still under `/opt/household-assistant/releases/`:

```
systemctl disable --now household-update.timer
cd /opt/household-assistant
flock /run/household-assistant/rollout.lock releases/v2026.10.23/scripts/household-converge.sh
ln -sfn releases/v2026.10.23 current.new && mv -T current.new current
```

Then add the bad tag to `failed` in `/var/lib/household-assistant/update/state.json`, and set `current` there to the release now in use, before starting the timer again; otherwise the next night's run installs the bad release again, since it is newer than the one in use.
The gateways' data comes back from the backup the update took first, in `/var/backups/household-assistant/`, as [How the backup covers it](openclaw.md#how-the-backup-covers-it) describes.
