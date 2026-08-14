<p align="center">
  <img src="assets/macassistant-hero-brand.png" alt="Mac小助手宣传图" width="960">
</p>

<p align="center">
  <a href="../README.md">English</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.ru.md">Русский</a>
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">
  <strong>一个 App，搞定 Mac 维护与 Apple 二进制工作流。</strong><br>
  把零散脚本、命令查询和重复操作，收进清晰、可预览的原生界面。
</p>

## 为什么值得用

| 日常维护 | Apple 开发工具 | 用得放心 |
| --- | --- | --- |
| 看状态、腾空间、修 App、查内存与网络。 | DEB、DYLIB、IPA、Mach-O 与签名集中处理。 | 操作前预览、关键步骤确认、开源且无遥测。 |

## 功能一览

### 日常工具

- **系统概览**：芯片、内存、磁盘、电池与运行时间一眼看清
- **安全清理**：缓存、日志、Xcode 数据等可再生文件
- **应用修复**：诊断签名、隔离属性与启动问题
- **内存与网络**：压力、进程、端口、Ping、DNS 与公网 IP
- **命令速查**：262 条 macOS 命令，支持搜索与风险标识

### 开发者工具 · Beta

- **DEB**：制作、检查、解包、转换与重新打包
- **DYLIB**：依赖检查、动态库提取、安装名与 rpath 修改
- **IPA**：注入流程、瘦身、头文件提取与逐层签名
- **Mach-O**：原生 Swift 检查与 dylib 注入，支持单架构和通用二进制
- **环境检查**：识别所需工具并提供清晰的安装指引

## 界面

<p align="center">
  <img src="assets/screenshots/system-cleanup.png" alt="系统清理" width="49%">
  <img src="assets/screenshots/deb-wizard.png" alt="DEB 向导" width="49%">
</p>

<p align="center">
  <img src="assets/screenshots/ipa-toolbox.png" alt="IPA 工具箱" width="49%">
  <img src="assets/screenshots/system-overview.png" alt="系统概览" width="49%">
</p>

## Star 目标

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/stargazers"><img src="https://img.shields.io/github/stars/iosrxwy/MacAssistant?style=for-the-badge&logo=github&label=Stars&color=0A84FF" alt="GitHub Stars"></a><br>
  <img src="https://progress-bar.xyz/1/?scale=100&title=First%20goal&width=480&color=0A84FF&suffix=%20%2F%20100" alt="首个 Star 目标：1 / 100">
</p>

<p align="center">如果它帮你省下了时间，点一个 Star 能让更多人看到这个项目。</p>

## 下载

前往 [Releases](https://github.com/iosrxwy/MacAssistant/releases) 下载 Apple Silicon + Intel 通用版本。

> 需要 macOS 13 或更高版本。开发者工具标记为 Beta，修改文件前请保留备份。

## 构建

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
open "dist/Mac小助手.app"
```

## 维护

由 **Codex 开发与维护** · 由 [iosrxwy](https://github.com/iosrxwy) 发布。

特别感谢以下两个可选开源工具：

- [Theos](https://github.com/theos/theos)：Tweak 项目构建环境
- [zsign](https://github.com/zhlynn/zsign)：IPA 与 Mach-O 签名工具

## 许可证

[MIT](../LICENSE)
