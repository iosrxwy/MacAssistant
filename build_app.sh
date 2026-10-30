#!/usr/bin/env bash
#
# 将 Swift Package 可执行文件打包为可双击运行的 macOS .app。
# 用法:./build_app.sh [debug|release] [universal|native]
#
# 签名分流（环境变量，绝不写进仓库）:
#   MA_SIGN_IDENTITY     Developer ID，走公证发行链路
#   MA_LOCAL_SIGN_IDENTITY  本机已有证书，只签名不公证（覆盖安装可保留 TCC）
#   MA_ADHOC=1           强制 ad-hoc（每次重编都会丢完全磁盘访问 / App 管理）
# 未设置以上变量时，自动创建并复用「MacAssistant Local」自签证书。
#
# 默认产出 x86_64 + arm64 通用二进制:Intel Mac 无法运行 arm64 切片,
# 只打宿主架构会让在 Apple Silicon 上构建的发行版在 Intel 机器上直接打不开。
# 本地快速迭代可用 native 只编当前架构。
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
ARCH_MODE="${2:-universal}"
case "$ARCH_MODE" in
  universal|native) ;;
  *) echo "错误:未知架构模式 $ARCH_MODE(可选:universal | native)" >&2; exit 1 ;;
esac

# 有并行代理会占用默认 .build 锁;需要时可用 MA_SCRATCH_PATH 指定独立目录避免竞争。
SCRATCH_ARGS=()
[[ -n "${MA_SCRATCH_PATH:-}" ]] && SCRATCH_ARGS=(--scratch-path "$MA_SCRATCH_PATH")

# 统一入口,保证「构建」与「取产物路径」使用完全相同的参数。
# `${arr[@]+"${arr[@]}"}` 是空数组在 set -u 下的安全展开写法:macOS 自带 bash 3.2 直接展开
# 空数组的 "${arr[@]}" 会报 unbound variable。
swift_build() {
  if [[ "$ARCH_MODE" == "universal" ]]; then
    swift build -c "$CONFIG" --arch x86_64 --arch arm64 ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} "$@"
  else
    swift build -c "$CONFIG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} "$@"
  fi
}

APP_NAME="Mac小助手"
BUNDLE_ID="com.opensource.macassistant"
# 新增一门语言:在这里加语言代码,并在两个 target 的 Localization/<代码>.lproj/ 放字符串表。
DEVELOPMENT_REGION="zh-Hans"
APP_LOCALIZATIONS="zh-Hans zh-Hant en es ko ru"
VERSION_FILE="Resources/AppVersion.txt"
[[ -f "$VERSION_FILE" ]] || { echo "错误:缺少版本文件 $VERSION_FILE" >&2; exit 1; }
IFS= read -r VERSION < "$VERSION_FILE"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){2}([-.][A-Za-z0-9.]+)?$ ]] || {
  echo "错误:版本格式无效: $VERSION" >&2
  exit 1
}

ICON_SRC="Resources/AppIcon.png"
SWIFTPM_ICON="Sources/MacAssistant/Resources/AppIcon.png"
[[ -f "$ICON_SRC" ]] || { echo "错误:未找到 $ICON_SRC" >&2; exit 1; }
mkdir -p "$(dirname "$SWIFTPM_ICON")"
if ! cmp -s "$ICON_SRC" "$SWIFTPM_ICON"; then
  echo "==> 同步 SwiftPM 心形图标资源 …"
  cp "$ICON_SRC" "$SWIFTPM_ICON"
fi
CANONICAL_ICON_HASH="$(shasum -a 256 "$ICON_SRC" | awk '{print $1}')"
SWIFTPM_ICON_HASH="$(shasum -a 256 "$SWIFTPM_ICON" | awk '{print $1}')"
[[ "$CANONICAL_ICON_HASH" == "$SWIFTPM_ICON_HASH" ]] || {
  echo "错误:SwiftPM 图标与 canonical PNG 不一致" >&2
  exit 1
}

echo "==> 编译 MacAssistant ($CONFIG / $ARCH_MODE) …"
swift_build

