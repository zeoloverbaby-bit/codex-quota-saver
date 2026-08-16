# 三层架构 A/B 评测方案（协议 A · 公开版）

> **目的**：量化「三层架构（网页 GPT 规划 + Codex Luna 执行 + luna_worker 子代理）」相对「老方法（Codex Sol 全包）」在额度、质量、速度、纪律四个方面的差异。
> **方法**：基准任务双跑 A/B——同一份任务规格书，两臂各跑一遍，ABBA 顺序，最终汇总为雷达图。
> **性质声明**：每级 n=2（T4 n=1），结果只报「试点数据 + 区间」，不做显著性检验，不宣称统计证明。
> **状态**：方案已冻结未执行。本目录 = 完整协议 + 渲染脚本 + 采集表头，任何评测者可按此复现。

## 0.1 决策冻结记录（2026-08-16，方案所有者已确认）

> 预注册的一部分：以下四项已冻结，执行时照此办理，跑完不改。

1. ✅ **评测期间 MCP 桥 workspace 切到评测仓库**（生产桥暂停 1-2 天，评测结束切回）
2. ✅ **A 臂用 CLI + 独立 `CODEX_HOME`**（如 `C:\eval\codex-home-a`）
3. ✅ **规模：完整版**（T1-T4 全部，T3-b 选跑）；最小可行版（仅 T2×2）作为时间不足时的兜底
4. ✅ **预注册阈值**：额度经济性 r ≥ 2.0（省 ≥50%）；通过率/返工/范围控制 ≥ 0.9；时间 ≥ 0.6 为可接受 tradeoff

## 1. 两臂定义（先钉死，再谈其他）

| | A 臂（老方法） | B 臂（新方法·三层架构） |
|---|---|---|
| 主线程模型 | Sol，effort = high | Luna，effort = max |
| 子代理 | 无（老环境默认不 spawn，若自发 spawn 则记录并计消耗） | 按路由规则可 spawn luna_worker（Luna Max） |
| 规划环节 | Codex 自己从任务规格书开始 | 网页 GPT（Sol xhigh）读规格书 + 读仓库 → 写 next-step.md → Codex 执行 |
| Codex 输入 | 任务规格书全文 | 仅 next-step.md（零思考指令） |
| 环境 | 干净隔离环境（§1.1） | 生产配置（全局 AGENTS.md + [agents] + luna-routing skill，即本仓库安装产物） |

**两臂的公共输入 = 同一份任务规格书**（§4.3）。差异只在"工作怎么分配"，这是归因干净的前提。

### 1.1 A 臂环境隔离（必做，否则对比不纯）

全局 `~/.codex/AGENTS.md` 的路由规则会污染 A 臂。A 臂使用独立 `CODEX_HOME`（如 `C:\eval\codex-home-a`），只含：

```toml
# config.toml（A 臂专用）
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
```

- 无 AGENTS.md、无 agents/ 目录、无 [agents] 段
- 启动方式：`CODEX_HOME=C:\eval\codex-home-a codex`（CLI）；若用 App，在会话选择时注意隔离
- **声明**：此环境是"老方法"的干净理论版，≠ 历史上任何真实环境，报表里如实注明

### 1.2 B 臂 = 生产真实配置

- **网页 GPT**：评测期间把 MCP 桥 workspace **临时切到评测仓库**（生产桥暂停 1-2 天，评测结束切回）。relay 模式（GPT 看不到仓库，只看规格书）会削弱 B 臂规划质量，不公平，仅作降级方案
- **Codex**：本仓库 install 脚本装出的生产配置；评测仓库自带项目根 `AGENTS.md`（评测协议）+ `.codex/config.toml`（Luna Max）+ `luna-routing` skill
- 子代理：T3 预期触发 spawn；每 run 后核对 rollout 实际模型——顺带完成 issue #32587 的首次实测

### 1.3 Arm C（候选臂，冻结外，条件触发）

2026-08-15 官方官宣 Codex 原生支持「Sol 主 + Luna 舰队」（Multi Agents v2 跨模型委派）。**本臂不在协议 A 预注册范围**，仅作协议 B 的候选对照登记在此。

| | B 臂（本方案） | C 臂（官方原生模式，候选） |
|---|---|---|
| 主线程模型 | Luna，effort = max | Sol，effort = 待定（推测 medium/high） |
| 子代理 | luna_worker（规则化 spawn） | 官方 Luna 委派（prompt 路由） |
| 规划环节 | 网页 GPT 写 next-step.md | 两个子方案：C1 = 同样走网页 GPT 交接；C2 = Codex 内闭环（Sol 自规划） |

