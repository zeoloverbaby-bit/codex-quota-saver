#!/usr/bin/env bats
# tests/install.bats —— CI 在 Ubuntu 上运行；本地无 bats 时用 bash -n + 手动场景
setup() {
  TESTDIR=$(mktemp -d)
  export CQS_TEST_CODEX_HOME="$TESTDIR/codex"
  export CQS_TEST_PROJECT="$TESTDIR/project"
  mkdir -p "$CQS_TEST_PROJECT"
}

teardown() { rm -rf "$TESTDIR"; }

# ---- Cross-version upgrade fixture：把 repo 源树复制为 s1/s2/s3 staged 副本，
# CQS_TEST_SOURCE_ROOT seam 指向哪个副本，install.sh 就读哪个版本的源。----
stage_sources() { # $1=dir
  local root="$1"
  mkdir -p "$root/s1" "$root/s2" "$root/s3"
  cp -r "$BATS_TEST_DIRNAME/../global" "$root/s1/global"
  cp -r "$BATS_TEST_DIRNAME/../project" "$root/s1/project"
  cp -r "$root/s1/global" "$root/s2/global"
  cp -r "$root/s1/project" "$root/s2/project"
  cp -r "$root/s1/global" "$root/s3/global"
  cp -r "$root/s1/project" "$root/s3/project"
}

@test "dry-run 不落任何文件" {
  run bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --dry-run
  [ "$status" -eq 0 ]
  [ ! -d "$CQS_TEST_CODEX_HOME" ]
}

@test "重复安装幂等：不产生第二个托管块" {
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  count=$(grep -c 'cqs-managed-block:global-agents begin' "$CQS_TEST_CODEX_HOME/AGENTS.md")
  [ "$count" -eq 1 ]
}

@test "已有部分 [agents] 表：缺失 key 插入现有表内，不产生第二个表（reconcile Case B）" {
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\nenabled = true\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$(grep -c '^\[agents\]' "$CQS_TEST_CODEX_HOME/config.toml")" -eq 1 ]
  grep -q 'default_subagent_model = "gpt-5.6-luna"' "$CQS_TEST_CODEX_HOME/config.toml"
  grep -q 'default_subagent_reasoning_effort = "max"' "$CQS_TEST_CODEX_HOME/config.toml"
  grep -q 'max_concurrent_threads_per_session = 6' "$CQS_TEST_CODEX_HOME/config.toml"
  [ "$(grep -c '^enabled =' "$CQS_TEST_CODEX_HOME/config.toml")" -eq 1 ]
  grep -qF '# --- codex-quota-saver managed [agents] begin ---' "$CQS_TEST_CODEX_HOME/config.toml"
}

@test "compatible key：ADOPT 不重复（reconcile Case C）" {
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\ndefault_subagent_model = "gpt-5.6-luna"\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$(grep -c '^default_subagent_model' "$CQS_TEST_CODEX_HOME/config.toml")" -eq 1 ]
  grep -q 'default_subagent_reasoning_effort = "max"' "$CQS_TEST_CODEX_HOME/config.toml"
}

@test "conflict：fail-fast 退出非零、文件字节不变、零 mutation（reconcile Case D）" {
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\ndefault_subagent_model = "other-model"\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  cp "$CQS_TEST_CODEX_HOME/config.toml" "$TESTDIR/config.before"
  run bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -ne 0 ]
  cmp -s "$TESTDIR/config.before" "$CQS_TEST_CODEX_HOME/config.toml"
  [ ! -f "$CQS_TEST_CODEX_HOME/AGENTS.md" ]
  [ ! -f "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" ]
}

