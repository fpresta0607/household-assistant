# Apple signing, identifiers and capabilities

Everything Apple needs to know about this app before it will run on a phone, and where each piece is kept.

**No secret goes into Git.**
Not a certificate, not a private key, not a provisioning profile, not an App Store Connect key, not an Apple ID, not a password.
Every identifier in this document is a placeholder written in angle brackets, and the repository is scanned in CI for anything shaped like a real one.
The two things that do exist in the repository are the bundle identifiers, which are public by nature and which carry the owner's registered prefix `com.siqstack`.

There is no Mac of our own.
The owner chose GitHub's hosted Macs on 14 October 2026, so every signed build happens on a Mac that GitHub lends for one job and wipes afterwards.
Nothing about signing lives on a machine in the house, and nobody signs in to Xcode anywhere.

---

## The short version

| thing | value | where it lives |
|---|---|---|
| Apple Developer Program membership | the owner's | developer.apple.com |
| Development team id | `<TEAM_ID>` | read from the profile Apple issues in each release run, never stored |
| Bundle identifier prefix | `com.siqstack`, the owner's registered prefix | `apps/ios/project.yml` |
| Signing style | Manual, on release only | `scripts/macos/build-ios.sh` writes it per target for the archive |
| Apple Distribution certificate | issued by Apple, the first release asks for it | Apple keeps it, and its private key is the `DISTRIBUTION_CERTIFICATE_KEY` secret |
| App Store profiles | one for the app, one for the widget | made or found by each release run, never stored |
| App Store Connect API key | `<KEY_ID>`, `<ISSUER_ID>`, and a `.p8` file, Admin role | the `testflight` environment's secrets, see [`testflight.md`](testflight.md) |
| APNs key | a `.p8` file | the household's credential store for the gateways, by the owner's hands, never in GitHub and never in Git |

---

## 1. The development team

An individual Apple Developer Program membership is enough for this app.
There are two people using it and no company, so there is no need for an organization membership, and an organization membership would require a legal entity and a D-U-N-S number.

After enrolling, the team id is the ten-character string on the membership page at developer.apple.com.
It is not a secret in the sense that a key is, but it identifies the owner's account, so it is treated as one here: it is never committed, and `scripts/macos/lib.sh` redacts it out of any command line a script prints.

Nobody types it anywhere.
Each release reads it from the App Store profile Apple issues, hands it to the archive and the export, and masks it in the run's log.

---

## 2. The bundle identifier

The identifiers are registered, and live in `apps/ios/project.yml`:

| target | identifier |
|---|---|
| app | `com.siqstack.stewardai` |
| widget extension | `com.siqstack.stewardai.widgets` |
| notification extension | `com.siqstack.stewardai.notifications` |
| Share Extension | `com.siqstack.stewardai.share` |
| unit tests | `com.siqstack.stewardai.tests` |
| UI tests | `com.siqstack.stewardai.uitests` |

`com.siqstack` is a reverse-DNS prefix the owner controls.
It replaced `com.example`, which is reserved and cannot be registered by anyone: while that placeholder was there, an accidental release could not collide with a real app and a signed build could not succeed by accident.

`scripts/macos/verify.sh` and `scripts/macos/build-ios.sh` still refuse the `com.example` prefix, so they now fire only if it is ever reverted.

The widget's identifier must stay a child of the app's identifier.
Apple requires an app extension's bundle identifier to be prefixed by its containing app's, and the build fails at signing rather than at compile time if it is not.

---

## 3. The App ID

Register the app identifier once, at developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → App IDs.

Two choices matter there:

**Explicit, not wildcard.**
A wildcard App ID cannot carry push notifications, App Groups, or associated domains, and this app needs all three eventually.

**Register the widget's identifier as well.**
An app extension is a separate App ID.
It needs the same App Group as the app and nothing else.

**And the notification extension's, `com.siqstack.stewardai.notifications`.**
It too needs only the App Group: it reads the key notifications are sealed under, and the faces the app draws, from there.

**And the Share Extension's, `com.siqstack.stewardai.share`.**
It too needs only the App Group: it leaves what was shared there for the app to send, and reads the faces and the assistant's name from there.
It holds no gateway link and no key, so it needs nothing else.

---

## 4. Capabilities, and why only one of them is in `project.yml` yet

