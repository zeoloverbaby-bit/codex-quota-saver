#!/usr/bin/env bash
# MCP 桥启动模板（macOS / Linux）。首次运行前填好全部 <占位符>，见 bridge/README.md。
# 本文件含密钥，只存本机，绝不进 git / 聊天 / 共享文档。
set -euo pipefail

export CODING_TOOLS_MCP_SERVER_URL="https://<你的-ngrok-静态域名>.ngrok-free.dev"
export CODING_TOOLS_MCP_OAUTH_PASSWORD="<你的-OAuth-密码>"
# OAuth 稳定性三件套：预注册连接器客户端 + 稳定签名密钥 + TTL（缺一即重启废 token）
export CODING_TOOLS_MCP_OAUTH_CLIENT_ID="<从连接器捕获的-client_id>"
export CODING_TOOLS_MCP_OAUTH_REDIRECT_URIS="<从连接器捕获的-redirect_uri>"
export CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET="<64位hex：secrets.token_hex(32)>"
export CODING_TOOLS_MCP_OAUTH_TOKEN_TTL="604800"

if ! (exec 3<>/dev/tcp/127.0.0.1/8765) 2>/dev/null; then
  echo "Starting MCP server (background)..."
  nohup coding-tools-mcp \
    --workspace "<你的项目仓库路径>" \
    --host 127.0.0.1 --port 8765 \
    --auth-token "<静态-Bearer-令牌>" \
    --oauth-mode > /tmp/coding-tools-mcp.log 2>&1 &
  sleep 8
else
  exec 3>&- 3<&-
  echo "[OK] MCP server already running on port 8765."
fi

echo "============================================"
echo "  PERMANENT URL (never changes):"
echo "  https://<你的-ngrok-静态域名>.ngrok-free.dev/mcp"
echo "  Keep this window open while using ChatGPT."
echo "  Close it to stop the tunnel (Ctrl+C)."
echo "============================================"

exec ngrok http --url="<你的-ngrok-静态域名>" 8765
