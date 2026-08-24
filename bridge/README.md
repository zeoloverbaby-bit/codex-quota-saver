# MCP 桥（bridge-guard 版）

## Connection Layer（v1.7.0）

```text
CQS Connection Layer
│
├── Secure MCP Tunnel          ← Windows verified / recommended
│     ChatGPT → OpenAI Tunnel → tunnel-client → 127.0.0.1:8766 guard → 127.0.0.1:8765 upstream → workspace
│
└── ngrok + CQS OAuth          ← existing fallback（向后兼容）
      ChatGPT 连接器 → ngrok → guard（OAuth 认证 + 白名单 + write_next_step）→ coding-tools-mcp（仅本机）
```

> 核心原则：**Tunnel 管「怎么进来」，Guard 管「进来以后能干什么」。**
> Secure MCP Tunnel 负责身份与公网 transport（不需要把 MCP server 暴露到公网）；bridge-guard 负责 capability policy（repository_read / git_read / write_next_step / filesystem boundary，deny exec/apply_patch 等）——两种连接方式共用同一个 guard，能力边界完全一致。

## 安全边界（能力层 + 身份层）

- guard 只暴露**白名单只读工具**（read/search/git 读类，共 11 个）+ `write_next_step`（服务端硬编码只能写 `.codex/next-step.md`）
- `apply_patch` / `exec_command` 及一切变更类工具在**协议层不存在**——模型连「想按」的机会都没有
- 认证（public/ngrok 模式）：guard **自建 OAuth 2.1 授权服务器**（授权码 + PKCE + DCR）。为什么不用 API key：ChatGPT 连接器的认证下拉只有 OAuth / 无身份验证 / 混合三种（2026-08-17 实测），发不了静态 API key 头
- 认证（tunnel 模式）：**OpenAI Secure MCP Tunnel 负责身份**，guard 不启用自建 OAuth——本地无 OAuth MCP 强制 loopback（127.0.0.1 / ::1），配置成非 loopback 会 fail-fast（详见「部署」）
- 授权流程（public/ngrok 模式）：连接器发起 OAuth → 浏览器打开 guard 的密码页 → 输入部署时生成的 OAuth 密码 → 拿到 access token（HS256 JWT，7 天有效）
- **重启免疫**：客户端注册表与签名密钥落盘 `guard/state/oauth_state.json`（状态目录 ACL 收紧/0700，文件 600），重启桥不失效（旧桥「重启即全断」的坑从设计上根治）。撤销全部已发 token = **停桥 → 删除该文件 → 重启桥**（进程运行中删除无效——密钥在内存，且会以同一密钥重建文件）；`/revoke` 端点为 no-op，撤销靠 7 天 TTL 兜底（见 [SECURITY.md](../SECURITY.md)）
- 上游 token 经 `CODING_TOOLS_MCP_AUTH_TOKEN` 环境变量传递（coding-tools-mcp 0.3.0 官方支持，不经命令行参数/argv）；上游不开 OAuth、不对外——认证全在 guard 层；token 仍存在于本机进程环境块（同权限/高权限本机进程可见），upstream 仅绑定 127.0.0.1
- secrets 落 `.secrets.local.env`（POSIX chmod 600 / Windows icacls 当前用户），已 gitignore
- 残余风险（如实声明）：guard 挡的是能力面；仓库内容本身仍是模型输入，prompt injection 的理论残余风险见 [SECURITY.md](../SECURITY.md)

## Capability Taxonomy（认知权限 vs 行动权限）

> 原则：Least Privilege = 完成角色职责所需的**最小充分权限**。Planner / Reviewer 需要广读仓库与 Git Evidence（认知），行动权限必须极窄——**Read broadly, act narrowly**。限制的是行动能力，不是认知能力。

| Bundle | 工具 | 语义 |
|---|---|---|
| `repository_read` | server_info, read_file, list_dir, list_files, search_text, view_image | 仓库内容 / 结构 / 元数据认知 |
| `git_read` | git_status（branch / HEAD / upstream / ahead-behind）、git_diff（执行结果审查）、git_log、git_show（commit evidence）、git_blame（根因定位） | Git Evidence 读取——Planner/Reviewer 闭环的最小充分证据集 |
| `handoff` | write_next_step（guard 自实现） | 唯一 mutation：固定 `.codex/next-step.md` |
| `diagnostics`（**不放行**） | check_exec_environment, read_output, request_permissions | 名字像 read，实为 Execution Runtime State / mutation 通道——Planner 无 exec 能力，无认知价值 |
| `forbidden`（协议层不存在） | apply_patch, exec_command, write_stdin, kill_command | mutation / 任意 shell / 进程控制 |

