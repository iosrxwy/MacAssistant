# Changelog

All notable changes to MacAssistant are recorded here.

## [1.0.0-beta.4] - 2026-08-19

Patch over 1.0.0-beta.3. Users on 1.0.0-beta.3 can pick this up from **About → Check for updates**.

### Highlights

- Fix App Store version-list compilation on the GitHub Actions macOS 14 / Swift 5.10 runner (`Task.detached` no longer captures a mutable array). 1.0.0-beta.3’s local build succeeded, but CI did not.

### Validation

- Local `swift test` and `swift build`.
- GitHub Actions `build` on `macos-14` must be green before this tag is published.

### Distribution note

This prerelease is ad-hoc signed and not notarized. macOS may block the first launch. Open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Full steps: [README](README.md#first-launch-blocked-by-macos).

## [1.0.0-beta.3] - 2026-08-18

Third public prerelease. Users on 1.0.0-beta.2 can pick this up from **About → Check for updates** or from [Releases](https://github.com/iosrxwy/MacAssistant/releases).

### Highlights

- IPA toolbox now has Install / Extract: sideload a signed IPA with upgrade or keep-data downgrade, package a local `.app` / `.xcarchive` / Payload, or export an app from a device as-is. FairPlay dump is still out of scope.
- Keep-data downgrade raises `CFBundleVersion` and re-signs so iOS treats the older package as an upgrade. Encrypted store IPAs are rejected on this path.
- Optional local `ipatool` (MIT, not bundled): sign in with your own Apple ID, search the App Store, list older versions, and download the official encrypted IPA. Install it from Environment Check with Homebrew.
- Official store packages stay FairPlay-encrypted. They are not sideloadable developer IPAs and cannot use keep-data downgrade.

### Validation

- `swift test`: 348 tests passed (2 skipped).
- Live `ipatool` 2.3.2: missing App Store login is reported as not signed in, not as a crash.
- Local IPA packaging, encrypted-copy reporting, and keep-data build bump covered by tests.
- Universal release build: successful.
- Strict local code-signature verification: successful.

### Distribution note

This prerelease is ad-hoc signed and not notarized. macOS may block the first launch. Open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Full steps: [README](README.md#first-launch-blocked-by-macos).

## [1.0.0-beta.2] - 2026-08-18

Second public prerelease. Users on 1.0.0-beta.1 can pick this up from **About → Check for updates** or from [Releases](https://github.com/iosrxwy/MacAssistant/releases).

### Highlights

- IPA drag-in workbench: drop an IPA, plugins, frameworks, and profiles, then run a previewable recipe pipeline. The six-step wizard remains as advanced mode.
- Apple ID signing, certificate library, connected-device listing, and provisioning-profile capability checks. Credentials stay in the Keychain; AltSign / xtool binaries are not bundled.
- DEB page is now one row of modes: Theos plugin, quick pack, convert, and inspect. Incoming “pack as DEB” drafts open Quick pack directly.
- DYLIB analysis snapshot is richer; Mach-O and extract sources accept drag-and-drop and multiple files.
- Language switch lives on About, next to update checks. First-launch Gatekeeper steps are in the README, because About is unreachable while macOS is blocking the app.
- CI runs `swift test`. Kit tests are in the repository. Release script records Hardened Runtime entitlements and a documented notarization path.
- License changed from MIT to GNU GPL-3.0.

### Validation

- Universal release build: successful.
- Strict local code-signature verification: successful.

### Distribution note

This prerelease is ad-hoc signed and not notarized. macOS may block the first launch. Open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Full steps: [README](README.md#first-launch-blocked-by-macos).

## [1.0.0-beta.1] - 2026-08-15

First public prerelease.

### Highlights

- Native SwiftUI workspace for macOS maintenance, diagnostics, and command discovery.
- End-to-end DEB creation, inspection, conversion, and Theos project workflows.
- DYLIB dependency inspection, extraction, and rpath editing.
- IPA injection, plugin planning, thinning, Class Dump, and layered signing tools.
- Pure-Swift Mach-O dylib injector with thin and universal-binary support.
- System cleanup, memory pressure, process, network, app repair, and quick-toggle tools.
- English and Simplified Chinese app UI; documentation in English, Chinese, Japanese, Korean, and Russian.
- Universal `x86_64 + arm64` development build with SHA-256 checksum.

### Validation

- Universal release build: successful.
- Strict local code-signature verification: successful.

### Distribution note

This prerelease is ad-hoc signed and not notarized. macOS may block the first launch. Open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Full steps: [README](README.md#first-launch-blocked-by-macos).

[1.0.0-beta.4]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.0-beta.4
[1.0.0-beta.3]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.0-beta.3
[1.0.0-beta.2]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.0-beta.2
[1.0.0-beta.1]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.0-beta.1
