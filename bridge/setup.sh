#!/usr/bin/env bash
# bridge/setup.sh —— 双进程部署（macOS / Linux）
# 用法: ./bridge/setup.sh <ngrok域名> <workspace> [<oauth密码>] [--dry-run]
# 认证：guard 自建 OAuth 2.1（ChatGPT 连接器只有 OAuth/无认证/混合，API key 不可行）。
# 安全：umask 077 全程；secrets 落 .secrets.local.env（600 + gitignore）；密码/token 经环境变量注入。
set -euo pipefail
umask 077

DOMAIN="${1:-}"; WORKSPACE="${2:-}"; OAUTH_PASSWORD="${3:-}"; MODE="${4:-install}"
# 兼容双参数简写：setup.sh <域名> <工作区> --dry-run
if [ "$OAUTH_PASSWORD" = "--dry-run" ]; then MODE="--dry-run"; OAUTH_PASSWORD=""; fi
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%/}"

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BRIDGE_DIR/.secrets.local.env"
GUARD_CONF="$BRIDGE_DIR/guard/guard_config.json"
OAUTH_STATE="$BRIDGE_DIR/guard/oauth_state.json"
LAUNCHER="$BRIDGE_DIR/start-bridge.local.sh"
GUARD_PORT=8766; UPSTREAM_PORT=8765

ALLOWLIST='server_info read_file list_dir list_files search_text git_status git_diff git_log git_show git_blame view_image'

new_token() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# awk 吃满全量输入再退出，避免 head 提前退出给 tr 发 SIGPIPE（pipefail 下会炸）
new_password() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z2-9' | awk '{print substr($0,1,16)}'; }

if [ -z "$DOMAIN" ] || [ -z "$WORKSPACE" ]; then
  echo "用法: setup.sh <ngrok域名> <workspace> [<oauth密码>] [--dry-run]"
  exit 2
fi
if [ ! -d "$WORKSPACE" ]; then
  echo "工作区不存在: $WORKSPACE"
  exit 1
fi
if [ -n "$OAUTH_PASSWORD" ] && ! echo "$OAUTH_PASSWORD" | grep -qE '^[A-Za-z0-9]+$'; then
  echo "OAuth 密码仅支持字母数字（启动器解析限制）；留空则自动生成随机密码"
  exit 2
fi

if [ "$MODE" = "--dry-run" ]; then
  echo "[dry-run] 将生成 $ENV_FILE / $GUARD_CONF / $LAUNCHER（密码随机，token 随机）"
  echo "[dry-run] 运行时生成 $OAUTH_STATE（token_secret + 客户端注册表，重启免疫）"
  echo "[dry-run] 依赖：coding-tools-mcp==0.3.0 + guard venv（mcp==2.0.0 + pyjwt==2.13.0）+ ngrok 3.39.11"
  exit 0
fi

command -v uv >/dev/null || { echo "缺少 uv: https://docs.astral.sh/uv/"; exit 1; }
command -v ngrok >/dev/null || { echo "缺少 ngrok（实测 pin: 3.39.11，见 COMPATIBILITY.md）"; exit 1; }
uv tool install "coding-tools-mcp==0.3.0" >/dev/null
if [ ! -x "$BRIDGE_DIR/guard/.venv/bin/python" ]; then
  uv venv --python 3.11 "$BRIDGE_DIR/guard/.venv" >/dev/null
fi
# 每次都同步依赖（幂等）：requirements 升级后重跑 setup 即生效（如 pyjwt 为新增依赖）
uv pip install --python "$BRIDGE_DIR/guard/.venv/bin/python" -r "$BRIDGE_DIR/guard/requirements.txt" >/dev/null

UP_TOK="$(new_token)"
if [ -z "$OAUTH_PASSWORD" ]; then OAUTH_PASSWORD="$(new_password)"; fi

cat > "$ENV_FILE" <<EOF
# codex-quota-saver bridge secrets (chmod 600 + gitignore) — DO NOT COMMIT
export CQS_OAUTH_PASSWORD=$OAUTH_PASSWORD
export CQS_UPSTREAM_TOKEN=$UP_TOK
EOF
chmod 600 "$ENV_FILE"

# shellcheck disable=SC2086  # $ALLOWLIST 故意的分词（拆成 JSON 数组元素）
ALLOWLIST_JSON=$(printf '"%s", ' $ALLOWLIST | sed 's/, $//')

cat > "$GUARD_CONF" <<EOF
{
  "host": "127.0.0.1", "port": $GUARD_PORT,
  "workspace": "$WORKSPACE",
  "upstream_url": "http://127.0.0.1:$UPSTREAM_PORT/mcp",
  "public_url": "https://$DOMAIN",
  "upstream_token_env": "CQS_UPSTREAM_TOKEN",
  "oauth_password_env": "CQS_OAUTH_PASSWORD",
  "oauth_state_file": "oauth_state.json",
  "allowlist": [$ALLOWLIST_JSON]
}
EOF
chmod 600 "$GUARD_CONF"

if [ -f "$OAUTH_STATE" ]; then
  echo "检测到已有 OAuth 状态（token_secret + 客户端注册表），保留不重置——重启/重跑 setup 后授权依然有效。"
else
  echo "OAuth 状态文件将在首次启动时自动生成（token_secret + 客户端注册表落盘 = 重启免疫）。"
fi

cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# codex-quota-saver bridge launcher (generated, gitignored)
# 上游不开 OAuth、不对外（认证全在 guard 层）；--auth-token 仅本机静态互信
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
echo "1. 运行 $LAUNCHER 启动桥（上游 + guard + ngrok 三进程）"
echo "2. ChatGPT -> 设置 -> 连接器 -> 新建：URL = https://$DOMAIN/mcp ，认证方式 = OAuth"
echo "3. 连接器发起授权时，浏览器打开的密码页输入 OAuth 密码："
echo "   OAuth 密码 = $OAUTH_PASSWORD（也在 $ENV_FILE 的 CQS_OAUTH_PASSWORD 行，建议存密码管理器）"
echo "4. 新对话冒烟：读仓库提建议 + write_next_step 落盘 .codex/next-step.md"
echo "日常使用：$LAUNCHER；不开发时关闭（隧道=项目后门）"
echo "重启免疫：注册表+签名密钥已落盘，重启桥授权依然有效；只有删除 $OAUTH_STATE 才需重新授权"