@test "mixed：adopt + adopt_stricter + add——只插缺失 key，保留用户更严值（reconcile Case E）" {
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\nenabled = true\ndefault_subagent_model = "gpt-5.6-luna"\nmax_concurrent_threads_per_session = 4\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$(grep -c '^max_concurrent_threads_per_session' "$CQS_TEST_CODEX_HOME/config.toml")" -eq 1 ]
  grep -q 'max_concurrent_threads_per_session = 4' "$CQS_TEST_CODEX_HOME/config.toml"
  ! grep -q 'max_concurrent_threads_per_session = 6' "$CQS_TEST_CODEX_HOME/config.toml"
  grep -q 'default_subagent_reasoning_effort = "max"' "$CQS_TEST_CODEX_HOME/config.toml"
  [ "$(grep -c '^default_subagent_model' "$CQS_TEST_CODEX_HOME/config.toml")" -eq 1 ]
}

@test "已有 [agents] 表 install×2 → uninstall：markers 摘除、用户 key 原样（reconcile Case F）" {
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\nenabled = true\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/config.toml")" = "$(printf '[agents]\nenabled = true')" ]
}

@test "uninstall 移除托管块（HTML 标记 + TOML [agents] 段）" {
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  run grep -c 'cqs-managed-block:global-agents' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  [ "$status" -ne 0 ]
  run grep -c 'default_subagent_model' "$CQS_TEST_CODEX_HOME/config.toml"
  [ "$status" -ne 0 ]
}

@test "项目 next-step.md 已存在时不覆盖" {
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  printf 'KEEP' > "$CQS_TEST_PROJECT/.codex/next-step.md"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  run cat "$CQS_TEST_PROJECT/.codex/next-step.md"
  [ "$output" = "KEEP" ]
}

@test "用户原有 project/AGENTS.md 不因卸载被删除（P0 回归：skip 条目绝不删除）" {
  printf 'USER CONTENT\n' > "$CQS_TEST_PROJECT/AGENTS.md"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ -f "$CQS_TEST_PROJECT/AGENTS.md" ]
  [ "$(cat "$CQS_TEST_PROJECT/AGENTS.md")" = "USER CONTENT" ]
}

@test "CQS 创建的项目 AGENTS.md 卸载后允许删除" {
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ -f "$CQS_TEST_PROJECT/AGENTS.md" ]
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ ! -f "$CQS_TEST_PROJECT/AGENTS.md" ]
}

@test "旧格式 manifest 条目（无所有权信息）保守跳过不删除" {
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf 'LEGACY\n' > "$TESTDIR/legacy.md"
  printf 'copy\t%s\tsha256=%s\n' "$TESTDIR/legacy.md" "$(sha256sum "$TESTDIR/legacy.md" | cut -d' ' -f1)" > "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ -f "$TESTDIR/legacy.md" ]
  [ "$(cat "$TESTDIR/legacy.md")" = "LEGACY" ]
}

@test "用户已有 project/AGENTS.md：安装追加协议块，卸载摘块保留用户内容" {
  printf 'USER CONTENT\n' > "$CQS_TEST_PROJECT/AGENTS.md"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  grep -q 'cqs-managed-block:project-protocol' "$CQS_TEST_PROJECT/AGENTS.md"
  grep -q 'USER CONTENT' "$CQS_TEST_PROJECT/AGENTS.md"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ -f "$CQS_TEST_PROJECT/AGENTS.md" ]
  [ "$(cat "$CQS_TEST_PROJECT/AGENTS.md")" = "USER CONTENT" ]
}

@test "CQS 创建后用户加内容：卸载只摘协议块保留新增内容" {
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  printf '\nUSER NEW CONTENT\n' >> "$CQS_TEST_PROJECT/AGENTS.md"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ -f "$CQS_TEST_PROJECT/AGENTS.md" ]
  ! grep -q 'cqs-managed-block' "$CQS_TEST_PROJECT/AGENTS.md"
  ! grep -q '三层协作协议' "$CQS_TEST_PROJECT/AGENTS.md"
  grep -q 'USER NEW CONTENT' "$CQS_TEST_PROJECT/AGENTS.md"
}

