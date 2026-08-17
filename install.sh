#!/usr/bin/env bash
# codex-quota-saver installer（macOS / Linux）
# 用法:
#   ./install.sh <CODEX_HOME> <PROJECT_PATH> [--dry-run|--uninstall]
# 行为: manifest 记录所有权（user/cqs）；追加内容带托管标记；项目数据文件绝不覆盖；
#       uninstall 按所有权精确回滚——用户原有文件永不删除、CQS 创建文件未改动才删、
#       覆盖过的文件恢复原备份（消费 .bak）；用户改过的文件一律保留；幂等（重复安装安全）。
# 生命周期幂等: 重复安装读旧 manifest 做 provenance 合并（created/modified 只增不减、
#       backup 身份只保留第一份）；安装全程写 journal，全部成功才原子提交——
#       中途失败旧 manifest 原样保留、本轮 mutation 回滚、journal 留存取证。
set -euo pipefail

CODEX_HOME="${1:-$HOME/.codex}"
PROJECT_PATH="${2:-}"
MODE="${3:-install}"
# 双参数简写：install.sh <CODEX_HOME> --uninstall / --dry-run
if [ "$MODE" = "install" ] && [ "$PROJECT_PATH" = "--uninstall" ]; then MODE="--uninstall"; PROJECT_PATH=""; fi
if [ "$MODE" = "install" ] && [ "$PROJECT_PATH" = "--dry-run" ]; then MODE="--dry-run"; PROJECT_PATH=""; fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 测试 seam：CQS_TEST_SOURCE_ROOT 指向 staged source 树（S1/S2 升级场景）；默认脚本所在目录
SOURCE_ROOT="${CQS_TEST_SOURCE_ROOT:-$REPO_ROOT}"
MANIFEST="$CODEX_HOME/.codex-quota-saver-manifest"
# provenance 合并需要旧 manifest 安装全程可读：写入只进 journal，成功后才原子提交
MANIFEST_JOURNAL="$MANIFEST.tmp"

log() { echo "[cqs] $*"; }
# 测试/排障专用跟踪（默认关闭；CQS_TEST_DEBUG=1 时输出 reconcile 内部状态）。
# 必须恒返回 0：`[ -n ] && log` 在变量未设置时列表返回 1，函数返回非零会被
# 调用处的 set -e 当场击落（2026-08-17 CI 现场：二次安装全部静默失败即此因）。
cqs_debug() {
  if [ -n "${CQS_TEST_DEBUG:-}" ]; then
    log "DEBUG: $*"
  fi
  return 0
}

# manifest 行式格式: action<TAB>dest<TAB>key=value 空格分隔（显式 TAB 连接，$* 会用 IFS 首字符=空格）
# dry-run 下为 no-op（dry-run 必须零落盘；skip 条目只属于真实安装）
manifest_add() {
  [ "$MODE" = "install" ] || return 0
  local line="" first=1 a
  for a in "$@"; do
    if [ "$first" = "1" ]; then line="$a"; first=0; else line="$line"$'\t'"$a"; fi
  done
  printf '%s\n' "$line" >> "$MANIFEST_JOURNAL"
}

unique_backup_path() { # $1=dest —— 同秒冲突防护：绝不覆盖既有备份（origin 只有第一份）
  local base i=1
  base="$1.bak-$(date +%Y%m%d-%H%M%S)"
  [ -e "$base" ] || { echo "$base"; return; }
  while [ -e "$base-$i" ]; do i=$((i+1)); done
  echo "$base-$i"
}

manifest_field() { # $1=line $2=field —— 与 do_uninstall 的解析口径一致
  local line="$1" f="$2"
  case "$f" in
    backup) printf '%s' "$line" | sed -n 's/.*backup=//p' ;;
    ownership) printf '%s' "$line" | sed -n 's/.*\bownership=\([^[:space:]]*\).*/\1/p' ;;
    created_by_cqs) printf '%s' "$line" | sed -n 's/.*\bcreated_by_cqs=\([^[:space:]]*\).*/\1/p' ;;
    modified_by_cqs) printf '%s' "$line" | sed -n 's/.*\bmodified_by_cqs=\([^[:space:]]*\).*/\1/p' ;;
    installed_hash) printf '%s' "$line" | sed -n 's/.*\binstalled_hash=\([^[:space:]]*\).*/\1/p' ;;
    *) printf '' ;;
  esac
}

