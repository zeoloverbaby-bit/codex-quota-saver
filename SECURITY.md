# Security

## 历史边界（v1.5.0 及以前，如实声明）

MCP 桥的安全边界是 **prompt 约束 + OAuth 认证**，不是能力约束：上游 coding-tools-mcp 不提供工具白名单，`apply_patch`/`exec_command` 在能力层可用，仅靠分析层指令约束模型不使用。

- 风险面：仓库内容本身是模型输入，存在 prompt injection 使模型偏离指令的理论可能
- 建议：桥的 workspace 指向专用仓库，不要部署在含高敏数据或密钥的仓库上；生成密钥只落在本机 `.local.*` 文件（已 gitignore），任何密钥/域名都不应进入本仓库

## v1.6.0 硬化后（bridge-guard）

- 能力层白名单：只读类工具（read/search/git 读）+ `write_next_step`（服务端硬编码仅可写 `.codex/next-step.md`）；exec/apply_patch 在协议层不存在。分类口径（repository_read / git_read / handoff / diagnostics / forbidden）见 [bridge/README.md](bridge/README.md)「Capability Taxonomy」
- `write_next_step` 物理边界（v1.6.6+）：`.codex` / `next-step.md` 为符号链接时 fail-closed 拒绝（绝不 follow）、realpath 边界包含检查兜底 Windows junction、同目录临时文件 + fsync + `os.replace` 原子写；安全拒绝经 MCP 层返回 `isError=true` 工具结果（v1.6.7+，不再冒到协议层 JSON-RPC error），会话保持可用
- 身份层：guard 自建 OAuth 2.1 授权服务器（授权码 + PKCE + DCR）。背景：ChatGPT 连接器实测只有 OAuth / 无身份验证 / 混合三种认证方式，无 API key 选项；「无身份验证」不可取（ngrok 域名公开可达，等于把工作区只读权限白送任何人）
- secrets：`.local.env` chmod 600（POSIX）/ icacls 当前用户（Windows）；OAuth 密码经环境变量注入 guard；上游 token 经 `CODING_TOOLS_MCP_AUTH_TOKEN` 环境变量传递（coding-tools-mcp 0.3.0 官方支持，不再经 `--auth-token` 进入进程 argv）；guard → 上游走 HTTP Bearer 头
- 残余风险（如实声明）：上游 token 持久化存储仅位于 owner-restricted secrets 文件；启动上游时 token 存在于本机子进程环境块（对同权限/高权限本机进程可见）；upstream 仅绑定 127.0.0.1，该风险属于本机同权限/高权限进程威胁模型
- 重启免疫：OAuth 客户端注册表 + 签名密钥落盘 `bridge/guard/state/oauth_state.json`（目录 ACL 收紧/0700，文件 600），重启桥授权不失效
- 撤销全部已发 token 的操作口径（与实现一致，如实声明）：**桥进程运行中删除 oauth_state.json 不撤销任何 token**（签名密钥在进程内存中，且下一次注册会以同一密钥重建文件）；`/revoke` 端点为 no-op（无状态自签 JWT，撤销靠 7 天 TTL 到期）。立即撤销全部 token 的唯一操作 = **停止桥 → 删除 oauth_state.json → 重启桥**（新随机密钥 → 已发 JWT 全部验签失败，连接器需重新授权）
- 残余风险（诚实条款）：白名单挡的是能力面；仓库内容本身仍是模型输入，prompt injection 的理论残余风险仍在。桥的 workspace 仍建议专用仓库

## v1.7.0 Secure MCP Tunnel Mode（threat boundary）

**Tunnel 管「怎么进来」，Guard 管「进来以后能干什么」。**

```
Internet
   X
No CQS public inbound MCP endpoint

Windows
  ↓ outbound HTTPS
OpenAI Secure Tunnel
  │
tunnel-client（本地，health 127.0.0.1:8081）
  ↓
bridge-guard   127.0.0.1:8766   ← capability boundary（白名单 + write_next_step + 文件系统边界）
  ↓
coding-tools-mcp  127.0.0.1:8765   ← 实际 MCP tools（仅本机）
  ↓
workspace
```

- **身份/transport**：OpenAI Secure MCP Tunnel 负责（ChatGPT ↔ 本机私网 transport、外部连接入口；不需要把 MCP server 暴露到公网）
- **能力**：CQS bridge-guard 负责（repository_read / git_read / write_next_step / filesystem boundary；deny exec/apply_patch/etc.）——与 public 模式**同一个 guard、同一份白名单**，Tunnel 模式没有能力边界旁路
- **tunnel mode 的 guard 本地 MCP 不启用 CQS OAuth，因此强制 loopback**：host 仅允许 `127.0.0.1` / `::1`；配置成非 loopback（0.0.0.0 / LAN / 公网 / localhost 名字）会 **fail-fast**——无 OAuth 的 MCP 永远不会被误配置成网络可访问服务
- **Tunnel 永远连 8766 guard，绝不直连 8765 upstream**（8765 = raw upstream，直连是安全边界绕过）；setup 生成的 profile MCP target 硬编码为 `http://127.0.0.1:8766/mcp`
- 网络边界：upstream/guard 只绑定 loopback；不开放 Windows Firewall inbound rule；不启动 ngrok；Tunnel 模式没有公网 listener

### Workspace Read Boundary（usage boundary）

> Bridge 对整个 workspace 具有广泛只读能力。**`.gitignore` ≠ Bridge 不可读。**

不要把以下内容放在 Tunnel workspace：`.env`、private key、SSH key、浏览器数据、客户数据、生产 secrets、高敏内部文件。推荐 **dedicated working copy**。

> 本轮不实现 path denylist / secret firewall——这是使用边界，不是技术边界。

### Runtime API Key Boundary

Runtime API Key（`CONTROL_PLANE_API_KEY`）：

- 不进 repo（gitignored `.secrets.tunnel.local.env`，ACL 仅当前用户）
- 不进 argv（setup 不接受 `-RuntimeApiKey` 参数；launcher 从 env 文件运行时加载）
- 不进 guard config / launcher 文本
- 运行时进入 tunnel-client environment（官方 `env:CONTROL_PLANE_API_KEY` 引用）
- 残余风险（如实声明）：运行期间 key 存在于当前用户进程环境块，同权限/高权限本机进程理论可读取——这是 Public Alpha threat model，**不是** hardware-backed secret

## 报告漏洞

直接开 issue 描述影响与复现。本仓库无赏金程序；发现密钥类问题请不要在 issue 中贴密钥原文。

## 免责声明

本仓库面向个人实验工作流，**不承诺**生产级安全保证。部署到任何含他人数据的仓库前，请自行评估。
