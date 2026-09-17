# AppRay

A macOS tool for Mac admins. Drop an application — macOS or iOS — on it and it
reads what that app can reach — usage descriptions, entitlements, linked frameworks, nested
helpers — then builds the MDM configuration that matches: a **PPPC profile**
(`.mobileconfig`) and a **DDM declaration** (`com.apple.configuration.app.settings`).

![The overview of an analysed app](docs/overview.png)

## Why

Writing a PPPC profile by hand means running `codesign -dvvv`, running
`codesign -d -r-` for the designated requirement, grepping `Info.plist` for
`NS*UsageDescription` keys, and then assembling XML — or, for declarative
management, assembling the *composed identifier*:

```
com.example.app {identifier "com.example.app" and anchor apple generic}
```

That last one is a reliable source of mistakes. This app builds it for you and
shows you what it is doing.

## What it shows

| Section | Contents |
| --- | --- |
| **Overview** | Icon, name, version, bundle ID, team ID, Gatekeeper verdict, architectures, SDK, URL schemes — and the two strings MDM targets the app by |
| **Privileges** | Every privacy-relevant capability found, grouped by how strong the evidence is, with the literal `Info.plist` key or entitlement that triggered it |
| **Signature** | Designated requirement, CDHash, signature verification, certificate validity, notarization, certificate chain, full entitlements tree, linked frameworks |
| **Components** | Privileged helpers, login items, XPC services, system extensions and plug-ins, each with its own team ID and requirement |

Every value copies to the clipboard on click.

### iOS and iPadOS apps

An iOS bundle is laid out flat — `Info.plist`, the executable and
`_CodeSignature` all at the top level, no `Contents` — so AppRay works out
which shape it is looking at before it reads anything, and says which one it
found. An iOS app installed on an Apple silicon Mac arrives inside a wrapper
bundle; AppRay follows `WrappedBundle` into it and tells you it did.

What changes for an iOS app:

- **Extensions instead of helpers.** `PlugIns` and `Extensions` hold `.appex`
  bundles, and `Watch` an embedded watch app. A privileged helper or a login
  item cannot exist, so neither is looked for.
- **`MinimumOSVersion` instead of `LSMinimumSystemVersion`.**
- **Gatekeeper is not asked.** It rejects every iOS bundle on sight, because
  macOS cannot run one. That verdict says nothing about the app, so it is not
  put on screen. The signature is still verified.
- **The macOS judgement calls are not offered.** iOS has no Accessibility, Full
  Disk Access, Input Monitoring or Send Keystrokes to decide about.
- **The iOS-only subjects are surfaced.** Face ID, Motion & Fitness, Health,
  Siri, Tracking, HomeKit, Focus Status, Notifications, Identity Documents and
  Alarms are read out of `Info.plist` and shown — marked, plainly, as things no
  MDM channel carries.

### Validity, and the part people get wrong

The Signature tab answers whether the app will actually run, and keep running:

- **Signature** — verified against every sealed resource in the bundle, strictly,
  the way Gatekeeper does it. A bundle someone dropped a file into fails here.
- **Signing certificate** — the full validity window and how many days are left,
  with a warning from 60 days out.
- **Secure timestamp** — present or not.
- **Notarization** — notarized, not notarized, Apple system software or App
  Store, read from the rule `spctl` says matched.
- **Stapled ticket** — separate from notarization, because it is not the same
  question.

The certificate and the timestamp interact, and AppRay spells the result out
rather than leaving you to work it out:

> An **expired certificate with a secure timestamp** is fine — the timestamp
> proves the app was signed while the certificate was valid, and macOS accepts
> it. An **expired certificate without one** genuinely breaks the app and it
> needs re-signing. A **live certificate without a timestamp** works today and
> stops working the day the certificate expires.

### Three levels of confidence

The analyzer never guesses silently:

- **Declared by the app** — a usage description or an entitlement says so outright.
- **Inferred from the binary** — the executable links a framework that needs it
  (ScreenCaptureKit, CoreLocation, EndpointSecurity …) but nothing declares it.
  Not pre-selected for export.
- **Requires your judgement** — Accessibility, Full Disk Access, Input Monitoring
  and Send Keystrokes leave no trace whatsoever in a bundle. They are offered,
  never assumed.

## What it exports

Both outputs are generated from the same set of decisions, and the app is
explicit about what each channel cannot carry.

**PPPC profile** — a `com.apple.TCC.configuration-profile-policy` payload,
device-scoped, using the modern `Authorization` key.

**DDM declaration** — `com.apple.configuration.app.settings` with
`Privacy.PermissionDefaults`, macOS 27 and later, supervised enrollment.

### The honest limits

These are enforced by the app, not buried in a footnote:

- **Camera, Microphone and Screen Recording cannot be granted by any profile.**
  Apple's own schema says a profile "can't grant access … it can only deny it".
  Select Allow for one of these and it is dropped from the profile, with the
  reason shown.
- **DDM privacy keys can only pre-approve, never deny.** A Deny decision has no
  DDM representation and is reported as an omission.
- **Full Disk Access, Screen Recording, Apple Events and the folder services
  have no DDM privacy key.** They stay PPPC-only.
- **Camera, Microphone, Accessibility, Speech Recognition and Bluetooth are
  deprecated as PPPC keys in macOS 27**; the app flags each one and points at
  its DDM successor.
- **Apple Events needs a receiving app.** All three `AEReceiver*` keys are
  required, so the service is left out until you supply a receiver.

Anything left out of an export is listed above the preview. Nothing is dropped
quietly.

### What an iOS app can and cannot be told to do

Both channels state their iOS limit above the preview, before anything is
generated:

- **There is no PPPC payload on iOS.** Apple's own schema lists
  `com.apple.TCC.configuration-profile-policy` as `introduced: n/a` for iOS, so
  a profile never reaches an iPhone or iPad. Whether one matches an iOS app
  running on a Mac, **AppRay does not know** — nobody has verified it, and the
  app says so rather than guessing.
- **A declaration is keyed differently.** Apple's schema: "In iOS, the app
  identifier is a bundle ID." There is no composed identifier and no designated
  requirement, so AppRay writes the bundle ID on its own. The requirement is
  still read and shown, labelled as something nothing on iOS uses.
- **The declaration does not reach an iOS app on a Mac.** Apple's note on the
  privacy defaults says "Only AppKit-based apps on macOS support this feature",
  and an iOS app on a Mac is UIKit.
- **The iOS-only subjects have no channel at all.** Face ID, Health, Motion,
  Siri, Tracking and the rest have no TCC service and no DDM privacy key on any
  platform. They are reported, then listed as omissions with that reason.

## Building

Requires Xcode 26 or later and macOS 26 or later.

```bash
open AppRay.xcodeproj    # or: ./scripts/build.sh
```

The app builds ad-hoc signed so it works on any machine without a team — set
your own team in Xcode under Signing & Capabilities to notarize and distribute
it.

Run the tests with:

```bash
xcodebuild -project AppRay.xcodeproj -scheme AppRay test
```

Some tests cross-check the analyzer against `codesign` on real system apps, and
validate a generated profile with `plutil -lint`. The iOS tests run against a
real bundle from an installed simulator runtime and skip themselves on a
machine that has none.

You can also point it at an app from the command line:

```bash
open -a AppRay /Applications/Google\ Chrome.app
```

## Design notes

**`BundleLayout` is the only place bundle structure is described.** Nothing
else hard-codes `Contents/`. It is what resolves a dropped `.app` into a
platform and a set of directories, and every reader takes it as an argument.

**The wrapper path is written from documentation, not from a sample.** No iOS
app from the Mac App Store was installed on the machine this was built on, so
`wrappedBundleURL(in:)` has never been run against a real wrapper. It is kept
in its own function, marked, so it can be corrected on its own.

**Not sandboxed, hardened runtime on.** The app reads bundles anywhere on disk
and runs `spctl` and `stapler` to determine Gatekeeper state. Everything else —
signing identity, entitlements, designated requirement, CDHash — comes straight
from Security.framework, with no subprocess and no output parsing.

**The project file is checked in and rarely changes.** `AppRay.xcodeproj` uses
synchronized folder groups, so `Sources/` and `Tests/` are folder references —
adding a file on disk is enough, the project does not need editing and the
`.pbxproj` stays out of your diffs.

**Verification runs separately.** Verifying every sealed resource and asking
Gatekeeper each take seconds on a bundle the size of Chrome, so they run
concurrently on a background task while the rest of the analysis (under 100 ms
for the same app) lands first. The validity rows fill themselves in.

**`Reference/`** holds the two Apple schema files the exporters are written
against, vendored so the tests do not depend on the network:

- [`com.apple.TCC.configuration-profile-policy.yaml`](Reference/com.apple.TCC.configuration-profile-policy.yaml)
- [`com.apple.configuration.app.settings.yaml`](Reference/com.apple.configuration.app.settings.yaml)

Both come from [apple/device-management](https://github.com/apple/device-management),
which is MIT licensed; Apple's notice is kept alongside them in
[`Reference/LICENSE-apple-device-management.txt`](Reference/LICENSE-apple-device-management.txt).

## Prior art

[Show Me Your ID 3.0](https://hcsonline.com/support/resources/apps/show-me-your-id)
does the drag-and-drop-for-a-code-requirement part. This app aims to cover the
rest of the trip to a working MDM payload.

## Licence

MIT — see [LICENSE](LICENSE).