@test "覆盖用户原文件且未改动：卸载恢复 ORIGINAL 并消费备份（Case 5）" {
  mkdir -p "$CQS_TEST_CODEX_HOME/agents"
  printf 'ORIGINAL\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  ! grep -q 'ORIGINAL' "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  [ "$(find "$CQS_TEST_CODEX_HOME/agents" -name '*.bak-*' | wc -l)" -eq 1 ]
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "ORIGINAL" ]
  [ "$(find "$CQS_TEST_CODEX_HOME/agents" -name '*.bak-*' | wc -l)" -eq 0 ]
}

@test "覆盖后用户又修改：卸载保留用户修改与备份，不自动覆盖（Case 6）" {
  mkdir -p "$CQS_TEST_CODEX_HOME/agents"
  printf 'ORIGINAL\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  printf 'USER MODIFIED VERSION\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "USER MODIFIED VERSION" ]
  [ "$(find "$CQS_TEST_CODEX_HOME/agents" -name '*.bak-*' | wc -l)" -eq 1 ]
}

@test "Case A：覆盖用户文件 ×2 → uninstall 恢复 ORIGINAL 且消费备份（重复安装 provenance）" {
  mkdir -p "$CQS_TEST_CODEX_HOME/agents"
  printf 'ORIGINAL\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$(find "$CQS_TEST_CODEX_HOME/agents" -name '*.bak-*' | wc -l)" -eq 1 ]
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "ORIGINAL" ]
  [ "$(find "$CQS_TEST_CODEX_HOME/agents" -name '*.bak-*' | wc -l)" -eq 0 ]
}

@test "Case B：CQS 创建文件 ×2 → uninstall 全部移除（不留空壳）" {
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ ! -f "$CQS_TEST_PROJECT/AGENTS.md" ]
  [ ! -f "$CQS_TEST_PROJECT/.codex/config.toml" ]
  [ ! -f "$CQS_TEST_PROJECT/.codex/next-step.md" ]
  [ ! -f "$CQS_TEST_CODEX_HOME/AGENTS.md" ]
  [ ! -f "$CQS_TEST_CODEX_HOME/config.toml" ]
  [ ! -f "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" ]
}

@test "Case C：用户已有 project/AGENTS.md + 托管块 ×2 → uninstall 只剩 USER CONTENT" {
  printf 'USER CONTENT\n' > "$CQS_TEST_PROJECT/AGENTS.md"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ -f "$CQS_TEST_PROJECT/AGENTS.md" ]
  [ "$(cat "$CQS_TEST_PROJECT/AGENTS.md")" = "USER CONTENT" ]
}

@test "Case D：CQS 创建 AGENTS + 用户追加内容 ×2 → uninstall 摘块保留用户内容、无空壳" {
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  printf '\nUSER NEW CONTENT\n' >> "$CQS_TEST_PROJECT/AGENTS.md"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ -f "$CQS_TEST_PROJECT/AGENTS.md" ]
  ! grep -q 'cqs-managed-block' "$CQS_TEST_PROJECT/AGENTS.md"
  grep -q 'USER NEW CONTENT' "$CQS_TEST_PROJECT/AGENTS.md"
}

@test "Case E：用户修改后二次安装不得再覆盖，uninstall 保留用户版与备份" {
  mkdir -p "$CQS_TEST_CODEX_HOME/agents"
  printf 'ORIGINAL\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  printf 'USER MODIFIED VERSION\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "USER MODIFIED VERSION" ]
  [ "$(find "$CQS_TEST_CODEX_HOME/agents" -name '*.bak-*' | wc -l)" -eq 1 ]
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "USER MODIFIED VERSION" ]
  [ "$(find "$CQS_TEST_CODEX_HOME/agents" -name '*.bak-*' | wc -l)" -eq 1 ]
}

@test "Case F：install×3 → uninstall 与 ×1 等价（provenance 不随次数衰减）" {
  mkdir -p "$CQS_TEST_CODEX_HOME/agents"
  printf 'ORIGINAL\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "ORIGINAL" ]
  [ "$(find "$CQS_TEST_CODEX_HOME/agents" -name '*.bak-*' | wc -l)" -eq 0 ]
}

