<p align="center">
  <img src="docs/assets/app-icon.png" width="96" alt="MacAssistant">
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">
  Native macOS toolkit for system care, app clones, app repair, commands, and sideloading.
</p>

<p align="center">
  <a href="docs/README.zh-CN.md">简体中文</a>
  · <a href="docs/README.es.md">Español</a>
  · <a href="docs/README.ko.md">한국어</a>
  · <a href="docs/README.ru.md">Русский</a>
</p>

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/actions/workflows/ci.yml"><img src="https://github.com/iosrxwy/MacAssistant/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/iosrxwy/MacAssistant" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/releases"><img src="https://img.shields.io/badge/Download-Releases-0A84FF?style=flat-square&logo=apple&logoColor=white" alt="Download"></a>
  <a href="https://x.com/iOSRXWY"><img src="https://img.shields.io/badge/X-@iOSRXWY-111111?style=flat-square&logo=x&logoColor=white" alt="X"></a>
  <a href="https://t.me/iosrxwy"><img src="https://img.shields.io/badge/Telegram-@iosrxwy-26A5E4?style=flat-square&logo=telegram&logoColor=white" alt="Telegram"></a>
</p>

<p align="center">
  <img src="docs/assets/macassistant-hero-brand.png" alt="System overview" width="880">
</p>

<p align="center">
  <sub>Live CPU, memory, disk, and battery. Screenshots in Simplified Chinese; six languages are in About.</sub>
</p>

## Everyday features

<table>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="docs/assets/screenshots/system-cleanup.png" alt="System cleanup" width="430">
      <br>
      <b>Cleanup</b><br>
      Preview caches, Derived Data, Docker, and Time Machine before anything is deleted. Home directory only.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="docs/assets/screenshots/app-clones.png" alt="App clones" width="430">
      <br>
      <b>App clones</b><br>
      Isolated WeChat, browser, and editor copies — own data, optional per-clone proxy.
    </td>
  </tr>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="docs/assets/screenshots/desktop-icons.png" alt="Desktop icons" width="430">
      <br>
      <b>Desktop icons</b><br>
      Recolor Finder icons, or replace them with clay stickers, folder costumes, and AI folders.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="docs/assets/screenshots/ipa-workbench.png" alt="IPA workbench" width="430">
      <br>
      <b>IPA workbench</b><br>
      Drag in an IPA, inject plugins, thin, dump headers, and sign. Beta.
    </td>
  </tr>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="docs/assets/screenshots/mac-inject.png" alt="Mac app injection" width="430">
      <br>
      <b>Mac app injection</b><br>
      Inject a dylib into a local <code>.app</code>, or copy first, then inject. Beta.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="docs/assets/screenshots/environment.png" alt="Environment check" width="430">
      <br>
      <b>Environment check</b><br>
      Find missing tools (Theos, zsign, Homebrew, codesign…) and get setup steps.
    </td>
  </tr>
</table>

### More features

| Daily | Developer |
| --- | --- |
| App repair (“damaged” launches, quarantine, signatures, automatic update checks) | DEB create, inspect, convert, rebuild |
| Menu bar: battery, Wi-Fi, volume, Bluetooth, energy mode | Scan and remove injected plugins from a Mac app |
| Uninstall an app to the Trash (system apps stay) | DYLIB dependencies, install names, rpaths |
| Live memory pressure, process list, freeze and resume | |
| Network: throughput, ports, ping, DNS, public IP | IPA install / extract as-is (no FairPlay dump) |
| Searchable command library with risk labels | Mach-O inspection and class-dump |
| Quick toggles for Finder, screenshots, hidden files | Layered signing and Apple ID signing |

Preview before destructive actions. Open source, no telemetry.

Page backgrounds, sidebar glass, icon colors, and six interface languages live in **About**.

## Download

Universal Apple Silicon + Intel: [Releases](https://github.com/iosrxwy/MacAssistant/releases). macOS 13+.

Updates: [X @iOSRXWY](https://x.com/iOSRXWY) · [Telegram](https://t.me/iosrxwy)

### First launch blocked by macOS?

> [!IMPORTANT]
> This release is **ad-hoc signed and not notarized**. Open the app once, then go to **System Settings → Privacy & Security → Open Anyway**. Do not turn Gatekeeper off.

## Build

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
open "dist/Mac小助手.app"
```

## Contributors

<table>
  <tr>
    <td align="center" width="120">
      <a href="https://github.com/iosrxwy"><img src="https://github.com/iosrxwy.png?size=120" width="72" height="72" alt="iosrxwy"></a><br>
      <a href="https://github.com/iosrxwy"><b>iosrxwy</b></a><br>
      <sub>Author</sub>
    </td>
    <td align="center" width="120">
      <a href="https://github.com/codex"><img src="https://github.com/codex.png?size=120" width="72" height="72" alt="Codex"></a><br>
      <a href="https://github.com/codex"><b>Codex</b></a><br>
      <sub>Development</sub>
    </td>
    <td align="center" width="120">
      <a href="https://x.ai/grok"><img src="https://github.com/xai-org.png?size=120" width="72" height="72" alt="Grok Build"></a><br>
      <a href="https://x.ai/grok"><b>Grok Build</b></a><br>
      <sub>Development</sub>
    </td>
  </tr>
</table>

<p align="center">
  <a href="https://x.com/iOSRXWY">X</a>
  · <a href="https://t.me/iosrxwy">Telegram</a>
  · <a href="https://github.com/iosrxwy">GitHub</a>
  · <a href="CONTRIBUTING.md">Contributing</a>
</p>

## Thanks

[AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign) · [ATBClone](https://github.com/aitobox/ATBClone)

Folder looks are redrawn from the idea of [Moonvy Folder Dressing](https://moonvy.com/apps/dir-hz/). Their artwork is not included. Clay stickers and AI folders are original drawings.

## License

[GNU GPL-3.0](LICENSE). Distributed modifications must remain free software under the same license, with complete corresponding source.

Security reports: [SECURITY.md](SECURITY.md).
