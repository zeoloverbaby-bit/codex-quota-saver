#requires -Version 5.1
# bridge/setup.ps1 —— 双进程部署：coding-tools-mcp(内部) + bridge-guard(对外)（本文件必须 UTF-8 带 BOM）
# 用法: .\bridge\setup.ps1 -Domain <ngrok域名> -Workspace <项目路径> [-OAuthPassword <密码>] [-DryRun]
#       （v1.7.0）.\bridge\setup.ps1 -Transport Tunnel -Workspace <项目路径> -TunnelId tunnel_xxx [-TunnelClientPath <路径>] [-HealthPort 8081] [-DryRun]
# 认证：guard 自建 OAuth 2.1（ChatGPT 连接器只有 OAuth/无认证/混合三种认证，API key 不可行）。
#       v1.7.0 Tunnel 模式：OpenAI Secure MCP Tunnel 负责身份/transport，guard 不再自建 OAuth（auth_mode=tunnel）。
# 安全：secrets 只落 .local.env（ACL 收紧到当前用户 + gitignore）；密码经环境变量注入 guard；
#       上游 token 经 CODING_TOOLS_MCP_AUTH_TOKEN 环境变量传递（coding-tools-mcp 0.3.0 官方支持，不进 argv）；
#       Runtime API Key 只进 gitignored ACL 收紧的 secrets 文件 + 子进程环境，绝不进 argv / guard config / launcher。
param(
    [Parameter(Mandatory=$false)][string]$Domain,
    [Parameter(Mandatory=$true)][string]$Workspace,
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword',
        'OAuth 密码：crypto RNG 生成（或用户显式传入），仅落盘 ACL 收紧的本地 secrets 文件，不经进程命令行')]
    [string]$OAuthPassword,
    [string]$Transport = '',
    [string]$TunnelId,
    [string]$TunnelClientPath,
    [int]$HealthPort = 8081,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $BridgeDir 'acl.ps1')   # Tighten-Acl：secrets 默认 (R,W)；launcher 需 (RX,W)——双击执行缺 X 会报「无法访问」
. (Join-Path $BridgeDir 'secrets.ps1')   # New-Token / New-Password（防越界 NUL 版）
. (Join-Path $BridgeDir 'tunnel.ps1')   # Tunnel 纯逻辑辅助（v1.7.0）
$EnvFile = Join-Path $BridgeDir '.secrets.local.env'
$TunnelEnvFile = Join-Path $BridgeDir '.secrets.tunnel.local.env'
$GuardConf = Join-Path $BridgeDir 'guard\guard_config.json'
$TunnelGuardConf = Join-Path $BridgeDir 'guard-config.tunnel.local.json'
$StateDir = Join-Path $BridgeDir 'guard\state'
$OAuthState = Join-Path $StateDir 'oauth_state.json'
$LegacyOAuthState = Join-Path $BridgeDir 'guard\oauth_state.json'
$Launcher = Join-Path $BridgeDir 'start-bridge.local.bat'
$TunnelLauncher = Join-Path $BridgeDir 'start-bridge-tunnel.local.bat'
$TunnelProfileDir = Join-Path $BridgeDir 'tunnel-profile'
$GuardPort = 8766
$UpstreamPort = 8765

$Allowlist = @(
    'server_info','read_file','list_dir','list_files','search_text',
    'git_status','git_diff','git_log','git_show','git_blame','view_image'
)

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- Transport 解析（v1.7.0；legacy 完全兼容）----
# -Transport 未指定 → legacy Ngrok（旧调用不加任何参数即此路径）
# -Transport Ngrok → 同 legacy，但要求 -Domain
# -Transport Tunnel → Secure MCP Tunnel（Windows verified / recommended）
if ($Transport -eq '') { $Transport = 'Ngrok' }
if ($Transport -notin @('Ngrok', 'Tunnel')) {
    throw "未知 -Transport: $Transport（支持: Ngrok / Tunnel）"
}
if ($Transport -eq 'Ngrok' -and -not $Domain) {
    throw '-Transport Ngrok 需要 -Domain <你的ngrok静态域名>（legacy 调用方式不变）'
}

