# MCP 桥（bridge-guard 版）

架构：

```
ChatGPT 连接器 → ngrok → bridge-guard（OAuth 认证 + 白名单 + write_next_step）→ coding-tools-mcp（内部引擎，仅本机）
```

> 三层架构的**分析层通道**。没有桥也能跑三层架构（网页 GPT 输出 next-step.md 全文，你人工落盘）；有桥则网页 GPT 可以直接读代码、直接写 `.codex/next-step.md`，省掉人工中转。
> 桥依赖第三方包 [xyTom/coding-tools-mcp](https://github.com/xyTom/coding-tools-mcp)（PyPI 可装，感谢原作者）；本目录的 guard 是能力层白名单代理 + 自建 OAuth 授权服务器。

## 安全边界（能力层 + 身份层）

- guard 只暴露**白名单只读工具**（read/search/git 读类，共 11 个）+ `write_next_step`（服务端硬编码只能写 `.codex/next-step.md`）
- `apply_patch` / `exec_command` 及一切变更类工具在**协议层不存在**——模型连「想按」的机会都没有
- 认证：guard **自建 OAuth 2.1 授权服务器**（授权码 + PKCE + DCR）。为什么不用 API key：ChatGPT 连接器的认证下拉只有 OAuth / 无身份验证 / 混合三种（2026-08-17 实测），发不了静态 API key 头
- 授权流程：连接器发起 OAuth → 浏览器打开 guard 的密码页 → 输入部署时生成的 OAuth 密码 → 拿到 access token（HS256 JWT，7 天有效）
- **重启免疫**：客户端注册表与签名密钥落盘 `guard/state/oauth_state.json`（状态目录 ACL 收紧/0700，文件 600），重启桥不失效（旧桥「重启即全断」的坑从设计上根治）；只有删除该文件才需重新授权
- 上游 token 只走环境变量（进程命令行不可见）；上游不开 OAuth、不对外——认证全在 guard 层
- secrets 落 `.secrets.local.env`（POSIX chmod 600 / Windows icacls 当前用户），已 gitignore
- 残余风险（如实声明）：guard 挡的是能力面；仓库内容本身仍是模型输入，prompt injection 的理论残余风险见 [SECURITY.md](../SECURITY.md)

## 部署

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\bridge\setup.ps1 -Domain <你的ngrok静态域名> -Workspace <项目路径>
# macOS / Linux（第三个参数可选：自定义 OAuth 密码，默认随机生成 16 位）
./bridge/setup.sh <你的ngrok静态域名> <项目路径>
```

一条命令装完依赖、生成密钥、写好启动器；你只需两件事（脚本会提示时机）：
1. ChatGPT 新建连接器：URL = `https://<域名>/mcp`，认证方式 = **OAuth**
2. 连接器发起授权时，浏览器打开的密码页里输入 **OAuth 密码**（脚本打印 + 写在 `.secrets.local.env`）

日常使用：双击 / 运行 `start-bridge.local.*`；**不开发时关闭**（隧道 = 项目后门）。

启动约 15 秒后会自动打开浏览器到桥密码页（预热 ngrok 拦截页）：新浏览器首次会看到英文警告页，**点一次「Visit Site」**（cookie 持久，之后不再出现）；点过之后每次启动直接见密码页，可当作「桥活着」的体检页。

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
