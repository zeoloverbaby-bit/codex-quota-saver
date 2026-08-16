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