BIN_DIR="$(swift_build --show-bin-path)"
EXECUTABLE="$BIN_DIR/MacAssistant"
# 两个 target 各有一张字符串表,Bundle.module 分别去自己的资源包里查。
RESOURCE_BUNDLES=(
  "$BIN_DIR/MacAssistant_MacAssistant.bundle"
  "$BIN_DIR/MacAssistant_MacAssistantKit.bundle"
)
if [[ ! -f "$EXECUTABLE" ]]; then
  echo "错误:未找到可执行文件 $EXECUTABLE" >&2
  exit 1
fi
ENERGY_HELPER="$BIN_DIR/MacAssistantEnergyHelper"
if [[ ! -x "$ENERGY_HELPER" ]]; then
  echo "错误:未找到能耗模式辅助程序 $ENERGY_HELPER" >&2
  exit 1
fi
for BUNDLE in "${RESOURCE_BUNDLES[@]}"; do
  if [[ ! -d "$BUNDLE" ]]; then
    echo "错误:未找到 SwiftPM 资源包 $BUNDLE" >&2
    exit 1
  fi
done

DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> 组装 .app bundle …"
rm -rf "$DIST"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$EXECUTABLE" "$CONTENTS/MacOS/MacAssistant"
chmod +x "$CONTENTS/MacOS/MacAssistant"
cp "Resources/more-mac-commands.md" "$CONTENTS/Resources/more-mac-commands.md"

# 少了资源包 .app 就没有翻译:Bundle.module 会在 Contents/Resources 下找同名 bundle。
for BUNDLE in "${RESOURCE_BUNDLES[@]}"; do
  cp -R "$BUNDLE" "$CONTENTS/Resources/"
done
for LANG_CODE in $APP_LOCALIZATIONS; do
  for BUNDLE in "${RESOURCE_BUNDLES[@]}"; do
    BUNDLE_NAME="$(basename "$BUNDLE")"
    # SwiftPM 会把 zh-Hans.lproj 写成小写,大小写敏感卷上按名字查会落空。
    # 另外 xcbuild 产出的是 Contents/Resources 结构化 bundle,SwiftPM 产出的是平铺 bundle,
    # 所以不能限定深度。
    LPROJ="$(find "$CONTENTS/Resources/$BUNDLE_NAME" -type d -iname "$LANG_CODE.lproj" -print -quit)"
    [[ -n "$LPROJ" ]] || {
      echo "错误:$BUNDLE_NAME 缺少 $LANG_CODE 语言资源" >&2
      exit 1
    }
  done
done

BUILT_ARCHS="$(lipo -archs "$CONTENTS/MacOS/MacAssistant")"
if [[ "$ARCH_MODE" == "universal" ]]; then
  for WANT in x86_64 arm64; do
    [[ " $BUILT_ARCHS " == *" $WANT "* ]] || {
      echo "错误:通用二进制缺少 $WANT 切片(实际:$BUILT_ARCHS)" >&2
      exit 1
    }
  done
  HELPER_ARCHS="$(lipo -archs "$ENERGY_HELPER")"
  for WANT in x86_64 arm64; do
    [[ " $HELPER_ARCHS " == *" $WANT "* ]] || {
      echo "错误:能耗模式辅助程序缺少 $WANT 切片(实际:$HELPER_ARCHS)" >&2
      exit 1
    }
  done
fi

# 从 Resources/AppIcon.png 生成 AppIcon.icns 放进 bundle(临时 iconset 目录用完即删,不入库)。
# 源图必须带 squircle 透明边:不透明白底会在旧系统 Launchpad 里显示成方块。
echo "==> 编译应用分身辅助程序 …"
HELPERS="$CONTENTS/Helpers"
mkdir -p "$HELPERS"
cp "$ENERGY_HELPER" "$HELPERS/MacAssistantEnergyHelper"
chmod +x "$HELPERS/MacAssistantEnergyHelper"
CLONE_SRC="Sources/MacAssistantKit/Resources/CloneSupport"
if [[ "$ARCH_MODE" == "universal" ]]; then
  CLONE_ARCHS=(-arch arm64 -arch x86_64)
else
  HOST_ARCH="$(uname -m)"
  [[ "$HOST_ARCH" == "arm64" || "$HOST_ARCH" == "x86_64" ]] || HOST_ARCH="arm64"
  CLONE_ARCHS=(-arch "$HOST_ARCH")
