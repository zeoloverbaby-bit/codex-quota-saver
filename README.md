# Codex Luna Orchestration

让最便宜的执行模型干最重的活：**Codex 三层架构执行层配置包**——Luna 主线程 + 有界 `luna_worker` 子代理 + 网页 GPT 规划层，一套文件全装齐。

> 面向被 Codex 额度焦虑困扰的 GPT Pro 用户。本仓库是纯配置与规则（无密钥、无个人数据），可直接由你自己的 AI 按 README 在你自己环境部署。

## 三层架构（一分钟看懂）

```
网页 GPT（Pro 网页额度）─ 规划 / 分析 / 审查 / 写 .codex/next-step.md
        │  零思考执行指令
Codex 主线程（默认 Luna Max）─ commit / merge / 批量 / 小修
        │  仅「重执行任务」才 spawn
luna_worker 子代理 ×N（Luna Max）─ 有界执行包，并行干活
        │
你 ─ 所有授权 / 方向决策（免费且不可外包）
```

核心判断只有一个：**「想」放在已经付过费的网页额度上，「做」放在最便宜的模型档上，只给最难的任务手动开 Sol。**

- Luna 的额度约为 Sol 的 20-25 倍（订阅配额口径，以你在 App 里看到的实际倍数为准）
- 默认永不 spawn 子代理（委派开销 > 工作本身 = 亏本买卖）；只有「重执行任务」且同时满足 4 条件才 spawn（规则见 `global/AGENTS.md`）
- 疑难决策不在 Codex 内 spawn Sol 子代理——STOP 报告，网页 GPT 分析后经 `next-step.md` 回流

## 目录结构（与安装位置一一对应）

```
codex-luna-orchestration/
  install.ps1 / install.sh         ← 一键安装（自动备份，绝不删文件）
  global/
    config-agents.toml             ← [agents] 段 → 追加进 ~/.codex/config.toml
    AGENTS.md                      ← 路由规则 + 协作协议 → ~/.codex/AGENTS.md
    agents/luna-worker.toml        ← 子代理定义 → ~/.codex/agents/
  project/
    dot-codex/config.toml          ← 项目级主线程 Luna → <你的仓库>/.codex/config.toml
    dot-codex/next-step.md         ← 交接协议模板 → <你的仓库>/.codex/next-step.md
    dot-codex/skills/luna-routing/SKILL.md  ← 路由决策技能 → <你的仓库>/.codex/skills/
    web-gpt-project-prompt.md      ← 粘贴给网页 GPT 的项目指令（不装磁盘）
```

## 快速安装

前置条件：Codex 订阅（App 或 CLI）、ChatGPT Pro 网页版。Windows 建议用 PowerShell；macOS/Linux 用 bash 脚本。

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

> 可选增强：想让网页 GPT 直接读写仓库（免人工中转），可自行部署 MCP 桥（如 coding-tools-mcp + 隧道）。桥涉及本地密钥，不在本仓库分发。

## 已知问题（诚实条款）

- **issue #32587（Open）**：子代理可能静默继承父模型。首次 spawn 后必须核对 rollout 实际模型是否为 `gpt-5.6-luna`（验证门槛已写入 AGENTS.md 与 luna-routing skill）
- **App 档位白名单**：config 写 `max` 但会话显示 `medium` = App 设置-配置未开启 max 档。**会话实际显示为准**
- **官方「Sol 主 + Luna 子」原生模式（2026-08-15 官宣，地面半成品）**：社区仍报 Luna 被 Multi Agents V2 的 `spawn_agent` 当 V1 过滤（[#36294](https://github.com/openai/codex/issues/36294) / [#35097](https://github.com/openai/codex/issues/35097)）。本仓库的「Luna 主 + Luna 子」全程 V1 同版本委派，天然绕开该坑区——修复落地前不建议换成 Sol 主线程
- 改动 AGENTS.md / config 后必须开新会话才生效

## 上游与致谢

模型分层与子代理结构参考 [BruceLanLan/sol-luna-engineering-workflow](https://github.com/BruceLanLan/sol-luna-engineering-workflow)（Luna-first + AGENTS.md 路由），在此基础上做了：Luna 主线程架构（分析层外置到网页 GPT）、规则化路由（默认不 spawn + 4 条件 + 禁止清单）、SDD 协作协议、`next-step.md` 覆盖式交接协议。

## License

[MIT](LICENSE)
