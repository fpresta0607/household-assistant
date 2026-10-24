# The iOS app

One app, two people.
Franco's phone talks to Corey, Gia's phone talks to Denise, and both talk to the same backend on the Linux VPS.

The VPS stays authoritative for memory, reminders, calendar state, lists, authentication and assistant logic.
The app is a client, and the Mac in the corner is a build appliance and a speech host, never a source of truth.

## What is here

Steward AI is a native client of the OpenClaw gateway WebSocket protocol, version 4.
Each phone pairs with one gateway, and the assistant's name and emoji come from that gateway, never from the app.

| directory | what it holds |
|---|---|
| `HouseholdAssistant/Protocol` | the codec, the device identity and its signature, the connection state machine, and `Fixtures/`, frames captured from the live gateway |
| `HouseholdAssistant/Model` | the transcript buffer, Talk's hands-free loop and the view models; no SwiftUI |
| `HouseholdAssistant/Views`, `Voice`, `Design`, `Intents`, `App` | Chats and Settings under the glass tab bar, with Talk as its accessory and the thread behind each conversation, Talk, Siri's App Intent and what Talk's does in the app, and the app's object graph |
| `HouseholdAssistant/Media` | what a message carries, readied on the phone: attachments from Photos, the camera, Files, the scanner and Contacts, thumbnails, link previews, and saving to Photos |
| `HouseholdAssistantWidgets` | the widgets: a conversation, the assistant's thread or the family room, on the Home Screen and the Lock Screen, the Lock Screen's Talk button, and the Talk control for Control Center |
| `HouseholdAssistantNotifications` | the notification extension: opens each sealed notification and shows it as a message from whoever wrote it, with their face |
| `HouseholdAssistantShare` | the Share Extension: Steward AI in every app's Share Sheet, handing photos, videos, files, links and words for the family room or the assistant's thread to the app through the App Group, which sends them signed |
| `Shared` | the palette, the widgets' views and the Talk intent, compiled into both the app and the widget extension, so the screenshot tests draw the widgets |
| `HouseholdAssistantTests` | unit tests; every fixture is decoded, the connection is driven by the captured frames, and `ScreenshotTests` renders every screen and state to `build/screenshots/` |
| `HouseholdAssistantUITests` | launches the app and checks it stays in the foreground |

**None of the Swift that needs SwiftUI or UIKit has been compiled yet.**
There is no Mac in the fleet, so the first build on the Mac runner is the first build there has been.

`Protocol` and `Model` need neither, and they are compiled and tested on Linux:

```bash
# verified
docker run --rm -v "$PWD/apps/ios:/src:ro" swift:6.1-jammy   bash -c 'cp -r /src /work && cd /work && swift test'
```

`Package.swift` exists only for `swift test`, which the `swift-test` job in `ios-ci.yml` runs in that same container on every pull request touching the paths that workflow watches.
It is not how the app is built.

## There is no `.xcodeproj` here either

`project.yml` is the project.
XcodeGen turns it into a real one on the Mac, every run, and `.gitignore` keeps the generated result out of the repository.

A binary Xcode project cannot be reviewed in a pull request and conflicts on every concurrent branch.
This can be read, and it cannot conflict in a way a person cannot resolve.

```bash
# not yet run on Apple hardware
xcodegen generate --spec apps/ios/project.yml --project apps/ios
```

In practice nobody runs that by hand, because each script below does it first:

```bash
# not yet run on Apple hardware
../../scripts/macos/test-ios.sh         # generate, build, test on a simulator
../../scripts/macos/screenshots-ios.sh  # generate, build, render every screen and state to build/screenshots/
../../scripts/macos/build-ios.sh        # generate, archive for distribution
```

## Before this will sign

The bundle identifiers all start with `com.siqstack`, the registered prefix; `com.example` was the placeholder until the App IDs existed.
`scripts/macos/verify.sh` and `scripts/macos/build-ios.sh` still refuse the `com.example` prefix, so they now fire only if it is ever reverted.

The project declares **one entitlement**: the App Group `group.com.siqstack.stewardai`, on the app and on the widget, because the widget reads what it shows from there.
An entitlement the App ID does not carry breaks automatic signing, so the App Group has to be enabled on both App IDs before the first signed build.
[`docs/apple-signing.md`](../../docs/apple-signing.md) says how, and which capabilities are still to come.

## Details worth knowing

- **iOS 26.0** is the deployment target, for Liquid Glass.
- **Swift 5 language mode with complete concurrency checking**, so the first build reports isolation findings as warnings instead of stopping on them.
- **One dependency**, pinned to one exact release in `project.yml` (the comment there says why the markdown package is pinned by commit, and why it also pins `swift-syntax`, which no target links): Microsoft's `SwiftStreamingMarkdown` for the assistant's replies.
- The **widget extension is embedded in the app**, which means the pipeline signs and uploads an app extension from the first run rather than discovering that work at release time.
- The **unit test bundle is hosted in the app**, with `TEST_HOST` and `BUNDLE_LOADER` written out rather than inferred, so `@testable import HouseholdAssistant` works regardless of which XcodeGen version generates the project.
- `ITSAppUsesNonExemptEncryption` is `false`: the app's one use of cryptography is a CryptoKit signature that authenticates the device, which is exempt, and the flag stops every TestFlight upload from waiting on an export compliance question.
- The **app icon** is in the asset catalogue, and again as `StewardIcon` for the screens that show the app's own mark.

## The look

The look is light first: frosted glass with a soft rainbow sheen on a warm white to pale sky background, and dark mode on the icon's navy with gold glass rims and no rainbow.
Royal blue belongs to the person and their controls, gold to the assistants.

Royal blue and gold are accents, shimmers and glimmers, never full fills (the owner's rule, 15 October 2026, for every new feature).
They go on rims, highlights, small marks, the selected state's ring or lens, and the light running round a rim, always on the light rainbow glass.
A surface, a card, a sheet, a button or a chip is glass or white, and its royal or gold is the edge, the glyph or the shimmer on it.
The assistant's bubble is the model: a white fill with a rim that shimmers, the soft rainbow in the light and gold glass in the dark as the app ships.
Settings → Appearance has two controls: Theme, then Light, Dark or Auto, which follows the iPhone.
The [appearance reference](../../docs/ios/appearance-themes.md) describes the theme collection and how each theme applies across the app.
The chat preview follows the selected appearance.
Existing seasonal choices migrate to their theme family.
The former custom editor, arbitrary colors, background photos, material sliders and component overrides have been removed.
The person's own message bubble keeps its royal fill as built, and nothing new is filled royal or gold.
Every shimmer stands still under the app's Reduce Motion choice.