prev_line() { # $1=dest —— 旧 manifest 中该 dest 的最后一条（awk 按 TAB 第 2 列精确匹配）
  [ -f "$MANIFEST" ] || return 0
  awk -F '\t' -v d="$1" '$2 == d { last=$0 } END { if (last != "") print last }' "$MANIFEST"
}

maybe_fail() { # $1=step —— 测试专用失败注入钩子（CQS_TEST_FAIL_AFTER，默认关闭）
  if [ -n "${CQS_TEST_FAIL_AFTER:-}" ]; then
    if [ "${CQS_TEST_FAIL_AFTER:-}" = "$1" ]; then
      log "injected failure (CQS_TEST_FAIL_AFTER=$1)" >&2
      return 1
    fi
  fi
  return 0
}

# 本轮 mutation 追踪（partial failure 回滚用；换行分隔以兼容路径含空格）
# BACKUPS_THIS_RUN = 本轮铸造的 origin 备份（失败时恢复并消费）
# TXN_BACKUPS_THIS_RUN = 本轮覆盖前的 txn 快照（升级 S1→S2 等；失败恢复、成功消费，绝不进 manifest）
# CREATED_THIS_RUN = 本轮新创建的文件（失败时删除）
BACKUPS_THIS_RUN=""
TXN_BACKUPS_THIS_RUN=""
CREATED_THIS_RUN=""
track_backup() { BACKUPS_THIS_RUN="$BACKUPS_THIS_RUN
$1"; }
track_txn_backup() { TXN_BACKUPS_THIS_RUN="$TXN_BACKUPS_THIS_RUN
$1"; }
track_created() { CREATED_THIS_RUN="$CREATED_THIS_RUN
$1"; }

# 失败时：回滚本轮 mutation，保留 journal 与旧 manifest，打印恢复指引；绝不打印成功
on_exit_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$MODE" = "install" ]; then
    local b d
    if [ -n "$BACKUPS_THIS_RUN" ]; then
      while IFS= read -r b; do
        [ -z "$b" ] && continue
        d="${b%.bak-*}"
        if [ -f "$b" ] && [ -f "$d" ]; then cp -p "$b" "$d" && rm -f "$b" && log "已回滚: $d"; fi
      done <<EOF
$BACKUPS_THIS_RUN
EOF
    fi
    if [ -n "$TXN_BACKUPS_THIS_RUN" ]; then
      while IFS= read -r b; do
        [ -z "$b" ] && continue
        d="${b%.bak-*}"
        if [ -f "$b" ] && [ -f "$d" ]; then cp -p "$b" "$d" && rm -f "$b" && log "已回滚(升级前版本): $d"; fi
      done <<EOF
$TXN_BACKUPS_THIS_RUN
EOF
    fi
    if [ -n "$CREATED_THIS_RUN" ]; then
      while IFS= read -r d; do
        [ -z "$d" ] && continue
        if [ -f "$d" ]; then rm -f "$d" && log "已移除本轮创建: $d"; fi
      done <<EOF
$CREATED_THIS_RUN
EOF
    fi
    log "安装失败（exit=$rc）。旧 manifest 未动；本次 journal 保留在 $MANIFEST_JOURNAL。"
    log "剩余未回滚的资源请按上述日志人工检查；.bak 备份一律不自动删除。"
  fi
  return $rc
}
trap on_exit_failure EXIT

block_begin() { echo "<!-- cqs-managed-block:$1 begin -->"; }
block_end()   { echo "<!-- cqs-managed-block:$1 end -->"; }

add_managed_block() { # $1=file $2=id $3=content-file
  local prev="" pcreated="" pbackup=""
  prev="$(prev_line "$1")"
  [ -z "$prev" ] || pcreated="$(manifest_field "$prev" created_by_cqs)"
  [ -z "$prev" ] || pbackup="$(manifest_field "$prev" backup)"
  if [ -f "$1" ] && grep -qF "$(block_begin "$2")" "$1"; then
    log "skip (block present): $1"
    # 生命周期幂等：旧 created/backup 保留（Rule A/B/E），绝不降级
    manifest_add "append" "$1" "managed_block_id=$2" "ownership=user" "created_by_cqs=$pcreated" "modified_by_cqs=1" "backup=$pbackup"
    return
  fi
  if [ "$MODE" = "--dry-run" ]; then log "dry-run append: $1"; return; fi
  # 覆盖前恰好快照一次，角色由 lifecycle provenance 决定（同 install_file 的 origin/txn 分离）
  local existed=0 created=1 modified=0 ownership="cqs" backup="" txn=""
  [ -f "$1" ] && existed=1
  if [ "$existed" = "1" ]; then
    if [ "$pcreated" = "1" ]; then
      txn="$(unique_backup_path "$1")"; cp -p "$1" "$txn"; track_txn_backup "$txn"
    elif [ -n "$pbackup" ]; then
      backup="$pbackup"; created=0; modified=1; ownership="user"
      txn="$(unique_backup_path "$1")"; cp -p "$1" "$txn"; track_txn_backup "$txn"
    else
      backup="$(unique_backup_path "$1")"; cp -p "$1" "$backup"; track_backup "$backup"
      created=0; modified=1; ownership="user"
    fi
  else
    track_created "$1"
  fi
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

# ---- [agents] 窄 key 级语义 reconciliation（NARROW：只 4 个 CQS 关注 key；不是 TOML merger）----
# 四态：missing→ADD / 相同→ADOPT / 更严但满足不变量→ADOPT_STRICTER / 破坏不变量→CONFLICT。
# 期望值运行时读自 global/config-agents.toml（source of truth）；冲突 = fail-fast
# （preflight 在任何 mutation 前终止）；文本补丁只在现有表头后插 markers+缺失 keys。
agents_desired() { # 输出 "key<TAB>raw值" 行（raw 原样保留引号）。
  # span 选择用 awk（仅行匹配无替换）；key=value 切分用 sed BRE——避开 mawk sub()
  # 的替换语义（现场：mawk 的 sub(/[[:space:]]*=/, "\t") 只吃掉 =、留下前导空格，
  # 导致期望值带空格、全部误判冲突）。
  agents_span "$SOURCE_ROOT/global/config-agents.toml" \
    | sed -n "s/^[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_]*\)[[:space:]]*=[[:space:]]*\([^[:space:]].*[^[:space:]]\|[^[:space:]]\)[[:space:]]*$/\1$(printf '\t')\2/p"
}

agents_span() { # $1=file —— [agents] 表头之后的 span 行（到下一表头为止；剥 CR）
  tr -d '\r' < "$1" | awk '
    /^[[:space:]]*\[agents\][[:space:]]*(#.*)?$/ { inagents=1; next }
    inagents && /^[[:space:]]*\[/ { exit }
    inagents { print }
  '
}

agents_span_value() { # $1=file $2=key → [agents] span 内该 key 的原始值；未找到→空
  agents_span "$1" | grep -E "^[[:space:]]*$2[[:space:]]*=" | head -n 1 \
    | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*#[^"]*$//' | sed 's/[[:space:]]*$//'
}

agents_classify() { # $1=key $2=desiredRaw $3=currentRaw(空=missing) → add|adopt|adopt_stricter|conflict|manual
  local k="$1" d="$2" c="$3" dnorm cnorm ci di
  if [ -z "$c" ]; then echo "add"; return; fi
  case "$k" in
    enabled)
      case "$c" in true|false) ;; *) echo "manual"; return ;; esac
      [ "$c" = "$d" ] && echo "adopt" || echo "conflict"
      ;;
    default_subagent_model|default_subagent_reasoning_effort)
      dnorm="${d%\"}"; dnorm="${dnorm#\"}"; cnorm="${c%\"}"; cnorm="${cnorm#\"}"
      [ "$cnorm" = "$dnorm" ] && echo "adopt" || echo "conflict"
      ;;
    max_concurrent_threads_per_session)
      case "$c" in *[!0-9]*|"") echo "manual"; return ;; esac
      ci="$c"; di="$d"
      if [ "$ci" -eq "$di" ]; then echo "adopt"; return; fi
      if [ "$ci" -lt "$di" ]; then echo "adopt_stricter"; return; fi   # 更严上限满足 ≤desired 不变量
      echo "conflict"
      ;;
    *) echo "manual" ;;
  esac
}

