#requires -Version 5.1
# bridge/tunnel.ps1 —— Secure MCP Tunnel 纯逻辑辅助（本文件必须 UTF-8 带 BOM；被 setup.ps1 点源引用，被 tests/setup-tunnel.Tests.ps1 直接测试）
# 全部无副作用：只做格式校验与内容生成——Tunnel 产品化路径的可测锚点。

# TunnelId 官方 CLI 权威格式（2026-08-24 实测 tunnel-client 0.0.12）：
#   init --tunnel-id 校验错误消息: "must match tunnel_<32 lowercase letters or digits>"（失败 exit 1）。
# CQS 预检口径：
#   - 符合 ^tunnel_[0-9a-z]{32}$（官方格式）→ 通过
#   - 纯 hex 与含非 hex 小写字母都放行；权威校验交给官方 CLI，不 hard-fail、不造 semver framework
function Test-TunnelIdFormat {
    param([string]$TunnelId)
    if ($null -eq $TunnelId) { return $false }
    return ($TunnelId -match '^tunnel_[0-9a-z]{32}$')
}

function Get-TunnelIdShort {
    param([string]$TunnelId)
    # profile 名用末尾 8 位：可预测 + 避免明显冲突（cqs-<short>，不做数据库）
    return $TunnelId.Substring($TunnelId.Length - 8)
}

function ConvertTo-PlainString {
    param([System.Security.SecureString]$Secure)
    # 仅在写 owner-restricted secrets 文件时需要 plaintext；绝不回显、绝不进 argv
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function New-TunnelGuardConfigJson {
    param([string]$Workspace, [int]$GuardPort = 8766, [int]$UpstreamPort = 8765, [string[]]$Allowlist)
    # 用户不再手写 JSON；隧道 ID / OpenAI runtime key 绝不进入 guard config。
    # guard 是 capability boundary：tunnel 永远连 8766 guard，绝不直连 8765 upstream。
    $guardJson = @{
        auth_mode = 'tunnel'
        host = '127.0.0.1'
        port = $GuardPort
        workspace = $Workspace.Replace('\', '/')
        upstream_url = "http://127.0.0.1:$UpstreamPort/mcp"
        upstream_token_env = 'CQS_UPSTREAM_TOKEN'
        allowlist = $Allowlist
    } | ConvertTo-Json -Depth 4
    return $guardJson
}

function New-TunnelSecretsContent {
    param([string]$UpstreamToken, [string]$RuntimeApiKey)
    # env 文件必须纯 ASCII：非 ASCII 字节会破坏 cmd for /f 在 GBK 系统的读取（2026-08-17 实测根因）
    if ($RuntimeApiKey -match '[^\x00-\x7F]') {
        throw 'Runtime API Key 含非 ASCII 字符，无法安全写入 launcher env 文件'
    }
    return "# codex-quota-saver secure tunnel secrets (gitignored, ACL-restricted) - DO NOT COMMIT`r`nCONTROL_PLANE_API_KEY=$RuntimeApiKey`r`nCQS_UPSTREAM_TOKEN=$UpstreamToken`r`n"
}

function New-TunnelLauncherBat {
    param(
        [string]$SecretsFile, [string]$McpExe, [string]$Workspace,
        [string]$GuardPy, [string]$GuardScript, [string]$GuardConf,
        [string]$TunnelClient, [string]$ProfileDir, [string]$ProfileName,
        [int]$UpstreamPort = 8765, [int]$GuardPort = 8766
    )
    # launcher 契约（全 ASCII；不含任何 secret 字面量——运行时从 env 文件加载）：
    # 1. 读 secrets env 文件 → 2. 设 CODING_TOOLS_MCP_AUTH_TOKEN（token 永不进 argv）
    # 3. 启动 upstream（127.0.0.1:8765，纯 loopback，无防火墙规则，无公网监听）
    # 4. 启动 guard（127.0.0.1:8766）→ 5. bounded readiness（30s，失败打印是哪一层、不宣称成功）
    # 6. tunnel-client doctor（失败即停）→ 7. tunnel-client run foreground（保活隧道）
    # 注意：单引号 here-string 避免 PS 插值吃掉 bat 里的 $ok/$i 等变量。
    $bat = @'
@echo off
REM codex-quota-saver secure tunnel launcher (generated, gitignored)
netstat -ano | findstr ":__GUARDPORT__ " | findstr LISTENING >nul 2>&1
if not errorlevel 1 (
  echo Bridge is already running - port __GUARDPORT__ in use. Do NOT start it twice.
  echo To restart: close all three windows first, then run this file again.
  pause
  exit /b 1
)
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("__SECRETS__") do set "%%a=%%b"
set "CODING_TOOLS_MCP_AUTH_TOKEN=%CQS_UPSTREAM_TOKEN%"
REM upstream/guard stay loopback only - no all-interfaces bind, no firewall rule, no public listener
start "upstream" /min "__MCPEXE__" --workspace "__WORKSPACE__" --host 127.0.0.1 --port __UPSTREAMPORT__
start "guard" /min "__GUARDPY__" "__GUARDSCRIPT__" --config "__GUARDCONF__"
powershell -NoProfile -Command "$ok=0; for($i=0;$i -lt 30;$i++){ $u = netstat -ano | Select-String ':__UPSTREAMPORT__ .*LISTENING'; $g = netstat -ano | Select-String ':__GUARDPORT__ .*LISTENING'; if($u -and $g){$ok=1;break}; Start-Sleep 1 }; if(-not $ok){ Write-Host 'FAILED: upstream or guard did not listen within 30s'; exit 1 }"
if errorlevel 1 (
  echo FAILED: upstream or guard did not listen within 30s - tunnel NOT started.
  pause
  exit /b 1
)
"__TUNNELCLIENT__" doctor --profile-dir "__PROFILEDIR__" --profile "__PROFILE__"
if errorlevel 1 (
  echo FAILED: tunnel-client doctor reported problems - tunnel NOT started.
  pause
  exit /b 1
)
REM tunnel-client runs in the foreground and keeps the Secure MCP Tunnel open
"__TUNNELCLIENT__" run --profile-dir "__PROFILEDIR__" --profile "__PROFILE__"
pause
'@
    $out = $bat.Replace('__GUARDPORT__', "$GuardPort")
    $out = $out.Replace('__UPSTREAMPORT__', "$UpstreamPort")
    $out = $out.Replace('__SECRETS__', $SecretsFile)
    $out = $out.Replace('__MCPEXE__', $McpExe)
    $out = $out.Replace('__WORKSPACE__', $Workspace)
    $out = $out.Replace('__GUARDPY__', $GuardPy)
    $out = $out.Replace('__GUARDSCRIPT__', $GuardScript)
    $out = $out.Replace('__GUARDCONF__', $GuardConf)
    $out = $out.Replace('__TUNNELCLIENT__', $TunnelClient)
    $out = $out.Replace('__PROFILEDIR__', $ProfileDir)
    $out = $out.Replace('__PROFILE__', $ProfileName)
    return $out
}