@test "中途失败：旧 manifest 原样保留、journal 留存、本轮改动回滚（bats failure injection）" {
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cp "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" "$TESTDIR/manifest.before"
  printf 'USER AGENTS\n' > "$CQS_TEST_CODEX_HOME/AGENTS.md"
  rm -f "$CQS_TEST_CODEX_HOME/config.toml" "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  run env CQS_TEST_FAIL_AFTER=3 bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -ne 0 ]
  cmp -s "$TESTDIR/manifest.before" "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest"
  [ -f "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest.tmp" ]
  [ "$(cat "$CQS_TEST_CODEX_HOME/AGENTS.md")" = "USER AGENTS" ]
  [ ! -f "$CQS_TEST_CODEX_HOME/config.toml" ]
  [ ! -f "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" ]
}

# ---- Cross-version upgrade（S1→S2/S3）：lifecycle provenance 不随版本升级衰减 ----

@test "Upgrade Case A：USER → S1 → S2 → uninstall → USER（origin 身份贯穿升级）" {
  stage_sources "$TESTDIR/src"
  printf 'LUNA WORKER V2\n' > "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  mkdir -p "$CQS_TEST_CODEX_HOME/agents"
  printf 'USER ORIGINAL\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cmp -s "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" "$TESTDIR/src/s1/global/agents/luna-worker.toml"
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 1 ]
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cmp -s "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  # origin 仍只有一份（txn 成功已消费）
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 1 ]
  grep 'agents/luna-worker.toml' "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" | grep -q 'created_by_cqs=0'
  grep 'agents/luna-worker.toml' "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" | grep -q 'backup=.*\.bak-'
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "USER ORIGINAL" ]
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 0 ]
}

@test "Upgrade Case B：missing → S1 → S2 → uninstall → missing（CQS-created 不被重分类）" {
  stage_sources "$TESTDIR/src"
  printf 'LUNA WORKER V2\n' > "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cmp -s "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  grep 'agents/luna-worker.toml' "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" | grep -q 'created_by_cqs=1'
  grep 'agents/luna-worker.toml' "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" | grep -q 'backup=$'
  # CQS-created 升级：绝不铸造假 origin；txn 已消费 → 零 .bak
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 0 ]
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ ! -f "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" ]
  [ ! -f "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" ]
}

@test "Upgrade Case C：USER → S1 → S2 → S3 → uninstall → USER（多版本不衰减）" {
  stage_sources "$TESTDIR/src"
  printf 'LUNA WORKER V2\n' > "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  printf 'LUNA WORKER V3\n' > "$TESTDIR/src/s3/global/agents/luna-worker.toml"
  mkdir -p "$CQS_TEST_CODEX_HOME/agents"
  printf 'USER ORIGINAL\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s3" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cmp -s "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" "$TESTDIR/src/s3/global/agents/luna-worker.toml"
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 1 ]
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "USER ORIGINAL" ]
}

@test "Upgrade Case D：missing → S1 → S2 → S3 → uninstall → missing" {
  stage_sources "$TESTDIR/src"
  printf 'LUNA WORKER V2\n' > "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  printf 'LUNA WORKER V3\n' > "$TESTDIR/src/s3/global/agents/luna-worker.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s3" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  grep 'agents/luna-worker.toml' "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" | grep -q 'created_by_cqs=1'
  grep 'agents/luna-worker.toml' "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" | grep -q 'backup=$'
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 0 ]
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ ! -f "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" ]
}