- 分类锚定 coding-tools-mcp 0.3.0 工具目录（18 个）；上游升级先重验契约测试（tests/test_guard.py），再改 setup 的 allowlist
- 已知窄认知缺口（**绝不为此开放 exec_command**）：任意两 refs 间 diff（如 `main...HEAD`）、merge-base、branch/tag refs 枚举——未来候选 guard 自实现只读工具 `git_compare` / `git_refs` / `git_merge_base`（固定 git 子命令、无 shell、workspace-bound），本轮记录不实现

## 部署

**两种连接方式（v1.7.0）**：推荐 Secure MCP Tunnel（Windows 已验证）；ngrok + OAuth 为向后兼容 fallback。

### Secure MCP Tunnel（Windows 推荐）

```powershell
powershell -ExecutionPolicy Bypass `
  -File .\bridge\setup.ps1 `
  -Transport Tunnel `
  -Workspace "D:\path\to\repo" `
  -TunnelId "tunnel_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" `
  -TunnelClientPath "D:\Tools\tunnel-client.exe"
```

setup 自动：生成 `bridge/.secrets.tunnel.local.env`（Runtime API Key + upstream token，gitignored + ACL 收紧）、生成 `guard-config.tunnel.local.json`（auth_mode=tunnel，无密钥，host 固定 127.0.0.1）、调用官方 tunnel-client init 创建 profile（`cqs-<tunnel-id 末 8 位>`，MCP target 恒为 `http://127.0.0.1:8766/mcp`——**绝不直连 8765 upstream**）、生成一键 launcher `start-bridge-tunnel.local.bat`。用户不再手写 JSON、不再手工起三个进程。

前置（hard）：Workspace 存在；TunnelId 官方格式 `tunnel_<32 lowercase letters or digits>`（权威校验由官方 CLI 完成，非法即 fail）；tunnel-client.exe 存在且 `--version` 可运行。Runtime API Key 优先读已有 `CONTROL_PLANE_API_KEY` 环境变量，否则 `Read-Host -AsSecureString` 交互输入（不回显）——**绝不进 argv / guard config / launcher**。

日常：双击 `start-bridge-tunnel.local.bat`——upstream(8765) → guard(8766) → bounded readiness(30s) → `tunnel-client doctor`（失败即停）→ `tunnel-client run` 前台保活隧道。关闭窗口即断开隧道。

### ngrok + CQS OAuth（fallback，向后兼容）

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\bridge\setup.ps1 -Domain <你的ngrok静态域名> -Workspace <项目路径>
# macOS / Linux（第三个参数可选：自定义 OAuth 密码，默认随机生成 16 位）
./bridge/setup.sh <你的ngrok静态域名> <项目路径>
```

一条命令装完依赖、生成密钥、写好启动器；你只需两件事（脚本会提示时机）：
1. ChatGPT 新建连接器：URL = `https://<域名>/mcp`，认证方式 = **OAuth**
2. 连接器发起授权时，浏览器打开的密码页里输入 **OAuth 密码**（脚本打印 + 写在 `.secrets.local.env`）

日常使用：双击 / 运行 `start-bridge.local.*`（ngrok 模式）或 `start-bridge-tunnel.local.bat`（Tunnel 模式）；**不开发时关闭**（隧道 = 项目后门）。

启动约 15 秒后会自动打开浏览器到桥密码页（预热 ngrok 拦截页，仅 ngrok 模式）：新浏览器首次会看到英文警告页，**点一次「Visit Site」**（cookie 持久，之后不再出现）；点过之后每次启动直接见密码页，可当作「桥活着」的体检页。

前置：ngrok 已注册 authtoken 并在控制台绑定静态域名（脚本会检查并提示）；工作区路径必须真实存在。

## 冒烟三连

1. `tools/list` 无 `apply_patch` / `exec_command`
2. `write_next_step` 落盘 `.codex/next-step.md` 成功
3. 尝试调用 `apply_patch` → 返回 `tool not allowed by bridge-guard allowlist`

## 兜底与排障

- 没桥也能跑三层架构：GPT 把 `.codex/next-step.md` 全文输出，人工落盘即可
- 桥只读 + 写 next-step，**不参与验收**——验收永远以你本地 git / 测试命令为准
- 端口冲突：guard 8766、上游 8765，先关旧桥再跑 setup
- 版本要求：coding-tools-mcp 0.3.0、mcp SDK 2.0.0（pin）、ngrok 3.39.11、Python 3.11（guard venv 由 setup 自建），见 [COMPATIBILITY.md](../COMPATIBILITY.md)
- 授权页打不开 / 401：确认连接器认证选的是 OAuth 而非「无身份验证」；OAuth 密码在 `.secrets.local.env` 的 `CQS_OAUTH_PASSWORD` 行
- 排障原则：服务器侧全绿就别动服务器——先开 ChatGPT 新对话重试（平台侧会话级状态），再点连接器「重新连接」；仍挂才怀疑服务器。完整排障见 [docs/pitfalls.md](../docs/pitfalls.md)