agents_key_impact() {
  case "$1" in
    enabled) echo "CQS 依赖多代理协作（Luna worker 子代理），enabled=false 会让 [agents] 失效" ;;
    default_subagent_model) echo "CQS 无法保证 Luna 默认子代理路由（期望 gpt-5.6-luna）" ;;
    default_subagent_reasoning_effort) echo "CQS 交接质量依赖 max 推理档" ;;
    max_concurrent_threads_per_session) echo "超过 CQS 配额上限 6，破坏额度节省不变量" ;;
    *) echo "CQS 配置契约冲突" ;;
  esac
}

agents_preflight() { # $1=config.toml —— 任何 filesystem mutation 之前：冲突/无法解析 → exit 1
  local f="$1" k d c st conflicts=0 desired=""
  [ -f "$f" ] || return 0
  grep -qE '^[[:space:]]*\[agents\][[:space:]]*(#.*)?$' "$f" || return 0
  desired="$(agents_desired || true)"
  while IFS=$'\t' read -r k d; do
    [ -n "$k" ] || continue
    c="$(agents_span_value "$f" "$k" || true)"
    st="$(agents_classify "$k" "$d" "$c")"
    case "$st" in
      manual|conflict)
        conflicts=1
        log "Conflict: [agents].$k"
        log "  Current: $c"
        log "  CQS expected: $d"
        log "  Impact: $(agents_key_impact "$k")"
        ;;
    esac
  done <<EOF
