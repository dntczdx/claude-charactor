#!/usr/bin/env bash
# 把 MCP 服务器写进 Claude 桌面版的配置（claude_desktop_config.json），并安装 npm 依赖。
# 装完重启 Claude 桌面版，再把 mcp/CLAUDE_PREFERENCES.md 里那段话贴进个人偏好。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "需要 Node.js 18+：brew install node" >&2
  exit 1
fi
NODE="$(command -v node)"
MAJOR="$("$NODE" -p 'process.versions.node.split(".")[0]')"
if [ "$MAJOR" -lt 18 ]; then
  echo "Node.js 版本太旧（$("$NODE" -v)），需要 18+" >&2
  exit 1
fi

echo "安装 MCP 服务器依赖…"
(cd mcp && npm install --silent --no-audit --no-fund)

CONFIG_DIR="$HOME/Library/Application Support/Claude"
CONFIG="$CONFIG_DIR/claude_desktop_config.json"
mkdir -p "$CONFIG_DIR"
[ -f "$CONFIG" ] || echo '{}' > "$CONFIG"
cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)"

PORT="${CLAUDEGIRL_PORT:-47333}"
"$NODE" - "$CONFIG" "$NODE" "$ROOT/mcp/server/index.js" "$PORT" <<'JS'
const fs = require("fs");
const [file, node, entry, port] = process.argv.slice(2);
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(file, "utf8") || "{}"); } catch (e) { cfg = {}; }
cfg.mcpServers = cfg.mcpServers || {};
cfg.mcpServers["claude-girl"] = {
  command: node,
  args: [entry],
  env: { CLAUDEGIRL_URL: `http://127.0.0.1:${port}` },
};
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
console.log("已写入", file);
JS

echo
echo "下一步："
echo "1. 完全退出并重新打开 Claude 桌面版（⌘Q 再启动）。"
echo "2. 设置 → 开发者 里应能看到 claude-girl 已连接。"
echo "3. 把 mcp/CLAUDE_PREFERENCES.md 里那段话贴进 设置 → 个人偏好。"
