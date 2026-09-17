# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS SwiftUI app for Mac admins. You drop an application bundle on it; it reads
the app's privilege surface and code signature, then generates the two MDM payloads
that match: a PPPC `.mobileconfig` and a `com.apple.configuration.app.settings` DDM
declaration. See `README.md` for the user-facing description.

Requires Xcode 26+ and macOS 26+. Deployment target is macOS 26.0; the UI uses
Liquid Glass APIs (`glassEffect`, `.buttonStyle(.glassProminent)`, `ToolbarSpacer`).

## Credits

Sorted by surname, ignoring the Dutch tussenvoegsel. This list mirrors the
About panel credits in `Sources/AppRay/App/AppRayApp.swift` — keep the two in
sync when adding a contributor.

- Bastiaan de Beer ([bastiaandb](https://github.com/bastiaandb))
- Ralf Deuze ([MacScully76](https://github.com/MacScully76))
- Sander Schram ([macbofh](https://github.com/macbofh))
- Erik Stam ([erikstam](https://github.com/erikstam))
- Rens Verhoeven ([renssies](https://github.com/renssies))
- Mike Vos ([vosmike](https://github.com/vosmike))

## Commands

```bash
./scripts/build.sh                 # Debug build, prints the .app path
./scripts/build.sh Release

xcodebuild -project AppRay.xcodeproj -scheme AppRay -derivedDataPath build test

# One suite or one test — the identifier is the Swift Testing *type* name,
# not the @Suite display string.
xcodebuild -project AppRay.xcodeproj -scheme AppRay -derivedDataPath build test \
  -only-testing:AppRayTests/NotarizationStatusTests
xcodebuild -project AppRay.xcodeproj -scheme AppRay -derivedDataPath build test \
  -only-testing:AppRayTests/DDMDeclarationTests/composedIdentifier

# Point the built app at a bundle without dragging (AppDelegate handles this).
open -a "$(./scripts/build.sh)" /Applications/Google\ Chrome.app
```

The app icon is `Resources/AppIcon.icon`, edited in Icon Composer
(`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`), not in the
asset catalog. `scripts/generate_icon.swift` predates that and writes to an
`AppIcon.appiconset` that no longer exists — it is dead and should not be run.

There is no linter and no CI.

## Project conventions

**The `.xcodeproj` is checked in. Do not introduce XcodeGen, Tuist, or a
`project.yml`** — the repo deliberately moved away from that. `Sources/` and
`Tests/` are *synchronized folder groups*, so adding a `.swift` file on disk is
enough; the `.pbxproj` does not need editing and should stay out of diffs. If a
change does touch the project file, that is a signal worth mentioning.

**Commits use the personal identity, not the work one.** Author is
`macbofh <1550491+macbofh@users.noreply.github.com>` and the bundle ID prefix is
`com.macbofh.*`. The global git config on some machines supplies a Secrid work
address; check `git log --format='%an <%ae>'` before the first commit on a new
device. Public repo: <https://github.com/macbofh/appray-macos>.

**The app is intentionally not sandboxed**, with Hardened Runtime on. It reads
bundles anywhere on disk and runs `spctl`/`stapler`. Do not add App Sandbox.

**Signed ad-hoc** (`CODE_SIGN_IDENTITY = "-"`) so the project builds on any
machine without a team. There is no Developer ID certificate available, so the
app cannot be notarized or distributed yet.

## Architecture

Four layers, one direction of dependency: `Model` ← `Analysis` ← `Export`/`UI`.

**`Model/`** — plain value types, all `Sendable` and `Hashable`.
`PlistValue` is a recursive enum replacing `[String: Any]` so parsed plists can
cross actor boundaries and drive SwiftUI diffing. `PrivilegeService` is the
domain core: one enum case per TCC service, each knowing its PPPC key, its
`PPPCSupport` (grant-and-deny / deny-only / unsupported), its DDM privacy key,
and whether Apple deprecated it in macOS 27.

**`Analysis/`** — `AppAnalyzer` orchestrates. It runs in two phases on purpose:

1. `analyzeSynchronously` is fast (<100 ms even for Chrome) and produces
   `AnalyzedApp` with `trust: nil`.
2. `assessTrust` runs `spctl` and a strict signature verification *concurrently*
   on a background task; each takes seconds on a large bundle. `InspectorModel`
   assigns the result afterwards and the UI fills in.

Anything slow belongs in phase 2. `AnalyzedApp.trust` being optional is what
lets the UI show pending rows — do not collapse it.

`CodeSignatureReader` uses Security.framework directly (`SecStaticCodeCreateWithPath`,
`SecCodeCopySigningInformation`, `SecCodeCopyDesignatedRequirement`). No
subprocess, no parsing of `codesign` output. `GatekeeperReader` is the only
place that shells out.

`PrivilegeCatalog` maps evidence → findings with a `Confidence`:
`declared` (usage description or entitlement), `inferred` (framework linkage),
`manual` (Accessibility, Full Disk Access, Input Monitoring, Send Keystrokes —
these leave no trace in a bundle and are never assumed). Only `declared`
findings are pre-selected for export. Adding a detection rule means adding a
row to one of the dictionaries at the top of that file.

**`Export/`** — `ExportPlan` holds the admin's decisions plus pre-generated
UUIDs (generated once, so the live preview does not churn). Both builders are
pure functions of `(AnalyzedApp, ExportPlan)`.

## Domain rules that are easy to get wrong

These are enforced in code and covered by tests. Verify against
`Reference/*.yaml` (Apple's own schemas, vendored, MIT) before changing any of
them — not from memory.

- **Only Camera, Microphone and ScreenCapture are PPPC deny-only.** Apple's
  schema says "can't grant access … can only deny it" for exactly those three.
  Contacts, Calendar, Reminders, Photos and Bluetooth *can* be granted.
- **DDM privacy keys can only pre-approve, never deny.** A Deny decision has no
  DDM representation.
- **`SpeechRecognition` (PPPC) is `Dictation` (DDM)** — same service, two names.
- **Location and LocalNetwork have no PPPC key at all.**
- **The DDM composed identifier is `bundleID {designated requirement}`** — braces,
  requirement verbatim, no escaping.
- **A PPPC entry carries `Authorization` or `Allowed`, never both.** This code
  uses `Authorization`.
- **`AppleEvents` requires all three `AEReceiver*` keys**, so it is dropped from
  the profile until a receiver is supplied.
- **An expired signing certificate does not break an app that has a secure
  timestamp.** `CodeSignature.isExpiryABlocker` encodes this; do not simplify it
  to "expired = bad".

Anything an export channel cannot carry is surfaced through
`ExportPlan.omissions(in:)` and shown above the preview. Never drop a selected
service silently.

## Verification gotchas

- `SecStaticCodeCheckValidity` **must** use `kSecCSStrictValidate`. Without it,
  files added to a bundle after signing are tolerated and tampering reads as
  valid.
- A **copy of a system app cannot be strictly validated** — it is off the sealed
  system volume. The tamper test uses AppRay's own bundle (`Bundle.main.bundleURL`,
  which is the host app under test) for this reason.
- Several tests run against real bundles on the machine and are gated with
  `.enabled(if: FileManager.default.fileExists(...))`, so they skip rather than
  fail on a machine without Chrome.
- UI automation is not available (osascript lacks Accessibility permission here).
  To check a screen visually: temporarily change the default `InspectorModel.section`,
  build, `open -a`, then `screencapture -l<windowID>` — and **revert the temporary
  change afterwards**. `docs/overview.png` in the README is produced this way.
- After changing the project file or build settings, verify with a fresh
  `git clone` into a temp directory followed by `xcodebuild … test`, not just the
  working copy — that is what catches a project that depends on local state.
