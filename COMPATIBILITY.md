# COMPATIBILITY 兼容性矩阵

> Last verified: 2026-08-16。高速变化领域，本文件随每次实测更新；「今天实测成功」不自动推出「clone 后成功」，请对照本矩阵。

| 项 | 版本 / 环境 | 状态 | 备注 |
|---|---|---|---|
| coding-tools-mcp | 0.3.0（2026-08-13 发布） | ✅ 实测 | 脚本已 pin；升级需重验 OAuth/bearer 参数 |
| ngrok | 3.39.11 | ✅ 实测（Windows） | winget 安装不在 PATH，脚本已处理 |
| Windows 11 + PowerShell 5.1 | — | ✅ 实测 | install.ps1 / bridge/setup.ps1 全路径实测；.ps1 必须 UTF-8 BOM |
| Ubuntu 24.04 | — | ⚠️ 未实机 | install.sh / setup.sh 仅 `bash -n` 语法验证，首跑请走 `--dry-run` |
| macOS | — | ⚠️ experimental | 未验证 |
| Codex | App / CLI（2026-08 实测档） | ✅ 实测 | 见 README 已知问题（#32587 / #36294 / #35097） |
| ChatGPT 连接器 | OAuth（当前）/ API key（bridge-guard 上线后） | ✅ / 待验证 | bridge-guard 上线时更新本行 |

## 已知不兼容 / 注意

- PowerShell 5.1：脚本文件必须 UTF-8 **带 BOM**，否则中文注释解析乱码
- PowerShell 5.1：不支持 `&&`、三元 `?:`、字符串内嵌 `$(if)` 语法
- 任何对 `~/.codex/AGENTS.md`、`config.toml` 的改动需**新会话**生效
