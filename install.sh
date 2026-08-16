#!/usr/bin/env bash
# codex-quota-saver installer（macOS / Linux）
# 用法:
#   ./install.sh <CODEX_HOME> <PROJECT_PATH> [--dry-run|--uninstall]
# 行为: 备份不删除; 追加内容带托管标记（可精确回滚）; 项目数据文件绝不覆盖;
#       manifest 驱动 uninstall/rollback; 幂等（重复安装安全）。
set -euo pipefail

CODEX_HOME="${1:-$HOME/.codex}"
PROJECT_PATH="${2:-}"
MODE="${3:-install}"
# 双参数简写：install.sh <CODEX_HOME> --uninstall / --dry-run
if [ "$MODE" = "install" ] && [ "$PROJECT_PATH" = "--uninstall" ]; then MODE="--uninstall"; PROJECT_PATH=""; fi
if [ "$MODE" = "install" ] && [ "$PROJECT_PATH" = "--dry-run" ]; then MODE="--dry-run"; PROJECT_PATH=""; fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$CODEX_HOME/.codex-quota-saver-manifest"

log() { echo "[cqs] $*"; }

# manifest 行式格式: action<TAB>dest<TAB>key=value 空格分隔（显式 TAB 连接，$* 会用 IFS 首字符=空格）
# dry-run 下为 no-op（dry-run 必须零落盘；skip 条目只属于真实安装）
manifest_add() {
  [ "$MODE" = "install" ] || return 0
  local line="" first=1 a
  for a in "$@"; do
    if [ "$first" = "1" ]; then line="$a"; first=0; else line="$line"$'\t'"$a"; fi
  done
  printf '%s\n' "$line" >> "$MANIFEST"
}

block_begin() { echo "<!-- cqs-managed-block:$1 begin -->"; }
block_end()   { echo "<!-- cqs-managed-block:$1 end -->"; }

add_managed_block() { # $1=file $2=id $3=content-file
  if [ -f "$1" ] && grep -qF "$(block_begin "$2")" "$1"; then
    log "skip (block present): $1"
    manifest_add "append" "$1" "id=$2" "created=0"   # 卸载仍需按 id 摘块
    return
  fi
  if [ "$MODE" = "--dry-run" ]; then log "dry-run append: $1"; return; fi
  local existed=0 created=1 backup=""
  [ -f "$1" ] && existed=1
  if [ "$existed" = "1" ]; then backup="$1.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$1" "$backup"; created=0; fi
  { printf '\n'; block_begin "$2"; cat "$3"; block_end "$2"; printf '\n'; } >> "$1"
  manifest_add "append" "$1" "id=$2" "backup=$backup" "created=$created"
  log "append block: $1"
}

remove_managed_block() { # $1=file $2=id [$3=begin $4=end]（默认 HTML 注释标记；TOML 段传 # 注释标记）
  local b e
  b="${3:-$(block_begin "$2")}"; e="${4:-$(block_end "$2")}"
  if [ ! -f "$1" ] || ! grep -qF "$b" "$1"; then return; fi
  awk -v b="$b" -v e="$e" '
    $0==b {skip=1; next} $0==e {skip=0; next} !skip' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
  log "remove block: $1"
}

merge_agents_toml() { # $1=file
  if [ -f "$1" ] && grep -qE '^[[:space:]]*\[agents\]' "$1"; then
    log "skip ([agents] present): $1"
    manifest_add "append" "$1" "id=agents-toml" "created=0"
    return
  fi
  if [ "$MODE" = "--dry-run" ]; then log "dry-run append: $1"; return; fi
  local existed=0 created=1 backup=""
  [ -f "$1" ] && existed=1
  if [ "$existed" = "1" ]; then backup="$1.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$1" "$backup"; created=0; fi
  cat >> "$1" <<'EOF'

# --- codex-quota-saver managed [agents] begin ---
[agents]
enabled = true
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "max"
max_concurrent_threads_per_session = 6
# --- codex-quota-saver managed [agents] end ---
EOF
  manifest_add "append" "$1" "id=agents-toml" "backup=$backup" "created=$created"
  log "append [agents]: $1"
}