The generated project declares **one entitlement**, the App Group, and nothing else.

That is not an oversight.
An entitlement in the project that the App ID does not carry makes automatic signing fail, with an error about a provisioning profile that does not match, and it fails on the first build on a machine where nothing else has gone wrong yet.
So each capability is documented here and added in the task that first needs it, and the App Group arrived with the first real widget.
**Enable App Groups on both App IDs before the first signed build.**
A simulator build signs nothing and needs none of this.

Here is what each will be, in the order the phases need them.

### App Groups - declared, and needed by the widget

A widget runs in its own process and cannot read the app's container.
An App Group gives both a shared one.

- Identifier: `group.com.siqstack.stewardai`, written in `project.yml` on both targets and in `apps/ios/HouseholdAssistant/Model/WidgetSnapshot.swift`
- Enabled on both the app's App ID and the widget's App ID
- Added to both targets as an `App Groups` entitlement

What crosses it is only what the widgets display, already filtered for the person whose phone it is: the assistant's name and emoji as the gateway reported them, who is in the family room, the newest five lines of the family room and of this phone's own thread with how many are unread, and the faces the app draws for the notifications.
No token and no gateway address is ever written there.
Corey's data and Denise's data never share a group, because the phones never share one.

### Push notifications - needed for reminders that arrive when the app is closed

This is the capability that matters most, because the approved plan's single most important reliability property is that reminders fire whether or not the model, the app or the network is healthy.

- `Push Notifications` enabled on the app's App ID
- `aps-environment` entitlement in the app target, `development` for debug and `production` for release
- An **APNs authentication key**, not a certificate: one `.p8` key works for every app on the team, in both environments, and does not expire, where a push certificate expires annually and is one per app per environment.

The APNs key is downloaded exactly once and cannot be downloaded again.
It belongs in the household's credential store beside the other backend secrets, because the thing that sends a push is the backend on the VPS, not the build and not the app.
It never goes into this repository or into a GitHub secret.
The owner stores it with `cfo auth store`, and [`apple-activation-checklist.md`](apple-activation-checklist.md) has the exact command.

Note for the phase that turns this on: the APNs key id and the team id are needed by the sender alongside the key itself.

### Background modes - audio and Voice over IP, for the call

`Audio, AirPlay and Picture in Picture` is declared for the call with the assistant, a CallKit call that keeps talking when the screen locks or the app goes to the back.
It runs only while a call has the sound, and Apple reviews background modes: a mode that is declared but unused is a rejection reason.
`Voice over IP` is declared because CallKit needs it for any call, placed or received.
Apple's documentation for `CXErrorCodeRequestTransactionError.unentitled` names a missing `voip` mode as the usual reason iOS refuses a call the app asks for.
Builds 14 to 17 left it out, on the reasoning that it was only for VoIP pushes that ring the phone.
From CallKit's arrival in build 14 until it was added, no call on either gateway reached a single turn.
The app still registers for no VoIP pushes: it only ever places a call.
`Remote notifications` is the mode that lets a push wake the app to fetch before showing something, and it is not declared either.
Background modes live in the Info.plist that `project.yml` writes, and need no App ID capability.

### App Intents and Siri - shipped, and still no capability

App Intents need no entitlement and no App ID capability.
They are a framework, and the intents themselves are declared in code: `Ask your assistant`, offered to Siri by an `AppShortcutsProvider`, and `Talk to your assistant`, which the widgets' Talk button and the Talk control in Control Center run to open the app into Talk.
Widgets, their Edit Widget choice and a Control Center control are App Intents and WidgetKit too, so none of them needs a capability either.

Siri only becomes a capability if the app wants to be invoked by voice without being opened, which nothing needs yet.

### Associated domains - only if the app ever needs a link to open it

`applinks:<your.domain>` plus an `apple-app-site-association` file served from that domain over HTTPS.

Nothing in the plan needs this yet.
It is listed because it is an App ID capability, so if it is ever wanted, it is one more thing to enable before a build will sign.

### Summary