# ============================================================
# Tunnel 模式（v1.7.0：Secure MCP Tunnel，Windows 推荐）
# 用户不再手写 guard JSON / 手工起三进程 / 手配 profile——
# setup 生成 secrets + guard config + tunnel-client profile + 一键 launcher。
# ============================================================
if ($Transport -eq 'Tunnel') {
    # --- DryRun：零变更（不写 secrets、不创建 profile、不安装依赖、不启动进程）---
    if ($DryRun) {
        Write-Host '[dry-run] Secure MCP Tunnel 将生成：'
        Write-Host "  $TunnelEnvFile （Runtime API Key + upstream token，ACL 收紧 + gitignored；值绝不回显）"
        Write-Host "  $TunnelGuardConf （auth_mode=tunnel，无密钥）"
        Write-Host "  $TunnelProfileDir\<profile>.yaml （tunnel-client profile，官方 CLI 生成）"
        Write-Host "  $TunnelLauncher （启动器：upstream → guard → doctor → run，ACL 收紧）"
        Write-Host '  依赖安装：coding-tools-mcp==0.3.0 + guard venv（mcp==2.0.0 + pyjwt==2.13.0）'
        Write-Host "  tunnel-client: $TunnelClientPath"
        Write-Host '  MCP target: http://127.0.0.1:8766/mcp （guard；绝不直连 8765 upstream）'
        Write-Host "  profile name: cqs-$(Get-TunnelIdShort $TunnelId)"
        Write-Host "  health port: $HealthPort"
        Write-Host "  launcher name: $TunnelLauncher"
        return
    }

    # --- 前置校验（fail-fast）---
    if (-not (Test-Path $Workspace)) { throw "工作区不存在: $Workspace" }
    if (-not (Test-TunnelIdFormat $TunnelId)) {
        throw "TunnelId 格式不正确: '$TunnelId'（官方格式: tunnel_<32 lowercase letters or digits>；在 OpenAI Platform Tunnels 页面复制）"
    }
    if (-not $TunnelClientPath) {
        $discovered = Get-Command 'tunnel-client' -ErrorAction SilentlyContinue
        if ($discovered) { $TunnelClientPath = $discovered.Source } else {
            throw '缺少 -TunnelClientPath：请从 OpenAI Tunnels 页面下载 tunnel-client 并传路径'
        }
    }
    if (-not (Test-Path $TunnelClientPath)) { throw "tunnel-client 不存在: $TunnelClientPath" }
    try {
        & $TunnelClientPath --version | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "tunnel-client --version 退出码 $LASTEXITCODE" }
    } catch { throw "tunnel-client 不可运行: $TunnelClientPath（$($_.Exception.Message)）" }

    # --- Runtime API Key（禁止命令行 secret：优先 env，否则 Read-Host -AsSecureString，绝不回显/进 argv）---
    if ($env:CONTROL_PLANE_API_KEY) {
        $runtimeApiKey = $env:CONTROL_PLANE_API_KEY
        Write-Host '使用当前进程已有的 CONTROL_PLANE_API_KEY（未回显）。'
    } else {
        $secure = Read-Host '请输入 Runtime API Key（OpenAI Platform → API keys；输入不回显）' -AsSecureString
        if (-not $secure -or $secure.Length -eq 0) { throw 'Runtime API Key 未输入' }
        $runtimeApiKey = ConvertTo-PlainString $secure
    }

    # --- 依赖（复用 Ngrok 路径的版本 pin）---
    $uv = Get-Command 'uv' -ErrorAction SilentlyContinue
    if (-not $uv) { throw '缺少 uv：https://docs.astral.sh/uv/ 安装后重跑' }
    & uv tool install 'coding-tools-mcp==0.3.0' | Out-Null
    $mcpExe = "$env:USERPROFILE\.local\bin\coding-tools-mcp.exe"
    if (-not (Test-Path $mcpExe)) { $mcpExe = (Get-Command 'coding-tools-mcp' -ErrorAction SilentlyContinue).Source }
    if (-not $mcpExe) { throw 'coding-tools-mcp 安装失败' }

    # --- guard venv（用户侧部署路径：setup 自建）---
    $GuardVenv = Join-Path $BridgeDir 'guard\.venv'
    if (-not (Test-Path $GuardVenv)) {
        & uv venv --python 3.11 $GuardVenv | Out-Null
    }
    & uv pip install --python (Join-Path $GuardVenv 'Scripts\python.exe') -r (Join-Path $BridgeDir 'guard\requirements.txt') | Out-Null
    $GuardPy = Join-Path $GuardVenv 'Scripts\python.exe'

    # --- secrets（gitignored + ACL 收紧；含 CONTROL_PLANE_API_KEY + CQS_UPSTREAM_TOKEN）---
    # 幂等：重跑 setup 生成新 token 并覆盖写（原子生成 + ACL 重新收紧），不无限追加
    $upTok = New-Token
    $secretsContent = New-TunnelSecretsContent -UpstreamToken $upTok -RuntimeApiKey $runtimeApiKey
    Write-Utf8NoBom $TunnelEnvFile $secretsContent
    Tighten-Acl $TunnelEnvFile

    # --- guard config（无密钥；auth_mode=tunnel；host 固定 127.0.0.1）---
    Write-Utf8NoBom $TunnelGuardConf (New-TunnelGuardConfigJson -Workspace $Workspace -GuardPort $GuardPort -UpstreamPort $UpstreamPort -Allowlist $Allowlist)

    # --- tunnel-client profile（官方 CLI 生成；--force 幂等；MCP target 恒为 8766 guard）---
    if (-not (Test-Path $TunnelProfileDir)) { New-Item -ItemType Directory -Force $TunnelProfileDir | Out-Null }
    Tighten-Acl $TunnelProfileDir '(R,W)'
    $profileName = "cqs-$(Get-TunnelIdShort $TunnelId)"
    & $TunnelClientPath init --profile-dir $TunnelProfileDir --profile $profileName `
        --sample sample_mcp_remote_no_auth `
        --mcp-server-url "http://127.0.0.1:$GuardPort/mcp" `
        --tunnel-id $TunnelId `
        --health-listen-addr "127.0.0.1:$HealthPort" `
        --force | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'tunnel-client init 失败' }

    # --- launcher（全 ASCII；无 secret 字面量；loopback + readiness + doctor + run foreground）---
    $batContent = New-TunnelLauncherBat `
        -SecretsFile $TunnelEnvFile -McpExe $mcpExe -Workspace $Workspace `
        -GuardPy $GuardPy -GuardScript (Join-Path $BridgeDir 'guard\guard.py') -GuardConf $TunnelGuardConf `
        -TunnelClient $TunnelClientPath -ProfileDir $TunnelProfileDir -ProfileName $profileName `
        -UpstreamPort $UpstreamPort -GuardPort $GuardPort
    [System.IO.File]::WriteAllText($TunnelLauncher, $batContent, (New-Object System.Text.ASCIIEncoding))
    Tighten-Acl $TunnelLauncher '(RX,W)'

    Write-Host ''
    Write-Host '======== Secure MCP Tunnel 部署完成（人工 2 分钟）========'
    Write-Host '1. OpenAI Platform 创建 Tunnel 并下载 tunnel-client（已由你提供）'
    Write-Host '2. ChatGPT → 设置 → 连接器 → 新建：Connection = Tunnel，选择对应 Tunnel'
    Write-Host '3. 双击 start-bridge-tunnel.local.bat（upstream → guard → doctor → tunnel 前台运行）'
    Write-Host '4. 新对话冒烟：server_info → read README → write_next_step 落盘 .codex/next-step.md'
    Write-Host '日常使用：双击 start-bridge-tunnel.local.bat；不开发时关闭（关闭窗口即断开隧道）'
    Write-Host -Object ('Runtime API Key 已安全落盘 ' + $TunnelEnvFile + '（gitignored + ACL 收紧），不会再次询问')
    return
}

if ($Domain -match '^https?://') { $Domain = ($Domain -replace '^https?://', '') }
$Domain = $Domain.TrimEnd('/')

if ($DryRun) {
    Write-Host '[dry-run] 将生成：'
    Write-Host "  $EnvFile （OAuth 密码 + 上游 token，ACL 收紧）"
    Write-Host "  $GuardConf （无密钥）"
    Write-Host "  $StateDir （状态目录，ACL 收紧：仅当前用户可读写）"
    Write-Host "  $OAuthState （运行时生成：token_secret + 客户端注册表，重启免疫）"
    Write-Host "  $Launcher （启动器，ACL 收紧）"
    Write-Host '  依赖安装：coding-tools-mcp==0.3.0 + guard venv（mcp==2.0.0 + pyjwt==2.13.0）'
    return
}

if (-not (Test-Path $Workspace)) { throw "工作区不存在: $Workspace" }
if ($OAuthPassword -and $OAuthPassword -notmatch '^[A-Za-z0-9]+$') {
    throw 'OAuthPassword 仅支持字母数字（启动器 .bat 解析限制；留空则自动生成随机密码）'
}

# 1) 预检 + 依赖（版本 pin 见 COMPATIBILITY.md）
$uv = Get-Command 'uv' -ErrorAction SilentlyContinue
if (-not $uv) { throw '缺少 uv：https://docs.astral.sh/uv/ 安装后重跑' }
$ngrok = Get-Command 'ngrok' -ErrorAction SilentlyContinue
if (-not $ngrok) {
    $wingetDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $found = Get-ChildItem -Path $wingetDir -Recurse -Filter 'ngrok.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*Ngrok.Ngrok*' } | Select-Object -First 1
    if (-not $found) { throw '缺少 ngrok（pin 3.39.11，见 COMPATIBILITY.md）' }
    $ngrokExe = $found.FullName
} else { $ngrokExe = $ngrok.Source }
& uv tool install 'coding-tools-mcp==0.3.0' | Out-Null
$mcpExe = "$env:USERPROFILE\.local\bin\coding-tools-mcp.exe"
if (-not (Test-Path $mcpExe)) { $mcpExe = (Get-Command 'coding-tools-mcp' -ErrorAction SilentlyContinue).Source }
if (-not $mcpExe) { throw 'coding-tools-mcp 安装失败' }

# 2) guard venv（用户侧部署路径：setup 自建，不依赖开发期 .venv-guard）
# 每次都同步依赖（幂等）：requirements 升级后重跑 setup 即生效（如 pyjwt 为新增依赖）
$GuardVenv = Join-Path $BridgeDir 'guard\.venv'
if (-not (Test-Path $GuardVenv)) {
    & uv venv --python 3.11 $GuardVenv | Out-Null
}
& uv pip install --python (Join-Path $GuardVenv 'Scripts\python.exe') -r (Join-Path $BridgeDir 'guard\requirements.txt') | Out-Null
$GuardPy = Join-Path $GuardVenv 'Scripts\python.exe'

# 3) 密钥（只写 .local.env，ACL 收紧）
$upTok = New-Token
if (-not $OAuthPassword) { $OAuthPassword = New-Password }
# env 文件必须纯 ASCII：非 ASCII 字节会破坏 cmd for /f 在 GBK 系统的文件读取（2026-08-17 实测 em-dash 注释导致变量全部加载失败）
Write-Utf8NoBom $EnvFile "# codex-quota-saver bridge secrets (gitignored, ACL-restricted) - DO NOT COMMIT`r`nCQS_OAUTH_PASSWORD=$OAuthPassword`r`nCQS_UPSTREAM_TOKEN=$upTok`r`n"
Tighten-Acl $EnvFile

# 4) guard 配置（无密钥；密码/token 经环境变量注入）
# OAuth state 目录先建并收紧 ACL——运行时生成的状态文件自动继承「仅当前用户」权限
# （Windows 下 os.chmod 对 ACL 无效，必须由这里处理；旧路径 oauth_state.json 自动迁移，授权不失效）
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force $StateDir | Out-Null }
Tighten-Acl $StateDir '(R,W)'
if ((Test-Path $LegacyOAuthState) -and -not (Test-Path $OAuthState)) {
    Move-Item $LegacyOAuthState $OAuthState -Force
    Tighten-Acl $OAuthState '(R,W)'
    Write-Host '已迁移旧 OAuth 状态到 guard\state\（授权依然有效，无需重新授权）。'
}
$guardJson = @{
    host = '127.0.0.1'; port = $GuardPort
    workspace = $Workspace.Replace('\', '/')
    upstream_url = "http://127.0.0.1:$UpstreamPort/mcp"
    public_url = "https://$Domain"
    upstream_token_env = 'CQS_UPSTREAM_TOKEN'
    oauth_password_env = 'CQS_OAUTH_PASSWORD'
    oauth_state_file = 'state/oauth_state.json'
    allowlist = $Allowlist
} | ConvertTo-Json -Depth 4
Write-Utf8NoBom $GuardConf $guardJson
if (Test-Path $OAuthState) {
    Write-Host '检测到已有 OAuth 状态（token_secret + 客户端注册表），保留不重置——重启/重跑 setup 后授权依然有效。'
} else {
    Write-Host 'OAuth 状态文件将在首次启动时自动生成（token_secret + 客户端注册表落盘 = 重启免疫）。'
}

# 5) 启动器（.bat 全 ASCII——非 ASCII 会被 GBK 解析乱码）
# 注意：PS 变量不区分大小写——内容变量绝不能叫 $launcher（会覆盖路径变量 $Launcher）
$guardPyWin = $GuardPy.Replace('\', '\')
$guardScriptWin = (Join-Path $BridgeDir 'guard\guard.py').Replace('\', '\')
$guardConfWin = $GuardConf.Replace('\', '\')
# 上游不开 OAuth、不对外（认证全在 guard 层）；token 经 CODING_TOOLS_MCP_AUTH_TOKEN 环境变量传递（0.3.0 官方支持，不进 argv）
$batContent = "@echo off`r`n" +
    "REM codex-quota-saver bridge launcher (generated, gitignored)`r`n" +
    "netstat -ano | findstr `":$GuardPort `" | findstr LISTENING >nul 2>&1`r`n" +
    "if not errorlevel 1 (`r`n" +
    "  echo Bridge is already running - port $GuardPort in use. Do NOT start it twice.`r`n" +
    "  echo To restart: close all three windows first, then run this file again.`r`n" +
    "  pause`r`n" +
    "  exit /b 1`r`n" +
    ")`r`n" +
    "for /f `"usebackq eol=# tokens=1,* delims==`" %%a in (`"$EnvFile`") do set `"%%a=%%b`"`r`n" +
    "set `"CODING_TOOLS_MCP_AUTH_TOKEN=%CQS_UPSTREAM_TOKEN%`"`r`n" +
    "REM upstream reads CODING_TOOLS_MCP_AUTH_TOKEN env var (0.3.0 official support) - token never enters argv`r`n" +
    "REM NOTE: start needs a non-empty title; an empty title swallows commands with quoted args`r`n" +
    "start `"upstream`" /min `"$mcpExe`" --workspace `"$Workspace`" --host 127.0.0.1 --port $UpstreamPort`r`n" +
    "start `"guard`" /min `"$guardPyWin`" `"$guardScriptWin`" --config `"$guardConfWin`"`r`n" +
    "REM warmup: ngrok free interstitial needs one manual browser click (persistent cookie); auto-open login page 15s after start`r`n" +
    "start `"`" powershell -NoProfile -WindowStyle Hidden -Command `"Start-Sleep -Seconds 15; Start-Process 'https://$Domain/auth/login'`"`r`n" +
    "`"$ngrokExe`" http --url=$Domain $GuardPort`r`n" +
    "pause`r`n"
[System.IO.File]::WriteAllText($Launcher, $batContent, (New-Object System.Text.ASCIIEncoding))
Tighten-Acl $Launcher '(RX,W)'   # launcher 需执行权限（双击 .bat）；secrets 保持默认 (R,W)

Write-Host ''
Write-Host '======== 部署完成（人工 2 分钟）========'
Write-Host "1. 双击 start-bridge.local.bat 启动桥（上游 + guard + ngrok 三进程）"
Write-Host '2. ChatGPT -> 设置 -> 连接器 -> 新建：URL = https://<域名>/mcp ，认证方式 = OAuth'
Write-Host '3. 连接器发起授权时，浏览器打开的密码页输入 OAuth 密码：'
Write-Host "   OAuth 密码 = $OAuthPassword （也在 $EnvFile 的 CQS_OAUTH_PASSWORD 行，建议存密码管理器）"
Write-Host '4. 新对话冒烟：读仓库提建议 + write_next_step 落盘 .codex/next-step.md'
Write-Host '日常使用：双击 start-bridge.local.bat；不开发时关闭（隧道=项目后门）'
Write-Host '重启免疫：注册表+签名密钥已落盘，重启桥授权依然有效；只有删除 guard\state\oauth_state.json 才需重新授权'
