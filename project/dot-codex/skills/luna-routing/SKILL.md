---
name: luna-routing
description: 执行规划时使用：判定当前任务是否属于「重执行任务」、是否 spawn luna_worker 子代理、如何拆包与验收。Use before delegating work, spawning subagents, or planning multi-file execution.
---

# Luna 路由决策（本项目专用）

## 决策树

1. **默认路径：主线程直接做**。需求清晰、或委派开销 > 工作本身时，一律不 spawn。
2. **重执行判定（全部满足才 spawn `luna_worker`）**：
   - ≥2 个真正独立、文件互斥、可单独验证的工作包；或单包大至需要保护主上下文
   - 每包范围与验收标准明确
   - 可写文件零重叠，每个文件只有一个 owner
   - 主线程负责集成与验收
3. **疑难决策**（架构、安全、数据完整性、破坏性迁移、跨系统接口、两次基于证据的尝试失败）→ **STOP 报告用户**，等 `.codex/next-step.md` 回流（网页 GPT 决策）。**不在 Codex 内 spawn Sol 子代理。**
4. **禁止 spawn 的场景**：单文件小改、查询/只读分析、Evidence 报告、文档更新、轻量修复。

## 执行包模板（派发给 worker 时）

```
目标：
可写范围（精确文件列表）：
不可触碰：
验收标准：
验证命令：
```

## 主线程模型切换（由用户手动控制）

- 默认 Luna：commit、merge、批量执行等常规/机械任务
- 高难度任务（架构、疑难 bug、复杂重构）：用户手动切 Sol（medium 档），完成后切回
- 本技能不改变模型选择；但若主线程为 Sol，路由判定更保守（spawn 门槛更高）

## 验证门槛

- 每个 worker 返回后核对：实际改动文件 ⊆ 授权范围；跑验收标准
- 集成由主线程完成，worker 不宣称最终验收
- **模型使用诚实条款**：只有 agent 活动或工具结果明确标识 `gpt-5.6-luna` 才可声称用了 Luna；首次 spawn 后核对 rollout 的实际模型（issue #32587：子代理可能静默继承父模型，如发生即报告用户）
