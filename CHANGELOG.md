# Changelog

All notable changes to MacAssistant are recorded here.

## [1.0.5] - 2026-10-30

Ad-hoc signed; not notarized by Apple. Update from **About → Check for updates**.

### Added

- **Menu bar**: one icon shows battery, Wi-Fi, and volume. Connect or disconnect Bluetooth devices, and switch Auto / Low Power / High Power. One admin prompt lasts for the rest of this launch. The icon stays after the window closes.
- **App uninstall**: move an app and its support files, caches, and preferences in your home library to the Trash. System apps and the running copy of Mac Assistant are left alone.
- **Desktop icons**: 16 original clay stickers, 8 folder costumes, and 9 AI folders (Codex, GPT, Claude, Grok, Grok Bot, DeepSeek, Kimi, GLM, Muse). Folder looks are inspired by [Moonvy Folder Dressing](https://moonvy.com/apps/dir-hz/) and redrawn, not their artwork. AI folders use familiar colors and marks and are not official logo files. Picking one replaces the whole icon.
- **Mac apps**: scan injected third-party plugins, remove the load command, and optionally delete the plugin and re-sign.
- **Repair**: turn off automatic macOS update checks, downloads, and installs. This does not spoof the system version. System Settings → General → Software Update can still install updates.

### Improved

- **Memory**: freeze an app's main process and helpers together. Paused processes stay in the list and can be resumed.

### Fixed

- Decorative page backgrounds no longer cover the sidebar and content.
- The close, minimize, and zoom buttons, and the sidebar toggle, stay above the page.

## [1.0.4] - 2026-09-08

Ad-hoc signed; not notarized by Apple. Update from **About → Check for updates**.

### Added

- **App Clones**: soft/hard clones of WeChat, browsers, and editors with isolated data; update, delete, and per-clone proxy
- Move “New Instance” onto App Clones; rename the injection-page copy action to avoid the name clash
- **Desktop Icons**: customize Finder icons for desktop files, folders, and apps, with color and type presets
- **Page backgrounds**: palettes such as Sky, Music, Notes, Freeform, Shortcuts, Podcasts, Things, Arc, Linear, Night Green, and Starfield (About or the View menu); title bar, sidebar, and content share one scene
- **Motion**: optional animated backgrounds. Clouds and motes drift slowly and part around the pointer
- **Appearance**: System / Light / Dark (Night Green and Starfield still use a dark recipe so light text does not sit on a dark scene)
- **Icon color**: monochrome, color, the same default palette as Desktop Icons, or a custom color. Each click of Color reshuffles sidebar icon tints
- **Languages**: Traditional Chinese, Korean, Spanish, and Russian in addition to Simplified Chinese and English (no Japanese)

### Improved

- Text fields on feature pages use a thin material fill instead of a solid white rounded border
- System Cleanup now covers system data, developer caches, Docker, and Time Machine snapshots; still home-directory only
- Overview and Network show live CPU, memory pressure, battery, and throughput; the memory row opens Memory tools
- DNS flush and quit-by-port move to Network
- App Repair and Quick Toggles are searchable; related pages state the permissions they need
- Development builds use a stable local certificate so overwrite installs keep TCC grants
- Environment check copy for `dsdump` and `xtool` is more accurate

### Fixed

- About → Sidebar: Translucent now actually shows the desktop or the page scene; it previously looked identical to System material
- Injection page no longer nags when App Management cannot be probed
- Memory tools process list updates when an app quits, instead of staying on the snapshot from when the page opened

## [1.0.3] - 2026-09-03

- Fix a launch crash on macOS 15.0–15.1
- Fix the non-rounded app icon on some devices
- Improve plugin injection:
  - Dropping a DEB no longer blocks packages with maintainer scripts
  - Stop incorrectly rewriting system libraries, which slowed injection

## [1.0.2] - 2026-08-31

- Improve automatic jailbreak-dependency rewriting during IPA injection
- Fix process-file handling when importing a Douyin IPA for header extraction
- Polish UI and improve the overall experience

## [1.0.1] - 2026-08-29

First official release after `v1.0.0-beta.4`. Ad-hoc signed; not notarized by Apple. Chinese: [CHANGELOG.zh-CN.md](CHANGELOG.zh-CN.md).

- Injection is handled in the workbench. An IPA, plugins, certificate, and profile can be selected together. Plugins are injected into the main executable by default; ProtobufLite must be chosen explicitly.
- Signing is optional: none, Apple ID, or P12. A matching p12 and profile uses certificate signing. The password is shown in clear text and defaults to `1`. iPhone IPAs use zsign; Mac apps still use `codesign`.
- Output is `*.injected.ipa` in the same folder as the original IPA.
- Display name, bundle ID, and version can be edited. Files sharing, URL-scheme removal, and deletion of Watch, extensions, or App Clips are supported.
- WeChat IPAs receive a dedicated dark-icon fix.
- Memory and dashboard values match Activity Monitor.
- Cleanup no longer reports an inaccessible folder as empty.
- App Store download has been removed. Install, extract, inject, and resign remain.

If the first launch is blocked: **System Settings → Privacy & Security → Open Anyway**. See [README](README.md#first-launch-blocked-by-macos).

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

[1.0.5]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.5
[1.0.4]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.4
[1.0.3]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.3
[1.0.2]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.2
[1.0.1]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.1
[1.0.0-beta.4]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.0-beta.4
[1.0.0-beta.3]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.0-beta.3
[1.0.0-beta.2]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.0-beta.2
[1.0.0-beta.1]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.0-beta.1
