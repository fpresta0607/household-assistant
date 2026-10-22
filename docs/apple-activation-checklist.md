# Apple activation checklist

Everything on the Apple side that only you can do, in order, from the Windows PC.
There is no Mac in any of it: GitHub's Macs do the building, and you click in a browser and run three commands.

Nothing here will ever ask you for an Apple password or for a secret in chat.
Each credential goes straight into the place that keeps it, by your hands.
If something does ask, that is the bug.

**Already done on 19 September:** you enrolled, made an App Store Connect API key and a second key, and stored four secrets in GitHub's `testflight` environment.
The two key files are still at the root of your household-assistant checkout, kept out of Git by name.
The steps below say where each one goes and when to move it.

**How to see what is left:** run a rehearsal, which reads App Store Connect and lists every step below as done or to do, then signs nothing and sends nothing:

```bash
# verified
python scripts/ios-cloud.py rehearse --ref main
```

Or Actions → ios-release → Run workflow, with the confirmation box left empty.
The list is on the run's summary page.

**What you need open:** developer.apple.com, appstoreconnect.apple.com, github.com/fpresta0607/household-assistant, and PowerShell.

---

## Part 1 - Apple

### ☐ 1. Check the membership

developer.apple.com → Account → Membership details.

You should see **Apple Developer Program** with a renewal date in the future.
If it says the enrolment is pending, stop here: approval takes a day or two, and nothing below works before it.

### ☐ 2. The two App IDs and the App Group

developer.apple.com → Certificates, IDs & Profiles → Identifiers.

The list should hold **com.siqstack.stewardai** and **com.siqstack.stewardai.widgets**.
If one is missing: the plus button → App IDs → App → Explicit, with that bundle id.

Then the App Group:

1. Switch the list at the top right from App IDs to **App Groups**.
2. If **group.com.siqstack.stewardai** is missing: the plus button → App Groups → that identifier → Register.
3. Back on App IDs, open **com.siqstack.stewardai**, tick **App Groups**, press Configure, tick the group, Continue, Save.
4. Do the same for **com.siqstack.stewardai.widgets**.

Leave every other capability off.
[`apple-signing.md`](apple-signing.md) says which task turns on which capability later.

### ☐ 3. The App Store Connect app

appstoreconnect.apple.com → Apps.

If **Steward AI** is there, this step is done.
If not: the plus button → New App.

| field | value |
|---|---|
| Platforms | iOS |
| Name | Steward AI, or Steward AI: Household if the name is taken |
| Primary language | English (U.S.) |
| Bundle ID | com.siqstack.stewardai |
| SKU | household-assistant |
| User access | Full Access |

Creating it publishes nothing.

### ☐ 4. The API key has Admin access

appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API → Team Keys.

Find the key whose id is in the name of the file `AuthKey_ASCKEYID00.p8`.
Its **Access** column must read **Admin**.

A hosted Mac keeps no keychain, so each release asks Apple for its signing profiles, and only an Admin key may.

If it reads anything else:

