# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 语义化版本。历史条目从仓库 commit 重建。

## [1.6.6] - 2026-08-17

### Security
- write_next_step 物理边界防逃逸（P0）：`.codex` / `next-step.md` 为符号链接时 fail-closed 拒绝（绝不 follow），realpath 边界包含检查兜底 Windows junction；写入改为同目录临时文件 + fsync + `os.replace` 原子写（实测修复前 junction 逃逸可把内容写进 workspace 外）
- installer 生命周期幂等（P0）：manifest 从「最近一次运行快照」改为 persistent provenance ledger——重复安装按 dest 合并旧条目（created/modified 只增不减、backup 身份只保留第一份 origin、installed_hash 沿用旧值），`install→install→uninstall` 与 `install→uninstall` 等价（覆盖恢复 ORIGINAL / CQS 创建全移除 / 用户安装后修改绝不再次覆盖）；备份名唯一化防同秒覆盖
- installer transaction 语义（P1）：写入只进 journal、全部成功才原子提交，旧 manifest 提交前绝不删除（bash 原在 mutation 前删除旧 manifest）；中途失败按文件系统事实回滚本轮 mutation、journal 留存并打印恢复指引，绝不打印成功
- installer [agents] 窄 key 级 semantic reconciliation（P1）：缺失→插入 managed markers、相同→ADOPT、更严且满足不变量→ADOPT_STRICTER（如线程上限 4 < 6 保留用户值）、破坏不变量→CONFLICT fail-fast（preflight 在任何 mutation 前终止，打印 key/当前值/期望值/影响）；期望值运行时读自 global/config-agents.toml；绝不整文件序列化、不新增依赖
- OAuth 公网入口 bounded state（P1）：MAX_CLIENTS / MAX_PENDING / MAX_CODES + 惰性 prune（DCR/authorize/code 不再无限膨胀；拒绝新请求、绝不驱逐既有合法 state）；撤销口径修正——运行中删除 oauth_state.json 不撤销任何 token，立即撤销 = 停桥 → 删文件 → 重启

### Added
- 回归测试：guard symlink 逃逸 3 个（Windows junction 本地复现）；installer 重复安装 Case A-F（Pester + bats）+ 备份身份/Merge 规则单测 + partial failure 注入（`CQS_TEST_FAIL_AFTER` 钩子，默认关闭）；[agents] reconcile 分类矩阵 + 冲突 preflight 零落盘（Pester + bats）；OAuth 上限/清理 5 个 + 撤销语义锚定 1 个

### Changed
- 文档事实修正（2026-08-17 官方源码复核）：`features.multi_agent_v2` 配置键存在（布尔/结构化表两种形态，Stable 阶段、默认关闭）——旧「查无实据」结论更正；Stable contract 与 Known upstream bug（#36294/#35097 Open，PR #32751 backend 兼容限制）分层表达
- README release 口径：Public Alpha 期间 GitHub Release 均为 versioned development release；全部 Stable Gates 通过后发布首个明确标记为 Stable 的版本
- eval/README mini-ops 数字标注「设计目标，基准仓库尚未构建」；CHANGELOG v1.6.5 移除与同版本「易漂移计数移除」相矛盾的措辞
- installer bash 侧健壮性（CI 现场迭代）：dry-run 不再提交不存在的 journal；[agents] span 提取改 awk 标志循环（消除 sed range 端点匹配表头导致的塌缩）；期望值切分避开 mawk sub() 替换语义；剥 CR 防 CRLF 行处理破坏；调试钩子恒零返回（防 set -e 击落）

## [1.6.5] - 2026-08-17

### Security
- installer ownership hardening（P0）：manifest 记录文件所有权（ownership / created_by_cqs / modified_by_cqs / installed_hash / managed_block_id）——修复「用户原有文件被 skip 后，卸载因 hash 没变而误删」的数据所有权缺陷（实测命中 `<project>/AGENTS.md`）；双平台语义一致，旧格式 manifest 条目保守不删（fail-safe）
- OAuth state 权限边界：状态文件移入 `bridge/guard/state/`（Windows 目录 ACL 收紧到当前用户、POSIX 目录 0700 / 文件 600）；setup 重跑自动迁移旧 `oauth_state.json`（授权不失效，无需重新授权）
- 上游 token 不再经 `--auth-token` 进入进程 argv：启动器改用 `CODING_TOOLS_MCP_AUTH_TOKEN` 环境变量（coding-tools-mcp 0.3.0 官方支持）；移除「进程命令行不可见」的虚假安全声明，如实记录残余风险（token 存在于本机进程环境块，对同权限/高权限本机进程可见；upstream 仅绑定 127.0.0.1）
- Capability Taxonomy 文档化（bridge/README）：Planner 最小充分认知权限 = repository_read + git_read + handoff（唯一 mutation = write_next_step）；diagnostics / mutation 类工具协议层不存在；本轮验证 Git Read 集合已完整（git_status 含 branch/HEAD/upstream/ahead-behind），窄缺口（两 refs 间 diff / merge-base / refs 枚举）记录为未来候选只读工具，绝不开放 exec_command

