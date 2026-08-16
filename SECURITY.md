# Security

## 当前边界（截至 v1.5.0，如实声明）

MCP 桥的安全边界是 **prompt 约束 + OAuth 认证**，不是能力约束：上游 coding-tools-mcp 不提供工具白名单，`apply_patch`/`exec_command` 在能力层可用，仅靠分析层指令约束模型不使用。

- 风险面：仓库内容本身是模型输入，存在 prompt injection 使模型偏离指令的理论可能
- 建议：桥的 workspace 指向专用仓库，不要部署在含高敏数据或密钥的仓库上；生成密钥只落在本机 `.local.*` 文件（已 gitignore），任何密钥/域名都不应进入本仓库

## v1.6.0 硬化后（bridge-guard）

- 能力层白名单：只读类工具（read/search/git 读）+ `write_next_step`（服务端硬编码仅可写 `.codex/next-step.md`）；exec/apply_patch 在协议层不存在
- secrets：`.local.env` chmod 600（POSIX）/ icacls 当前用户（Windows）；认证 token 经环境变量注入（进程命令行不可见）——若上游暂不支持则在此处如实标注例外

## 报告漏洞

直接开 issue 描述影响与复现。本仓库无赏金程序；发现密钥类问题请不要在 issue 中贴密钥原文。

## 免责声明

本仓库面向个人实验工作流，**不承诺**生产级安全保证。部署到任何含他人数据的仓库前，请自行评估。
