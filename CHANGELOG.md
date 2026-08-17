# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 语义化版本。历史条目从仓库 commit 重建。

## [Unreleased]

## [1.6.2] - 2026-08-17

### Fixed
- launcher env 加载失效（关键修复，双重根因）：
  - `New-Password` 越界索引：固定模数 59 但字母表实际 57 字符，越界索引返回 `$null` → NUL 字符混入密码（实测 42% 概率）→ NUL 字节写进 `.secrets.local.env` → cmd 的 `for /f` 文本模式读到 NUL 即停止 → `CQS_*` 变量全部未加载 → guard 启动 KeyError 静默退出（重试 10×3s 后窗口消失）、upstream 空 token 崩溃。现场表现：「双击后约 30 秒两个窗口消失、只剩 ngrok」。修复：按字母表实际长度取模 + 拒绝采样上限 `floor(255/n)*n`；生成逻辑抽为 `bridge/secrets.ps1` 并加 200 次生成回归测试
  - env 文件注释含 em-dash（非 ASCII）同样会破坏 `for /f` 在 GBK 系统的读取：模板改纯 ASCII + `eol=#` + `set` 引号
- `bridge/guard/guard.py`：环境变量缺失立即失败并打印明确原因，不再静默重试 30 秒
- launcher 二重启动防护：guard 端口已监听时提示「桥已在运行」并退出（Windows `netstat` / macOS·Linux `netstat` 双实现）；修复防护块内 echo 含括号导致 cmd 语法错误的问题
- 新增回归测试：secrets 生成 200 次、env 模板 ASCII 断言、`for /f` 加载功能测试、二重启动防护功能测试（Pester）

## [1.6.1] - 2026-08-17

### Fixed
- bridge/setup.ps1：launcher ACL 收紧误用 `(R,W)` 缺执行位，导致 Windows 双击 `start-bridge.local.bat` 报「Windows 无法访问指定设备、路径或文件。你可能没有适当的权限访问该项目」。改为 `(RX,W)`；secrets 保持 `(R,W)` 不变
- ACL 逻辑抽取为 `bridge/acl.ps1`（Rights 参数化）+ 新增 `tests/setup-acl.Tests.ps1` 回归测试（icacls 真实验证执行位）；CI windows 腿改为全量 `tests/` + 分析 `acl.ps1`
- CHANGELOG：v1.6.0 内容此前滞留 `[Unreleased]`，补 `[1.6.0]` 版本段

## [1.6.0] - 2026-08-17

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
