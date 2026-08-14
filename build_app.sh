#!/usr/bin/env bash
#
# 将 Swift Package 可执行文件打包为可双击运行的 macOS .app。
# 用法:./build_app.sh [debug|release] [universal|native]
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

# 统一入口,保证「构建」与「取产物路径」使用完全相同的参数。
swift_build() {
  if [[ "$ARCH_MODE" == "universal" ]]; then
    swift build -c "$CONFIG" --arch x86_64 --arch arm64 "$@"
  else
    swift build -c "$CONFIG" "$@"
  fi
}

APP_NAME="Mac小助手"
BUNDLE_ID="com.opensource.macassistant"
# 新增一门语言:在这里加语言代码,并在两个 target 的 Localization/<代码>.lproj/ 放字符串表。
DEVELOPMENT_REGION="zh-Hans"
APP_LOCALIZATIONS="zh-Hans en"
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
fi

# 从 Resources/AppIcon.png 生成 AppIcon.icns 放进 bundle(临时 iconset 目录用完即删,不入库)。
echo "==> 生成 AppIcon.icns …"
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE"       "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}.png"     >/dev/null
  DBL=$((SIZE * 2))
  sips -z "$DBL" "$DBL"         "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png"  >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
ICON_NAME="AppIcon"

# 让访达 / 系统设置认得这是本地化 App,并按语言给出显示名。
localized_display_name() {
  case "$1" in
    en) printf 'Mac Assistant' ;;
    *)  printf '%s' "$APP_NAME" ;;
  esac
}
LOCALIZATIONS_XML=""
for LANG_CODE in $APP_LOCALIZATIONS; do
  mkdir -p "$CONTENTS/Resources/$LANG_CODE.lproj"
  cat > "$CONTENTS/Resources/$LANG_CODE.lproj/InfoPlist.strings" <<STRINGS
"CFBundleDisplayName" = "$(localized_display_name "$LANG_CODE")";
STRINGS
  LOCALIZATIONS_XML="$LOCALIZATIONS_XML
        <string>$LANG_CODE</string>"
done

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
    <key>CFBundleIconName</key><string>${ICON_NAME}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>MIT License · Open Source</string>
    <key>MacAssistantBuildKind</key><string>Development (ad-hoc, not notarized)</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 开发签名（非 Developer ID、未公证）…"
codesign --force --sign - "$CONTENTS/MacOS/MacAssistant"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=4 "$APP"

echo ""
echo "✅ 完成:$APP"
echo "   架构:$BUILT_ARCHS"
echo "   运行:open \"$APP\""