@test "Upgrade Case E：USER → S1 → 升级 S2 失败 → 恢复 S1（不楔死、origin 完好）" {
  stage_sources "$TESTDIR/src"
  printf 'LUNA WORKER V2\n' > "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  mkdir -p "$CQS_TEST_CODEX_HOME/agents"
  printf 'USER ORIGINAL\n' > "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cp "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" "$TESTDIR/manifest.before"
  run env CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" CQS_TEST_FAIL_AFTER=3 bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -ne 0 ]
  # transaction invariant：文件系统 = S1，manifest = S1，origin 备份完好
  cmp -s "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" "$TESTDIR/src/s1/global/agents/luna-worker.toml"
  cmp -s "$TESTDIR/manifest.before" "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest"
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 1 ]
  # 不楔死：重试升级可完成；uninstall 恢复 USER ORIGINAL
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cmp -s "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(cat "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml")" = "USER ORIGINAL" ]
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 0 ]
}

@test "agents Case I：CQS-owned key threads=6 → S2 desired 4 → 升级、用户 key 不动" {
  stage_sources "$TESTDIR/src"
  sed -i 's/max_concurrent_threads_per_session = 6/max_concurrent_threads_per_session = 4/' "$TESTDIR/src/s2/global/config-agents.toml"
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\nenabled = true\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  grep -q 'max_concurrent_threads_per_session = 6' "$CQS_TEST_CODEX_HOME/config.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  grep -q 'max_concurrent_threads_per_session = 4' "$CQS_TEST_CODEX_HOME/config.toml"
  ! grep -q 'max_concurrent_threads_per_session = 6' "$CQS_TEST_CODEX_HOME/config.toml"
  [ "$(grep -c '^enabled' "$CQS_TEST_CODEX_HOME/config.toml")" -eq 1 ]
  [ "$(grep -c '^max_concurrent_threads_per_session' "$CQS_TEST_CODEX_HOME/config.toml")" -eq 1 ]
  [ "$(grep -c 'codex-quota-saver managed \[agents\] begin' "$CQS_TEST_CODEX_HOME/config.toml")" -eq 1 ]
  grep 'config.toml' "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" | grep -q 'installed_block_hash='
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ "$(grep -v '^[[:space:]]*$' "$CQS_TEST_CODEX_HOME/config.toml")" = $'[agents]\nenabled = true' ]
}

@test "agents Case J：user-owned threads=6 → S2 desired 4 → CONFLICT fail-fast、零 mutation" {
  stage_sources "$TESTDIR/src"
  sed -i 's/max_concurrent_threads_per_session = 6/max_concurrent_threads_per_session = 4/' "$TESTDIR/src/s2/global/config-agents.toml"
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\nmax_concurrent_threads_per_session = 6\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cp "$CQS_TEST_CODEX_HOME/config.toml" "$TESTDIR/cfg.before"
  cp "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" "$TESTDIR/manifest.before"
  run env CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -ne 0 ]
  cmp -s "$TESTDIR/cfg.before" "$CQS_TEST_CODEX_HOME/config.toml"
  cmp -s "$TESTDIR/manifest.before" "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest"
}

@test "agents duplicate key：region 内 + region 外同名 → CONFLICT fail-fast" {
  stage_sources "$TESTDIR/src"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  printf '\nmax_concurrent_threads_per_session = 6\n' >> "$CQS_TEST_CODEX_HOME/config.toml"
  cp "$CQS_TEST_CODEX_HOME/config.toml" "$TESTDIR/cfg.before"
  run env CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -ne 0 ]
  cmp -s "$TESTDIR/cfg.before" "$CQS_TEST_CODEX_HOME/config.toml"
}

@test "threads=0（user key）：安装不能成功（conflict fail-fast、零 mutation）" {
  stage_sources "$TESTDIR/src"
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\nmax_concurrent_threads_per_session = 0\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  cp "$CQS_TEST_CODEX_HOME/config.toml" "$TESTDIR/cfg.before"
  run env CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -ne 0 ]
  cmp -s "$TESTDIR/cfg.before" "$CQS_TEST_CODEX_HOME/config.toml"
  [ ! -f "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" ]
}

