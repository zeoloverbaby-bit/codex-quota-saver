#requires -Version 5.1
# codex-quota-saver installer（本文件必须 UTF-8 带 BOM）
# 用法:
#   .\install.ps1 -ProjectPath D:\path\to\repo                 # 安装
#   .\install.ps1 -ProjectPath D:\path\to\repo -DryRun         # 演练
#   .\install.ps1 -Uninstall [-CodexHome <dir>]                # 按 manifest 卸载
param(
    [Parameter(Mandatory=$false)][string]$ProjectPath,
    [Parameter(Mandatory=$false)][string]$CodexHome = "$env:USERPROFILE\.codex",
    [switch]$DryRun,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot

function Get-Timestamp { Get-Date -Format 'yyyyMMdd-HHmmss' }
function Get-Sha256([string]$Path) { (Get-FileHash -Path $Path -Algorithm SHA256).Hash }
function Get-ManifestPath([string]$CodexHome) { Join-Path $CodexHome '.codex-quota-saver-manifest.json' }

function Read-Manifest([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    # -Raw 单字符串入 ConvertFrom-Json；返回数组由 PowerShell 自然展开，调用方统一 @() 包裹
    return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-Manifest([string]$Path, [array]$Entries) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    ($Entries | ConvertTo-Json -Depth 4) | Set-Content -Path $Path -Encoding UTF8
}

# 追加带标记的托管块；幂等：已有该块则跳过。
# 所有返回条目带所有权字段（ownership/created_by_cqs/modified_by_cqs/managed_block_id）——
# 卸载据此区分「CQS 创建 / CQS 改过 / 用户原有」，绝不按 hash 猜所有权。
function Add-ManagedBlock([string]$Path, [string]$Id, [string]$Content, [bool]$DryRun) {
    $begin = "<!-- cqs-managed-block:$Id begin -->"
    $end   = "<!-- cqs-managed-block:$Id end -->"
    $existed = Test-Path $Path
    if ($existed) {
        $raw = "$(Get-Content $Path -Raw -Encoding UTF8)"
        if ($raw.Contains($begin)) {
            return @{action='skip';dest=$Path;reason='block-present';managed_block_id=$Id;ownership='user';created_by_cqs=$false;modified_by_cqs=$true}
        }
    }
    $block = "`n$begin`n$Content`n$end`n"
    if ($DryRun) { return @{action='append';dest=$Path;dry=$true} }
    $backup = $null
    if ($existed) {
        $backup = "$Path.bak-$(Get-Timestamp)"
        Copy-Item $Path $backup -Force
    }
    Add-Content -Path $Path -Value $block -Encoding UTF8
    $ownership = 'cqs'; $modified = $false
    if ($existed) { $ownership = 'user'; $modified = $true }
    return @{action='append';dest=$Path;backup=$backup;managed_block_id=$Id;ownership=$ownership;created_by_cqs=(-not $existed);modified_by_cqs=$modified}
}

# 按标记精确移除托管块；无块则跳过。begin/end 可自定义（TOML 段用 # 注释标记）
function Remove-ManagedBlock([string]$Path, [string]$Id, [string]$Begin, [string]$End) {
    if (-not (Test-Path $Path)) { return @{action='skip';dest=$Path;reason='missing'} }
    $raw = "$(Get-Content $Path -Raw -Encoding UTF8)"
    if (-not $Begin) { $Begin = "<!-- cqs-managed-block:$Id begin -->" }
    if (-not $End)   { $End   = "<!-- cqs-managed-block:$Id end -->" }
    if (-not $raw.Contains($Begin)) { return @{action='skip';dest=$Path;reason='block-absent'} }
    $pattern = "(?ms)\r?\n?" + [regex]::Escape($Begin) + ".*?" + [regex]::Escape($End) + "\r?\n?"
    $new = [regex]::Replace($raw, $pattern, "`n")
    Set-Content -Path $Path -Value $new -Encoding UTF8 -NoNewline
    return @{action='remove-block';dest=$Path;id=$Id}
}

# [agents] 段追加；已有该段则完全跳过（不备份不覆盖）
function Merge-AgentsToml([string]$Path, [bool]$DryRun) {
    $block = @"

# --- codex-quota-saver managed [agents] begin ---
[agents]
enabled = true
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "max"
max_concurrent_threads_per_session = 6
# --- codex-quota-saver managed [agents] end ---
"@
    $existed = Test-Path $Path
    if ($existed) {
        $raw = "$(Get-Content $Path -Raw -Encoding UTF8)"
        if ($raw -match '(?m)^\s*\[agents\]') {
            return @{action='skip';dest=$Path;reason='agents-present';managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$true}
        }
    }
    if ($DryRun) { return @{action='append';dest=$Path;dry=$true} }
    $backup = $null
    if ($existed) {
        $backup = "$Path.bak-$(Get-Timestamp)"
        Copy-Item $Path $backup -Force
    }
    Add-Content -Path $Path -Value $block -Encoding UTF8
    $ownership = 'cqs'; $modified = $false
    if ($existed) { $ownership = 'user'; $modified = $true }
    return @{action='append';dest=$Path;backup=$backup;managed_block_id='agents-toml';ownership=$ownership;created_by_cqs=(-not $existed);modified_by_cqs=$modified}
}

# 复制文件；目标存在时：SkipIfExists 绝不覆盖；OverwriteIfChanged 内容相同则跳过。
# 返回条目带所有权字段；installed_hash 只用于「CQS 创建/改过」条目的卸载判定，
# skip（用户原有）条目绝不携带哈希——卸载阶段没有「hash 没变就可删」的路径。
function Install-File([string]$Src, [string]$Dest, [bool]$SkipIfExists, [bool]$OverwriteIfChanged, [bool]$DryRun) {
    $existed = Test-Path $Dest
    if ($existed) {
        if ($SkipIfExists) {
            return @{action='skip';dest=$Dest;reason='exists';ownership='user';created_by_cqs=$false;modified_by_cqs=$false}
        }
        if ($OverwriteIfChanged -and (Get-Sha256 $Src) -eq (Get-Sha256 $Dest)) {
            return @{action='skip';dest=$Dest;reason='identical';ownership='user';created_by_cqs=$false;modified_by_cqs=$false}
        }
    }
    if ($DryRun) { return @{action='copy';dest=$Dest;dry=$true} }
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $backup = $null
    if ($existed) {
        $backup = "$Dest.bak-$(Get-Timestamp)"
        Copy-Item $Dest $backup -Force
    }
    Copy-Item $Src $Dest -Force
    $ownership = 'cqs'; $created = $true; $modified = $false
    if ($existed) { $ownership = 'user'; $created = $false; $modified = $true }
    return @{action='copy';dest=$Dest;src=$Src;ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified;backup=$backup;installed_hash=(Get-Sha256 $Dest)}
}

function Invoke-Uninstall([string]$CodexHome) {
    $ManifestPath = Get-ManifestPath $CodexHome
    $entries = @(Read-Manifest -Path $ManifestPath)
    if ($entries.Count -eq 0) { Write-Host '无安装记录，无需卸载。'; return }
    $dirty = $false
    foreach ($e in $entries) {
        # 新格式用 managed_block_id/ownership；旧格式 append 条目用 id（块摘除是安全的，兼容处理）
        $blockId = $null
        if ($e.managed_block_id) { $blockId = [string]$e.managed_block_id }
        elseif ($e.id) { $blockId = [string]$e.id }
        $legacyCopy = (-not $e.ownership) -and (-not $blockId)
        if ($blockId) {
            # 托管块条目：只摘块，绝不触碰块外内容；CQS 创建且摘后为空才删文件
            $tBegin = $null; $tEnd = $null
            if ($blockId -eq 'agents-toml') {
                $tBegin = '# --- codex-quota-saver managed [agents] begin ---'
                $tEnd   = '# --- codex-quota-saver managed [agents] end ---'
            }
            if (Test-Path $e.dest) {
                Remove-ManagedBlock -Path $e.dest -Id $blockId -Begin $tBegin -End $tEnd | Out-Null
                $createdFlag = $e.created_by_cqs
                if ($null -eq $createdFlag -and $null -ne $e.created) { $createdFlag = $e.created }
                if ($createdFlag) {
                    $left = "$(Get-Content $e.dest -Raw -Encoding UTF8)".Trim()
                    if ([string]::IsNullOrEmpty($left)) { Remove-Item $e.dest -Force; Write-Host "已移除（安装创建）: $($e.dest)" }
                    else { Write-Host "含用户内容，保留文件（托管块已摘除）: $($e.dest)" }
                }
                else {
                    Write-Host "托管块已摘除: $($e.dest)"
                }
            }
        }
        elseif ($legacyCopy) {
            # 旧格式 copy 条目只有 sha256、无所有权证据 → 保守永不删除（fail-safe）
            if (Test-Path $e.dest) { Write-Host "旧版 manifest 条目（无所有权信息），保守跳过: $($e.dest)" }
        }
        elseif ($e.created_by_cqs) {
            # CQS 创建的文件：自安装后未改动才删；改动则保留
            if (Test-Path $e.dest) {
                if ((Get-Sha256 $e.dest) -eq $e.installed_hash) {
                    Remove-Item $e.dest -Force
                    Write-Host "已移除（安装创建，未改动）: $($e.dest)"
                } else {
                    $dirty = $true
                    Write-Host "安装后已被修改，保留文件: $($e.dest)"
                }
            }
        }
        elseif ($e.modified_by_cqs -and $e.backup) {
            # CQS 覆盖过用户原文件：未改动 → 恢复原文件并消费 backup；改动 → 保留两者提示人工
            if (Test-Path $e.dest) {
                if ((Get-Sha256 $e.dest) -eq $e.installed_hash) {
                    Copy-Item $e.backup $e.dest -Force
                    Remove-Item $e.backup -Force
                    Write-Host "已恢复原文件（备份已消费）: $($e.dest)"
                } else {
                    $dirty = $true
                    Write-Host "安装后已被修改，保留当前文件与备份，请人工处理: $($e.dest) / $($e.backup)"
                }
            }
        }
        else {
            # ownership=user 且 CQS 未修改（skip 条目）：无论 hash 如何，永不删除
            if (Test-Path $e.dest) { Write-Host "用户原有文件，跳过（不删除）: $($e.dest)" }
        }
    }
    if ($dirty) { Write-Host "部分文件已改动未处理；manifest 保留备查: $ManifestPath" }
    else { Remove-Item $ManifestPath -Force -ErrorAction SilentlyContinue; Write-Host "已清除安装记录（干净卸载）。" }
    Write-Host "卸载完成。.bak 备份文件未删除，请自行处理。"
}

function Invoke-Install([string]$ProjectPath, [string]$CodexHome, [bool]$DryRun) {
    if ([string]::IsNullOrEmpty($ProjectPath) -or -not (Test-Path $ProjectPath)) {
        throw 'ProjectPath 不存在或未提供。'
    }
    # 全新环境：先确保 CODEX_HOME 目录存在（dry-run 不落任何文件）
    if (-not $DryRun) {
        if (-not (Test-Path $CodexHome)) { New-Item -ItemType Directory -Force $CodexHome | Out-Null }
        if (-not (Test-Path (Join-Path $CodexHome 'agents'))) { New-Item -ItemType Directory -Force (Join-Path $CodexHome 'agents') | Out-Null }
    }
    $globalAgents = Join-Path $CodexHome 'AGENTS.md'
    $codexConfig  = Join-Path $CodexHome 'config.toml'
    $workerDest   = Join-Path $CodexHome 'agents\luna-worker.toml'
    $projectDot   = Join-Path $ProjectPath '.codex'

    $Staged = New-Object System.Collections.ArrayList
    # 1) 全局 AGENTS：子代理硬规则（托管块）
    $Staged.Add((Add-ManagedBlock -Path $globalAgents -Id 'global-agents' -Content (Get-Content "$RepoRoot\global\AGENTS.md" -Raw -Encoding UTF8) -DryRun:$DryRun)) | Out-Null
    # 2) 全局 config.toml：[agents] 段
    $Staged.Add((Merge-AgentsToml -Path $codexConfig -DryRun:$DryRun)) | Out-Null
    # 3) 全局 luna-worker 定义
    $Staged.Add((Install-File -Src "$RepoRoot\global\agents\luna-worker.toml" -Dest $workerDest -SkipIfExists $false -OverwriteIfChanged $true -DryRun:$DryRun)) | Out-Null
    # 4) 项目级协议 → <project>/AGENTS.md（已存在则跳过，绝不覆盖）
    $Staged.Add((Install-File -Src "$RepoRoot\project\AGENTS.md" -Dest (Join-Path $ProjectPath 'AGENTS.md') -SkipIfExists $true -OverwriteIfChanged $false -DryRun:$DryRun)) | Out-Null
    # 5) 项目级 .codex 三件（config/next-step 已存在则跳过；skill 按内容更新）
    $Staged.Add((Install-File -Src "$RepoRoot\project\dot-codex\config.toml" -Dest (Join-Path $projectDot 'config.toml') -SkipIfExists $true -OverwriteIfChanged $false -DryRun:$DryRun)) | Out-Null
    $Staged.Add((Install-File -Src "$RepoRoot\project\dot-codex\next-step.md" -Dest (Join-Path $projectDot 'next-step.md') -SkipIfExists $true -OverwriteIfChanged $false -DryRun:$DryRun)) | Out-Null
    $Staged.Add((Install-File -Src "$RepoRoot\project\dot-codex\skills\luna-routing\SKILL.md" -Dest (Join-Path $projectDot 'skills\luna-routing\SKILL.md') -SkipIfExists $false -OverwriteIfChanged $true -DryRun:$DryRun)) | Out-Null

    if ($DryRun) {
        Write-Host '[dry-run] 将执行：'
        $Staged | ForEach-Object { Write-Host "  $($_.action) -> $($_.dest) $($_.reason)" }
        return
    }
    Write-Manifest -Path (Get-ManifestPath $CodexHome) -Entries $Staged.ToArray()
    Write-Host '安装完成。行为：备份不删除、已有项目数据绝不覆盖。详见 manifest:'
    Write-Host (Get-ManifestPath $CodexHome)
}

function Invoke-Main {
    param(
        [string]$ProjectPath,
        [string]$CodexHome = "$env:USERPROFILE\.codex",
        [switch]$DryRun,
        [switch]$Uninstall
    )
    if ($Uninstall) { Invoke-Uninstall -CodexHome $CodexHome; return }
    Invoke-Install -ProjectPath $ProjectPath -CodexHome $CodexHome -DryRun:([bool]$DryRun)
}

# 点源（测试）时不要执行 main
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -ProjectPath $ProjectPath -CodexHome $CodexHome -DryRun:([bool]$DryRun) -Uninstall:([bool]$Uninstall)
}
