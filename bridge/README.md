# MCP 桥（可选增强）：让网页 GPT 直接读写你的仓库

> 三层架构的**分析层通道**。没有桥也能跑三层架构（网页 GPT 输出 next-step.md 全文，你人工落盘）；有桥则网页 GPT 可以直接读代码、直接写 `.codex/next-step.md`，省掉人工中转。
> 桥依赖第三方包 [xyTom/coding-tools-mcp](https://github.com/xyTom/coding-tools-mcp)（PyPI 可装，感谢原作者），本目录提供**半自动部署脚本、脱敏启动模板与排障知识**。

## 原理 30 秒版

```
coding-tools-mcp（本地 8765 端口，文件读写工具）
        ▲
ngrok 隧道（静态域名 https://<你的域名>.ngrok-free.dev）
        ▲
ChatGPT 连接器（OAuth 2.1 + PKCE 授权）
        ▲
网页 GPT → 读仓库 / 只写 .codex/next-step.md
```

两个认证通道：**OAuth**（连接器标准授权，带密码页）与 **Bearer**（静态令牌备用通道，OAuth 出问题时仍可用）。

## 方式 A（推荐）：半自动 setup，一条命令 + 两次人工

```
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Domain <你的ngrok静态域名> -Workspace <项目路径>
# macOS / Linux
./setup.sh <你的ngrok静态域名> <项目路径>
```

脚本自动完成：装依赖 → 生成密钥 → 写 `start-bridge.local.bat`（**含密钥，已 gitignore，绝不提交**）→ 启动捕获模式 → 轮询 ngrok 流量 API 自动捕获连接器的 client_id/redirect_uri → 回写启动文件并收尾。

**你全程只需两件事**（脚本会提示时机）：
1. 在 ChatGPT 里创建 Custom MCP 连接器（URL `https://<域名>/mcp`，认证 OAuth）——授权页报 `Unknown client_id` 是**预期的**（捕获模式，脚本正等着抓参数）
2. 最后点「重新连接」→ 输脚本给的 OAuth 密码

部署完成后，**每天双击 `start-bridge.local.bat`**（或运行 `.local.sh`）启动桥。

前置：ngrok 已注册 authtoken 并在控制台绑定静态域名（脚本会检查并提示）；工作区路径必须真实存在。

## 方式 B（兜底/审查）：手动两阶段

不用脚本时照下面的流程做，逻辑与 setup 相同。

### 阶段 1：准备 + 启动捕获模式

1. 装包：`uv tool install coding-tools-mcp`（或 pipx）；装 ngrok 并申请静态域名
2. 复制 `start-bridge.bat` / `start-bridge.sh` 到本机，按占位符表填写（client_id/redirect_uri 两行**先填 `__CAPTURE_PENDING__`**）
3. 启动脚本 → 在 ChatGPT 创建连接器（URL `https://<域名>/mcp`，OAuth）——`Unknown client_id` 是预期的

### 阶段 2：捕获 + 重启

4. 从授权 URL 或 ngrok 流量 API 捕获 client_id / redirect_uri（方法见下）
5. 把捕获值填进启动文件 → 关掉脚本窗口重开 → 回 ChatGPT「重新连接」→ 输密码 → 完成

### 占位符填写表

| 占位符 | 从哪来 | 存哪 |
|---|---|---|
| `<你的-ngrok-静态域名>` | ngrok 控制台申请 | 本机脚本 |
| `<你的-OAuth-密码>` | 你自己编一个（连接器授权页输它） | 本机脚本 |
| `<64位-hex-密钥>` | 随机生成：`python -c "import secrets; print(secrets.token_hex(32))"` | **仅本机脚本** |
| `<静态-Bearer-令牌>` | 服务器启动输出（或自定静态值） | 本机脚本 |
| `<你的项目仓库路径>` | 工作区路径 | 本机脚本 |
| `<从连接器捕获的-client_id>` / `<…redirect_uri>` | 见下方「连接器参数捕获」 | 本机脚本 |
| `<coding-tools-mcp.exe 路径>` / `<ngrok.exe 路径>` | 安装位置（winget 装的 ngrok 常在 `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Ngrok.Ngrok_*\`） | 本机脚本 |

**安全红线：以上值全部只存本机，绝不进 git、不进聊天、不进任何共享文档。**

### 连接器参数捕获（client_id / redirect_uri）

ChatGPT 连接器是 PKCE 公共客户端，`client_id` 和 `redirect_uri` 由平台生成。两个获取法：

1. **从授权 URL 捕获**：在 ChatGPT 里点连接器「重新连接」，跳转的授权 URL 参数里就有 `client_id=...` 和 `redirect_uri=...`
2. **从隧道流量捕获**：`ngrok` 本地 API `http://127.0.0.1:4040/api/requests/http` 的请求缓冲里能看到连接器打来的完整授权请求（raw 字段是 base64 编码）——setup 脚本就是自动轮询这里

捕获后填进启动脚本的 `CODING_TOOLS_MCP_OAUTH_CLIENT_ID` / `CODING_TOOLS_MCP_OAUTH_REDIRECT_URIS`——这两个 env 让服务器**重启后仍认识连接器**（否则授权页报 `Unknown client_id`）。

## OAuth 稳定性三件套（setup 已自动做；手动模式照此配）

服务器默认行为：签名密钥**每次启动随机生成**、客户端注册表**纯内存态**——所以**重启即废所有 token**（表现为连接器工具全挂 / 401 / TaskGroup 报错）。三个 env 一次固化：

| env | 值 | 作用 |
|---|---|---|
| `CODING_TOOLS_MCP_OAUTH_CLIENT_ID` + `CODING_TOOLS_MCP_OAUTH_REDIRECT_URIS` | 捕获的连接器参数 | 预注册客户端，重启后仍认识连接器 |
| `CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET` | 64 位 hex | 稳定签名密钥，重启后旧 token 仍有效 |
| `CODING_TOOLS_MCP_OAUTH_TOKEN_TTL` | `604800`（7 天，官方上限） | token 有效期；7 天后重授权一次即可。**365 天需自行改服务器源码放宽上限，本仓库不附带补丁**（升级会覆盖，维护成本自负） |

## 冒烟测试三连（部署验收）

```bash
# ① initialize
curl -s -X POST http://127.0.0.1:8765/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"1.0"}}}' | head -c 300

# ② tools/list（应返回 18 个工具）
curl -s -X POST http://127.0.0.1:8765/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <静态-Bearer-令牌>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | head -c 300

# ③ tools/call read_file（读工作区里的真实文件，返回内容与磁盘一致）
curl -s -X POST http://127.0.0.1:8765/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <静态-Bearer-令牌>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"<仓库里的一个真实文件>"}}}' | head -c 500
```

**排障原则：服务器侧全绿就别动服务器**——先开 ChatGPT 新对话重试（平台侧会话级状态），再点「重新连接」；仍挂才怀疑服务器。完整排障见 [docs/pitfalls.md](../docs/pitfalls.md)。

## 不开发时关掉

隧道 = 给 ChatGPT 开了项目后门。不用时关闭启动脚本窗口（关窗口即断）。