@test "threads=1（user key）：更严且合法 → adopt_stricter、安装成功" {
  stage_sources "$TESTDIR/src"
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\nmax_concurrent_threads_per_session = 1\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  grep -q 'max_concurrent_threads_per_session = 1' "$CQS_TEST_CODEX_HOME/config.toml"
  ! grep -q 'max_concurrent_threads_per_session = 6' "$CQS_TEST_CODEX_HOME/config.toml"
}

@test "desired 自身非法（threads=0）→ 安装拒绝启动（drift guard）" {
  stage_sources "$TESTDIR/src"
  sed -i 's/max_concurrent_threads_per_session = 6/max_concurrent_threads_per_session = 0/' "$TESTDIR/src/s1/global/config-agents.toml"
  run env CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -ne 0 ]
}

@test "Managed Block Case G：用户内容 + 块 S1 → 模板升级 S2 → 块升级、卸载只剩用户内容" {
  stage_sources "$TESTDIR/src"
  printf 'LUNA PROTOCOL V1\n' > "$TESTDIR/src/s1/global/AGENTS.md"
  printf 'LUNA PROTOCOL V2\n' > "$TESTDIR/src/s2/global/AGENTS.md"
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf 'USER AGENTS\n' > "$CQS_TEST_CODEX_HOME/AGENTS.md"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  grep -q 'LUNA PROTOCOL V1' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  grep -q 'LUNA PROTOCOL V2' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  ! grep -q 'LUNA PROTOCOL V1' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  grep -q 'USER AGENTS' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  [ "$(grep -c 'cqs-managed-block:global-agents begin' "$CQS_TEST_CODEX_HOME/AGENTS.md")" -eq 1 ]
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 1 ]
  grep 'AGENTS.md' "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" | grep -q 'installed_block_hash='
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  grep -q 'USER AGENTS' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  ! grep -q 'LUNA PROTOCOL' "$CQS_TEST_CODEX_HOME/AGENTS.md"
}

@test "Managed Block Case H：用户编辑块内 → S2 尝试 → 不覆盖 + 明确报告" {
  stage_sources "$TESTDIR/src"
  printf 'LUNA PROTOCOL V1\n' > "$TESTDIR/src/s1/global/AGENTS.md"
  printf 'LUNA PROTOCOL V2\n' > "$TESTDIR/src/s2/global/AGENTS.md"
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf 'USER AGENTS\n' > "$CQS_TEST_CODEX_HOME/AGENTS.md"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  sed -i 's/LUNA PROTOCOL V1/USER EDIT INSIDE BLOCK/' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  run env CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -eq 0 ]
  grep -q 'USER EDIT INSIDE BLOCK' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  ! grep -q 'LUNA PROTOCOL V2' "$CQS_TEST_CODEX_HOME/AGENTS.md"
  echo "$output" | grep -q '已被用户修改'
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 1 ]
}

@test "Upgrade Case F：missing → S1 → 升级 S2 失败 → 恢复 S1 且 created_by_cqs 保持" {
  stage_sources "$TESTDIR/src"
  printf 'LUNA WORKER V2\n' > "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s1" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cp "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest" "$TESTDIR/manifest.before"
  run env CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" CQS_TEST_FAIL_AFTER=3 bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  [ "$status" -ne 0 ]
  cmp -s "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" "$TESTDIR/src/s1/global/agents/luna-worker.toml"
  cmp -s "$TESTDIR/manifest.before" "$CQS_TEST_CODEX_HOME/.codex-quota-saver-manifest"
  [ "$(find "$CQS_TEST_CODEX_HOME" -name '*.bak-*' | wc -l)" -eq 0 ]
  CQS_TEST_SOURCE_ROOT="$TESTDIR/src/s2" bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  cmp -s "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" "$TESTDIR/src/s2/global/agents/luna-worker.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT" --uninstall
  [ ! -f "$CQS_TEST_CODEX_HOME/agents/luna-worker.toml" ]
}
