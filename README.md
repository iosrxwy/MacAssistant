<p align="center">
  <img src="docs/assets/macassistant-hero-brand.png" alt="MacAssistant" width="880">
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">
  One native Mac app for system care and Apple-binary work.
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

## Why MacAssistant

| Everyday Mac tools | Apple developer workflows | Built for confidence |
| --- | --- | --- |
| See system health, reclaim space, repair apps and inspect memory or network state. | Build DEB packages, inspect DYLIBs, process IPAs, edit Mach-O files and manage signing. | Preview-first actions, explicit confirmation, open source and no telemetry. |

## What’s inside

### Daily toolkit

- **System overview** — chip, memory, disk, battery and uptime at a glance
- **Safe cleanup** — caches, logs, Xcode data and other regenerable files
- **App repair** — diagnose signatures, quarantine attributes and launch issues
- **Memory & network** — pressure, processes, ports, ping, DNS and public IP
- **Command library** — 262 searchable macOS commands with risk labels

### Developer toolkit · Beta

- **DEB** — create, inspect, unpack, convert and rebuild packages
- **DYLIB** — inspect dependencies, extract libraries and rewrite install names or rpaths
- **IPA** — drag-in workbench, install and extract (as-is, no FairPlay dump), optional App Store download via local `ipatool` (own Apple ID, still encrypted), injection, thinning, header extraction, layered signing, and Apple ID signing
- **Mach-O** — native Swift inspection and dylib injection for thin or universal binaries
- **Environment check** — find required tools and get guided setup actions

## Screenshots

<p align="center">
  <img src="docs/assets/screenshots/system-cleanup.png" alt="System cleanup" width="49%">
  <img src="docs/assets/screenshots/deb-wizard.png" alt="DEB wizard" width="49%">
</p>

<p align="center">
  <img src="docs/assets/screenshots/ipa-toolbox.png" alt="IPA toolbox" width="49%">
  <img src="docs/assets/screenshots/system-overview.png" alt="System overview" width="49%">
</p>

## Download

Universal Apple Silicon + Intel build: [Releases](https://github.com/iosrxwy/MacAssistant/releases). macOS 13+.

Updates and notes: [X @iOSRXWY](https://x.com/iOSRXWY) · [Telegram](https://t.me/iosrxwy)

### First launch blocked by macOS?

This public beta is **ad-hoc signed and not notarized**. Open the app once, then go to **System Settings → Privacy & Security → Open Anyway**. Do not turn Gatekeeper off.

## Build

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
open "dist/Mac小助手.app"
```

## Stars

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/stargazers"><img src="https://img.shields.io/github/stars/iosrxwy/MacAssistant?style=flat-square&logo=github" alt="GitHub stars"></a>
</p>

<p align="center">
  <img src="https://progress-bar.xyz/1/?scale=100&title=goal&width=420&color=0A84FF&suffix=%20/%20100" alt="Star goal: 1 / 100">
</p>

<p align="center">
  <a href="https://star-history.com/#iosrxwy/MacAssistant&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=iosrxwy/MacAssistant&type=Date&theme=dark">
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=iosrxwy/MacAssistant&type=Date">
      <img alt="Star History" src="https://api.star-history.com/svg?repos=iosrxwy/MacAssistant&type=Date" width="640">
    </picture>
  </a>
</p>

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

[AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign) · [ipatool](https://github.com/majd/ipatool)

None of these binaries are bundled.

## License

[GNU GPL-3.0](LICENSE). Distributed modifications must remain free software under the same license, with complete corresponding source. This does not authorize bundling other projects: `class-dump` is also GPL-3.0 and needs its corresponding source; `dsdump` has no clear license and must not be redistributed; AltStore / AltSign are AGPL-3.0 and are referenced as protocol documentation only.

Security reports: [SECURITY.md](SECURITY.md).