**触发条件（同时满足才启动，届时单独预注册）**：
1. 官方修复落地——社区确认 V2 `spawn_agent` 不再把 Luna 当 V1 过滤（跟踪 issue #36294 / #35097；2026-08-16 仍 Open）
2. #32587（子代理静默继承父模型）经实测确认修复，或 C 臂的 prompt 路由经 rollout 核对稳定
3. 协议 A 数据产出后——A/B 结论决定 C 臂的对照问题（若 B 已大幅优于 A，则 C 的对照问题 = "C vs B：Sol 编排是否值得"；若 B 未达标，则对照 A）

**本臂的额外意义**：桥宕机时 Codex 内闭环（C2）是 B 臂架构的天然兜底，评测可顺带测量「无网页 GPT 中转」的额度代价。

## 2. 指标定义

### 2.1 原始指标（每 run 记录）

| 指标 | 定义 | 来源 |
|---|---|---|
| main_tokens_in/out | 主线程输入/输出 token | token_count 事件（§2.1.1），按 turn 序列归因模型 |
| sub_tokens_in/out | 子代理 token（若 spawn） | 同上；主/子分离为加分项，非雷达必选项 |
| web_chars_in/out | 网页 GPT 提示/输出字符数 | 人工记录（复制时计数） |
| pass_focused / pass_affected | 验证命令通过数/总数 | 验收时实跑 |
| rework_rounds | 执行→审核→修复的循环数 | 人工记录 |
| wall_minutes | 从给任务到验收通过的墙钟分钟 | 人工计时 |
| interventions | 需要人决策/纠偏的次数（例行确认不算） | 人工记录 |
| out_of_scope_files | 越出任务规格书"可改范围"的改动文件数 | `git diff --name-only` 对照 |

### 2.1.1 数据源实测结论（2026-08-16 已实地验证）

翻查了 08-15/16 共 4 个真实会话 JSONL（`~/.codex/sessions/2026/08/`），结论：

**A. token 计量存在，位置与预期不同**
- 没有"消息级 usage 字段"；计量在 `event_msg` 中 `type=token_count` 的事件，约每个 turn 结束发射一次
- 每事件含 `total_token_usage`（会话累计）与 `last_token_usage`（最近一轮），字段细分：`input_tokens / cached_input_tokens / cache_write_input_tokens / output_tokens / reasoning_output_tokens / total_tokens`
- **采集口径**：轮级增量 = 相邻 token_count 事件的 `total_token_usage` 差值（主口径）；`last_token_usage` 做交叉验证

**B. 模型按 turn 序列归因（已验证可行）**
- `turn_context` 事件带 `model`（实测见 gpt-5.6-luna / gpt-5.6-sol / codex-auto-review）；token_count 事件本身不带 model
- 事件按时间有序 → 每段 token 增量归给最近一个 turn_context 的 model（序列归因，采集脚本实现；归因近似性在报表声明）
- 实测确认同一会话内可混用多个模型——**采集必须按 turn 拆，不能按会话混计**

**C. 子代理独立记账：尚未可知（T3 首 spawn 现场验证）**
- 存量会话 multi_agent_version 均 disabled，从未 spawn 过，无从验证
- 若子代理 token 混入同一 token_count 流 → 不分离，雷达主口径仍成立：A 臂全 Sol、B 臂全 Luna，按模型汇总即可；子代理分离只是 T3 内部附加分析

**D. cached 占比极高（实测 ~99%）**
- 08-16 会话 cached_input 207,616 / input 208,221。**额度主口径 = `total_tokens`（平台记账口径）**，cached 占比在报表附表披露，不做折扣假设

**E. 新风险：codex-auto-review 会混入计量**
- 实测 08-16 有一会话 models 含 `codex-auto-review`（自动 review 的消耗进了 token_count）
- **评测环境两臂都必须关闭 auto review**（若某臂无法关闭，该 run 作废重跑并在报表声明）

### 2.2 归一化：额度单位

```
1 额度单位 = 1 Sol token
1 Luna token = 1/20 额度单位（取保守端）
网页 GPT token ≈ web_chars ÷ 1.5（粗估）——单独一列，不进额度单位
```

> **系数复核提醒（2026-08-15 官方降价）**：Luna API 降 80%、Terra 降 20%。本系数是**订阅配额**口径（非 API 价格），执行前在 App 实测一次配额倍率，若与 1/20 偏差 >50% 则更新此系数并记录于决策冻结记录。