install_file() { # $1=src $2=dest $3=skip_if_exists(0/1) $4=overwrite_if_changed(0/1)
  if [ -f "$2" ]; then
    if [ "$3" = "1" ]; then
      log "skip (exists): $2"
      manifest_add "copy" "$2" "sha256=$(sha256sum "$2" | cut -d' ' -f1)"   # 卸载按未改动判定可删
      return
    fi
    if [ "$4" = "1" ] && cmp -s "$1" "$2"; then
      log "skip (identical): $2"
      manifest_add "copy" "$2" "sha256=$(sha256sum "$2" | cut -d' ' -f1)"
      return
    fi
  fi
  if [ "$MODE" = "--dry-run" ]; then log "dry-run copy: $2"; return; fi
  mkdir -p "$(dirname "$2")"
  local backup=""
  if [ -f "$2" ]; then backup="$2.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$2" "$backup"; fi
  cp -p "$1" "$2"
  manifest_add "copy" "$2" "src=$1" "backup=$backup" "sha256=$(sha256sum "$2" | cut -d' ' -f1)"
  log "copy: $2"
}

do_uninstall() {
  if [ ! -f "$MANIFEST" ]; then log "无安装记录，无需卸载。"; return; fi
  local dirty=0
  while IFS=$'\t' read -r action dest rest; do
    [ -z "$action" ] && continue
    case "$action" in
      append)
        id=$(printf '%s' "$rest" | sed -n 's/.*\bid=\([^[:space:]]*\).*/\1/p')
        created=$(printf '%s' "$rest" | sed -n 's/.*\bcreated=\([^[:space:]]*\).*/\1/p')
        [ -n "$id" ] || continue
        if [ "$id" = "agents-toml" ]; then
          remove_managed_block "$dest" "$id" '# --- codex-quota-saver managed [agents] begin ---' '# --- codex-quota-saver managed [agents] end ---' || true
        else
          remove_managed_block "$dest" "$id" || true
        fi
        if [ "$created" = "1" ] && [ -f "$dest" ]; then
          # 安装创建的文件：块摘除后若为空则整删
          if ! grep -q '[^[:space:]]' "$dest"; then rm -f "$dest"; log "已移除（安装创建）: $dest"; else log "含用户内容，保留文件（托管块已摘除）: $dest"; fi
        fi
        ;;
      copy)
        [ -f "$dest" ] || continue
        case "$dest" in
          */.codex/config.toml|*/.codex/next-step.md) log "跳过项目数据文件（保留）: $dest"; continue ;;
        esac
        sha=$(printf '%s' "$rest" | sed -n 's/.*\bsha256=\([^[:space:]]*\).*/\1/p')
        cur=$(sha256sum "$dest" | cut -d' ' -f1)
        if [ -n "$sha" ] && [ "$cur" = "$sha" ]; then rm -f "$dest"; log "已移除: $dest"; else dirty=1; log "已改动，跳过（备份仍在）: $dest"; fi
        ;;
    esac
  done < "$MANIFEST"
  if [ "$dirty" = "1" ]; then log "部分文件已改动未删除；manifest 保留备查: $MANIFEST"; else rm -f "$MANIFEST"; log "已清除安装记录（干净卸载）。"; fi
  log "卸载完成。.bak 备份文件未删除，请自行处理。"
}

if [ "$MODE" = "--uninstall" ]; then do_uninstall; exit 0; fi
if [ "$MODE" != "--dry-run" ] && [ "$MODE" != "install" ]; then
  echo "用法: install.sh <CODEX_HOME> <PROJECT_PATH> [--dry-run|--uninstall]"; exit 2
fi
if [ -z "$PROJECT_PATH" ] || [ ! -d "$PROJECT_PATH" ]; then
  echo "项目路径不存在"
  exit 1
fi

# dry-run 不得落任何文件（目录也不建）；uninstall 已提前退出
if [ "$MODE" = "install" ]; then
  rm -f "$MANIFEST"   # 本次运行重新记录（幂等靠各步骤的 skip 判定，skip 条目同样写入 manifest）
  mkdir -p "$CODEX_HOME/agents"
fi

add_managed_block "$CODEX_HOME/AGENTS.md" "global-agents" "$REPO_ROOT/global/AGENTS.md"
merge_agents_toml  "$CODEX_HOME/config.toml"
install_file "$REPO_ROOT/global/agents/luna-worker.toml" "$CODEX_HOME/agents/luna-worker.toml" 0 1
install_file "$REPO_ROOT/project/AGENTS.md" "$PROJECT_PATH/AGENTS.md" 1 0
install_file "$REPO_ROOT/project/dot-codex/config.toml" "$PROJECT_PATH/.codex/config.toml" 1 0
install_file "$REPO_ROOT/project/dot-codex/next-step.md" "$PROJECT_PATH/.codex/next-step.md" 1 0
install_file "$REPO_ROOT/project/dot-codex/skills/luna-routing/SKILL.md" "$PROJECT_PATH/.codex/skills/luna-routing/SKILL.md" 0 1
log "安装完成（mode=$MODE）。"
