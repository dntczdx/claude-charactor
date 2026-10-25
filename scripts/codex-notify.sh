#!/usr/bin/env bash
# Codex CLI 的 notify hook：Codex 在每轮结束（agent-turn-complete）时以一个 JSON 参数调用本脚本。
# 这里把它转成桌宠的 /notify 事件（agent=codex）。Codex 桌面版不执行这个 hook，桌面版靠 app 监听会话日志。
#
# 安装：scripts/install-codex.sh 会把下面这行写进 ~/.codex/config.toml
#   notify = ["bash", "<仓库路径>/scripts/codex-notify.sh"]
set -u
PAYLOAD="${1:-}"
[ -n "$PAYLOAD" ] || exit 0
URL="${CLAUDEGIRL_URL:-http://127.0.0.1:47333}"

/usr/bin/python3 -I - "$PAYLOAD" "$URL" <<'PY' 2>/dev/null || true
import json, sys, urllib.request
raw, url = sys.argv[1], sys.argv[2]
try:
    ev = json.loads(raw)
except Exception:
    sys.exit(0)
if ev.get("type") not in (None, "agent-turn-complete"):
    sys.exit(0)

def first_line(s, n):
    for line in (s or "").replace("\r", "").split("\n"):
        line = line.strip().lstrip("#*-• ").strip()
        if line:
            return line[:n]
    return ""

inputs = ev.get("input-messages") or ev.get("input_messages") or []
topic = first_line(inputs[0] if inputs else "", 24) or (ev.get("cwd") or "Codex").rstrip("/").split("/")[-1]
last = ev.get("last-assistant-message") or ev.get("last_assistant_message") or ""
lines = [l.strip().lstrip("#*-• ").strip() for l in last.replace("\r", "").split("\n")]
lines = [l for l in lines if l and not l.startswith("```")]
headline = (lines[0] if lines else "这条做完了")[:60]
points = [l[:70] for l in lines[1:] if len(l) >= 4][:3]
body = {
    "agent": "codex",
    "topic": topic,
    "headline": headline,
    "points": points,
    "kind": "done",
    "chat_id": ev.get("thread-id") or ev.get("thread_id") or ev.get("conversation-id"),
}
req = urllib.request.Request(url.rstrip("/") + "/notify", data=json.dumps(body).encode("utf-8"),
                             headers={"content-type": "application/json"}, method="POST")
try:
    urllib.request.urlopen(req, timeout=3).read()
except Exception:
    pass
PY
exit 0
