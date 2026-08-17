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
    manifest_add "append" "$1" "managed_block_id=$2" "ownership=user" "created_by_cqs=0" "modified_by_cqs=1"
    return
  fi
  if [ "$MODE" = "--dry-run" ]; then log "dry-run append: $1"; return; fi
  local existed=0 created=1 modified=0 ownership="cqs" backup=""
  [ -f "$1" ] && existed=1
  if [ "$existed" = "1" ]; then backup="$1.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$1" "$backup"; created=0; modified=1; ownership="user"; fi
  { printf '\n'; block_begin "$2"; cat "$3"; block_end "$2"; printf '\n'; } >> "$1"
  manifest_add "append" "$1" "managed_block_id=$2" "ownership=$ownership" "created_by_cqs=$created" "modified_by_cqs=$modified" "backup=$backup"
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
    manifest_add "append" "$1" "managed_block_id=agents-toml" "ownership=user" "created_by_cqs=0" "modified_by_cqs=1"
    return
  fi
  if [ "$MODE" = "--dry-run" ]; then log "dry-run append: $1"; return; fi
  local existed=0 created=1 modified=0 ownership="cqs" backup=""
  [ -f "$1" ] && existed=1
  if [ "$existed" = "1" ]; then backup="$1.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$1" "$backup"; created=0; modified=1; ownership="user"; fi
  cat >> "$1" <<'EOF'

# --- codex-quota-saver managed [agents] begin ---
[agents]
enabled = true
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "max"
max_concurrent_threads_per_session = 6
# --- codex-quota-saver managed [agents] end ---
EOF
  manifest_add "append" "$1" "managed_block_id=agents-toml" "ownership=$ownership" "created_by_cqs=$created" "modified_by_cqs=$modified" "backup=$backup"
  log "append [agents]: $1"
}

install_file() { # $1=src $2=dest $3=skip_if_exists(0/1) $4=overwrite_if_changed(0/1)
  local existed=0
  [ -f "$2" ] && existed=1
  if [ "$existed" = "1" ]; then
    if [ "$3" = "1" ]; then
      log "skip (exists): $2"
      # skip（用户原有）条目不记录哈希：卸载阶段没有「hash 没变就可删」的路径
      manifest_add "copy" "$2" "ownership=user" "created_by_cqs=0" "modified_by_cqs=0"
      return
    fi
    if [ "$4" = "1" ] && cmp -s "$1" "$2"; then
      log "skip (identical): $2"
      manifest_add "copy" "$2" "ownership=user" "created_by_cqs=0" "modified_by_cqs=0"
      return
    fi
  fi
  if [ "$MODE" = "--dry-run" ]; then log "dry-run copy: $2"; return; fi
  mkdir -p "$(dirname "$2")"
  local backup=""
  if [ "$existed" = "1" ]; then backup="$2.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$2" "$backup"; fi
  cp -p "$1" "$2"
  local ownership="cqs" created=1 modified=0
  if [ "$existed" = "1" ]; then ownership="user" created=0 modified=1; fi
  # backup 必须为最后字段（路径可含空格，uninstall 用「最后出现的 backup=」提取）
  manifest_add "copy" "$2" "ownership=$ownership" "created_by_cqs=$created" "modified_by_cqs=$modified" "installed_hash=$(sha256sum "$2" | cut -d' ' -f1)" "src=$1" "backup=$backup"
  log "copy: $2"
}

