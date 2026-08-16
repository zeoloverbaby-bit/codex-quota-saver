#!/usr/bin/env bash
# bridge/setup.sh —— 双进程部署（macOS / Linux）
# 用法: ./bridge/setup.sh <ngrok域名> <workspace> [--dry-run]
# 认证简化：连接器用 API key = guard token；OAuth 链路整体退役。
# 安全：umask 077 全程；secrets 落 .secrets.local.env（600 + gitignore）；token 经环境变量注入。
set -euo pipefail
umask 077

DOMAIN="${1:-}"; WORKSPACE="${2:-}"; MODE="${3:-install}"
BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BRIDGE_DIR/.secrets.local.env"
GUARD_CONF="$BRIDGE_DIR/guard/guard_config.json"
LAUNCHER="$BRIDGE_DIR/start-bridge.local.sh"
GUARD_PORT=8766; UPSTREAM_PORT=8765

ALLOWLIST='server_info read_file list_dir list_files search_text git_status git_diff git_log git_show git_blame view_image'

new_token() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

if [ -z "$DOMAIN" ] || [ -z "$WORKSPACE" ]; then
  echo "用法: setup.sh <ngrok域名> <workspace> [--dry-run]"
  exit 2
fi
if [ ! -d "$WORKSPACE" ]; then
  echo "工作区不存在: $WORKSPACE"
  exit 1
fi

if [ "$MODE" = "--dry-run" ]; then
  echo "[dry-run] 将生成 $ENV_FILE / $GUARD_CONF / $LAUNCHER（token 随机）"
  echo "[dry-run] 依赖：coding-tools-mcp==0.3.0 + guard venv（mcp>=2.0）+ ngrok 3.39.11"
  exit 0
fi

command -v uv >/dev/null || { echo "缺少 uv: https://docs.astral.sh/uv/"; exit 1; }
command -v ngrok >/dev/null || { echo "缺少 ngrok（实测 pin: 3.39.11，见 COMPATIBILITY.md）"; exit 1; }
uv tool install "coding-tools-mcp==0.3.0" >/dev/null
if [ ! -x "$BRIDGE_DIR/guard/.venv/bin/python" ]; then
  uv venv --python 3.11 "$BRIDGE_DIR/guard/.venv" >/dev/null
  uv pip install --python "$BRIDGE_DIR/guard/.venv/bin/python" -r "$BRIDGE_DIR/guard/requirements.txt" >/dev/null
fi

GUARD_TOK="$(new_token)"; UP_TOK="$(new_token)"
cat > "$ENV_FILE" <<EOF
# codex-quota-saver bridge secrets (chmod 600 + gitignore) — DO NOT COMMIT
export CQS_GUARD_TOKEN=$GUARD_TOK
export CQS_UPSTREAM_TOKEN=$UP_TOK
EOF
chmod 600 "$ENV_FILE"

cat > "$GUARD_CONF" <<EOF
{
  "host": "127.0.0.1", "port": $GUARD_PORT,
  "workspace": "$WORKSPACE",
  "upstream_url": "http://127.0.0.1:$UPSTREAM_PORT/mcp",
  "token_env": "CQS_GUARD_TOKEN", "upstream_token_env": "CQS_UPSTREAM_TOKEN",
  # shellcheck disable=SC2086  # $ALLOWLIST 故意的分词（拆成 JSON 数组元素）
  "allowlist": [$(printf '"%s", ' $ALLOWLIST | sed 's/, $//')]
}
EOF
chmod 600 "$GUARD_CONF"

cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# codex-quota-saver bridge launcher (generated, gitignored)
set -euo pipefail
source "$ENV_FILE"
"\$(command -v coding-tools-mcp)" --workspace "$WORKSPACE" --host 127.0.0.1 --port $UPSTREAM_PORT --auth-token "\$CQS_UPSTREAM_TOKEN" &
UP_PID=\$!
"$BRIDGE_DIR/guard/.venv/bin/python" "$BRIDGE_DIR/guard/guard.py" --config "$GUARD_CONF" &
GUARD_PID=\$!
trap 'kill \$UP_PID \$GUARD_PID 2>/dev/null || true' EXIT
ngrok http --url="$DOMAIN" $GUARD_PORT
EOF
chmod 700 "$LAUNCHER"

echo ""
echo "======== 部署完成（人工 2 分钟）========"
echo "1. ChatGPT -> 设置 -> 连接器 -> 新建：URL = https://$DOMAIN/mcp ，认证方式 = API key"
echo "2. API key 值 = $GUARD_TOK（也在 $ENV_FILE 的 CQS_GUARD_TOKEN 行）"
echo "3. 新对话冒烟：read + write_next_step 落盘"
echo "日常使用：$LAUNCHER；不开发时关闭（隧道=项目后门）"
