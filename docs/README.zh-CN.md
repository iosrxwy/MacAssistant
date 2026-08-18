<p align="center">
  <img src="assets/macassistant-hero-brand.png" alt="Mac小助手" width="880">
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">
  一个 App，搞定 Mac 维护与 Apple 二进制工作流。
</p>

<p align="center">
  <a href="../README.md">English</a>
  · <a href="README.es.md">Español</a>
  · <a href="README.ko.md">한국어</a>
  · <a href="README.ru.md">Русский</a>
</p>

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/releases"><img src="https://img.shields.io/badge/Download-Releases-0A84FF?style=flat-square&logo=apple&logoColor=white" alt="Download"></a>
  <a href="https://x.com/iOSRXWY"><img src="https://img.shields.io/badge/X-@iOSRXWY-111111?style=flat-square&logo=x&logoColor=white" alt="X"></a>
  <a href="https://t.me/iosrxwy"><img src="https://img.shields.io/badge/Telegram-@iosrxwy-26A5E4?style=flat-square&logo=telegram&logoColor=white" alt="Telegram"></a>
</p>

## 功能

| 日常 | 开发者工具 · Beta |
| --- | --- |
| 系统概览、清理、应用修复 | DEB、DYLIB、IPA、Mach-O |
| 内存、网络、262 条命令 | 签名、注入、环境检查 |

操作前预览，关键步骤确认。开源，无遥测。IPA 安装与提取保持原样，不脱壳。

## 界面

<p align="center">
  <img src="assets/screenshots/system-cleanup.png" alt="系统清理" width="49%">
  <img src="assets/screenshots/deb-wizard.png" alt="DEB 向导" width="49%">
</p>

<p align="center">
  <img src="assets/screenshots/ipa-toolbox.png" alt="IPA 工具箱" width="49%">
  <img src="assets/screenshots/system-overview.png" alt="系统概览" width="49%">
</p>

## 下载

通用版（Apple Silicon + Intel）：[Releases](https://github.com/iosrxwy/MacAssistant/releases)。需要 macOS 13+。

发布动态：[X @iOSRXWY](https://x.com/iOSRXWY) · [Telegram](https://t.me/iosrxwy)

### 首次打开被拦截？

当前公开测试版是 **ad-hoc 签名，未经 Apple 公证**。先打开一次，再到 **系统设置 → 隐私与安全性 → 仍要打开**。不要全局关闭 Gatekeeper。

## 构建

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
open "dist/Mac小助手.app"
```

## 星标

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/stargazers"><img src="https://img.shields.io/github/stars/iosrxwy/MacAssistant?style=flat-square&logo=github" alt="GitHub stars"></a>
</p>

<p align="center">
  <img src="https://progress-bar.xyz/1/?scale=100&title=goal&width=420&color=0A84FF&suffix=%20/%20100" alt="Star 目标：1 / 100">
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

## 贡献者

<table>
  <tr>
    <td align="center" width="120">
      <a href="https://github.com/iosrxwy"><img src="https://github.com/iosrxwy.png?size=120" width="72" height="72" alt="iosrxwy"></a><br>
      <a href="https://github.com/iosrxwy"><b>iosrxwy</b></a><br>
      <sub>作者</sub>
    </td>
    <td align="center" width="120">
      <a href="https://github.com/codex"><img src="https://github.com/codex.png?size=120" width="72" height="72" alt="Codex"></a><br>
      <a href="https://github.com/codex"><b>Codex</b></a><br>
      <sub>开发</sub>
    </td>
    <td align="center" width="120">
      <a href="https://x.ai/grok"><img src="https://github.com/xai-org.png?size=120" width="72" height="72" alt="Grok Build"></a><br>
      <a href="https://x.ai/grok"><b>Grok Build</b></a><br>
      <sub>开发</sub>
    </td>
  </tr>
</table>

<p align="center">
  <a href="https://x.com/iOSRXWY">X</a>
  · <a href="https://t.me/iosrxwy">Telegram</a>
  · <a href="https://github.com/iosrxwy">GitHub</a>
  · <a href="../CONTRIBUTING.md">参与贡献</a>
</p>

## 致谢

[AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign) · [ipatool](https://github.com/majd/ipatool)

均不捆绑其二进制。

## 许可证

[GNU GPL-3.0](../LICENSE)。对外分发的修改版必须继续以同样许可证提供完整对应源代码。这并不允许把别人的工具打进 App：`class-dump` 同为 GPL-3.0，捆绑时必须一并提供对应源代码；`dsdump` 许可证不明，不可再分发；AltStore / AltSign 为 AGPL-3.0，本项目只参考公开协议。

安全问题见 [SECURITY.md](../SECURITY.md)。
