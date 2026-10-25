#!/usr/bin/env python3
"""
把龙娘的透明 webm 动画拼成 Codex 原生桌宠的 spritesheet（hatch-pet 规范）。

规范：8 列 × 9 行，每格 192×208，整张 1536×1872，透明 WebP/PNG；行顺序固定：
  0 idle(6)  1 running-right(8)  2 running-left(8)  3 waving(4)  4 jumping(5)
  5 failed(8)  6 waiting(6)  7 running(6，原地干活)  8 review(6)

用法：python3 scripts/build-codex-spritesheet.py <webm目录> <输出目录>
需要 ffmpeg（带 libvpx-vp9 以保留透明通道）和 Pillow。
"""
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image

CELL_W, CELL_H = 192, 208
COLS = 8
ROWS = [
    ("idle", 6, "待机呼吸休闲", False),
    ("running-right", 8, "原地左转奔跑", True),   # 原片朝左，镜像成朝右
    ("running-left", 8, "原地左转奔跑", False),
    ("waving", 4, "点击回应-元气挥手", False),
    ("jumping", 5, "点击回应-开心跃动", False),
    ("failed", 8, "工作状态-垂头叹气冒汗", False),
    ("waiting", 6, "工作状态-原地踱步张望", False),
    ("running", 6, "工作状态-忙碌点按", False),
    ("review", 6, "工作状态-清点归档", False),
]


def extract(webm, outdir, fps=12):
    os.makedirs(outdir, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-c:v", "libvpx-vp9", "-i", webm,
         "-vf", f"fps={fps}", "-pix_fmt", "rgba", os.path.join(outdir, "%03d.png")],
        check=True,
    )
    return sorted(os.path.join(outdir, f) for f in os.listdir(outdir) if f.endswith(".png"))


def sample(frames, n):
    if len(frames) <= n:
        return frames + [frames[-1]] * (n - len(frames))
    return [frames[int(i * len(frames) / n)] for i in range(n)]


def main(src, out):
    tmp = tempfile.mkdtemp(prefix="dragon-sheet-")
    rows_frames = []
    union = None
    for name, count, clip, flip in ROWS:
        webm = os.path.join(src, clip + ".webm")
        if not os.path.exists(webm):
            sys.exit(f"缺少 {webm}")
        frames = extract(webm, os.path.join(tmp, name))
        picked = sample(frames, count)
        imgs = []
        for f in picked:
            im = Image.open(f).convert("RGBA")
            if flip:
                im = im.transpose(Image.FLIP_LEFT_RIGHT)
            imgs.append(im)
            bb = im.split()[3].point(lambda a: 255 if a > 8 else 0).getbbox()
            if bb:
                union = bb if union is None else (min(union[0], bb[0]), min(union[1], bb[1]), max(union[2], bb[2]), max(union[3], bb[3]))
        rows_frames.append((name, imgs))

    # 统一裁切框：所有片段里人物出现过的范围，这样各行的脚底和身高一致
    x0, y0, x1, y1 = union
    w, h = x1 - x0, y1 - y0
    scale = min((CELL_W - 8) / w, (CELL_H - 6) / h)
    tw, th = int(w * scale), int(h * scale)
    print(f"人物范围 {union} → 缩放 {scale:.3f} → {tw}×{th}")

    sheet = Image.new("RGBA", (CELL_W * COLS, CELL_H * len(ROWS)), (0, 0, 0, 0))
    for r, (name, imgs) in enumerate(rows_frames):
        for c, im in enumerate(imgs):
            crop = im.crop((x0, y0, x1, y1)).resize((tw, th), Image.LANCZOS)
            cell_x = c * CELL_W + (CELL_W - tw) // 2
            cell_y = r * CELL_H + (CELL_H - th) - 3          # 贴着格子底部
            sheet.alpha_composite(crop, (cell_x, cell_y))

    os.makedirs(out, exist_ok=True)
    sheet.save(os.path.join(out, "spritesheet.webp"), format="WEBP", lossless=True, quality=100, method=6)
    sheet.save(os.path.join(out, "spritesheet-preview.png"))
    with open(os.path.join(out, "pet.json"), "w", encoding="utf-8") as f:
        json.dump({
            "id": "gpt-dragon",
            "displayName": "GPT 龙娘",
            "description": "白紫配色的 GPT 龙娘。形象来自 ZipZipPipe《大 AI 与小 AI 们》与 ApprenTice 的 Q 版设定，动画取自 Houraiji9/ai-pet-7in1（CC BY-NC-SA 4.0，非商用）。",
            "spritesheetPath": "spritesheet.webp",
        }, f, ensure_ascii=False, indent=2)
    print("完成：", out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
