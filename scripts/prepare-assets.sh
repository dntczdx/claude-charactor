#!/usr/bin/env bash
# 动画素材准备。
#
# 仓库里已经自带 Assets/clips/<代号>.webp（带透明通道的动图，app 用 ImageIO 直接解码），
# 一般情况下什么都不用做，这个脚本只是校验一下。
#
# 只有想重新从原项目生成（比如换分辨率/帧率、或加别的片段）时，才需要 ffmpeg（带 libvpx）：
#   REBUILD=1 scripts/prepare-assets.sh
# 产物：Assets/clips/<代号>/001.png … 帧目录（优先级高于同名 .webp）。
#
# 素材版权：GitHub wangxianda941030/Claude-girl，CC BY-NC 4.0（署名、非商用）。
set -euo pipefail
cd "$(dirname "$0")/.."

CLIPS="${CLIPS:-A01 A02 A03 A05 A06 A07 B04 C01 C02 C06 D01 D03}"

if [ -z "${REBUILD:-}" ]; then
  missing=0
  for c in $CLIPS; do
    if [ -s "Assets/clips/$c.webp" ] || [ -s "Assets/clips/$c/001.png" ]; then
      :
    else
      echo "缺少 $c（Assets/clips/$c.webp）"
      missing=1
    fi
  done
  if [ "$missing" = 0 ]; then
    echo "素材齐全：Assets/clips/ 里已有 $(ls Assets/clips/*.webp 2>/dev/null | wc -l | tr -d ' ') 个 webp。"
    echo "想从原项目重新生成帧序列：REBUILD=1 scripts/prepare-assets.sh"
    exit 0
  fi
  echo "有缺失，尝试用 ffmpeg 从原项目生成…"
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "需要 ffmpeg：brew install ffmpeg" >&2
  exit 1
fi
if ! ffmpeg -hide_banner -decoders 2>/dev/null | grep -q 'libvpx-vp9'; then
  echo "这个 ffmpeg 没带 libvpx-vp9 解码器，拆不出透明通道（背景会变黑）。" >&2
  echo "请用 Homebrew 的 ffmpeg：brew install ffmpeg（或 brew reinstall ffmpeg）" >&2
  exit 1
fi

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
  if [ -z "${REBUILD:-}" ] && [ -s "$out/001.png" ]; then
    echo "已有 $c，跳过"
    continue
  fi
  echo "拆帧 $c"
  rm -rf "$out"
  mkdir -p "$out"
  # 原片 960x540，人物居中；裁掉两侧空白再缩放。-c:v 必须放在 -i 前面才会用 libvpx 解码 alpha
  ffmpeg -v error -y -c:v libvpx-vp9 -i "$raw" \
    -vf "crop=780:540:100:0,fps=${FPS},scale=${WIDTH}:-2:flags=lanczos" \
    -pix_fmt rgba "$out/%03d.png"
  n="$(ls "$out" | wc -l | tr -d ' ')"
  alpha="$(sips -g hasAlpha "$out/001.png" 2>/dev/null | awk '/hasAlpha/{print $2}')"
  echo "  $n 帧，hasAlpha=$alpha"
  if [ "$alpha" != "yes" ]; then
    echo "  警告：帧没有透明通道，背景会是黑的" >&2
  fi
done

echo "完成。"
