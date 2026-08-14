<p align="center">
  <img src="assets/macassistant-hero-brand.png" alt="Mac小助手宣传图" width="960">
</p>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> · <a href="README.ru.md">Русский</a>
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">macOS 유지 관리와 Apple 바이너리 작업을 위한 네이티브 SwiftUI 도구 모음.</p>

## 주요 기능

- 시스템 개요, 정리, App 복구, 메모리 및 네트워크 도구
- 위험 표시가 포함된 262개 macOS 명령
- DEB, DYLIB, IPA, Mach-O, 서명 및 Class Dump
- 변경 작업 전 미리보기와 확인
- Apple Silicon 및 Intel 지원
- 오픈 소스, 텔레메트리 없음

## 스크린샷

<p align="center">
  <img src="assets/screenshots/system-cleanup.png" alt="System cleanup" width="49%">
  <img src="assets/screenshots/deb-wizard.png" alt="DEB wizard" width="49%">
</p>

## 다운로드

[Releases](https://github.com/iosrxwy/MacAssistant/releases)에서 최신 버전을 받을 수 있습니다. macOS 13 이상이 필요합니다.

## 빌드

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

**Codex가 개발·유지 관리** · [iosrxwy](https://github.com/iosrxwy)가 배포합니다.

Thanks: [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign)
