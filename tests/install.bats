#!/usr/bin/env bats
# tests/install.bats —— CI 在 Ubuntu 上运行；本地无 bats 时用 bash -n + 手动场景
setup() {
  TESTDIR=$(mktemp -d)
  export CQS_TEST_CODEX_HOME="$TESTDIR/codex"
  export CQS_TEST_PROJECT="$TESTDIR/project"
  mkdir -p "$CQS_TEST_PROJECT"
}

teardown() { rm -rf "$TESTDIR"; }

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

@test "config.toml 已有 [agents] 段时跳过" {
  mkdir -p "$CQS_TEST_CODEX_HOME"
  printf '[agents]\nenabled = true\n' > "$CQS_TEST_CODEX_HOME/config.toml"
  bash "$BATS_TEST_DIRNAME/../install.sh" "$CQS_TEST_CODEX_HOME" "$CQS_TEST_PROJECT"
  run grep -c 'default_subagent_model' "$CQS_TEST_CODEX_HOME/config.toml"
  [ "$status" -ne 0 ]
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
