#!/usr/bin/env bash
# 生成一张本机自签名的代码签名证书「ClaudeGirl Dev」并装进登录钥匙串。
# 之后 build-app.sh 会自动用它签名，签名稳定了，辅助功能权限就不用每次重编译都重新授权。
# 只需运行一次。
set -euo pipefail

NAME="ClaudeGirl Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "钥匙串里已经有「${NAME}」，不用再生成。"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > ext.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ClaudeGirl Dev
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -config ext.cnf >/dev/null 2>&1
PASS="claudegirl"
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -passout "pass:$PASS" -name "$NAME" >/dev/null 2>&1

echo "导入登录钥匙串（可能弹出输入登录密码的窗口）…"
security import cert.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# 信任这张证书用于代码签名（当前用户）
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem 2>/dev/null || \
  security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem
# 让 codesign 用这把私钥时不反复弹窗
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "完成：$(security find-identity -v -p codesigning | grep "$NAME")"
  echo "现在重新跑 scripts/build-app.sh，第一次 codesign 若弹窗问是否允许访问钥匙串，选「始终允许」。"
  echo "装好后在 Accessibility 里把旧条目删掉、重新加一次 /Applications/ClaudeGirl.app，以后就不用再动了。"
else
  echo "证书导入了，但 codesign 还没识别为可用身份。打开「钥匙串访问」，找到「${NAME}」→ 显示简介 → 信任 → 代码签名 改为「始终信任」，再重试。" >&2
  exit 1
fi
