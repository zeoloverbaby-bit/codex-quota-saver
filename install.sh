#!/usr/bin/env bash
# codex-three-tier-orchestration 安装脚本（macOS / Linux）
# 用法: ./install.sh [CODEX_HOME] [PROJECT_PATH]
# 行为: 备份不删除; config.toml 只追加 [agents] 段; AGENTS.md 只追加小节;
#       项目级 config.toml / next-step.md 已存在则跳过（绝不覆盖真实任务数据）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${1:-$HOME/.codex}"
PROJECT_PATH="${2:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"

backup() { [ -e "$1" ] && cp "$1" "$1.bak-$STAMP" && echo "[backup] $1 -> $1.bak-$STAMP"; }
ensure_dir() { [ -d "$1" ] || mkdir -p "$1"; }

echo "== codex-three-tier-orchestration installer =="
echo "CODEX_HOME   = $CODEX_HOME"
echo "PROJECT_PATH = ${PROJECT_PATH:-<未指定，跳过项目级文件>}"
echo ""

# 1. config.toml: 追加 [agents] 段（已存在则跳过）
CFG="$CODEX_HOME/config.toml"
BLOCK="$REPO_ROOT/global/config-agents.toml"
if [ -f "$CFG" ]; then
  if grep -q '^\s*\[agents\]' "$CFG"; then
    echo "[skip] config.toml 已有 [agents] 段"
  else
    backup "$CFG"
    printf '\n\n' >> "$CFG"
    cat "$BLOCK" >> "$CFG"
    echo "[append] [agents] 段 -> $CFG"
  fi
else
  ensure_dir "$CODEX_HOME"
  cp "$BLOCK" "$CFG"
  echo "[create] $CFG"
fi

# 2. AGENTS.md: 不存在则创建; 已存在则追加小节（不覆盖）
AG="$CODEX_HOME/AGENTS.md"
SRC="$REPO_ROOT/global/AGENTS.md"
if [ -f "$AG" ]; then
  if grep -q '子代理使用规则' "$AG"; then
    echo "[skip] AGENTS.md 已含路由规则小节"
  else
    backup "$AG"
    {
      printf '\n\n---\n\n## 以下内容由 codex-three-tier-orchestration 安装（可整体删除回滚）\n\n'
      cat "$SRC"
    } >> "$AG"
    echo "[append] 路由规则小节 -> $AG"
  fi
else
  ensure_dir "$CODEX_HOME"
  cp "$SRC" "$AG"
  echo "[create] $AG"
fi

# 3. luna-worker.toml: 备份 + 复制
DST="$CODEX_HOME/agents/luna-worker.toml"
ensure_dir "$(dirname "$DST")"
backup "$DST"
cp "$REPO_ROOT/global/agents/luna-worker.toml" "$DST"
echo "[install] $DST"

# 4. 项目级文件（PROJECT_PATH 指定时）
if [ -n "$PROJECT_PATH" ]; then
  if [ -f "$PROJECT_PATH/.codex/config.toml" ]; then
    echo "[skip] 已存在，保留你的版本: $PROJECT_PATH/.codex/config.toml"
  else
    ensure_dir "$PROJECT_PATH/.codex"
    cp "$REPO_ROOT/project/dot-codex/config.toml" "$PROJECT_PATH/.codex/config.toml"
    echo "[install] $PROJECT_PATH/.codex/config.toml"
  fi
  if [ -f "$PROJECT_PATH/.codex/next-step.md" ]; then
    echo "[skip] 已存在，保留你的版本（真实任务数据绝不覆盖）: $PROJECT_PATH/.codex/next-step.md"
  else
    ensure_dir "$PROJECT_PATH/.codex"
    cp "$REPO_ROOT/project/dot-codex/next-step.md" "$PROJECT_PATH/.codex/next-step.md"
    echo "[install] $PROJECT_PATH/.codex/next-step.md"
  fi
  SKILL_DST="$PROJECT_PATH/.codex/skills/luna-routing/SKILL.md"
  ensure_dir "$(dirname "$SKILL_DST")"
  if [ -f "$SKILL_DST" ]; then
    backup "$SKILL_DST"
    cp "$REPO_ROOT/project/dot-codex/skills/luna-routing/SKILL.md" "$SKILL_DST"
    echo "[update] $SKILL_DST"
  else
    cp "$REPO_ROOT/project/dot-codex/skills/luna-routing/SKILL.md" "$SKILL_DST"
    echo "[install] $SKILL_DST"
  fi
else
  echo "[skip] 未指定 PROJECT_PATH，跳过项目级文件（用法: ./install.sh ~/.codex /path/to/project）"
fi

echo ""
echo "完成。下一步："
echo "1. Codex App 设置-配置 开启 reasoning effort 档位（含 max）"
echo "2. Codex 开新会话（AGENTS.md / config 改动需新会话才生效）"
echo "3. 首次 spawn 子代理后核对 rollout 实际模型是否为 gpt-5.6-luna（issue #32587）"