$desired
EOF
  if [ "$conflicts" = "1" ]; then
    log "config.toml [agents] 冲突（见上方明细），安装终止（fail-fast，任何修改前终止）。"
    exit 1
  fi
}

merge_agents_toml() { # $1=file —— key 级 reconciliation
  local prev="" pcreated="" pbackup=""
  prev="$(prev_line "$1")"
  [ -z "$prev" ] || pcreated="$(manifest_field "$prev" created_by_cqs)"
  [ -z "$prev" ] || pbackup="$(manifest_field "$prev" backup)"
  local begin="# --- codex-quota-saver managed [agents] begin ---" end="# --- codex-quota-saver managed [agents] end ---"
  # 无 [agents] 表（文件不存在或表不存在）：整块 append（CQS 拥有整个表）
  if [ ! -f "$1" ] || ! grep -qE '^[[:space:]]*\[agents\][[:space:]]*(#.*)?$' "$1"; then
    if [ "$MODE" = "--dry-run" ]; then log "dry-run append: $1"; return; fi
    # 覆盖前恰好快照一次，角色由 lifecycle provenance 决定（同 install_file 的 origin/txn 分离）
    local existed=0 created=1 modified=0 ownership="cqs" backup="" txn=""
    [ -f "$1" ] && existed=1
    if [ "$existed" = "1" ]; then
      if [ "$pcreated" = "1" ]; then
        txn="$(unique_backup_path "$1")"; cp -p "$1" "$txn"; track_txn_backup "$txn"
      elif [ -n "$pbackup" ]; then
        backup="$pbackup"; created=0; modified=1; ownership="user"
        txn="$(unique_backup_path "$1")"; cp -p "$1" "$txn"; track_txn_backup "$txn"
      else
        backup="$(unique_backup_path "$1")"; cp -p "$1" "$backup"; track_backup "$backup"
        created=0; modified=1; ownership="user"
      fi
    else
      track_created "$1"
    fi
    {
      printf '\n'; printf '%s\n' "$begin"; printf '[agents]\n'
      local desired=""
      desired="$(agents_desired || true)"
      while IFS=$'\t' read -r k d; do
        [ -n "$k" ] || continue
        printf '%s = %s\n' "$k" "$d"
      done <<EOF
$desired
EOF
      printf '%s\n' "$end"
    } >> "$1"
    manifest_add "append" "$1" "managed_block_id=agents-toml" "ownership=$ownership" "created_by_cqs=$created" "modified_by_cqs=$modified" "backup=$backup"
    log "append [agents]: $1"
    return
  fi
  # 表存在：逐 key 分类（reconcile plan）
  local k d c st conflicts=0 addlines="" desired=""
  desired="$(agents_desired || true)"
  cqs_debug "desired=[$(printf '%s' "$desired" | tr '\n' '|')]"
  while IFS=$'\t' read -r k d; do
    [ -n "$k" ] || continue
    c="$(agents_span_value "$1" "$k" || true)"
    st="$(agents_classify "$k" "$d" "$c")"
    cqs_debug "key=[$k] desired=[$d] current=[$c] state=[$st]"
    case "$st" in
      manual)
        log "config.toml [agents] 段含无法可靠解析的内容，跳过自动修改（fail-safe），请人工处理: $1"
        manifest_add "append" "$1" "managed_block_id=agents-toml" "ownership=user" "created_by_cqs=$pcreated" "modified_by_cqs=0" "backup=$pbackup"
        return
        ;;
      conflict)
        conflicts=1
        log "Conflict: [agents].$k"
        log "  Current: $c"
        log "  CQS expected: $d"
        log "  Impact: $(agents_key_impact "$k")"
        ;;
      add) addlines="$addlines
