#requires -Version 5.1
# bridge/setup.ps1 —— 双进程部署：coding-tools-mcp(内部) + bridge-guard(对外)（本文件必须 UTF-8 带 BOM）
# 用法: .\bridge\setup.ps1 -Domain <ngrok域名> -Workspace <项目路径> [-DryRun]
# 认证简化：连接器用 API key = guard token；OAuth 链路整体退役。
# 安全：secrets 只落 .secrets.local.env（ACL 收紧到当前用户 + gitignore）；token 经环境变量注入，进程命令行不可见。
param(
    [Parameter(Mandatory=$true)][string]$Domain,
    [Parameter(Mandatory=$true)][string]$Workspace,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $BridgeDir '.secrets.local.env'
$GuardConf = Join-Path $BridgeDir 'guard\guard_config.json'
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
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
function Tighten-Acl([string]$Path) {
    icacls $Path /inheritance:r /grant:r "$env:USERNAME`:(R,W)" | Out-Null
}

if ($Domain -match '^https?://') { $Domain = ($Domain -replace '^https?://', '') }
$Domain = $Domain.TrimEnd('/')

if ($DryRun) {
    Write-Host '[dry-run] 将生成：'
    Write-Host "  $EnvFile （两个随机 token，ACL 收紧）"
    Write-Host "  $GuardConf （无密钥）"
    Write-Host "  $Launcher （启动器，ACL 收紧）"
    Write-Host '  依赖安装：coding-tools-mcp==0.3.0 + guard venv（mcp>=2.0）'
    return
}

if (-not (Test-Path $Workspace)) { throw "工作区不存在: $Workspace" }

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
$GuardVenv = Join-Path $BridgeDir 'guard\.venv'
if (-not (Test-Path $GuardVenv)) {
    & uv venv --python 3.11 $GuardVenv | Out-Null
    & uv pip install --python (Join-Path $GuardVenv 'Scripts\python.exe') -r (Join-Path $BridgeDir 'guard\requirements.txt') | Out-Null
}
$GuardPy = Join-Path $GuardVenv 'Scripts\python.exe'

# 3) 密钥（只写 .local.env，ACL 收紧）
$guardTok = New-Token; $upTok = New-Token
Write-Utf8NoBom $EnvFile "# codex-quota-saver bridge secrets (gitignored, ACL-restricted) — DO NOT COMMIT`r`nCQS_GUARD_TOKEN=$guardTok`r`nCQS_UPSTREAM_TOKEN=$upTok`r`n"
Tighten-Acl $EnvFile

# 4) guard 配置（无密钥；token 经环境变量注入）
$guardJson = @{
    host = '127.0.0.1'; port = $GuardPort
    workspace = $Workspace.Replace('\', '/')
    upstream_url = "http://127.0.0.1:$UpstreamPort/mcp"
    token_env = 'CQS_GUARD_TOKEN'; upstream_token_env = 'CQS_UPSTREAM_TOKEN'
    allowlist = $Allowlist
} | ConvertTo-Json -Depth 4
Write-Utf8NoBom $GuardConf $guardJson

# 5) 启动器（.bat 全 ASCII——非 ASCII 会被 GBK 解析乱码）
# 注意：PS 变量不区分大小写——内容变量绝不能叫 $launcher（会覆盖路径变量 $Launcher）
$guardPyWin = $GuardPy.Replace('\', '\')
$guardScriptWin = (Join-Path $BridgeDir 'guard\guard.py').Replace('\', '\')
$guardConfWin = $GuardConf.Replace('\', '\')
$batContent = "@echo off`r`n" +
    "REM codex-quota-saver bridge launcher (generated, gitignored)`r`n" +
    "for /f `"usebackq tokens=1,* delims==`" %%a in (`"$EnvFile`") do set %%a=%%b`r`n" +
    "REM NOTE: start needs a non-empty title; an empty title swallows commands with quoted args`r`n" +
    "start `"upstream`" /min `"$mcpExe`" --workspace `"$Workspace`" --host 127.0.0.1 --port $UpstreamPort --auth-token %CQS_UPSTREAM_TOKEN%`r`n" +
    "start `"guard`" /min `"$guardPyWin`" `"$guardScriptWin`" --config `"$guardConfWin`"`r`n" +
    "`"$ngrokExe`" http --url=$Domain $GuardPort`r`n" +
    "pause`r`n"
[System.IO.File]::WriteAllText($Launcher, $batContent, (New-Object System.Text.ASCIIEncoding))
Tighten-Acl $Launcher

Write-Host ''
Write-Host '======== 部署完成（人工 2 分钟）========'
Write-Host "1. ChatGPT -> 设置 -> 连接器 -> 新建：URL = https://$Domain/mcp ，认证方式 = API key"
Write-Host "2. API key 值 = $guardTok （也在 $EnvFile 的 CQS_GUARD_TOKEN 行）"
Write-Host '3. 新对话冒烟：读仓库提建议 + write_next_step 落盘 .codex/next-step.md'
Write-Host '日常使用：双击 start-bridge.local.bat；不开发时关闭（隧道=项目后门）'
