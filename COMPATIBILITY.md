# COMPATIBILITY 兼容性矩阵

> Last verified: 2026-08-16。高速变化领域，本文件随每次实测更新；「今天实测成功」不自动推出「clone 后成功」，请对照本矩阵。

| 项 | 版本 / 环境 | 状态 | 备注 |
|---|---|---|---|
| coding-tools-mcp | 0.3.0（2026-08-13 发布） | ✅ 实测 | 脚本已 pin；上游 token 经 `CODING_TOOLS_MCP_AUTH_TOKEN` env（0.3.0 官方支持，不进 argv）；升级需重验 OAuth/bearer 参数 |
| ngrok | 3.39.11 | ✅ 实测（Windows） | winget 安装不在 PATH，脚本已处理 |
| Windows 11 + PowerShell 5.1 | — | ✅ 实测 | install.ps1 / bridge/setup.ps1 全路径实测；.ps1 必须 UTF-8 BOM |
| Ubuntu 24.04 | — | ⚠️ 未实机 | install.sh / setup.sh 仅 `bash -n` 语法验证，首跑请走 `--dry-run` |
| macOS | — | ⚠️ experimental | 未验证 |
| Codex | App / CLI（2026-08 实测档） | ✅ 实测 | 见 README 已知问题（#32587 / #36294 / #35097） |
| ChatGPT 连接器 | 认证方式只有 OAuth / 无身份验证 / 混合（2026-08-17 实测） | ✅ 实测 | 无 API key 选项 → bridge-guard 自建 OAuth 2.1（授权码 + PKCE + DCR）接入 |
| mcp SDK（guard） | 2.0.0（pin）+ pyjwt 2.13.0（pin） | ✅ 实测 | 12 个测试含端到端 OAuth 全流程（DCR → 密码页 → PKCE → Bearer 调 MCP） |

## 已知不兼容 / 注意

- PowerShell 5.1：脚本文件必须 UTF-8 **带 BOM**，否则中文注释解析乱码
- PowerShell 5.1：不支持 `&&`、三元 `?:`、字符串内嵌 `$(if)` 语法
- 任何对 `~/.codex/AGENTS.md`、`config.toml` 的改动需**新会话**生效
