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
function Get-UniqueBackupPath([string]$Dest) {
    # 备份名唯一化：同秒多次安装不覆盖既有备份（origin 只有第一份，Rule E）
    $base = "$Dest.bak-$(Get-Timestamp)"
    if (-not (Test-Path $base)) { return $base }
    $i = 1
    while (Test-Path "$base-$i") { $i++ }
    return "$base-$i"
}
function Test-FailAfter([int]$Step) {
    # 测试专用失败注入钩子（默认关闭）：CQS_TEST_FAIL_AFTER=<step> 时在第 N 步后抛错
    if ($env:CQS_TEST_FAIL_AFTER -and ([int]$env:CQS_TEST_FAIL_AFTER) -eq $Step) {
        throw "injected failure (CQS_TEST_FAIL_AFTER=$Step)"
    }
}

function Read-Manifest([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    # -Raw 单字符串入 ConvertFrom-Json；返回数组由 PowerShell 自然展开，调用方统一 @() 包裹
    return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-Manifest([string]$Path, [array]$Entries) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    # 原子提交：先写临时文件再替换——中途崩溃不会留下半本 manifest
    $tmp = "$Path.tmp"
    ($Entries | ConvertTo-Json -Depth 4) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

# 生命周期幂等（Persistent Provenance Ledger）：provenance 只增不减——
# 本轮 observation 与旧条目按 OR/沿用规则合并进返回值，绝不降级（Rule A/B/C/E）。
function Merge-ManifestEntry($Prev, $New) {
    if ($null -eq $Prev) { return $New }
    if ($Prev.created_by_cqs -or $New.created_by_cqs) { $New.created_by_cqs = $true }
    if ($Prev.modified_by_cqs -or $New.modified_by_cqs) { $New.modified_by_cqs = $true }
    # 本轮未产生新值 → 沿用旧值：backup 身份只有第一份（origin），hash 只记 CQS 最近一次落盘内容
    if (-not $New.backup -and $Prev.backup) { $New.backup = $Prev.backup }
    if (-not $New.installed_hash -and $Prev.installed_hash) { $New.installed_hash = $Prev.installed_hash }
    if (-not $New.managed_block_id -and $Prev.managed_block_id) { $New.managed_block_id = $Prev.managed_block_id }
    return $New
}

# 追加带标记的托管块；幂等：已有该块则跳过。
# 所有返回条目带所有权字段（ownership/created_by_cqs/modified_by_cqs/managed_block_id）——
# 卸载据此区分「CQS 创建 / CQS 改过 / 用户原有」，绝不按 hash 猜所有权。
# -Prev 为旧 manifest 中同 dest 的条目（生命周期幂等合并，重复安装不丢 provenance）。
function Add-ManagedBlock([string]$Path, [string]$Id, [string]$Content, [bool]$DryRun, $Prev) {
    $begin = "<!-- cqs-managed-block:$Id begin -->"
    $end   = "<!-- cqs-managed-block:$Id end -->"
    $existed = Test-Path $Path
    if ($existed) {
        $raw = "$(Get-Content $Path -Raw -Encoding UTF8)"
        if ($raw.Contains($begin)) {
            return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='block-present';managed_block_id=$Id;ownership='user';created_by_cqs=$false;modified_by_cqs=$true})
        }
    }
    $block = "`n$begin`n$Content`n$end`n"
    if ($DryRun) { return @{action='append';dest=$Path;dry=$true} }
    $backup = $null
    $backupCreatedThisRun = $false
    if ($existed) {
        if ($null -ne $Prev -and $Prev.backup) { $backup = $Prev.backup }
        else { $backup = Get-UniqueBackupPath $Path; Copy-Item $Path $backup -Force; $backupCreatedThisRun = $true }
    }
    Add-Content -Path $Path -Value $block -Encoding UTF8
    $ownership = 'cqs'; $modified = $false
    if ($existed) { $ownership = 'user'; $modified = $true }
    return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$backup;managed_block_id=$Id;ownership=$ownership;created_by_cqs=(-not $existed);modified_by_cqs=$modified;created_this_run=(-not $existed);backup_created_this_run=$backupCreatedThisRun})
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