网页 GPT 消耗不进雷达、不并入额度维度，但在报表中并列披露——诚实口径：**换预算 ≠ 零成本**，Pro 网页额度也是有限资源。

### 2.3 雷达六维（统一"越高越好"）

| 维度 | 原始指标 | 方向 | 单任务比率 r |
|---|---|---|---|
| 额度经济性 | quota_units | 低好 | A/B |
| 测试通过率 | pass_focused + pass_affected | 高好 | B/A |
| 返工轮数 | rework_rounds | 低好 | A/B |
| 完成时间 | wall_minutes | 低好 | A/B |
| 人工干预 | interventions | 低好 | A/B |
| 范围控制 | out_of_scope_files | 低好 | A/B |

**边界规则（防除零）**：
- 双方同 0（如都无越界）或同满分（如通过率都 100%）→ r = 1（持平）
- A = 0 且 B > 0（cost 维）→ B 记 0 分（该维完败）
- 通过率分母为 0 的任务 → 该任务此维剔除

## 3. 雷达图设计（基准圆法）

- **A 臂 = 六边形基准圆**（每维 100 分）
- **B 臂每维得分 = min(r_geo, 2.0) × 100**，r_geo = 该级内任务的几何平均比率；截断 200 防单点爆表
- 解读规则：**B 越出圆 = 该维优于老方法；缩进 = 劣于**
- 图集：主雷达 1 张（全部 run 的几何平均）；分层雷达 4 张（T1-T4 各一张，选做）
- 渲染：`radar.py`（本目录，填数据即出 PNG）
- 图下必注：n、截断说明、网页 GPT 消耗估算值

**为什么用比率而不用绝对分**：绝对评分要人为定"多少 token 算 5 分"，比率为 0-1 外任意定义；比率法的 A 臂基准圆天然成立，B 臂分数有直接业务含义（200 = 好一倍，50 = 差一半）。

## 4. 评测集设计（分级）

### 4.1 分级总表

| 级 | 定义 | 对应路由场景 | 预期发现 | 任务 |
|---|---|---|---|---|
| T1 机械 | 单文件/单点、零规划价值 | 主线程 Luna vs Sol | 省额度但幅度有限（规划本来就少） | T1-a, T1-b |
| T2 中等 | 2-4 文件小功能 | 规划移出 + 执行 Luna | **主战场，预期省幅最大** | T2-a, T2-b |
| T3 重型 | ≥2 个文件互斥的独立工作包 | 触发 luna_worker 并行 | 子代理经济学 + 范围控制 | T3-a, T3-b |
| T4 疑难 | 隐蔽缺陷、需架构判断 | B 臂手动切 Sol medium | 预期大体持平（验证"不受伤"） | T4-a |

**执行顺序**：每级内 ABBA（A-B-B-A），各级按 T1→T2→T3→T4。同任务的 A/B 两 run 尽量放在**同一额度窗口周期**内，避免窗口重置差异。

### 4.2 基准仓库 mini-ops 设计

Python + uv + pytest + SQLite 的小型任务流水线（镜像真实项目形态，约 12 个文件、基线约 35 个测试全绿）：

```
mini_ops/
  jobs.py        # Job 模型与入队
  repository.py  # SQLite 仓储
  worker.py      # 执行循环
  finalizer.py   # 终态后处理 + audit
  utils.py       # 工具函数
  config.py      # 常量
tests/           # pytest 套件（基线全绿）
```

- 基线标签：`v1.0-base`（T1-T3 用）、`v1.0-t4-seed`（T4 用，已预埋 bug）
- 输入补丁 commit：`t1b-red`（仅含一个 RED 测试，作为 T1-b 的任务输入）
- 每个 run 从基线独立 worktree 出发，互不污染

### 4.3 任务规格书（每 run 的公共输入，两臂同文）

**规格书模板字段**：编号 / 分级 / 目标 / 基线 / 输入补丁 / 可改范围 / 禁止 / 验收命令 / 说明

> 注：T4 的通过率维度两臂都会是 100%（验收含全量 PASS），区分度主要在时间、返工、额度——报表如实声明。

**[T1-a] utils 新增 format_duration**（机械·单文件）

- 目标：`utils.py` 新增 `format_duration(seconds: int) -> str`，输出 `"1h 2m 3s"`，为 0 的段省略；补 3 个单测（覆盖 0 / 60 / 3661）
- 基线：`v1.0-base`；可改：`mini_ops/utils.py`、`tests/test_utils.py`
- 验收：`uv run pytest tests/test_utils.py -q` 全 PASS；`ruff check` 两个文件零告警

