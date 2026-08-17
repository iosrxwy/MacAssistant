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

### 初回起動でブロックされる場合

この公開ベータは **ad-hoc の開発ビルドで、Apple の公証を受けていません。** 初回起動時に「開発元を確認できない」と出たり、起動が拒否されたりします。破損ではありません。

1. いったんアプリを開く（ブロックされるのが正常です）。
2. **システム設定 → プライバシーとセキュリティ** を開く。
3. このアプリに関する表示までスクロールし、**このまま開く** を押す。
4. もう一度アプリを開く。

Gatekeeper を全体でオフにしないでください。「このまま開く」が見当たらないときは、初回ブロックのあと少し待ってから同じ画面を確認してください。

## ビルド

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

**Codex が開発・保守** · [iosrxwy](https://github.com/iosrxwy) が公開しています。

Thanks: [AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign). These projects’ binaries are not bundled.