# ---- [agents] 窄 key 级语义 reconciliation（NARROW：只 CQS 关注的 4 个 key；不是 TOML merger）----
# 四态：missing→ADD / 相同→ADOPT / 更严但满足不变量→ADOPT_STRICTER / 破坏不变量→CONFLICT。
# 期望值运行时读自 global/config-agents.toml（source of truth）；语义规则（类型 + 更严判定）
# 是显式代码。冲突 = fail-fast（preflight 在任何 mutation 前终止）；绝不静默覆盖用户值；
# 文本补丁只在现有表头后插 markers+缺失 keys，绝不整文件序列化。
function Get-AgentsDesiredState {
    $toml = Get-Content (Join-Path $RepoRoot 'global\config-agents.toml') -Raw -Encoding UTF8
    $found = @{}
    $inAgents = $false
    foreach ($line in ($toml -split "`r?`n")) {
        if ($line -match '^\s*\[agents\]\s*(#.*)?$') { $inAgents = $true; continue }
        if ($inAgents) {
            if ($line -match '^\s*\[') { break }
            if ($line -match '^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+?)\s*(?:#.*)?$') {
                $found[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    $policy = [ordered]@{
        'enabled'                            = 'bool'
        'default_subagent_model'             = 'string'
        'default_subagent_reasoning_effort'  = 'string'
        'max_concurrent_threads_per_session' = 'int'
    }
    $desired = [ordered]@{}
    foreach ($k in $policy.Keys) {
        if (-not $found.ContainsKey($k)) { throw "global/config-agents.toml 缺少期望 key [$k]（source of truth 损坏）" }
        $desired[$k] = @{ raw = $found[$k]; type = $policy[$k] }
    }
    return $desired
}

function Get-AgentsReconcilePlan([string]$Raw, [hashtable]$Desired) {
    # 返回: table_exists / header_index / states(key→add|adopt|adopt_stricter|conflict) /
    #       current(key→原始值) / writer_supported（span 内出现无法可靠解析的行 = false）
    $plan = @{ table_exists = $false; header_index = -1; states = @{}; current = @{}; writer_supported = $true }
    $lines = $raw -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[agents\]\s*(#.*)?$') {
            $plan.table_exists = $true
            $plan.header_index = $i
            $spanEnd = $lines.Count
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match '^\s*\[') { $spanEnd = $j; break }
            }
            for ($j = $i + 1; $j -lt $spanEnd; $j++) {
                $ln = $lines[$j]
                if ($ln -match '^\s*(#.*)?$') { continue }
                if ($ln -match '^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+?)\s*(?:#.*)?$') {
                    $plan.current[$Matches[1]] = $Matches[2].Trim()
                } else {
                    $plan.writer_supported = $false   # 多行值等无法可靠定位 → fail-safe 人工
                }
            }
            break
        }
    }
    foreach ($k in $Desired.Keys) {
        $d = $Desired[$k]
        if (-not $plan.current.ContainsKey($k)) { $plan.states[$k] = 'add'; continue }
        $cur = $plan.current[$k]
        switch ($d.type) {
            'bool' { if ($cur -notin @('true','false')) { $plan.writer_supported = $false } }
            'int'  { if ($cur -notmatch '^\d+$') { $plan.writer_supported = $false } }
        }
        if (-not $plan.writer_supported) { $plan.states[$k] = 'conflict'; continue }
        $curNorm = $cur.Trim('"')
        if ($d.type -eq 'int') {
            $desiredInt = [int]$d.raw
            $curInt = [int]$cur
            if ($curInt -eq $desiredInt) { $plan.states[$k] = 'adopt' }
            elseif ($curInt -lt $desiredInt) { $plan.states[$k] = 'adopt_stricter' }
            else { $plan.states[$k] = 'conflict' }
        } else {
            if ($curNorm -eq $d.raw.Trim('"')) { $plan.states[$k] = 'adopt' }
            else { $plan.states[$k] = 'conflict' }
        }
    }
    return $plan
}

function Get-AgentsKeyImpact([string]$Key) {
    switch ($Key) {
        'enabled' { return 'CQS 依赖多代理协作（Luna worker 子代理），enabled=false 会让 [agents] 失效' }
        'default_subagent_model' { return 'CQS 无法保证 Luna 默认子代理路由（期望 gpt-5.6-luna）' }
        'default_subagent_reasoning_effort' { return 'CQS 交接质量依赖 max 推理档' }
        'max_concurrent_threads_per_session' { return '超过 CQS 配额上限 6，破坏额度节省不变量' }
        default { return 'CQS 配置契约冲突' }
    }
}

function Write-AgentsConflictReport($Plan, [hashtable]$Desired) {
    foreach ($k in $Desired.Keys) {
        if ($Plan.states[$k] -eq 'conflict') {
            Write-Host "  [agents].$k"
            Write-Host "    当前值: $($Plan.current[$k])"
            Write-Host "    CQS 期望: $($Desired[$k].raw)"
            Write-Host "    影响: $(Get-AgentsKeyImpact $k)"
        }
    }
}

function New-AgentsManagedBlock([hashtable]$Desired) {
    return @"

# --- codex-quota-saver managed [agents] begin ---
[agents]
enabled = $($Desired['enabled'].raw)
default_subagent_model = $($Desired['default_subagent_model'].raw)
default_subagent_reasoning_effort = $($Desired['default_subagent_reasoning_effort'].raw)
max_concurrent_threads_per_session = $($Desired['max_concurrent_threads_per_session'].raw)
# --- codex-quota-saver managed [agents] end ---
"@
}

function Merge-AgentsToml([string]$Path, [bool]$DryRun, $Prev) {
    $begin = '# --- codex-quota-saver managed [agents] begin ---'
    $end   = '# --- codex-quota-saver managed [agents] end ---'
    $desired = Get-AgentsDesiredState
    $existed = Test-Path $Path
    if (-not $existed) {
        # 文件不存在：整块创建（CQS 拥有整个表）
        if ($DryRun) { return @{action='append';dest=$Path;dry=$true} }
        Add-Content -Path $Path -Value (New-AgentsManagedBlock $desired) -Encoding UTF8
        return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$null;managed_block_id='agents-toml';ownership='cqs';created_by_cqs=$true;modified_by_cqs=$false;created_this_run=$true;backup_created_this_run=$false})
    }
    $raw = "$(Get-Content $Path -Raw -Encoding UTF8)"
    $plan = Get-AgentsReconcilePlan -Raw $raw -Desired $desired
    if (-not $plan.table_exists) {
        # 文件存在但无 [agents] 表：整块 append（用户文件 → 备份 + user ownership）
        if ($DryRun) { return @{action='append';dest=$Path;dry=$true} }
        $backup = $null
        $backupCreatedThisRun = $false
        if ($null -ne $Prev -and $Prev.backup) { $backup = $Prev.backup }
        else { $backup = Get-UniqueBackupPath $Path; Copy-Item $Path $backup -Force; $backupCreatedThisRun = $true }
        Add-Content -Path $Path -Value (New-AgentsManagedBlock $desired) -Encoding UTF8
        return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$backup;managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$true;created_this_run=$false;backup_created_this_run=$backupCreatedThisRun})
    }
    $conflictKeys = @($plan.states.GetEnumerator() | Where-Object { $_.Value -eq 'conflict' })
    if ($DryRun) {
        Write-Host '[agents] reconcile 计划：'
        foreach ($k in $desired.Keys) {
            $st = $plan.states[$k]
            if ($st -eq 'add') { Write-Host "  ADD              $k = $($desired[$k].raw)" }
            elseif ($st -eq 'adopt') { Write-Host "  ADOPT            $k（已一致，不修改）" }
            elseif ($st -eq 'adopt_stricter') { Write-Host "  ADOPT_STRICTER   $k = $($plan.current[$k])（保留用户更严值）" }
            elseif ($st -eq 'conflict') { Write-Host "  CONFLICT         $k（当前 $($plan.current[$k])，CQS 期望 $($desired[$k].raw)）" }
        }
        return @{action='skip';dest=$Path;dry=$true;reason='agents-reconcile-plan'}
    }
    if (-not $plan.writer_supported) {
        Write-Host "config.toml [agents] 段含无法可靠解析的内容，跳过自动修改（fail-safe），请人工处理: $Path"
        return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='agents-manual';managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$false})
    }
    if ($conflictKeys.Count -gt 0) {
        Write-Host "config.toml [agents] 冲突（fail-fast）："
        Write-AgentsConflictReport $plan $desired
        throw "[agents] config conflict——安装终止；请调整 config.toml 后重试"
    }
    foreach ($k in $desired.Keys) {
        if ($plan.states[$k] -eq 'adopt_stricter') {
            Write-Host "已采纳用户更严值 [agents].$k = $($plan.current[$k])（满足 CQS 不变量，不覆盖）"
        }
    }
    $addKeys = @($desired.Keys | Where-Object { $plan.states[$_] -eq 'add' })
    if ($addKeys.Count -eq 0) {
        return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='agents-adopted';managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$false})
    }
    # 文本补丁：表头后插 markers + 缺失 keys（绝不整文件序列化；保留换行风格）
    $nl = "`r`n"; if (-not $raw.Contains("`r`n")) { $nl = "`n" }
    $lines = $raw -split "`r?`n"
    $newLines = New-Object System.Collections.ArrayList
    for ($i = 0; $i -le $plan.header_index; $i++) { [void]$newLines.Add($lines[$i]) }
    [void]$newLines.Add($begin)
    foreach ($k in $desired.Keys) { if ($plan.states[$k] -eq 'add') { [void]$newLines.Add("$k = $($desired[$k].raw)") } }
    [void]$newLines.Add($end)
    for ($i = $plan.header_index + 1; $i -lt $lines.Count; $i++) { [void]$newLines.Add($lines[$i]) }
    $backup = $null
    $backupCreatedThisRun = $false
    if ($null -ne $Prev -and $Prev.backup) { $backup = $Prev.backup }
    else { $backup = Get-UniqueBackupPath $Path; Copy-Item $Path $backup -Force; $backupCreatedThisRun = $true }
    Set-Content -Path $Path -Value ($newLines -join $nl) -Encoding UTF8
    return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$backup;managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$true;created_this_run=$false;backup_created_this_run=$backupCreatedThisRun})
}