fi
clang -O2 "${CLONE_ARCHS[@]}" -framework Foundation \
  -o "$HELPERS/MacAssistantCloneLauncher" "$CLONE_SRC/clone_launcher.m"
clang -dynamiclib -O2 "${CLONE_ARCHS[@]}" -framework Foundation \
  -install_name @executable_path/../Frameworks/libMacAssistantCloneEnv.dylib \
  -o "$HELPERS/libMacAssistantCloneEnv.dylib" "$CLONE_SRC/clone_env.m"

echo "==> 生成 AppIcon.icns …"
python3 scripts/render_app_icon.py "$ICON_SRC" --inspect
ICON_TMP="$(mktemp -d)"
# 发行链路里一旦有任何一步失败,绝不能把「已标记为已公证」的半成品留在 dist/。
# 只有走完签名 + 公证 + 装订 + 校验后才会把 RELEASE_COMPLETE 置 1;否则退出时删除产物。
RELEASE_COMPLETE=0
LOCAL_SIGN_KEYCHAIN=""
LOCAL_SIGN_SAVED_KEYCHAINS=()
restore_local_signing_keychain() { :; }
cleanup() {
  local code=$?
  restore_local_signing_keychain
  rm -rf "$ICON_TMP"
  if [[ "${RELEASE_MODE:-0}" -eq 1 && "$RELEASE_COMPLETE" -ne 1 && -d "${APP:-}" ]]; then
    echo "⚠️ 发行链路未完整成功(退出码 $code),删除可能被误标为已公证的产物:$APP" >&2
    rm -rf "$APP"
  fi
}
trap cleanup EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE"       "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}.png"     >/dev/null
  DBL=$((SIZE * 2))
  sips -z "$DBL" "$DBL"         "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png"  >/dev/null
done
# sips 缩放后仍须保住透明边,否则 iconutil 打出来又是方块。
python3 scripts/render_app_icon.py "$ICONSET/icon_512x512@2x.png" --inspect
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
ICON_NAME="AppIcon"

# 让访达 / 系统设置认得这是本地化 App,并按语言给出显示名。
localized_display_name() {
  case "$1" in
    en|es|ru) printf 'Mac Assistant' ;;
    ko) printf 'Mac 도우미' ;;
    *)  printf '%s' "$APP_NAME" ;;
  esac
}
# 读蓝牙设备时系统会查这句。缺了会直接 SIGABRT，而不是弹出授权框。
bluetooth_usage() {
  case "$1" in
    zh-Hant) printf '%s' '在選單列裡顯示已配對的藍牙裝置，並連接或中斷它們。' ;;
    en) printf '%s' 'Shows paired Bluetooth devices in the menu bar, and connects or disconnects them.' ;;
    es) printf '%s' 'Muestra los dispositivos Bluetooth emparejados en la barra de menús y permite conectarlos o desconectarlos.' ;;
    ko) printf '%s' '메뉴 막대에서 페어링된 Bluetooth 기기를 보여주고 연결하거나 끊습니다.' ;;
    ru) printf '%s' 'Показывает сопряжённые устройства Bluetooth в строке меню и позволяет их подключать или отключать.' ;;
    *) printf '%s' '在菜单栏里显示已配对的蓝牙设备，并连接或断开它们。' ;;
  esac
}
LOCALIZATIONS_XML=""
for LANG_CODE in $APP_LOCALIZATIONS; do
  mkdir -p "$CONTENTS/Resources/$LANG_CODE.lproj"
  cat > "$CONTENTS/Resources/$LANG_CODE.lproj/InfoPlist.strings" <<STRINGS
"CFBundleDisplayName" = "$(localized_display_name "$LANG_CODE")";
"NSBluetoothAlwaysUsageDescription" = "$(bluetooth_usage "$LANG_CODE")";
STRINGS
  LOCALIZATIONS_XML="$LOCALIZATIONS_XML
        <string>$LANG_CODE</string>"
done

