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

### 처음 열 때 macOS가 막는 경우

이 공개 베타는 **ad-hoc 개발 빌드이며 Apple 공증을 받지 않았습니다.** 처음 열면 “확인된 개발자가 아님”이 뜨거나 실행이 차단될 수 있습니다. 파일이 깨진 것이 아닙니다.

1. 앱을 한 번 열어 봅니다(차단되는 것이 정상입니다).
2. **시스템 설정 → 개인정보 보호 및 보안**을 엽니다.
3. 이 앱에 대한 안내까지 스크롤한 뒤 **그래도 열기**를 누릅니다.
4. 앱을 다시 엽니다.

Gatekeeper를 전역으로 끄지 마세요. **그래도 열기**가 안 보이면 잠시 기다린 뒤 같은 화면을 다시 확인하세요. 보통 처음 차단된 뒤에 나타납니다.

## 빌드

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

**Codex가 개발·유지 관리** · [iosrxwy](https://github.com/iosrxwy)가 배포합니다.

Thanks: [AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign). These projects’ binaries are not bundled.