function Assert-AgentsPreflight([string]$ConfigPath) {
    # 任何 filesystem mutation 之前：config.toml [agents] 冲突/无法解析 → fail-fast 终止
    if (-not (Test-Path $ConfigPath)) { return }
    $desired = Get-AgentsDesiredState
    $plan = Get-AgentsReconcilePlan -Raw "$(Get-Content $ConfigPath -Raw -Encoding UTF8)" -Desired $desired
    if (-not $plan.table_exists) { return }
    $conflictKeys = @($plan.states.GetEnumerator() | Where-Object { $_.Value -eq 'conflict' })
    if (-not $plan.writer_supported -or $conflictKeys.Count -gt 0) {
        Write-Host "config.toml [agents] 冲突（fail-fast，任何修改前终止）："
        Write-AgentsConflictReport $plan $desired
        throw "[agents] config conflict——安装已在任何修改前终止；请调整 config.toml 后重试"
    }
}

# 复制文件；目标存在时：SkipIfExists 绝不覆盖；OverwriteIfChanged 内容相同则跳过。
# 返回条目带所有权字段；installed_hash 只用于「CQS 创建/改过」条目的卸载判定，
# skip（用户原有）条目绝不携带哈希——卸载阶段没有「hash 没变就可删」的路径。
# -Prev 为旧 manifest 中同 dest 的条目；用户安装后改过（hash 与旧 installed_hash 不一致）
# 时绝不再次覆盖（Case E / Rule D fail-safe）。
function Install-File([string]$Src, [string]$Dest, [bool]$SkipIfExists, [bool]$OverwriteIfChanged, [bool]$DryRun, $Prev) {
    $existed = Test-Path $Dest
    if ($existed -and $null -ne $Prev -and $Prev.installed_hash) {
        if ((Get-Sha256 $Dest) -ne $Prev.installed_hash) {
            Write-Host "用户安装后修改过，保留不覆盖: $Dest"
            $entry = @{action='skip';dest=$Dest;reason='user-modified';ownership=$Prev.ownership;created_by_cqs=[bool]$Prev.created_by_cqs;modified_by_cqs=[bool]$Prev.modified_by_cqs;installed_hash=$Prev.installed_hash;src=$Src}
            if ($Prev.backup) { $entry.backup = $Prev.backup }
            return $entry
        }
    }
    if ($existed) {
        if ($SkipIfExists) {
            return (Merge-ManifestEntry $Prev @{action='skip';dest=$Dest;reason='exists';ownership='user';created_by_cqs=$false;modified_by_cqs=$false})
        }
        if ($OverwriteIfChanged -and (Get-Sha256 $Src) -eq (Get-Sha256 $Dest)) {
            return (Merge-ManifestEntry $Prev @{action='skip';dest=$Dest;reason='identical';ownership='user';created_by_cqs=$false;modified_by_cqs=$false})
        }
    }
    if ($DryRun) { return @{action='copy';dest=$Dest;dry=$true} }
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $backup = $null
    $backupCreatedThisRun = $false
    if ($existed -and -not ($null -ne $Prev -and $Prev.backup)) {
        # origin 备份只有第一份：旧条目已有备份则绝不新建、绝不覆盖（Rule E）
        $backup = Get-UniqueBackupPath $Dest
        Copy-Item $Dest $backup -Force
        $backupCreatedThisRun = $true
    }
    Copy-Item $Src $Dest -Force
    $ownership = 'cqs'; $created = $true; $modified = $false
    if ($existed) { $ownership = 'user'; $created = $false; $modified = $true }
    return (Merge-ManifestEntry $Prev @{action='copy';dest=$Dest;src=$Src;ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified;backup=$backup;installed_hash=(Get-Sha256 $Dest);created_this_run=(-not $existed);backup_created_this_run=$backupCreatedThisRun})
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
    # preflight（任何 filesystem mutation 之前）：config.toml [agents] 冲突 → fail-fast
    if (-not $DryRun) { Assert-AgentsPreflight (Join-Path $CodexHome 'config.toml') }
    # 全新环境：先确保 CODEX_HOME 目录存在（dry-run 不落任何文件）
    if (-not $DryRun) {
        if (-not (Test-Path $CodexHome)) { New-Item -ItemType Directory -Force $CodexHome | Out-Null }
        if (-not (Test-Path (Join-Path $CodexHome 'agents'))) { New-Item -ItemType Directory -Force (Join-Path $CodexHome 'agents') | Out-Null }
    }
    # 生命周期幂等：先读旧 manifest（persistent provenance ledger），本轮 observation 与之合并
    $manifestPath = Get-ManifestPath $CodexHome
    $prevByDest = @{}
    if (-not $DryRun) {
        foreach ($e in @(Read-Manifest -Path $manifestPath)) {
            if ($e.dest) { $prevByDest[[string]$e.dest] = $e }
        }
    }
    $globalAgents = Join-Path $CodexHome 'AGENTS.md'
    $codexConfig  = Join-Path $CodexHome 'config.toml'
    $workerDest   = Join-Path $CodexHome 'agents\luna-worker.toml'
    $projectDot   = Join-Path $ProjectPath '.codex'

    $Staged = New-Object System.Collections.ArrayList
    try {
        # 1) 全局 AGENTS：子代理硬规则（托管块）
        $Staged.Add((Add-ManagedBlock -Path $globalAgents -Id 'global-agents' -Content (Get-Content "$RepoRoot\global\AGENTS.md" -Raw -Encoding UTF8) -DryRun:$DryRun -Prev $prevByDest[$globalAgents])) | Out-Null
        Test-FailAfter 1
        # 2) 全局 config.toml：[agents] 段
        $Staged.Add((Merge-AgentsToml -Path $codexConfig -DryRun:$DryRun -Prev $prevByDest[$codexConfig])) | Out-Null
        Test-FailAfter 2
        # 3) 全局 luna-worker 定义
        $Staged.Add((Install-File -Src "$RepoRoot\global\agents\luna-worker.toml" -Dest $workerDest -SkipIfExists $false -OverwriteIfChanged $true -DryRun:$DryRun -Prev $prevByDest[$workerDest])) | Out-Null
        Test-FailAfter 3
        # 4) 项目级协议 → <project>/AGENTS.md（托管块合并：已存在追加、不存在创建；
        #    协议文本 source of truth = project/AGENTS.md，installer 内不复制第二份）
        $projAgents = Join-Path $ProjectPath 'AGENTS.md'
        $Staged.Add((Add-ManagedBlock -Path $projAgents -Id 'project-protocol' -Content (Get-Content "$RepoRoot\project\AGENTS.md" -Raw -Encoding UTF8) -DryRun:$DryRun -Prev $prevByDest[$projAgents])) | Out-Null
        Test-FailAfter 4
        # 5) 项目级 .codex 三件（config/next-step 已存在则跳过；skill 按内容更新）
        $dotConfig = Join-Path $projectDot 'config.toml'
        $Staged.Add((Install-File -Src "$RepoRoot\project\dot-codex\config.toml" -Dest $dotConfig -SkipIfExists $true -OverwriteIfChanged $false -DryRun:$DryRun -Prev $prevByDest[$dotConfig])) | Out-Null
        Test-FailAfter 5
        $dotNext = Join-Path $projectDot 'next-step.md'
        $Staged.Add((Install-File -Src "$RepoRoot\project\dot-codex\next-step.md" -Dest $dotNext -SkipIfExists $true -OverwriteIfChanged $false -DryRun:$DryRun -Prev $prevByDest[$dotNext])) | Out-Null
        Test-FailAfter 6
        $skillDest = Join-Path $projectDot 'skills\luna-routing\SKILL.md'
        $Staged.Add((Install-File -Src "$RepoRoot\project\dot-codex\skills\luna-routing\SKILL.md" -Dest $skillDest -SkipIfExists $false -OverwriteIfChanged $true -DryRun:$DryRun -Prev $prevByDest[$skillDest])) | Out-Null
        Test-FailAfter 7

        if ($DryRun) {
            Write-Host '[dry-run] 将执行：'
            $Staged | ForEach-Object { Write-Host "  $($_.action) -> $($_.dest) $($_.reason)" }
            return
        }
        # 提交点：剥离仅本轮回滚使用的临时字段后原子写 manifest
        foreach ($e in @($Staged)) { [void]$e.Remove('created_this_run'); [void]$e.Remove('backup_created_this_run') }
        Write-Manifest -Path $manifestPath -Entries $Staged.ToArray()
    } catch {
        # partial failure：旧 manifest 原样保留（唯一提交点 = Write-Manifest），
        # 本轮已发生的 mutation 按文件系统事实回滚；无法完全恢复的保留证据并提示人工。
        Write-Host "安装失败：$($_.Exception.Message)"
        foreach ($e in @($Staged)) {
            if ($e.action -ne 'append' -and $e.action -ne 'copy') { continue }
            if ($e.backup_created_this_run -and (Test-Path $e.backup)) {
                Copy-Item $e.backup $e.dest -Force
                Remove-Item $e.backup -Force
                Write-Host "  已回滚: $($e.dest)"
            } elseif ($e.created_this_run -and (Test-Path $e.dest)) {
                Remove-Item $e.dest -Force
                Write-Host "  已移除本轮创建: $($e.dest)"
            }
        }
        Write-Host '旧 manifest 未动；无法完全恢复的资源请人工检查。.bak 备份一律保留。'
        throw
    }
    Write-Host '安装完成。行为：备份不删除、已有项目数据绝不覆盖。详见 manifest:'
    Write-Host $manifestPath
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
