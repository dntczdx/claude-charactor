#!/usr/bin/env bash
# 把龙娘接到 Codex 上：
#  1. ~/.codex/config.toml：加 MCP 服务器（notify 工具，agent=codex）和 notify hook（CLI 用）
#  2. ~/.codex/AGENTS.md：追加「每轮结束调用 notify」的全局说明
#  3. ~/.codex/pets/gpt-dragon：安装 Codex 原生桌宠包（Settings → Appearance → Pets 里选）
# 桌面版的完成提醒不依赖这些：app 会直接监听 ~/.codex/sessions 的会话日志。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_HOME"
CONFIG="$CODEX_HOME/config.toml"
[ -f "$CONFIG" ] || touch "$CONFIG"
cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)"

if ! command -v node >/dev/null 2>&1; then
  echo "需要 Node.js 18+：brew install node" >&2
  exit 1
fi
NODE="$(command -v node)"
(cd mcp && npm install --silent --no-audit --no-fund)
PORT="${CLAUDEGIRL_PORT:-47333}"

# --- 1. config.toml ---
if grep -q '^\[mcp_servers\.codex-girl\]' "$CONFIG"; then
  echo "config.toml 已有 [mcp_servers.codex-girl]，跳过"
else
  cat >> "$CONFIG" <<TOML

# 桌面上的 GPT 龙娘：回复结束通知 + 气泡里收集回答（由 claude-charactor/scripts/install-codex.sh 写入）
[mcp_servers.codex-girl]
command = "$NODE"
args = ["$ROOT/mcp/server/index.js"]
env = { CLAUDEGIRL_URL = "http://127.0.0.1:$PORT", PET_AGENT = "codex" }
TOML
  echo "已写入 [mcp_servers.codex-girl]"
fi

if grep -q '^notify *=' "$CONFIG"; then
  echo "config.toml 已有 notify 设置，保留原样（如需桌宠提醒，请改成：notify = [\"bash\", \"$ROOT/scripts/codex-notify.sh\"]）"
else
  # notify 必须是顶层键，插到第一个 [section] 之前
  TMP="$(mktemp)"
  awk -v line="notify = [\"bash\", \"$ROOT/scripts/codex-notify.sh\"]" '
    BEGIN { done = 0 }
    /^\[/ && !done { print line; print ""; done = 1 }
    { print }
    END { if (!done) print line }
  ' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
  echo "已写入 notify hook（Codex CLI 用）"
fi

# --- 2. AGENTS.md ---
AGENTS="$CODEX_HOME/AGENTS.md"
if [ -f "$AGENTS" ] && grep -q 'GPT 龙娘' "$AGENTS"; then
  echo "AGENTS.md 已有龙娘说明，跳过"
else
  cat >> "$AGENTS" <<'MD'

## 桌面上的 GPT 龙娘（桌宠通知）

桌面上有一只叫「GPT 龙娘」的桌宠替我盯着所有线程。规则：
1. 先正常写完完整的回复，notify 只是最后附带的一条通知，绝不能用 notify 代替回复。
2. 回复写完后的最后一步，调用 notify 工具：topic 是这条线程的主题（几个字，每次保持一致）；headline 一句话结论；points 最多三条要点。
3. 需要我做决定时，填 question，能给选项就给 options（2–4 个，第一个放推荐项）；工具会把我在气泡里的回答直接返回给你，拿到后直接继续。
4. 出错、卡住、做不了时 kind 填 error。闲聊和一句话能答完的问题不用调用。
MD
  echo "已追加 AGENTS.md 说明"
fi

# --- 3. 原生桌宠包 ---
if [ -f codex-pet/gpt-dragon/spritesheet.webp ]; then
  mkdir -p "$CODEX_HOME/pets"
  rm -rf "$CODEX_HOME/pets/gpt-dragon"
  cp -R codex-pet/gpt-dragon "$CODEX_HOME/pets/gpt-dragon"
  echo "已安装 Codex 原生桌宠：$CODEX_HOME/pets/gpt-dragon（Codex → Settings → Appearance → Pets 里选 GPT 龙娘）"
fi

echo
echo "下一步：完全退出并重开 Codex 桌面版。打开 ClaudeGirl.app 后，龙娘会站在大小姐左边。"
echo "验证：在 Codex 里跑一个任务，结束时龙娘应弹出气泡；或者在菜单栏茶杯里点「测试一下龙娘的气泡」。"
