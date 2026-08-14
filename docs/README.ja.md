<p align="center">
  <img src="assets/macassistant-hero-brand.png" alt="Mac小助手宣传图" width="960">
</p>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ko.md">한국어</a> · <a href="README.ru.md">Русский</a>
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">macOS メンテナンスと Apple バイナリ作業のためのネイティブ SwiftUI ツールボックス。</p>

## 主な機能

- システム概要、クリーンアップ、App 修復、メモリ、ネットワーク
- リスク表示付きの 262 件の macOS コマンド
- DEB、DYLIB、IPA、Mach-O、署名、Class Dump
- 変更前のプレビューと確認
- Apple Silicon / Intel 対応
- オープンソース、テレメトリなし

## スクリーンショット

<p align="center">
  <img src="assets/screenshots/system-cleanup.png" alt="System cleanup" width="49%">
  <img src="assets/screenshots/deb-wizard.png" alt="DEB wizard" width="49%">
</p>

## ダウンロード

最新版は [Releases](https://github.com/iosrxwy/MacAssistant/releases) から入手できます。macOS 13 以降が必要です。

## ビルド

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

**Codex が開発・保守** · [iosrxwy](https://github.com/iosrxwy) が公開しています。

Thanks: [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign)
