#!/usr/bin/env bash
# 编译并打包成 build/ClaudeGirl.app（菜单栏应用，不占 Dock）
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  echo "需要 Xcode 命令行工具：xcode-select --install" >&2
  exit 1
fi
if [ ! -d Assets/clips ] || [ -z "$(ls -A Assets/clips 2>/dev/null)" ]; then
  echo "还没有动画素材，先跑 scripts/prepare-assets.sh" >&2
  exit 1
fi

CONFIG="${CONFIG:-release}"
echo "swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/ClaudeGirl"
APP="build/ClaudeGirl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeGirl"
cp -R Assets/clips "$APP/Contents/Resources/clips"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>ClaudeGirl</string>
  <key>CFBundleIdentifier</key><string>com.dntczdx.claudegirl</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>克劳德大小姐</string>
  <key>CFBundleDisplayName</key><string>克劳德大小姐</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>角色「克劳德大小姐」美术来自 Claude-girl（CC BY-NC 4.0）</string>
</dict>
</plist>
PLIST

# 临时签名：辅助功能权限跟签名绑定，每次重新编译后需要在「系统设置 → 隐私与安全性 → 辅助功能」里重新勾一次
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "打包完成：$APP"
echo "运行：open $APP"
echo "（可选）装到应用程序：cp -R $APP /Applications/"
