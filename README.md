# codex-luna-orchestration

**解决一个问题：Codex 额度被最贵的模型干了最便宜的活。**

这是一个「三层架构」执行层的完整工具包——Luna 主线程 + 有界 `luna_worker` 子代理 + 网页 GPT 规划层 + 可选的 MCP 桥模板，外加 15 个实测坑的排坑表和一套可复现的 A/B 评测方案。目标读者：被 Codex 额度焦虑困扰的 GPT Pro 用户，以及替他们部署这套方案的 AI。仓库无任何密钥、无个人数据，MIT 开源。

## 它解决什么（三个浪费口子）

| 痛点 | 浪费在哪 | 本仓库的药方 |
|---|---|---|
| 规划思考在 Codex 里烧 Sol | 分析、拆解、审查全走最贵档 | 三层架构：把「想」外置到网页 GPT（已付费的 Pro 额度） |
| 所有任务无差别用 Sol | commit、merge 这种机械活也烧 Sol | 主线程默认 Luna Max + Sol 手动档（Luna 额度约为 Sol 的 20-25 倍） |
| 子代理要么不用要么乱用 | 小活 spawn 亏委派开销，大活不 spawn 慢 | 规则化路由：默认不 spawn，4 条件才 spawn，有界执行包 |

一句话总结：**「想」放在已经付过费的网页额度上，「做」放在最便宜的模型档上，只给最难的任务手动开 Sol。**

## 方案一页看懂

```
网页 GPT（Pro 网页额度）─ 规划 / 分析 / 审查 / 写 .codex/next-step.md
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

## 目录对照表（每个文件解决哪个痛点）

| 路径 | 是什么 | 解决什么 |
|---|---|---|
| `global/config-agents.toml` | `[agents]` 段模板 | 子代理默认用 Luna Max、并发上限 6 |
| `global/AGENTS.md` | 路由规则 + 协作协议 | 「默认不 spawn + 4 条件」纪律；执行层职责边界 |
| `global/agents/luna-worker.toml` | 子代理定义 | 有界执行包（文件互斥、7 类 STOP 条件、不宣称验收） |
| `project/dot-codex/config.toml` | 项目级配置 | 该项目主线程 = Luna Max（按项目分层，其他项目不受影响） |
| `project/dot-codex/next-step.md` | 交接协议模板 | 网页 GPT → Codex 的零思考指令格式 |
| `project/dot-codex/skills/luna-routing/SKILL.md` | 路由决策技能 | spawn 判定决策树 + 执行包模板 + 验证门槛 |
| `project/web-gpt-project-prompt.md` | GPT 项目指令模板 | 分析层的行为规范（粘贴给网页 GPT，不装磁盘） |
| `install.ps1` / `install.sh` | 一键安装 | 备份不删除、只追加不覆盖，见下节 |
| `bridge/` | MCP 桥启动模板（可选增强） | 网页 GPT 直连仓库，免人工中转（占位符版，无密钥） |
| `docs/pitfalls.md` | 15 个实测坑 | 部署与排障，人话版 |
| `eval/` | A/B 评测方案 | 量化省了多少额度（协议 + 任务集 + 雷达图脚本） |

## 快速安装

前置条件：Codex 订阅（App 或 CLI）、ChatGPT Pro 网页版。Windows 建议 PowerShell；macOS/Linux 用 bash 脚本。

```bash
git clone https://github.com/zeoloverbaby-bit/codex-luna-orchestration.git
cd codex-luna-orchestration
```

```powershell
# Windows（-ProjectPath 换成你自己的仓库路径）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -ProjectPath "D:\path\to\your\repo"
```

```bash
# macOS / Linux（参数：CODEX_HOME、项目路径）
./install.sh ~/.codex /path/to/your/repo
```

装完记得：Codex **App 设置-配置**开启 reasoning effort 的 max 档位（否则 config 里的 max 被静默降级），然后**新会话**才生效。

## 安装脚本的行为边界（重要）

- **备份不删除**：任何被改写的既有文件先复制为 `<文件>.bak-<时间戳>`，不删除任何东西
- `config.toml`：只追加 `[agents]` 段；已有 `[agents]` 则跳过
- `AGENTS.md`：不存在则创建；已存在则**追加**两个小节（带「可整体删除回滚」标记），不覆盖你原有内容
- 项目级 `config.toml` / `next-step.md`：已存在则**跳过并提示**（绝不覆盖你的真实任务数据）
- 仓库里没有任何密钥、域名、个人信息——脚本也不碰任何凭据文件

## 每日使用节奏（5 步）

1. 网页 ChatGPT **新对话** → 粘贴 `project/web-gpt-project-prompt.md` 作为项目指令 → 给任务
2. GPT 分析后只写 `.codex/next-step.md`（覆盖式：当前状态 / 唯一下一步 / 验证步骤 / 风险提示）
3. Codex **新会话**说一句：*「读 .codex/next-step.md，按文档执行，完成后输出执行报告」*
4. 高难度任务（架构/疑难 bug/复杂重构）手动切 Sol（medium 档），干完切回 Luna
5. GPT 用 git 核对结果 → 更新 next-step.md → 闭环

两个「新」不能省：ChatGPT 的对话是工具快照（旧对话看不到新连接器）；Codex 的 AGENTS.md 改动要新会话才生效。

> 可选增强：想让网页 GPT 直接读写仓库（免人工中转），按 `bridge/README.md` 部署 MCP 桥（含 OAuth 稳定性三件套与冒烟测试）。

## 已知问题（诚实条款）

- **issue #32587（Open）**：子代理可能静默继承父模型。首次 spawn 后必须核对 rollout 实际模型是否为 `gpt-5.6-luna`（验证门槛已写入 AGENTS.md 与 luna-routing skill）
- **App 档位白名单**：config 写 `max` 但会话显示 `medium` = App 设置-配置未开启 max 档。**会话实际显示为准**
- **官方「Sol 主 + Luna 子」原生模式（2026-08-15 官宣，地面半成品）**：社区仍报 Luna 被 Multi Agents V2 的 `spawn_agent` 当 V1 过滤（[#36294](https://github.com/openai/codex/issues/36294) / [#35097](https://github.com/openai/codex/issues/35097)）。本仓库的「Luna 主 + Luna 子」全程 V1 同版本委派，天然绕开该坑区——修复落地前不建议换成 Sol 主线程
- 改动 AGENTS.md / config 后必须开新会话才生效

更多坑见 [docs/pitfalls.md](docs/pitfalls.md)；想量化省了多少额度，用 [eval/](eval/) 的 A/B 评测方案。

## 上游与致谢

模型分层与子代理结构参考 [BruceLanLan/sol-luna-engineering-workflow](https://github.com/BruceLanLan/sol-luna-engineering-workflow)（Luna-first + AGENTS.md 路由），在此基础上做了：Luna 主线程架构（分析层外置到网页 GPT）、规则化路由（默认不 spawn + 4 条件 + 禁止清单）、三层协作协议、`next-step.md` 覆盖式交接协议。MCP 桥基于 [xyTom/coding-tools-mcp](https://github.com/xyTom/coding-tools-mcp)。

## License

[MIT](LICENSE)
