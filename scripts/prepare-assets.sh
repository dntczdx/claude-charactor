#!/usr/bin/env bash
# 下载 Claude-girl 原项目的动画片段（VP9 + alpha 的 webm），拆成带透明通道的 PNG 帧序列。
# 产物：Assets/clips/<片段代号>/001.png …   由 build-app.sh 打进 app 包。
#
# 素材版权：GitHub wangxianda941030/Claude-girl，CC BY-NC 4.0（署名、非商用）。
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "需要 ffmpeg：brew install ffmpeg" >&2
  exit 1
fi

DECODER=""
if ffmpeg -hide_banner -decoders 2>/dev/null | grep -q 'libvpx-vp9'; then
  DECODER="-c:v libvpx-vp9"
else
  echo "警告：这个 ffmpeg 没带 libvpx-vp9 解码器，透明通道会丢（背景变黑）。建议 brew install ffmpeg。" >&2
fi

# 代号 → 含义（见 README）
CLIPS="${CLIPS:-A01 A02 A03 A05 A06 A07 B04 C01 C02 C06 D01 D03}"
BASE="https://raw.githubusercontent.com/wangxianda941030/Claude-girl/main/clips"
FPS="${FPS:-12}"
WIDTH="${WIDTH:-520}"

mkdir -p Assets/raw Assets/clips
for c in $CLIPS; do
  raw="Assets/raw/$c.webm"
  if [ ! -s "$raw" ]; then
    echo "下载 $c.webm"
    curl -fL --retry 3 -o "$raw" "$BASE/$c.webm"
  fi
  out="Assets/clips/$c"
  if [ -s "$out/001.png" ]; then
    echo "已有 $c，跳过"
    continue
  fi
  echo "拆帧 $c"
  mkdir -p "$out"
  # 原片 960x540，人物居中；裁掉两侧空白再缩放
  # shellcheck disable=SC2086
  ffmpeg -v error -y $DECODER -i "$raw" \
    -vf "crop=780:540:100:0,fps=${FPS},scale=${WIDTH}:-2:flags=lanczos" \
    -pix_fmt rgba "$out/%03d.png"
  echo "  $(ls "$out" | wc -l | tr -d ' ') 帧"
done

echo "完成。帧目录：Assets/clips/"
