# Security

## 当前边界（截至 v1.5.0，如实声明）

MCP 桥的安全边界是 **prompt 约束 + OAuth 认证**，不是能力约束：上游 coding-tools-mcp 不提供工具白名单，`apply_patch`/`exec_command` 在能力层可用，仅靠分析层指令约束模型不使用。

- 风险面：仓库内容本身是模型输入，存在 prompt injection 使模型偏离指令的理论可能
- 建议：桥的 workspace 指向专用仓库，不要部署在含高敏数据或密钥的仓库上；生成密钥只落在本机 `.local.*` 文件（已 gitignore），任何密钥/域名都不应进入本仓库

## v1.6.0 硬化后（bridge-guard）

- 能力层白名单：只读类工具（read/search/git 读）+ `write_next_step`（服务端硬编码仅可写 `.codex/next-step.md`）；exec/apply_patch 在协议层不存在
- 身份层：guard 自建 OAuth 2.1 授权服务器（授权码 + PKCE + DCR）。背景：ChatGPT 连接器实测只有 OAuth / 无身份验证 / 混合三种认证方式，无 API key 选项；「无身份验证」不可取（ngrok 域名公开可达，等于把工作区只读权限白送任何人）
- secrets：`.local.env` chmod 600（POSIX）/ icacls 当前用户（Windows）；OAuth 密码经环境变量注入 guard；上游 token 经 `CODING_TOOLS_MCP_AUTH_TOKEN` 环境变量传递（coding-tools-mcp 0.3.0 官方支持，不再经 `--auth-token` 进入进程 argv）；guard → 上游走 HTTP Bearer 头
- 残余风险（如实声明）：上游 token 持久化存储仅位于 owner-restricted secrets 文件；启动上游时 token 存在于本机子进程环境块（对同权限/高权限本机进程可见）；upstream 仅绑定 127.0.0.1，该风险属于本机同权限/高权限进程威胁模型
- 重启免疫：OAuth 客户端注册表 + 签名密钥落盘 `bridge/guard/state/oauth_state.json`（目录 ACL 收紧/0700，文件 600），重启桥授权不失效；删除该文件 = 撤销全部已发 token
- 残余风险（诚实条款）：白名单挡的是能力面；仓库内容本身仍是模型输入，prompt injection 的理论残余风险仍在。桥的 workspace 仍建议专用仓库

## 报告漏洞

直接开 issue 描述影响与复现。本仓库无赏金程序；发现密钥类问题请不要在 issue 中贴密钥原文。

## 免责声明

本仓库面向个人实验工作流，**不承诺**生产级安全保证。部署到任何含他人数据的仓库前，请自行评估。
