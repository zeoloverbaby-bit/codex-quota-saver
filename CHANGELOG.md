# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 语义化版本。历史条目从仓库 commit 重建。

## [Unreleased]

### Security
- bridge-guard：MCP 桥能力层白名单（只读类工具 + write_next_step），取代 prompt 级约束
- bridge-guard：自建 OAuth 2.1 授权服务器（授权码 + PKCE + DCR；注册表与签名密钥落盘 = 重启免疫；7 天 JWT）。ChatGPT 连接器实测只有 OAuth/无认证/混合三种认证方式，无 API key 选项——API key 方案因此废弃
- secrets 硬化：.local.env chmod 600 / Windows ACL；密码与 token 走环境变量

### Added
- COMPATIBILITY.md 兼容性矩阵；依赖版本 pin
- install 脚本工程化：--dry-run / --uninstall / manifest / rollback / 幂等
- eval 工具链：collect.py + score.py + radar.py（CSV 输入）
- CI（Windows Pester+PSScriptAnalyzer / Ubuntu ShellCheck+bats+pytest / gitleaks / link check）
- SECURITY.md / CONTRIBUTING.md / Roadmap 与稳定 Gate

### Changed
- AGENTS 拆分：全局只留子代理规则；三层协作协议移入项目级 AGENTS.md
- README：Public Alpha 状态声明；Luna/Sol 倍率改为待校准假设

## [1.5.0] - 2026-08-16

- README 重构为「两个痛点一份方案」：档位浪费 vs 过度治理
- docs/lean-execution.md 新增三个根因与六类反模式（脱敏）

## [1.4.0] - 2026-08-16

- 更名 codex-quota-saver；新增 docs/lean-execution.md（AI 执行治理八原则）

## [1.3.0] - 2026-08-16

- 更名 codex-three-tier-orchestration；README 六步完整部署流程；Plus/未充值账号前置条件修正

## [1.2.0] - 2026-08-16

- bridge/ 半自动 setup 脚本（预检依赖 / 密钥生成 / client_id 捕获 / 冒烟）

## [1.1.0] - 2026-08-16

- 新增 bridge/ 模板、docs/pitfalls.md（15 坑）、eval/ A/B 评测协议

## [1.0.0] - 2026-08-16

- 初始发布：三层架构工具包（global/ + project/ + install 脚本）
