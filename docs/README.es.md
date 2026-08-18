<p align="center">
  <img src="assets/macassistant-hero-brand.png" alt="Mac小助手宣传图" width="960">
</p>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ko.md">한국어</a> · <a href="README.ru.md">Русский</a>
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">Caja de herramientas nativa en SwiftUI para el mantenimiento de macOS y el trabajo con binarios de Apple.</p>

## Funciones principales

- Resumen del sistema, limpieza, reparación de apps, memoria y red
- 262 comandos de macOS con etiquetas de riesgo
- DEB, DYLIB, IPA, Mach-O, firma y Class Dump
- Vista previa y confirmación antes de cada cambio
- Compatible con Apple Silicon e Intel
- Código abierto, sin telemetría

## Capturas

<p align="center">
  <img src="assets/screenshots/system-cleanup.png" alt="System cleanup" width="49%">
  <img src="assets/screenshots/deb-wizard.png" alt="DEB wizard" width="49%">
</p>

## Descarga

La última versión está en [Releases](https://github.com/iosrxwy/MacAssistant/releases). Requiere macOS 13 o posterior.

### ¿macOS bloquea el primer inicio?

Esta beta pública es una **compilación de desarrollo ad-hoc, no notarizada por Apple.** Al abrirla por primera vez puede aparecer “no se puede verificar el desarrollador” o bloquearse el inicio. No está dañada.

1. Intenta abrir la app una vez (que la bloquee es lo normal).
2. Abre **Ajustes del Sistema → Privacidad y seguridad**.
3. Baja hasta el aviso de esta app y pulsa **Abrir de todos modos**.
4. Abre la app otra vez.

No desactives Gatekeeper de forma global. Si no ves el botón, espera un momento y vuelve a esa pantalla: suele aparecer después del primer bloqueo.

## Compilar

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

## Stars y colaboradores

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
      <sub>Autor</sub>
    </td>
    <td align="center" valign="top" width="140">
      <a href="https://github.com/codex">
        <img src="https://github.com/codex.png?size=140" width="88" height="88" alt="Codex">
      </a><br>
      <a href="https://github.com/codex"><b>Codex</b></a><br>
      <sub>Desarrollo</sub>
    </td>
    <td align="center" valign="top" width="140">
      <a href="https://x.ai/grok">
        <img src="https://github.com/xai-org.png?size=140" width="88" height="88" alt="Grok Build">
      </a><br>
      <a href="https://x.ai/grok"><b>Grok Build</b></a><br>
      <sub>Desarrollo</sub>
    </td>
  </tr>
</table>

**Desarrollo y mantenimiento: Codex** · Publicado por [iosrxwy](https://github.com/iosrxwy).

Thanks: [AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign). These projects’ binaries are not bundled.
