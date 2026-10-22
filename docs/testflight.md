# TestFlight

How a build gets from this repository onto Franco's phone and Gia's phone, with no Mac of our own.

The owner chose GitHub's hosted Macs on 14 October 2026, with a cap of 5 dollars a day.
GitHub lends a fresh Mac for each job and wipes it afterwards, so nothing about signing lives on a machine in the house.

---

## The shape of it

```
one click                ios-release.yml
Run workflow, UPLOAD ──► budget ──► preflight ──► testflight (GitHub Mac) ──► testers ──► cost
or ios-cloud.py          Linux      Linux         sign, archive, upload       Linux       Linux
testflight                                                                      │
                                                                     Apple processes the build
                                                                                │
                                                                    TestFlight, internal group
                                                                          │            │
                                                                       Franco         Gia
```

| job | runs on | what it does |
|---|---|---|
| `budget` | Linux | refuses the run when today's Mac minutes plus this run's 45 minute timeout could pass 5 dollars |
| `preflight` | Linux | reads App Store Connect and stops an upload before any Mac minute is spent if an Apple step is missing |
| `testflight` | GitHub's macOS 26 Mac | makes the signing identity, archives, signs and uploads |
| `testers` | Linux | waits, at most 30 minutes, until Apple has processed the build and the internal group can install it |
| `cost` | Linux | writes the run's Mac minutes and their price on the run's summary page |

Two people, two devices, internal testing only.
An internal tester is a member of the App Store Connect team, gets a build as soon as processing finishes, and never waits for Beta App Review.

---

## Releasing

### The button

github.com/fpresta0607/household-assistant → Actions → ios-release → Run workflow, on `main`, with `UPLOAD` typed in the confirmation box.
The GitHub app on a phone has the same button under the repository's Actions.

### The command

From any computer with the GitHub CLI signed in:

```bash
# not yet run on Apple hardware
python scripts/ios-cloud.py testflight
```

It starts the same run on `main`, prints each job as it changes, and ends with what the run cost.

### What happens next

The `testers` job waits for Apple's processing, usually a few minutes, and says when the build is ready.
TestFlight then tells both phones there is a new build.
If processing fails, Apple emails the account holder and the job says so.

### A rehearsal

Leave the confirmation box empty, or run:

```bash
# verified
python scripts/ios-cloud.py rehearse --ref <branch>
```

A rehearsal reads which Apple steps are done, shows the signing settings each target would get, archives the Release build with signing switched off, and prints the export options an upload would use.
It signs nothing and sends nothing, so it can run on any branch.

### What cannot start an upload

A pull request or a push cannot: `ios-release.yml` has only `workflow_dispatch`.
A run on any branch but `main` is refused before a Mac starts, and so is a run without `UPLOAD` typed exactly.
`deploy-testflight.sh` refuses again by itself without `--confirm`, and refuses outright when the GitHub event is a pull request.

---

## What it costs

This repository is public since 22 October 2026, and GitHub's standard hosted Macs, `macos-26` among them, are free on a public repository (docs.github.com/en/billing/concepts/product-billing/github-actions, read 22 October 2026).
`scripts/ios-cloud.py` reads the repository's visibility each time it counts the day, so its Mac minutes cost $0.00 and the cap never refuses a run.
A larger runner, such as `macos-26-xlarge`, bills even on a public repository, and no workflow here uses one.

While private, the repository paid $0.062 a Mac minute, rounded up per job (docs.github.com/en/billing/reference/actions-runner-pricing, read 14 October 2026), with no free Mac minutes.
The figures below are from then, and hold again if it ever goes private:

| run | about | at most |
|---|---|---|
| a TestFlight build | 9 minutes, $0.56, build 12 on 15 October | its 45 minute timeout, $2.79 |
| a preview, fix lane | 5 minutes, $0.31, with the cached build, 6 without, measured on 15 October | its 30 minute timeout, $1.86 |
| a preview, full lane with every screenshot | 20 minutes, $1.24, measured on 15 October, 659 seconds of it the screenshots | its 30 minute timeout, $1.86 |

A fix round is the fix lane: the build, the unit tests, and only the UI tests it names with `--ui-tests`.
The full lane adds every UI test and both films, and is for the commit going to TestFlight:

```bash
# verified
python scripts/ios-cloud.py preview --ref main --ui-tests "LaunchUITests"
python scripts/ios-cloud.py preview --ref main --lane full --ui-tests "LaunchUITests"
```

Screenshots render only the states a change touches, named by id or the start of one, and every screen only with `all`, when the owner asks:

```bash
# not yet run on Apple hardware
python scripts/ios-cloud.py preview --ref main --screenshots "call. room.direct.call- chats.populated"
```

Every Mac run is started by hand, and the `budget` job refuses one that could take the day past 5 dollars.
The cap is `DAILY_CAP_USD` in `scripts/ios-cloud.py`, and the private price is `MAC_MINUTE_USD` beside it.
To read back what a run cost:

```bash
# verified
python scripts/ios-cloud.py cost --run <run id>
```

Run from a GitHub sign-in with the `user` scope, `preview`, `rehearse` and `testflight` also read GitHub's own bill for the day.

---

## The secrets

They live in the `testflight` environment at Settings → Environments, never at the repository level, and only `ios-release.yml` reads them.

| secret | what it is |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | the App Store Connect API key's id |
| `APP_STORE_CONNECT_ISSUER_ID` | the team's issuer id |
| `APP_STORE_CONNECT_KEY_P8` | the whole `.p8` file, `BEGIN` and `END` lines included |
| `DISTRIBUTION_CERTIFICATE_KEY` | the RSA private key that belongs to the team's Apple Distribution certificate |
| `HOUSEHOLD_GATEWAY_HOST` | the box's tailnet name, which the repository holds only as a placeholder in `apps/ios/Household.xcconfig` |
| `GOOGLE_IOS_CLIENT_ID` | Google's iOS OAuth client id, the part before `.apps.googleusercontent.com`, likewise |

Each secret is handed only to the step that reads it.
Both private keys are written to files under `RUNNER_TEMP` with `umask 077`, passed by path, and deleted, with the throwaway keychain, in a step that runs whether the job succeeded or failed.
The full rationale is in the header of [`.github/workflows/ios-release.yml`](../.github/workflows/ios-release.yml).

The `DEVELOPMENT_TEAM` secret stored on 19 September is no longer read: the release reads the team id from the profile Apple issues.

### The App Store Connect API key

appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API.

The release key needs **Admin** access.
A hosted Mac keeps no keychain, so each run asks Apple for the App Store profiles, and makes the distribution certificate the first time, and only an Admin key may do either.
App Manager can upload but cannot sign.
The `preflight` job says which the stored key is.

The `.p8` file downloads exactly once.
It must never be committed, and CI scans for a PEM private key block anywhere in the repository on every run.

### The distribution key

`DISTRIBUTION_CERTIFICATE_KEY` is made on the owner's computer and goes straight into the secret without touching the disk.
[`apple-activation-checklist.md`](apple-activation-checklist.md) has the one command.
The first release sends Apple a signing request for it and gets the team's Apple Distribution certificate back, and every later release finds that certificate again by its public key.
If the key is ever lost, make a new one the same way: the next release makes a new certificate, and the old one can be revoked at developer.apple.com.
Apple allows a team only a few distribution certificates, so revoke the old one rather than letting them pile up.

---

## Before the first upload will succeed

The `preflight` job checks each of these and names the one that is missing:

- the App Store Connect app record for `com.siqstack.stewardai`
- an Admin API key
- the App IDs `com.siqstack.stewardai` and `com.siqstack.stewardai.widgets`, each with App Groups on and `group.com.siqstack.stewardai` assigned
- an internal TestFlight group that gets every build, with at least one tester

Two things an upload checks for are already in the app.
The 1024 × 1024 icon with no alpha channel is in `apps/ios/HouseholdAssistant/Assets.xcassets/AppIcon.appiconset/`.
`ITSAppUsesNonExemptEncryption` is `false` in the app's Info.plist, so no build waits for an export compliance answer.
The comment beside it in [`apps/ios/project.yml`](../apps/ios/project.yml) says why.

---

## Version and build numbers

`MARKETING_VERSION` (`0.1.0`) is the version people see, and it lives in `apps/ios/project.yml`.
`CURRENT_PROJECT_VERSION` is the build number, and the release stamps it with the workflow run number, which only ever grows, unless the build number box says otherwise.

App Store Connect refuses a version and build number pair it has already seen, after the upload rather than before.
`manageAppVersionAndBuildNumber` is `false` in the export options, so what was archived is what is uploaded.

---

## Things that will go wrong, and what they mean

**"the API key's role cannot make certificates".**
The stored key is not Admin.
Make an Admin key and replace the three key secrets.

**"the profile for ... does not carry the App Group".**
App Groups is off on that App ID, or `group.com.siqstack.stewardai` is not assigned to it.
Fix it at developer.apple.com → Identifiers and run again: the next run asks for a fresh profile.

**"Apple will not make another Apple Distribution certificate".**
The team has its maximum.
Revoke one that no secret holds the key for.

**"The bundle version must be higher than the previously uploaded version."**
The build number did not increase.
Run again with a higher number in the build number box.

**"Apple refused the API key".**
The key id, the issuer id and the `.p8` do not belong to each other, or the key has been revoked.

**The run is refused by `budget`.**
Today's Mac minutes plus this run's timeout could pass 5 dollars.
It can run after midnight UTC.

---

## Related

- [`apple-signing.md`](apple-signing.md) - identifiers, capabilities, the certificate and the profiles
- [`apple-activation-checklist.md`](apple-activation-checklist.md) - the owner's steps, in order
- [`scripts/ios-cloud.py`](../scripts/ios-cloud.py) - the one command, the cap and the cost