### Added
- docs/pitfalls.md：新增坑 16-19（桥加固期：NUL env 窗口消失 / ACL 执行位 / 421 DNS-rebinding / ngrok 拦截页）；排坑表 15 → 19 坑
- 回归测试：installer ownership 全场景（Pester + bats：用户文件保留 / 合并摘块 / 创建删除 / 恢复原备份 / 用户修改保护 / legacy 保守）；OAuth state ACL（Pester 目录继承行为 + setup 源码断言；pytest POSIX 权限位）；launcher env token 模板断言；guard 工具契约测试（锚定 0.3.0 目录，防上游漂移）

### Changed
- README：部署第 3 步与「已知问题」清单补充 ngrok 免费版拦截页说明（无法技术跳过、点一次 Visit Site、v1.6.4 起启动器自动预热）
- README：Status 行同步稳定 Gate 进度（五道已过四道，仅剩 A/B 评测数据产出）
- README：第 3 步措辞 v1.6.x 化（「捕获连接器参数」→「自动注册连接器（DCR，无需捕获任何参数）」）
- docs/pitfalls.md：坑 4/10/11 标注 v1.6.0 已根治（oauth_state.json 落盘）；自救清单密码位置改为 `.secrets.local.env`
- installer：项目级协议改为 managed block 合并（`project-protocol`）——已有 `AGENTS.md` 追加、不存在创建、重复安装幂等、卸载只摘块；协议文本 source of truth 仍是 `project/AGENTS.md`
- installer：卸载真 rollback——CQS 覆盖过的文件在未改动时恢复原备份（消费 .bak）；用户安装后修改的文件一律保留并提示人工处理
- Tighten-Acl 目录分支：ACE 补 (OI)(CI) 继承标志 + Delete（否则子文件拿创建 token 默认 DACL、且 owner 无法删除 state 文件重新授权）
- README：CI 平台口径改为 Windows + Ubuntu（ci.yml 无 macOS runner，不再称「三平台」）；坑表/测试数量等易漂移数字从稳定文档与 GitHub repo description 移除；SECURITY v1.5.0 边界段标题历史化
- web-gpt prompt 工具权限节修正：write_next_step 是唯一写工具（apply_patch 协议层不存在），补充 git 工具用途（git_diff 审查执行结果 / git_show 验证 commit evidence）

### Removed
- bridge/start-bridge.bat / bridge/start-bridge.sh：v1.1-1.5 时代旧模板（手工填占位符 + 上游直连 `--oauth-mode`）。已被 setup 生成的 `start-bridge.local.*` 完全取代且全仓库零引用——删除以保持「启动器唯一权威来源 = setup」

## [1.6.4] - 2026-08-17

### Added
- 启动器预热：启动桥约 15 秒后自动打开默认浏览器到桥密码页（`https://<域名>/auth/login`）。ngrok 免费版拦截页无法用技术手段跳过（官方禁止注入 skip 头），必须浏览器手动点一次「Visit Site」（cookie 持久）——预热把「用到时才发现要点」提前到「启动时顺手点掉」，点过之后每次启动直接见密码页（兼作桥存活体检页）。Windows 用隐藏 PowerShell 延迟打开（不阻塞 ngrok 前台）；macOS/Linux 用 `xdg-open`（回退 `open`）后台打开
- 新增回归测试：launcher 模板含预热行断言（Pester 断言 setup.ps1 + setup.sh 源码）

## [1.6.3] - 2026-08-17

### Fixed
- bridge-guard `/mcp` 端点被 SDK 默认的 DNS-rebinding 防护误拦：guard 以 `host=127.0.0.1` 启动时，SDK 自动只放行本机回环 Host——经 ngrok 转发的请求（Host=公网域名）全部 421「Invalid Host header」。现场表现：ChatGPT 连接器 OAuth 授权成功（`/token` 200）后连接 MCP 失败、工具列表为空、UI 报「建立连接时发生意外错误」。修复：新增 `build_transport_security(public_url)` 显式放行公网域名（含带端口形式）+ 本机回环，其余陌生 Host 仍被拒绝
- 新增回归测试：公网 Host 下完整 OAuth + MCP 流程（不修复则 /mcp 421 失败）；transport security 放行/拒绝矩阵单测（公网域名、带端口、回环放行；陌生 Host 421；POST 非 JSON 400）

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