$k = $d" ;;
      adopt) : ;;
      adopt_stricter) log "已采纳用户更严值 [agents].$k = $c（满足 CQS 不变量，不覆盖）" ;;
    esac
  done <<EOF
$desired
EOF
  if [ "$MODE" = "--dry-run" ]; then log "dry-run reconcile plan: $1（详见上方冲突/采纳输出）"; return; fi
  if [ "$conflicts" = "1" ]; then
    log "config.toml [agents] 冲突（见上方明细），安装终止（fail-fast）。"
    exit 1
  fi
  if [ -z "$addlines" ]; then
    manifest_add "append" "$1" "managed_block_id=agents-toml" "ownership=user" "created_by_cqs=$pcreated" "modified_by_cqs=0" "backup=$pbackup"
    log "[agents] reconcile: 全部 adopt（未修改文件）: $1"
    return
  fi
  # 文本补丁：表头后插 markers + 缺失 keys（绝不整文件序列化）
  local backup=""
  if [ -n "$pbackup" ]; then backup="$pbackup"; else backup="$(unique_backup_path "$1")"; cp -p "$1" "$backup"; track_backup "$backup"; fi
  awk -v begin="$begin" -v end="$end" -v keys="$addlines" '
    BEGIN { split(keys, klines, "\n") }
    { print }
    $0 ~ /^[[:space:]]*\[agents\][[:space:]]*(#.*)?$/ && !done {
      print begin
      for (i = 1; i in klines; i++) { if (klines[i] != "") print klines[i] }
      print end
      done = 1
    }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
  manifest_add "append" "$1" "managed_block_id=agents-toml" "ownership=user" "created_by_cqs=$pcreated" "modified_by_cqs=1" "backup=$backup"
  log "reconcile [agents]: 插入缺失 keys → $1"
}

