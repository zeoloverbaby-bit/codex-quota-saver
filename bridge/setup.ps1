#requires -Version 5.1
# bridge/setup.ps1 —— 双进程部署：coding-tools-mcp(内部) + bridge-guard(对外)（本文件必须 UTF-8 带 BOM）
# 用法: .\bridge\setup.ps1 -Domain <ngrok域名> -Workspace <项目路径> [-OAuthPassword <密码>] [-DryRun]
# 认证：guard 自建 OAuth 2.1（ChatGPT 连接器只有 OAuth/无认证/混合三种认证，API key 不可行）。
# 安全：secrets 只落 .secrets.local.env（ACL 收紧到当前用户 + gitignore）；密码/token 经环境变量注入，进程命令行不可见。
param(
    [Parameter(Mandatory=$true)][string]$Domain,
    [Parameter(Mandatory=$true)][string]$Workspace,
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword',
        'OAuth 密码：crypto RNG 生成（或用户显式传入），仅落盘 ACL 收紧的本地 secrets 文件，不经进程命令行')]
    [string]$OAuthPassword,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $BridgeDir 'acl.ps1')   # Tighten-Acl：secrets 默认 (R,W)；launcher 需 (RX,W)——双击执行缺 X 会报「无法访问」
$EnvFile = Join-Path $BridgeDir '.secrets.local.env'
$GuardConf = Join-Path $BridgeDir 'guard\guard_config.json'
$OAuthState = Join-Path $BridgeDir 'guard\oauth_state.json'
$Launcher = Join-Path $BridgeDir 'start-bridge.local.bat'
$GuardPort = 8766
$UpstreamPort = 8765

$Allowlist = @(
    'server_info','read_file','list_dir','list_files','search_text',
    'git_status','git_diff','git_log','git_show','git_blame','view_image'
)

function New-Token {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] 32
    $rng.GetBytes($buf)
    return (-join ($buf | ForEach-Object { $_.ToString('x2') }))
}
function New-Password {
    param([int]$Length = 16)
    # 59 字符字母表（去易混 0O1lI）；拒绝采样保证均匀（4*59=236 <= 255）
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $chars = New-Object System.Collections.Generic.List[char]
    while ($chars.Count -lt $Length) {
        $b = New-Object byte[] 1
        $rng.GetBytes($b)
        if ($b[0] -ge 236) { continue }
        $chars.Add($alphabet[$b[0] % 59])
    }
    return (-join $chars)
}
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

if ($Domain -match '^https?://') { $Domain = ($Domain -replace '^https?://', '') }
$Domain = $Domain.TrimEnd('/')

if ($DryRun) {
    Write-Host '[dry-run] 将生成：'
    Write-Host "  $EnvFile （OAuth 密码 + 上游 token，ACL 收紧）"
    Write-Host "  $GuardConf （无密钥）"
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
Write-Utf8NoBom $EnvFile "# codex-quota-saver bridge secrets (gitignored, ACL-restricted) — DO NOT COMMIT`r`nCQS_OAUTH_PASSWORD=$OAuthPassword`r`nCQS_UPSTREAM_TOKEN=$upTok`r`n"
Tighten-Acl $EnvFile

# 4) guard 配置（无密钥；密码/token 经环境变量注入）
$guardJson = @{
    host = '127.0.0.1'; port = $GuardPort
    workspace = $Workspace.Replace('\', '/')
    upstream_url = "http://127.0.0.1:$UpstreamPort/mcp"
    public_url = "https://$Domain"
    upstream_token_env = 'CQS_UPSTREAM_TOKEN'
    oauth_password_env = 'CQS_OAUTH_PASSWORD'
    oauth_state_file = 'oauth_state.json'
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
# 上游不开 OAuth、不对外（认证全在 guard 层）；--auth-token 仅本机静态互信
$batContent = "@echo off`r`n" +
    "REM codex-quota-saver bridge launcher (generated, gitignored)`r`n" +
    "for /f `"usebackq tokens=1,* delims==`" %%a in (`"$EnvFile`") do set %%a=%%b`r`n" +
    "REM NOTE: start needs a non-empty title; an empty title swallows commands with quoted args`r`n" +
    "start `"upstream`" /min `"$mcpExe`" --workspace `"$Workspace`" --host 127.0.0.1 --port $UpstreamPort --auth-token %CQS_UPSTREAM_TOKEN%`r`n" +
    "start `"guard`" /min `"$guardPyWin`" `"$guardScriptWin`" --config `"$guardConfWin`"`r`n" +
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
Write-Host '重启免疫：注册表+签名密钥已落盘，重启桥授权依然有效；只有删除 guard\oauth_state.json 才需重新授权'