# ── 发行模式判定 ───────────────────────────────────────────────────────────
# 只有显式提供 Developer ID 签名身份(MA_SIGN_IDENTITY)才进入发行链路。
# 开发构建默认用本机稳定证书,避免每次覆盖安装都丢掉 TCC(完全磁盘访问 / App 管理)。
# 所有证书/凭据一律从环境变量或本机 Application Support 读取,绝不写进仓库或产物。
# 判定必须在写 Info.plist 之前完成,因为 MacAssistantBuildKind 直接决定 About 页如何显示。
SIGN_IDENTITY="${MA_SIGN_IDENTITY:-}"
LOCAL_SIGN_IDENTITY=""
LOCAL_SIGN_KEYCHAIN=""
LOCAL_SIGN_KEYCHAIN_PASSWORD=""
LOCAL_SIGN_DEFAULT_KEYCHAIN=""
LOCAL_SIGN_SAVED_KEYCHAINS=()
ENTITLEMENTS="Resources/MacAssistant.entitlements"
NOTARY_ARGS=()

restore_local_signing_keychain() {
  if [[ -n "$LOCAL_SIGN_DEFAULT_KEYCHAIN" ]]; then
    security default-keychain -d user -s "$LOCAL_SIGN_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
    LOCAL_SIGN_DEFAULT_KEYCHAIN=""
  fi
  if [[ ${#LOCAL_SIGN_SAVED_KEYCHAINS[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${LOCAL_SIGN_SAVED_KEYCHAINS[@]}" >/dev/null 2>&1 || true
    LOCAL_SIGN_SAVED_KEYCHAINS=()
  fi
  if [[ -n "$LOCAL_SIGN_KEYCHAIN" && -f "$LOCAL_SIGN_KEYCHAIN" ]]; then
    security delete-keychain "$LOCAL_SIGN_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  LOCAL_SIGN_KEYCHAIN=""
  LOCAL_SIGN_KEYCHAIN_PASSWORD=""
}

# 创建或复用本机自签代码签名证书。成功时设置 LOCAL_SIGN_IDENTITY / LOCAL_SIGN_KEYCHAIN。
setup_local_signing() {
  local cn="MacAssistant Local"
  if [[ -n "${MA_LOCAL_SIGN_IDENTITY:-}" ]]; then
    LOCAL_SIGN_IDENTITY="$MA_LOCAL_SIGN_IDENTITY"
    return 0
  fi

  command -v openssl >/dev/null || return 1
  command -v security >/dev/null || return 1

  local store="${MA_LOCAL_CERT_DIR:-$HOME/Library/Application Support/com.opensource.macassistant/signing}"
  local p12="$store/MacAssistantLocal.p12"
  local passfile="$store/p12.pass"
  mkdir -p "$store"
  chmod 700 "$store"

  if [[ ! -f "$p12" || ! -f "$passfile" ]]; then
    echo "==> 创建本机稳定签名证书（仅此一次，覆盖安装可保留 TCC）…"
    local pass
    pass="$(openssl rand -hex 16)" || return 1
    local cfg="$ICON_TMP/local-codesign.cnf"
    cat > "$cfg" <<'CNF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[req_distinguished_name]
CN = MacAssistant Local
O = MacAssistant Local

[v3_codesign]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
    local key="$ICON_TMP/local-codesign.key"
    local cert="$ICON_TMP/local-codesign.crt"
    openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
      -keyout "$key" -out "$cert" -config "$cfg" >/dev/null 2>&1 || return 1
    openssl pkcs12 -export -inkey "$key" -in "$cert" -out "$p12" \
      -passout "pass:$pass" -name "$cn" \
      -legacy >/dev/null 2>&1 || \
    openssl pkcs12 -export -inkey "$key" -in "$cert" -out "$p12" \
      -passout "pass:$pass" -name "$cn" >/dev/null 2>&1 || return 1
    printf '%s' "$pass" > "$passfile"
    chmod 600 "$p12" "$passfile"
    rm -f "$key" "$cert"
  fi

  local pass
  pass="$(cat "$passfile")" || return 1
  [[ -n "$pass" && -f "$p12" ]] || return 1

  LOCAL_SIGN_SAVED_KEYCHAINS=()
  local line
  while IFS= read -r line; do
    line="${line#*\"}"
    line="${line%\"*}"
    [[ -n "$line" ]] && LOCAL_SIGN_SAVED_KEYCHAINS+=("$line")
  done < <(security list-keychains -d user)
  LOCAL_SIGN_DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed 's/^[[:space:]]*"//;s/"$//')"

  LOCAL_SIGN_KEYCHAIN="$ICON_TMP/ma-sign.keychain-db"
  rm -f "$LOCAL_SIGN_KEYCHAIN"
  LOCAL_SIGN_KEYCHAIN_PASSWORD="$(openssl rand -hex 16)" || return 1
  security create-keychain -p "$LOCAL_SIGN_KEYCHAIN_PASSWORD" "$LOCAL_SIGN_KEYCHAIN" >/dev/null || return 1
  if [[ -n "$LOCAL_SIGN_DEFAULT_KEYCHAIN" ]]; then
    security default-keychain -d user -s "$LOCAL_SIGN_DEFAULT_KEYCHAIN" >/dev/null || true
  fi
  security set-keychain-settings -lut 21600 "$LOCAL_SIGN_KEYCHAIN" >/dev/null || true
  security unlock-keychain -p "$LOCAL_SIGN_KEYCHAIN_PASSWORD" "$LOCAL_SIGN_KEYCHAIN" >/dev/null || return 1
  security list-keychains -d user -s "$LOCAL_SIGN_KEYCHAIN" "${LOCAL_SIGN_SAVED_KEYCHAINS[@]}" >/dev/null || return 1

  security import "$p12" -k "$LOCAL_SIGN_KEYCHAIN" -P "$pass" \
    -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null || return 1
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$LOCAL_SIGN_KEYCHAIN_PASSWORD" "$LOCAL_SIGN_KEYCHAIN" >/dev/null || true

  LOCAL_SIGN_IDENTITY="$cn"
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  RELEASE_MODE=1
  BUILD_KIND="Release (Developer ID, notarized & stapled)"
  [[ -f "$ENTITLEMENTS" ]] || { echo "错误:发行模式缺少 entitlements 文件 $ENTITLEMENTS" >&2; exit 1; }
  # 公证凭据三选一,缺失即报错退出 —— 发行模式绝不静默降级成 ad-hoc。
  if [[ -n "${MA_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$MA_NOTARY_KEYCHAIN_PROFILE")
  elif [[ -n "${MA_NOTARY_API_KEY:-}" && -n "${MA_NOTARY_API_KEY_ID:-}" && -n "${MA_NOTARY_API_ISSUER:-}" ]]; then
    NOTARY_ARGS=(--key "$MA_NOTARY_API_KEY" --key-id "$MA_NOTARY_API_KEY_ID" --issuer "$MA_NOTARY_API_ISSUER")
  elif [[ -n "${MA_NOTARY_APPLE_ID:-}" && -n "${MA_NOTARY_PASSWORD:-}" && -n "${MA_TEAM_ID:-}" ]]; then
    NOTARY_ARGS=(--apple-id "$MA_NOTARY_APPLE_ID" --password "$MA_NOTARY_PASSWORD" --team-id "$MA_TEAM_ID")
  else
    echo "错误:发行模式需要 Apple 公证凭据(三选一,均通过环境变量传入):" >&2
    echo "  1) MA_NOTARY_KEYCHAIN_PROFILE(notarytool store-credentials 存好的 profile 名)" >&2
    echo "  2) MA_NOTARY_API_KEY + MA_NOTARY_API_KEY_ID + MA_NOTARY_API_ISSUER(App Store Connect API Key)" >&2
    echo "  3) MA_NOTARY_APPLE_ID + MA_NOTARY_PASSWORD + MA_TEAM_ID(Apple ID + App 专用密码)" >&2
    exit 1
  fi
else
  RELEASE_MODE=0
  if [[ "${MA_ADHOC:-0}" != "1" ]] && setup_local_signing; then
    BUILD_KIND="Development (local certificate, not notarized)"
  else
    restore_local_signing_keychain
    LOCAL_SIGN_IDENTITY=""
    BUILD_KIND="Development (ad-hoc, not notarized)"
    if [[ "${MA_ADHOC:-0}" != "1" ]]; then
      echo "⚠️ 本机稳定证书不可用，回退 ad-hoc。覆盖安装会失去完全磁盘访问等 TCC 授权。" >&2
    fi
  fi
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacAssistant</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>MacAssistant</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>${DEVELOPMENT_REGION}</string>
    <key>CFBundleLocalizations</key>
    <array>${LOCALIZATIONS_XML}
    </array>
    <key>CFBundleIconFile</key><string>${ICON_NAME}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>$(bluetooth_usage "$DEVELOPMENT_REGION")</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>GNU GPL-3.0 · Open Source</string>
    <key>MacAssistantBuildKind</key><string>${BUILD_KIND}</string>
</dict>
</plist>
PLIST

if [[ "$RELEASE_MODE" -eq 1 ]]; then
  echo "==> Developer ID 签名 + Hardened Runtime（由内向外，附安全时间戳）…"
  # 先签内层可执行文件,再签整个 .app;两层都启用 runtime 加固并写入最小 entitlements。
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$HELPERS/MacAssistantCloneLauncher"
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$HELPERS/MacAssistantEnergyHelper"
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$HELPERS/libMacAssistantCloneEnv.dylib"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$CONTENTS/MacOS/MacAssistant"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=4 "$APP"

  echo "==> 提交 Apple 公证服务（notarytool，阻塞等待结果）…"
  NOTARIZE_ZIP="$DIST/$APP_NAME-notarize.zip"
  /usr/bin/ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
  # 捕获输出以便判定状态;失败即退出,绝不继续装订或标记为已公证。
  if ! SUBMIT_LOG="$(xcrun notarytool submit "$NOTARIZE_ZIP" "${NOTARY_ARGS[@]}" --wait 2>&1)"; then
    echo "$SUBMIT_LOG" >&2
    echo "错误:公证提交失败" >&2
    rm -f "$NOTARIZE_ZIP"
    exit 1
  fi
  echo "$SUBMIT_LOG"
  rm -f "$NOTARIZE_ZIP"
  # notarytool 的退出码在部分版本上并不可靠,再显式校验 status 必须为 Accepted。
  grep -q "status: Accepted" <<<"$SUBMIT_LOG" || {
    echo "错误:公证结果非 Accepted,不装订、不标记为发行版" >&2
    exit 1
  }

  echo "==> 装订 notarization ticket（stapler）…"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # Gatekeeper 评估:只有真正公证并装订后才会 accepted,这是「已公证」标记的最终把关。
  spctl --assess --type execute --verbose=4 "$APP"

  # 走到这里才算发行链路完整成功,产物中的「已公证」标记与事实一致。
  RELEASE_COMPLETE=1
elif [[ -n "$LOCAL_SIGN_IDENTITY" ]]; then
  echo "==> 本机稳定证书签名（${LOCAL_SIGN_IDENTITY}，未公证）…"
  local_codesign() {
    if [[ -n "$LOCAL_SIGN_KEYCHAIN" ]]; then
      codesign --force --sign "$LOCAL_SIGN_IDENTITY" --keychain "$LOCAL_SIGN_KEYCHAIN" "$@"
    else
      codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$@"
    fi
  }
  local_codesign "$HELPERS/MacAssistantCloneLauncher"
  local_codesign "$HELPERS/MacAssistantEnergyHelper"
  local_codesign "$HELPERS/libMacAssistantCloneEnv.dylib"
  local_codesign "$CONTENTS/MacOS/MacAssistant"
  local_codesign "$APP"
  codesign --verify --strict --verbose=4 "$APP"
else
  echo "==> ad-hoc 开发签名（非 Developer ID、未公证）…"
  codesign --force --sign - "$HELPERS/MacAssistantCloneLauncher"
  codesign --force --sign - "$HELPERS/MacAssistantEnergyHelper"
  codesign --force --sign - "$HELPERS/libMacAssistantCloneEnv.dylib"
  codesign --force --sign - "$CONTENTS/MacOS/MacAssistant"
  codesign --force --sign - "$APP"
  codesign --verify --strict --verbose=4 "$APP"
fi

echo "==> 计算产物 SHA-256 …"
shasum -a 256 "$CONTENTS/MacOS/MacAssistant"
# 同时产出可分发 zip 及其校验值,供发布页公布,便于用户核对下载内容。
RELEASE_ZIP="$DIST/$APP_NAME-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$RELEASE_ZIP"
shasum -a 256 "$RELEASE_ZIP" | tee "$RELEASE_ZIP.sha256"

echo ""
echo "✅ 完成:$APP"
echo "   构建种类:$BUILD_KIND"
echo "   架构:$BUILT_ARCHS"
echo "   分发包:$RELEASE_ZIP"
echo "   运行:open \"$APP\""