**[T1-b] 修复 get 缺失抛出**（机械·单点）

- 目标：`repository.get(job_id)` 对不存在的 id 应返回 None（当前抛 KeyError）
- 基线：`v1.0-base` + 输入补丁 `t1b-red`（新增 RED 测试 `test_get_missing`）
- 可改：`mini_ops/repository.py`；禁止：改动测试文件
- 验收：focused 转绿；全量回归 PASS

**[T2-a] job 幂等入队**（中等·3 文件）

- 目标：`enqueue` 时同一 `unique_key` 已存在则返回已有 job，不重复插入；repository 层加唯一约束；补 4 个测试（含并发重复入队场景）
- 基线：`v1.0-base`；可改：`jobs.py`、`repository.py`、`tests/test_jobs.py`、`tests/test_repository.py`
- 验收：focused + affected 全 PASS；ruff 零告警

**[T2-b] max_attempts 与 retry_failed 终态**（中等·3 文件）

- 目标：Job 增加 `max_attempts`（默认 3）与 attempt 计数；worker 达上限后置**新终态 `retry_failed`**（终态枚举与 repository 状态机同步更新）
- 基线：`v1.0-base`；可改：`jobs.py`、`worker.py`、`repository.py` + 对应测试文件
- 验收：focused + affected 全 PASS；新终态有状态机测试覆盖

**[T3-a] notifier + exporter 双模块**（重型·文件互斥）

- 目标：两个独立模块并行实现——`notifier.py`（job 达终态时产生通知事件）+ `exporter.py`（导出 job 历史为 CSV）；主线程集成：worker 调 notifier、新增 CLI 入口调 exporter，补集成测试
- **互斥文件组**：① `notifier.py` + `tests/test_notifier.py`；② `exporter.py` + `tests/test_exporter.py`；主线程独占：`worker.py`、`cli.py`、`tests/test_integration.py`
- 基线：`v1.0-base`；禁止：两模块互相引用、跨组改文件
- 验收：focused 全 PASS + affected 全 PASS；集成测试通过

**[T3-b] finalizer 拆分 + stats 模块**（重型·备选）

- 目标：`finalizer.py` 拆为 `finalizer.py`（状态推进）+ `auditor.py`（audit 独立职责）；另新增 `stats.py`（成功率/耗时分布统计）；主线程集成
- 互斥组：① finalizer/auditor 及其测试；② `stats.py` + `tests/test_stats.py`；主线程：`worker.py` + 集成测试
- 验收：同 T3-a
- 说明：时间紧可只跑 T3-a（方案默认 T3-a 必跑、T3-b 选跑）

**[T4-a] 潜伏 bug：audit 偶发丢失**（疑难·n=1）

- 场景输入（模仿真实用户报告）："高并发下偶发 audit 记录缺失，测试套件全绿，请定位根因并修复"——**不提供 bug 位置**
- 基线：`v1.0-t4-seed`（预埋：finalizer 先 finish job 再写 audit，写入失败时 job 已终态且 audit 丢失；该窗口无测试覆盖，现有套件全绿）
- 可改：合理范围内不限；禁止：修改既有测试的语义
- 验收：根因报告 + 最小修复（audit 与 finish 同事务或补偿路径）+ 新增防回归测试（模拟写入失败）+ 全量 PASS
- 说明：T4 疑难任务构造成本高，n=1，报表单列

## 5. 执行流程（每 run 标准清单）

1. **建环境**：`git worktree add eval/<run_id> <基线>`；有输入补丁则 cherry-pick
2. **计时开始**（T0）
3. **按臂执行**：
   - A 臂：干净 CODEX_HOME 启动 → 贴任务规格书 → 执行 → 验收
   - B 臂：网页 GPT（新对话，@ 连接器）给规格书 → 读仓库、写 next-step.md → Codex 新会话"读 .codex/next-step.md，按文档执行，完成后输出执行报告" → 验收
4. **验收**（两臂同一套动作）：跑验收命令 + `git diff --name-only` 对照"可改范围" + 记录 rework/interventions/时间
5. **采集**：提取该 run 的 session JSONL usage → 填 ledger.csv
6. **收尾**：worktree 保留 diff 存档后 `git worktree remove`