do_uninstall() {
  if [ ! -f "$MANIFEST" ]; then log "无安装记录，无需卸载。"; return; fi
  local dirty=0
  while IFS=$'\t' read -r action dest rest; do
    [ -z "$action" ] && continue
    # 新格式用 managed_block_id/ownership；旧格式 append 条目用 id（块摘除安全，兼容处理）
    block_id=$(printf '%s' "$rest" | sed -n 's/.*\bmanaged_block_id=\([^[:space:]]*\).*/\1/p')
    if [ -z "$block_id" ]; then block_id=$(printf '%s' "$rest" | sed -n 's/.*\bid=\([^[:space:]]*\).*/\1/p'); fi
    ownership=$(printf '%s' "$rest" | sed -n 's/.*\bownership=\([^[:space:]]*\).*/\1/p')
    created_by_cqs=$(printf '%s' "$rest" | sed -n 's/.*\bcreated_by_cqs=\([^[:space:]]*\).*/\1/p')
    if [ -z "$created_by_cqs" ]; then created_by_cqs=$(printf '%s' "$rest" | sed -n 's/.*\bcreated=\([^[:space:]]*\).*/\1/p'); fi
    modified_by_cqs=$(printf '%s' "$rest" | sed -n 's/.*\bmodified_by_cqs=\([^[:space:]]*\).*/\1/p')
    installed_hash=$(printf '%s' "$rest" | sed -n 's/.*\binstalled_hash=\([^[:space:]]*\).*/\1/p')
    backup=$(printf '%s' "$rest" | sed -n 's/.*backup=//p')
    case "$action" in
      append)
        if [ -n "$block_id" ]; then
          if [ "$block_id" = "agents-toml" ]; then
            remove_managed_block "$dest" "$block_id" '# --- codex-quota-saver managed [agents] begin ---' '# --- codex-quota-saver managed [agents] end ---' || true
          else
            remove_managed_block "$dest" "$block_id" || true
          fi
          if [ "$created_by_cqs" = "1" ] && [ -f "$dest" ]; then
            # 安装创建的文件：块摘除后若为空则整删
            if ! grep -q '[^[:space:]]' "$dest"; then rm -f "$dest"; log "已移除（安装创建）: $dest"; else log "含用户内容，保留文件（托管块已摘除）: $dest"; fi
          fi
        fi
        ;;
      copy)
        [ -f "$dest" ] || continue
        if [ -z "$ownership" ] && [ -z "$block_id" ]; then
          # 旧格式条目（只有 sha256）：无所有权证据 → 保守永不删除（fail-safe）
          log "旧版 manifest 条目（无所有权信息），保守跳过: $dest"
          continue
        fi
        cur=$(sha256sum "$dest" | cut -d' ' -f1)
        if [ "$created_by_cqs" = "1" ]; then
          # CQS 创建的文件：自安装后未改动才删；改动则保留
          if [ -n "$installed_hash" ] && [ "$cur" = "$installed_hash" ]; then rm -f "$dest"; log "已移除（安装创建，未改动）: $dest"; else dirty=1; log "安装后已被修改，保留文件: $dest"; fi
        elif [ "$modified_by_cqs" = "1" ] && [ -n "$backup" ]; then
          # CQS 覆盖过用户原文件：未改动 → 恢复原文件并消费 backup；改动 → 保留两者提示人工
          if [ "$cur" = "$installed_hash" ]; then cp -p "$backup" "$dest" && rm -f "$backup"; log "已恢复原文件（备份已消费）: $dest"; else dirty=1; log "安装后已被修改，保留当前文件与备份，请人工处理: $dest / $backup"; fi
        else
          # ownership=user 且 CQS 未修改（skip 条目）：无论 hash 如何，永不删除
          log "用户原有文件，跳过（不删除）: $dest"
        fi
        ;;
    esac
  done < "$MANIFEST"
  if [ "$dirty" = "1" ]; then log "部分文件已改动未处理；manifest 保留备查: $MANIFEST"; else rm -f "$MANIFEST"; log "已清除安装记录（干净卸载）。"; fi
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
# 项目级协议：托管块合并（已存在追加、不存在创建）；协议文本 source of truth = project/AGENTS.md
add_managed_block "$PROJECT_PATH/AGENTS.md" "project-protocol" "$REPO_ROOT/project/AGENTS.md"
install_file "$REPO_ROOT/project/dot-codex/config.toml" "$PROJECT_PATH/.codex/config.toml" 1 0
install_file "$REPO_ROOT/project/dot-codex/next-step.md" "$PROJECT_PATH/.codex/next-step.md" 1 0
install_file "$REPO_ROOT/project/dot-codex/skills/luna-routing/SKILL.md" "$PROJECT_PATH/.codex/skills/luna-routing/SKILL.md" 0 1
log "安装完成（mode=$MODE）。"