install_file() { # $1=src $2=dest $3=skip_if_exists(0/1) $4=overwrite_if_changed(0/1)
  local prev="" pcreated="" pmodified="" pbackup="" phash="" cur=""
  prev="$(prev_line "$2")"
  [ -z "$prev" ] || pcreated="$(manifest_field "$prev" created_by_cqs)"
  [ -z "$prev" ] || pmodified="$(manifest_field "$prev" modified_by_cqs)"
  [ -z "$prev" ] || pbackup="$(manifest_field "$prev" backup)"
  [ -z "$prev" ] || phash="$(manifest_field "$prev" installed_hash)"
  local existed=0
  [ -f "$2" ] && existed=1
  # 用户安装后改过（旧 installed_hash 与当前不一致）→ 绝不再次覆盖（Case E / Rule D）
  if [ "$existed" = "1" ] && [ -n "$phash" ]; then
    cur="$(sha256sum "$2" | cut -d' ' -f1)"
    if [ "$cur" != "$phash" ]; then
      log "用户安装后修改过，保留不覆盖: $2"
      manifest_add "copy" "$2" "ownership=user" "created_by_cqs=$pcreated" "modified_by_cqs=$pmodified" "installed_hash=$phash" "src=$1" "backup=$pbackup"
      return
    fi
  fi
  if [ "$existed" = "1" ]; then
    if [ "$3" = "1" ]; then
      log "skip (exists): $2"
      # skip（用户原有）条目不记录哈希：卸载阶段没有「hash 没变就可删」的路径
      manifest_add "copy" "$2" "ownership=user" "created_by_cqs=$pcreated" "modified_by_cqs=$pmodified" "installed_hash=$phash" "src=$1" "backup=$pbackup"
      return
    fi
    if [ "$4" = "1" ] && cmp -s "$1" "$2"; then
      log "skip (identical): $2"
      manifest_add "copy" "$2" "ownership=user" "created_by_cqs=$pcreated" "modified_by_cqs=$pmodified" "installed_hash=$phash" "src=$1" "backup=$pbackup"
      return
    fi
  fi
  if [ "$MODE" = "--dry-run" ]; then log "dry-run copy: $2"; return; fi
  mkdir -p "$(dirname "$2")"
  # 覆盖前恰好快照一次，角色由 lifecycle provenance 决定（filesystem existence 只是 observation）：
  #  - 用户文件首次被 CQS 覆盖（无 origin）→ 快照即 origin（进 manifest，卸载恢复用）
  #  - 已有 origin（升级）或 dest 是 CQS 自己创建的 → 快照是 txn（仅本轮回滚用，成功后消费，绝不进 manifest）
  local backup="" txn="" created=1 modified=0 ownership="cqs"
  if [ "$existed" = "1" ]; then
    if [ "$pcreated" = "1" ]; then
      txn="$(unique_backup_path "$2")"; cp -p "$2" "$txn"; track_txn_backup "$txn"
    elif [ -n "$pbackup" ]; then
      backup="$pbackup"; created=0; modified=1; ownership="user"
      txn="$(unique_backup_path "$2")"; cp -p "$2" "$txn"; track_txn_backup "$txn"
    else
      backup="$(unique_backup_path "$2")"; cp -p "$2" "$backup"; track_backup "$backup"
      created=0; modified=1; ownership="user"
    fi
  else
    track_created "$2"
  fi
  cp -p "$1" "$2"
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

# preflight（任何 filesystem mutation 之前）：config.toml [agents] 冲突 → fail-fast
if [ "$MODE" = "install" ]; then agents_preflight "$CODEX_HOME/config.toml"; fi

# dry-run 不得落任何文件（目录也不建）；uninstall 已提前退出
if [ "$MODE" = "install" ]; then
  rm -f "$MANIFEST_JOURNAL"   # 新 journal 从零开始；旧 manifest 保留到提交点（provenance 合并 + 失败恢复依赖）
  mkdir -p "$CODEX_HOME/agents"
fi

add_managed_block "$CODEX_HOME/AGENTS.md" "global-agents" "$SOURCE_ROOT/global/AGENTS.md"
maybe_fail 1
merge_agents_toml  "$CODEX_HOME/config.toml"
maybe_fail 2
install_file "$SOURCE_ROOT/global/agents/luna-worker.toml" "$CODEX_HOME/agents/luna-worker.toml" 0 1
maybe_fail 3
# 项目级协议：托管块合并（已存在追加、不存在创建）；协议文本 source of truth = project/AGENTS.md
add_managed_block "$PROJECT_PATH/AGENTS.md" "project-protocol" "$SOURCE_ROOT/project/AGENTS.md"
maybe_fail 4
install_file "$SOURCE_ROOT/project/dot-codex/config.toml" "$PROJECT_PATH/.codex/config.toml" 1 0
maybe_fail 5
install_file "$SOURCE_ROOT/project/dot-codex/next-step.md" "$PROJECT_PATH/.codex/next-step.md" 1 0
maybe_fail 6
install_file "$SOURCE_ROOT/project/dot-codex/skills/luna-routing/SKILL.md" "$PROJECT_PATH/.codex/skills/luna-routing/SKILL.md" 0 1
maybe_fail 7

# 提交点：全部步骤成功后原子替换旧 manifest（dry-run 无 journal，跳过提交）。
# mv 先于 txn 消费：若 mv 失败，EXIT trap 仍可用 txn 回滚。
if [ "$MODE" = "install" ]; then
  mv -f "$MANIFEST_JOURNAL" "$MANIFEST"
  if [ -n "$TXN_BACKUPS_THIS_RUN" ]; then
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      [ -f "$b" ] && rm -f "$b"
    done <<EOF
$TXN_BACKUPS_THIS_RUN
EOF
  fi
fi
log "安装完成（mode=$MODE）。"
