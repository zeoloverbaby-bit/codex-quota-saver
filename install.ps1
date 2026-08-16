# codex-three-tier-orchestration 安装脚本（Windows PowerShell 5.1+）
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [-CodexHome <dir>] [-ProjectPath <repo>]
# 行为: 备份不删除; config.toml 只追加 [agents] 段; AGENTS.md 只追加小节;
#       项目级 config.toml / next-step.md 已存在则跳过（绝不覆盖真实任务数据）。
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
  [string]$ProjectPath = ""
)

$RepoRoot = $PSScriptRoot
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ErrorActionPreference = "Stop"

Write-Host "== codex-three-tier-orchestration installer =="
Write-Host "CODEX_HOME   = $CodexHome"
$ProjDisplay = $ProjectPath
if ($ProjectPath -eq "") { $ProjDisplay = "<未指定，跳过项目级文件>" }
Write-Host "PROJECT_PATH = $ProjDisplay"
Write-Host ""

function Backup-File([string]$Path) {
  if (Test-Path $Path) {
    $Bak = "$Path.bak-$Stamp"
    Copy-Item $Path $Bak -Force
    Write-Host "[backup] $Path -> $Bak"
  }
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force $Path | Out-Null }
}

# 1. config.toml: 追加 [agents] 段（已存在则跳过）
$Cfg = Join-Path $CodexHome "config.toml"
$AgentsBlock = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "global\config-agents.toml"), $Utf8NoBom)
if (Test-Path $Cfg) {
  $Existing = [System.IO.File]::ReadAllText($Cfg, $Utf8NoBom)
  if ($Existing -match "(?m)^\s*\[agents\]") {
    Write-Host "[skip] config.toml 已有 [agents] 段"
  } else {
    Backup-File $Cfg
    [System.IO.File]::AppendAllText($Cfg, "`r`n`r`n" + $AgentsBlock, $Utf8NoBom)
    Write-Host "[append] [agents] 段 -> $Cfg"
  }
} else {
  Ensure-Dir $CodexHome
  [System.IO.File]::WriteAllText($Cfg, $AgentsBlock, $Utf8NoBom)
  Write-Host "[create] $Cfg"
}

# 2. AGENTS.md: 不存在则创建; 已存在则追加小节（不覆盖）
$Ag = Join-Path $CodexHome "AGENTS.md"
$AgContent = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "global\AGENTS.md"), $Utf8NoBom)
if (Test-Path $Ag) {
  $Existing = [System.IO.File]::ReadAllText($Ag, $Utf8NoBom)
  if ($Existing -match "子代理使用规则") {
    Write-Host "[skip] AGENTS.md 已含路由规则小节"
  } else {
    Backup-File $Ag
    $Header = "`r`n`r`n---`r`n`r`n## 以下内容由 codex-three-tier-orchestration 安装（可整体删除回滚）`r`n`r`n"
    [System.IO.File]::AppendAllText($Ag, $Header + $AgContent, $Utf8NoBom)
    Write-Host "[append] 路由规则小节 -> $Ag"
  }
} else {
  Ensure-Dir $CodexHome
  [System.IO.File]::WriteAllText($Ag, $AgContent, $Utf8NoBom)
  Write-Host "[create] $Ag"
}

# 3. luna-worker.toml: 备份 + 复制
$WorkerSrc = Join-Path $RepoRoot "global\agents\luna-worker.toml"
$WorkerDst = Join-Path $CodexHome "agents\luna-worker.toml"
Ensure-Dir (Split-Path $WorkerDst -Parent)
Backup-File $WorkerDst
Copy-Item $WorkerSrc $WorkerDst -Force
Write-Host "[install] $WorkerDst"

# 4. 项目级文件（-ProjectPath 指定时）
if ($ProjectPath -ne "") {
  $Pairs = @(
    @{ Src = "project\dot-codex\config.toml";                  Dst = ".codex\config.toml";  OverwriteIfExists = $false },
    @{ Src = "project\dot-codex\next-step.md";                 Dst = ".codex\next-step.md"; OverwriteIfExists = $false },
    @{ Src = "project\dot-codex\skills\luna-routing\SKILL.md"; Dst = ".codex\skills\luna-routing\SKILL.md"; OverwriteIfExists = $true }
  )
  foreach ($P in $Pairs) {
    $Src = Join-Path $RepoRoot $P.Src
    $Dst = Join-Path $ProjectPath $P.Dst
    if (Test-Path $Dst) {
      if ($P.OverwriteIfExists) {
        Backup-File $Dst
        Copy-Item $Src $Dst -Force
        Write-Host "[update] $Dst"
      } else {
        Write-Host "[skip] 已存在，保留你的版本: $Dst"
      }
    } else {
      Ensure-Dir (Split-Path $Dst -Parent)
      Copy-Item $Src $Dst -Force
      Write-Host "[install] $Dst"
    }
  }
} else {
  Write-Host "[skip] 未指定 -ProjectPath，跳过项目级文件（用法: .\install.ps1 -ProjectPath <你的仓库路径>）"
}

Write-Host ""
Write-Host "完成。下一步："
Write-Host "1. Codex App 设置-配置 开启 reasoning effort 档位（含 max）"
Write-Host "2. Codex 开新会话（AGENTS.md / config 改动需新会话才生效）"
Write-Host "3. 首次 spawn 子代理后核对 rollout 实际模型是否为 gpt-5.6-luna（issue #32587）"