| capability | App ID | entitlement | secret | who adds it |
|---|---|---|---|---|
| App Groups | app, widget, notification extension and Share Extension | `com.apple.security.application-groups` | none | declared in `project.yml`, enable it on all four App IDs |
| Push notifications | app | `aps-environment` | APNs `.p8`, on the VPS | the task that makes reminders reach a closed app |
| Communication notifications | app | `com.apple.developer.usernotifications.communication` | none | declared in `project.yml`, so a notification shows the sender's face |
| Time Sensitive notifications | app | `com.apple.developer.usernotifications.time-sensitive` | none | declared in `project.yml`, so a reminder's push gets through a Focus; a portal tick, the API cannot turn it on |
| Background audio | none | `UIBackgroundModes` in Info.plist | none | declared in `project.yml`, so a call with the assistant keeps talking locked or in the background; nothing to enable |
| Voice over IP | none | `UIBackgroundModes` in Info.plist | none | declared in `project.yml`, so CallKit takes the app's calls; no VoIP pushes, nothing to enable |
| Remote notifications | none | `UIBackgroundModes` in Info.plist | none | the task that makes a push wake the app |
| Location updates | none | `UIBackgroundModes` in Info.plist | none | declared in `project.yml`, so a live map in a chat keeps moving in the background while it lasts; nothing to enable |
| App Intents | none | none | none | declared in code, nothing to enable |
| Associated domains | app | `com.apple.developer.associated-domains` | none | only if wanted |

---

## 5. The certificate and the profiles

A hosted Mac is a fresh machine for every job, so it cannot keep a signing identity in a keychain the way a Mac in the house would.
Each release builds one instead, from two secrets, and throws it away at the end.

**One Apple Distribution certificate.**
Its private key is the `DISTRIBUTION_CERTIFICATE_KEY` secret, an RSA key made once on the owner's computer and piped straight into GitHub without touching the disk.
The first release sends Apple a signing request for that key and gets the certificate back.
Every later release lists the team's distribution certificates and picks the one whose public key matches, so there is one certificate however many releases run.
That matters, because Apple allows a team only a few distribution certificates, and a hosted Mac that asked for a new one each run would use them up.

**Two App Store profiles.**
The app and the widget are separate App IDs, so each needs its own profile.
Each release asks App Store Connect for an active App Store profile on that App ID that names the certificate, and makes one when there is none.
A profile Apple invalidated, because a capability changed on the App ID, is simply not picked, and the run makes a fresh one.
So turning on a capability later needs no step in GitHub.

**A throwaway keychain.**
`scripts/macos/app-store-connect.py signing` imports the certificate and its key into a keychain with a random password, puts the two profiles where Xcode reads them, and writes the profile names for the archive and the export.
The archive signs by hand with exactly those, per target, from an xcconfig that `build-ios.sh` writes, and the export names the same profiles.
The keychain, the key files and the profiles are deleted at the end of the job, and the Mac is wiped after it.

Making certificates and profiles needs the App Store Connect API key to have the **Admin** role.
App Manager can upload a build but cannot do either.

If `DISTRIBUTION_CERTIFICATE_KEY` is ever lost or leaked, make a new key the same way, and revoke the old certificate at developer.apple.com → Certificates.
The next release makes a new certificate for the new key.
Builds already in TestFlight are not affected.

---

## 6. What the preview is given

Nothing.

The preview job in `ios-ci.yml` builds for the simulator with `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`.
A simulator build needs no certificate, no profile, no team and no entitlement, so it never touches a secret.

The only workflow given a secret is `ios-release.yml`, from the `testflight` environment.
See [`testflight.md`](testflight.md).

---

## 7. Things that will go wrong, and what they mean

**"the App ID ... is not registered".**
Register it at developer.apple.com → Identifiers, as section 3 says.

**"the profile for ... does not carry the App Group".**
App Groups is off on that App ID, or the group is not assigned to it.
Fix it there and run the release again: the next run asks for a fresh profile.

**"the keychain holds no valid Apple Distribution identity".**
The Mac could not chain the certificate to Apple's root, which means Apple's WWDR G3 intermediate certificate is missing from the runner image.
Say so in an issue: the release then has to install it before the import.

**"Provisioning profile doesn't include the `<capability>` entitlement."** during the archive.
An entitlement was added to `project.yml` but not enabled on the App ID.
Enable it at developer.apple.com, and the next run makes a profile that carries it.

---

## Related

- [`testflight.md`](testflight.md) - the API key, the secrets, the upload and what it costs
- [`apple-activation-checklist.md`](apple-activation-checklist.md) - the ordered list of what the owner does
