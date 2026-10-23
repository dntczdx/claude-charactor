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
[ -f Assets/AppIcon.icns ] && cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>ClaudeGirl</string>
  <key>CFBundleIdentifier</key><string>com.dntczdx.claudegirl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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

# 默认装到 /Applications 并重启；不想装就 INSTALL=0 scripts/build-app.sh
if [ "${INSTALL:-1}" = "1" ]; then
  pkill -x ClaudeGirl 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/ClaudeGirl.app
  cp -R "$APP" /Applications/ClaudeGirl.app
  touch /Applications/ClaudeGirl.app
  open /Applications/ClaudeGirl.app
  echo "已安装并启动：/Applications/ClaudeGirl.app"
  echo "提醒：重新编译后要在 System Settings → Privacy & Security → Accessibility 里把开关重新打开一次"
else
  echo "运行：open $APP"
fi