1. The plus button → Name `household-release`, Access **Admin** → Generate.
2. Download the key. Apple offers the file once.
3. In PowerShell, from the folder the file downloaded to, replace the three key secrets (put the new key's id where it says):

```powershell
Get-Content -Raw .\AuthKey_<NEW_KEY_ID>.p8 | gh secret set APP_STORE_CONNECT_KEY_P8 --env testflight --repo fpresta0607/household-assistant
gh secret set APP_STORE_CONNECT_KEY_ID --env testflight --repo fpresta0607/household-assistant --body <NEW_KEY_ID>
```

4. Revoke the old key on the same page.

The issuer id is the same for every key on the team, so its secret stays.

### ☐ 5. The push key

developer.apple.com → Certificates, IDs & Profiles → Keys.

Look for a key with **Apple Push Notifications service (APNs)** enabled.
If its id matches the file `AuthKey_APNSKEYID0.p8`, you already have it.
If there is none: the plus button → a name such as `household-push` → tick **Apple Push Notifications service (APNs)** → Configure → Environment **Sandbox & Production**, Key Restriction **Team Scoped (All Topics)** → Save, Continue, Register, Download.
Those two settings cannot be changed later.

The push key belongs to the gateways, which send the pushes, not to GitHub.
From PowerShell, at the root of your household-assistant checkout, store it in the household's credential store, as one line of base64 so no line break can be lost on the way (with the push key's id in place of `APNSKEYID0` if you made a new one):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\AuthKey_APNSKEYID0.p8))) | goblins auth store --project household-assistant APNS_AUTH_KEY_P8_BASE64
goblins auth store --project household-assistant APNS_KEY_ID APNSKEYID0
```

Nothing uses it yet.
It is here because Apple offers the file once, and the reminders task will need it.

---

## Part 2 - GitHub

### ☐ 6. The signing key, one command

```powershell
& "$env:ProgramFiles\Git\usr\bin\openssl.exe" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 | gh secret set DISTRIBUTION_CERTIFICATE_KEY --env testflight --repo fpresta0607/household-assistant
```

It makes a private key and pipes it straight into GitHub, so it never sits on the disk.
`gh` answers `Set Actions secret DISTRIBUTION_CERTIFICATE_KEY for fpresta0607/household-assistant`.
The first release turns it into the team's Apple Distribution certificate.

### ☐ 7. Optional: a monthly ceiling at GitHub

Every Mac run is already refused when it could take the day past 5 dollars.
For a second, monthly ceiling: github.com → your picture → Settings → Billing and licensing → Budgets and alerts → New budget → Actions, scoped to the repository household-assistant, an amount such as 40 dollars, and **Stop usage when budget limit is reached**.

---

## Part 3 - The two phones

### ☐ 8. Invite Gia

appstoreconnect.apple.com → Users and Access → People → the plus button.

Her first name, last name, and the email of **her Apple ID**.
Role: **Marketing**, the smallest role that may test.
She gets an email from Apple and accepts it.
She never needs a developer account and never sees the code.

### ☐ 9. The Family testing group

appstoreconnect.apple.com → Apps → Steward AI → TestFlight → Internal Testing → the plus button.

Name it **Family** and tick **Enable automatic distribution**, so every new build reaches both phones without a click.
Then add the testers: you, and Gia once she has accepted.

### ☐ 10. TestFlight on both iPhones

On each iPhone: App Store → search **TestFlight** → Get.
Open it once, signed in with the same Apple ID the invitation went to.

---

## Part 4 - The first build

### ☐ 11. The one click

github.com/fpresta0607/household-assistant → Actions → **ios-release** → Run workflow.
Branch **main**, type **UPLOAD** in the confirmation box, Run workflow.

The GitHub app on your iPhone has the same button: the repository → Actions → ios-release → Run workflow.

Or from PowerShell, at the root of your household-assistant checkout:

```powershell
python scripts\ios-cloud.py testflight
```

It takes about twenty minutes.
The run's summary page says when the build is ready for the Family group and what it cost, about 62 cents.

### ☐ 12. Install it

On each iPhone, TestFlight shows **Steward AI** → Install → Open.
Then pair it with your assistant, as the app shows.

---

## Part 5 - Tidy up

### ☐ 13. Move the key files

Both `.p8` files are in GitHub or the credential store now.
Move `AuthKey_ASCKEYID00.p8` and `AuthKey_APNSKEYID0.p8` out of your household-assistant checkout into your password manager, and delete them from the folder.

### ☐ 14. Lock the keys to main

github.com/fpresta0607/household-assistant → Settings → Environments → **testflight** → Deployment branches and tags → **Selected branches and tags** → Add deployment branch rule → `main`.

From then on only a run on main can read the Apple keys, so a branch someone pushes cannot.
Rehearsals still run, from main.

---

## Every later build

The same one click: Actions → ios-release → Run workflow → main → UPLOAD.
The phones get it by themselves through the Family group.

---

## Related

- [`testflight.md`](testflight.md) - the release, the secrets and what it costs
- [`apple-signing.md`](apple-signing.md) - identifiers, capabilities, the certificate and the profiles