**计时规则**：只计 AI 侧执行墙钟（给任务 → 验收通过）；中途人工离开需中断计时并在 notes 声明。

## 6. 环境准备清单（执行前逐项打勾）

- [x] 数据源验证：token 计量在 event_msg/token_count 事件，按 turn 序列归因模型可行（2026-08-16 已实地验证）；新风险=auto review 混入计量，两臂须关闭
- [ ] 建 mini-ops 仓库 + 打 tag `v1.0-base` / `v1.0-t4-seed` + 提交 `t1b-red` 补丁
- [ ] 建 A 臂干净环境（独立 CODEX_HOME）
- [ ] 评测仓库放项目根 `AGENTS.md`（评测协议）+ `.codex/config.toml`（Luna Max）+ 复制 luna-routing skill
- [ ] 把 MCP 桥 workspace 切到评测仓库（生产桥暂停，结束后切回）
- [ ] 初始化 ledger.csv（表头见附录 C）
- [ ] 雷达图脚本就位（`radar.py`）
- [ ] **预注册判定标准（§7）写入并冻结**——跑之前定，跑之后不改

## 7. 预注册判定标准（冻结后不可改）

| 判定 | 条件 |
|---|---|
| ✅ 有效 | 额度经济性 r_geo ≥ 2.0（省 ≥50%）；通过率 r ≥ 0.9；返工 r ≥ 0.9；范围控制 r ≥ 0.9 |
| ⚠️ 部分有效 | 额度达标但质量/纪律任一维 < 0.9 → 逐维归因，回查路由规则 |
| ❌ 无效 | 额度 r < 2.0 → 不宣称节省；先查实际档位与归一化系数 |
| 时间维度 | 预期 r < 1.0（新方法多一次交接，大概率更慢）；r ≥ 0.6 为可接受 tradeoff，低于 0.6 单独讨论 |

时间维度**不并入**"有效"判定，单独披露——新方法的卖点是额度，不是速度。

## 8. 结果报表模板

### 8.1 原始数据表
ledger.csv 直接呈现（附录 C 表头）。

### 8.2 雷达图
主雷达 1 张（全任务几何平均）+ 分层雷达 4 张（选做）。

### 8.3 诚实披露清单（报表必附，逐条照写）
- n=2/级（T4 n=1）：试点数据，无显著性检验
- 网页 GPT 消耗为字符估算（÷1.5），不进额度单位，见附表
- A 臂为"老方法"干净理论版，非任何历史真实环境
- ABBA 仅部分抵消学习效应；顺序未随机化（时间约束）
- 雷达分数截断于 200
- T4 通过率两臂均 100%，该维在 T4 无区分度
- 时间维度为已知 tradeoff，单独讨论

## 9. 时间预算

| 项 | 预估 |
|---|---|
| 基准仓库 + tag + 补丁 | 0.5 天 |
| T1 ×4 run | 1.5 h |
| T2 ×4 run | 3 h |
| T3 ×4 run（含 T3-b） | 4-5 h |
| T4 ×2 run | 2 h |
| 提取 + 汇总 + 出图 | 2-3 h |
| **合计** | **分散 2-3 天，约 13-15 h** |

**最小可行版**：只跑 T2×2（4 run）+ 主雷达 6 维，约 4-5 h 出第一版数字。

---

## 附录 A：雷达图渲染脚本

见本目录 [`radar.py`](radar.py)（matplotlib 骨架，填实测数据即出 PNG）。

## 附录 B：B 臂网页 GPT 固定话术（新对话开场）

```
你是 AB 评测 B 臂的分析层，按生产协作规范工作：
1. 读仓库与下方任务规格书，产出零思考执行指令
2. 用 apply_patch 把指令写入 .codex/next-step.md（覆盖式：当前状态/下一步任务/验证步骤/风险提示）
3. 禁止执行类操作；不宣称最终验收；指令精确到文件路径与验收命令

任务规格书：
[粘贴对应任务的规格书全文]
```

## 附录 C：ledger.csv 表头

```csv
run_id,tier,task,arm,order,date,main_model,main_effort,sub_model,sub_effort,main_tok_in,main_tok_out,sub_tok_in,sub_tok_out,web_chars_in,web_chars_out,quota_units,pass_focused,pass_affected,rework_rounds,wall_minutes,interventions,out_of_scope_files,notes
```

- `quota_units` 计算：Sol token ×1 + Luna token ×1/20（main 与 sub 分开算再求和）
- `order`：本任务内的执行次序（1/2，用于 ABBA 与学习效应披露）
