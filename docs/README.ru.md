<p align="center">
  <img src="assets/macassistant-hero-brand.png" alt="Mac小助手宣传图" width="960">
</p>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.es.md">Español</a> · <a href="README.ko.md">한국어</a>
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">Нативный SwiftUI-набор для обслуживания macOS и работы с бинарными файлами Apple.</p>

## Возможности

- Сведения о системе, очистка, восстановление App, память и сеть
- 262 команды macOS с поиском и отметками риска
- DEB, DYLIB, IPA, Mach-O, подпись и Class Dump
- Предпросмотр и подтверждение изменений
- Поддержка Apple Silicon и Intel
- Открытый код, без телеметрии

## Скриншоты

<p align="center">
  <img src="assets/screenshots/system-cleanup.png" alt="System cleanup" width="49%">
  <img src="assets/screenshots/deb-wizard.png" alt="DEB wizard" width="49%">
</p>

## Загрузка

Последняя версия доступна в [Releases](https://github.com/iosrxwy/MacAssistant/releases). Требуется macOS 13 или новее.

### macOS блокирует первый запуск?

Этот публичный бета-билд подписан **ad-hoc и не нотаризован Apple**. При первом открытии может появиться «не удаётся проверить разработчика» или запуск будет заблокирован. Это ожидаемо, архив не повреждён.

1. Попробуйте открыть приложение один раз (блокировка — нормально).
2. Откройте **Системные настройки → Конфиденциальность и безопасность**.
3. Прокрутите до сообщения об этом приложении и нажмите **Всё равно открыть**.
4. Откройте приложение ещё раз.

Не отключайте Gatekeeper глобально. Если кнопки нет, подождите минуту и снова откройте этот раздел — она обычно появляется после первой блокировки.

## Сборка

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

## Звёзды и участники

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/stargazers"><img src="https://img.shields.io/github/stars/iosrxwy/MacAssistant?style=for-the-badge&logo=github&label=Stars&color=0A84FF" alt="GitHub stars"></a><br>
  <img src="https://progress-bar.xyz/1/?scale=100&title=First%20goal&width=480&color=0A84FF&suffix=%20%2F%20100" alt="First star goal: 1 / 100">
</p>

<p align="center">
  <a href="https://star-history.com/#iosrxwy/MacAssistant&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=iosrxwy/MacAssistant&type=Date&theme=dark">
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=iosrxwy/MacAssistant&type=Date">
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=iosrxwy/MacAssistant&type=Date" width="640">
    </picture>
  </a>
</p>

<table>
  <tr>
    <td align="center" valign="top" width="140">
      <a href="https://github.com/iosrxwy">
        <img src="https://github.com/iosrxwy.png?size=140" width="88" height="88" alt="iosrxwy">
      </a><br>
      <a href="https://github.com/iosrxwy"><b>iosrxwy</b></a><br>
      <sub>Автор</sub>
    </td>
    <td align="center" valign="top" width="140">
      <a href="https://github.com/codex">
        <img src="https://github.com/codex.png?size=140" width="88" height="88" alt="Codex">
      </a><br>
      <a href="https://github.com/codex"><b>Codex</b></a><br>
      <sub>Разработка</sub>
    </td>
    <td align="center" valign="top" width="140">
      <a href="https://x.ai/grok">
        <img src="https://github.com/xai-org.png?size=140" width="88" height="88" alt="Grok Build">
      </a><br>
      <a href="https://x.ai/grok"><b>Grok Build</b></a><br>
      <sub>Разработка</sub>
    </td>
  </tr>
</table>

**Разработка и сопровождение: Codex** · Публикация: [iosrxwy](https://github.com/iosrxwy).

Thanks: [AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign). These projects’ binaries are not bundled.
