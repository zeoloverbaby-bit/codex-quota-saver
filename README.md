# codex-quota-saver

> **Status: Public Alpha / Experimental**——思路与文档完整、可实际运行，但安全边界、CI、卸载路径仍在 hardening 中（gate 见 [Roadmap](#roadmap)）。个人或熟人小团队自用足够；把它装进重要生产仓库前，请先读 [SECURITY.md](SECURITY.md)。

**解决一个问题：Codex 额度被最贵的模型干了最便宜的活。** 两个浪费源：**档位浪费**（规划、机械活烧着最贵的 Sol）与**过度治理**（本应在任务内自动收敛的工程问题，被错误升级成人工 Gate、全量重验——每一轮无谓的 STOP 都在烧最贵的 token 和你的注意力）。

这是一个「三层架构」（分析层 / 执行层 / 授权层）的完整部署工具包——Luna 主线程 + 有界 `luna_worker` 子代理 + 网页 GPT 规划层 + 可选的 MCP 桥模板，外加 15 个实测坑的排坑表、一套 AI 执行治理八原则和一套可复现的 A/B 评测方案。目标读者：被 Codex 额度焦虑困扰的 ChatGPT Plus/Pro 用户，以及替他们部署这套方案的 AI。仓库无任何密钥、无个人数据，MIT 开源。

## 它解决什么（两个痛点，一份方案）

**痛点 1 · 额度不够用**：项目开发/实施中 Codex 额度消耗快，还没干完就没了。

药方 = 三层架构「续命」：大头分析、审查放网页 GPT（已付费的网页额度）；Codex 只做执行——主线程默认 Luna Max（基于当前账户观察，假设 Luna 相对 Sol 有显著额度优势，暂估 20-25 倍；正式评测前重新校准，见 eval/README §2.2 系数复核提醒），高难度任务才手动切 Sol，仅「重执行任务」才 spawn 有界子代理；人在重要节点授权。

**痛点 2 · Sol 过度治理**：把本应在已授权任务内自动收敛的工程问题（普通 RED、typing、fixture、CLI 适配…），错误升级成人工 Gate、全量重验、治理事件——每一轮无谓的 STOP 和重跑都在烧最贵的 token 和你的注意力。

药方 = [AI 执行治理八原则](docs/lean-execution.md)：连续执行 / STOP 稀缺 / Evidence 继承 / 验证成比例。

一句话总结：**「想」放在已经付过费的网页额度上，「做」放在最便宜的模型档上，「停」只停在真正跨过 authority 边界的时刻。**

## 方案一页看懂

```
网页 GPT（网页额度）─ 规划 / 分析 / 审查 / 写 .codex/next-step.md
        │  零思考执行指令
Codex 主线程（默认 Luna Max）─ commit / merge / 批量 / 小修
        │  仅「重执行任务」才 spawn
luna_worker 子代理 ×N（Luna Max）─ 有界执行包，并行干活
        │
你 ─ 所有授权 / 方向决策（免费且不可外包）
```

两个关键纪律：

- **默认永不 spawn 子代理**（委派开销 > 工作本身 = 亏本买卖）；「重执行任务」且同时满足 4 条件才 spawn（规则见 `global/AGENTS.md`）
- **疑难决策不在 Codex 内 spawn Sol 子代理**——STOP 报告，网页 GPT 分析后经 `next-step.md` 回流

这两条纪律是 [docs/lean-execution.md](docs/lean-execution.md)「AI 执行治理八原则」在 Codex 语境的落地——额度浪费的第二来源是治理低效，原则总纲见该文档。

## 目录对照表（每个文件解决哪个痛点）

| 路径 | 是什么 | 解决什么 |
|---|---|---|
| `global/config-agents.toml` | `[agents]` 段模板 | 子代理默认用 Luna Max、并发上限 6 |
| `global/AGENTS.md` | 子代理路由硬规则（全局） | 「默认不 spawn + 4 条件」纪律 |
| `global/agents/luna-worker.toml` | 子代理定义 | 有界执行包（文件互斥、7 类 STOP 条件、不宣称验收） |
| `project/dot-codex/config.toml` | 项目级配置 | 该项目主线程 = Luna Max（按项目分层，其他项目不受影响） |
| `project/AGENTS.md` | 三层协作协议（项目级模板） | 三层角色与执行层职责只进本项目，不污染其他仓库 |
| `project/dot-codex/next-step.md` | 交接协议模板 | 网页 GPT → Codex 的零思考指令格式 |
| `project/dot-codex/skills/luna-routing/SKILL.md` | 路由决策技能 | spawn 判定决策树 + 执行包模板 + 验证门槛 |
| `project/web-gpt-project-prompt.md` | GPT 项目指令模板 | 分析层的行为规范（粘贴给网页 GPT，不装磁盘） |
| `install.ps1` / `install.sh` | 一键安装 | 备份不删除、只追加不覆盖，见下节 |
| `bridge/` | MCP 桥半自动部署（可选增强） | 网页 GPT 直连仓库免人工中转；`setup.ps1/.sh` 一条命令装完，用户只需创建连接器 + 输一次密码（生成的 `.local.*` 文件含密钥、已 gitignore） |
| `docs/lean-execution.md` | AI 执行治理八原则（提炼版） | 治理低效也是额度浪费：连续执行 + STOP 稀缺 + Evidence 继承 + 验证成比例 |
| `COMPATIBILITY.md` | 兼容性矩阵 + 版本 pin | 今天能跑 → clone 后也能跑 |
| `SECURITY.md` | 安全边界与免责声明 | 部署前必读 |
| `CHANGELOG.md` | 版本历史 | 判断要不要升级 |
| `docs/pitfalls.md` | 15 个实测坑 | 部署与排障，人话版 |
| `eval/` | A/B 评测方案 | 量化省了多少额度（协议 + 任务集 + 雷达图脚本） |

## 完整部署流程

从零到跑起来，全程约 15 分钟（不含桥）。

### 第 0 步 · 前置条件

- **ChatGPT 账号**：Plus 或 Pro 均可（Pro 的网页额度更充裕）；**未充值的账号也能跑**，只是网页 GPT 与 Codex 的模型选择里都没有 Sol 档，方案退化为「Luna 为主 + 人把关」
- **Codex**：App 或 CLI 都行（App 免费额度 / CLI 订阅额度都能用这套编排）
- Windows 建议 PowerShell 5.1+；macOS/Linux 用 bash 脚本

### 第 1 步 · 安装工具包

```bash
git clone https://github.com/zeoloverbaby-bit/codex-quota-saver.git
cd codex-quota-saver
```

```powershell
# Windows（-ProjectPath 换成你自己的仓库路径）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -ProjectPath "D:\path\to\your\repo"
```

```bash
# macOS / Linux（参数：CODEX_HOME、项目路径）
./install.sh ~/.codex /path/to/your/repo
```

脚本装了哪些文件、动了哪些既有文件，见下方「安装脚本的行为边界」。

### 第 2 步 · Codex App 开启推理档位

打开 Codex **App 设置-配置**，开启 reasoning effort 的 **max** 档——否则 config 里的 max 被静默降级为 medium。改完开**新会话**才生效。

### 第 3 步 · 部署 MCP 桥（可选增强，约 10 分钟）

想让网页 GPT 直接读写仓库（免人工中转 next-step.md）才做这一步：

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\bridge\setup.ps1 -Domain <你的ngrok静态域名> -Workspace <项目路径>
# macOS / Linux
./bridge/setup.sh <你的ngrok静态域名> <项目路径>
```

一条命令自动装完依赖、生成密钥、捕获连接器参数；你全程只需两件事（脚本会提示时机）：在 ChatGPT 创建连接器、最后输一次 OAuth 密码。

> 没桥也能跑三层架构：GPT 把 `.codex/next-step.md` 全文输出给你，手动落盘即可。桥的完整说明、手动兜底与冒烟测试见 [bridge/README.md](bridge/README.md)。

### 第 4 步 · 配置网页 GPT（分析层）

打开 ChatGPT 网页版 → **新对话** → 把 `project/web-gpt-project-prompt.md` 的全文粘贴为第一条消息（或用 ChatGPT 项目指令功能固定它）。

这份指令规定分析层的行为：只读仓库、只写 `.codex/next-step.md`、不执行代码、疑难决策报告你。

### 第 5 步 · 首次运转（先拿小任务试跑）

1. 给网页 GPT 一个小任务（如「读这个仓库的 README，提出 3 条改进建议」）
2. 把 GPT 产出的 `.codex/next-step.md`（或全文）落到项目根目录
3. Codex 开**新会话**，说一句：*「读 .codex/next-step.md，按文档执行，完成后输出执行报告」*
4. 用执行报告对照 GPT 给的验证步骤，核对结果一致

### 第 6 步 · 部署验收清单

- [ ] Codex 新会话模型显示 **Luna + max 档**（显示 medium = 第 2 步没做对；以会话实际显示为准）
- [ ] 新会话让它「读 AGENTS.md，复述我的编排规则」——能讲出「默认不 spawn + 4 条件」纪律
- [ ] 第一次 spawn 子代理后，核对 rollout 实际模型是 `gpt-5.6-luna`（见已知问题 #32587）
- [ ] （部署了桥）[bridge/README.md](bridge/README.md) 冒烟测试三连通过

## 安装脚本的行为边界（重要）

- **备份不删除**：任何被改写的既有文件先复制为 `<文件>.bak-<时间戳>`，不删除任何东西
- `config.toml`：只追加 `[agents]` 段；已有 `[agents]` 则跳过
- `AGENTS.md`：只追加子代理硬规则一个托管块（带 `cqs-managed-block` 标记），**不再包含三层协作协议**；不覆盖你原有内容
- 三层协作协议写入**项目根** `AGENTS.md`（项目级指令），不再追加到全局 `~/.codex/AGENTS.md`——其他仓库不受三层协议影响
- 项目级 `config.toml` / `next-step.md`：已存在则**跳过并提示**（绝不覆盖你的真实任务数据）
- 支持 `--dry-run`（演练，零落盘）/ `--uninstall`（按 manifest 精确回滚；项目数据文件与 .bak 一律保留，不自动删除）
- 每次安装落一份 manifest 到 `~/.codex/.codex-quota-saver-manifest.*`，重复安装幂等
- 仓库里没有任何密钥、域名、个人信息——脚本也不碰任何凭据文件

## 部署完成后，每天就 5 步

1. 网页 ChatGPT **新对话** → 粘贴 `project/web-gpt-project-prompt.md` 作为项目指令 → 给任务
2. GPT 分析后只写 `.codex/next-step.md`（覆盖式：当前状态 / 唯一下一步 / 验证步骤 / 风险提示）
3. Codex **新会话**说一句：*「读 .codex/next-step.md，按文档执行，完成后输出执行报告」*
4. 高难度任务（架构/疑难 bug/复杂重构）手动切 Sol（medium 档），干完切回 Luna
5. GPT 用 git 核对结果 → 更新 next-step.md → 闭环

两个「新」不能省：ChatGPT 的对话是工具快照（旧对话看不到新连接器）；Codex 的 AGENTS.md 改动要新会话才生效。

## 已知问题（诚实条款）

每条已知问题标注类型与验证时间（口径：**Stable contract** = 官方契约 / **Observed behavior** = 本仓库实测 / **Known upstream bug** = 上游缺陷跟踪）：

- **Known upstream bug · #32587（Open，verified_at=2026-08-16）**：子代理可能静默继承父模型。首次 spawn 后必须核对 rollout 实际模型是否为 `gpt-5.6-luna`（验证门槛已写入 AGENTS.md 与 luna-routing skill）
- **Observed behavior · verified_at=2026-08-16**：App 档位白名单：config 写 `max` 但会话显示 `medium` = App 设置-配置未开启 max 档。**会话实际显示为准**
- **Known upstream bug · [#36294](https://github.com/openai/codex/issues/36294) / [#35097](https://github.com/openai/codex/issues/35097)（Open，verified_at=2026-08-16）**：官方「Sol 主 + Luna 子」原生模式（2026-08-15 官宣，地面半成品）：社区仍报 Luna 被 Multi Agents V2 的 `spawn_agent` 当 V1 过滤。本仓库的「Luna 主 + Luna 子」全程 V1 同版本委派，天然绕开该坑区——修复落地前不建议换成 Sol 主线程
- **Observed behavior · verified_at=2026-08-16**：改动 AGENTS.md / config 后必须开新会话才生效
- **Observed behavior · verified_at=2026-08-16**：v1.5.0 及以前安装会把三层协议追加到全局 `~/.codex/AGENTS.md`。升级到 v1.6.0 后建议迁移：删除全局 AGENTS.md 中旧的两个小节（标记「可整体删除回滚」），改为依赖项目根 `AGENTS.md`（重新运行新 install 写入）

更多坑见 [docs/pitfalls.md](docs/pitfalls.md)；执行纪律的方法论总纲见 [docs/lean-execution.md](docs/lean-execution.md)；想量化省了多少额度，用 [eval/](eval/) 的 A/B 评测方案。

## Roadmap 与稳定 Gate

以下 gate 全部通过前，本仓库保持 Public Alpha；过线后移除 Alpha 标注、发布 stable：

- [x] 安全边界硬化：MCP 桥能力层白名单 + 自建 OAuth 认证（bridge-guard）已发布
- [x] CI 三平台绿（installer / eval / 静态检查 / gitleaks / link check）
- [x] installer 幂等 / dry-run / uninstall / rollback 测试通过
- [ ] A/B 评测数据产出（协议见 eval/，n 小不宣称统计显著）
- [x] 干净卸载路径验证

## 上游与致谢

模型分层与子代理结构参考 [BruceLanLan/sol-luna-engineering-workflow](https://github.com/BruceLanLan/sol-luna-engineering-workflow)（Luna-first + AGENTS.md 路由），在此基础上做了：Luna 主线程架构（分析层外置到网页 GPT）、规则化路由（默认不 spawn + 4 条件 + 禁止清单）、三层协作协议、`next-step.md` 覆盖式交接协议。MCP 桥基于 [xyTom/coding-tools-mcp](https://github.com/xyTom/coding-tools-mcp)。

## License

[MIT](LICENSE)
