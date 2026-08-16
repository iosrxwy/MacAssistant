<p align="center">
  <img src="docs/assets/macassistant-hero-brand.png" alt="Mac小助手宣传图" width="960">
</p>

<p align="center">
  <a href="docs/README.zh-CN.md">简体中文</a> ·
  <a href="docs/README.ja.md">日本語</a> ·
  <a href="docs/README.ko.md">한국어</a> ·
  <a href="docs/README.ru.md">Русский</a>
</p>

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/actions/workflows/ci.yml"><img src="https://github.com/iosrxwy/MacAssistant/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/iosrxwy/MacAssistant" alt="MIT License"></a>
  <a href="https://github.com/iosrxwy/MacAssistant/stargazers"><img src="https://img.shields.io/github/stars/iosrxwy/MacAssistant?style=flat" alt="GitHub stars"></a>
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">
  <strong>One native Mac app for system care and Apple-binary work.</strong><br>
  Replace scattered scripts and terminal lookups with clear, previewable workflows.
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
- **IPA** — injection workflows, thinning, header extraction and layered signing
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

## Star goal

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/stargazers"><img src="https://img.shields.io/github/stars/iosrxwy/MacAssistant?style=for-the-badge&logo=github&label=Stars&color=0A84FF" alt="GitHub stars"></a><br>
  <img src="https://progress-bar.xyz/1/?scale=100&title=First%20goal&width=480&color=0A84FF&suffix=%20%2F%20100" alt="First star goal: 1 / 100">
</p>

<p align="center">If MacAssistant saves you time, a star helps more people discover it.</p>

## Download

Get the universal Apple Silicon + Intel build from [Releases](https://github.com/iosrxwy/MacAssistant/releases).

> Requires macOS 13 or later. Developer tools are Beta; keep a backup before modifying files.

## Build

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
open "dist/Mac小助手.app"
```

## Contributing

- **Issue** — bugs, ideas, and usage questions. Use the form; do not open an empty PR to report a problem.
- **Pull request** — code or docs you want merged. CI (`build`) must pass.
- Scope and “will not accept” list: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## Credits

Developed and maintained by **Codex** · Published by [iosrxwy](https://github.com/iosrxwy).

Special thanks to these two optional open-source tools:

- [Theos](https://github.com/theos/theos) — tweak project build environment
- [zsign](https://github.com/zhlynn/zsign) — IPA and Mach-O signing tool

## License

[MIT](LICENSE)
