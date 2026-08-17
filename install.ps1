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

function Get-SourceRoot {
    # 测试 seam：CQS_TEST_SOURCE_ROOT 指向 staged source 树（S1/S2 升级场景）；默认脚本所在目录
    if ($env:CQS_TEST_SOURCE_ROOT) { return $env:CQS_TEST_SOURCE_ROOT }
    return $RepoRoot
}

function Get-Timestamp { Get-Date -Format 'yyyyMMdd-HHmmss' }
function Get-Sha256([string]$Path) { (Get-FileHash -Path $Path -Algorithm SHA256).Hash }
function Get-StringSha256([string]$S) {
    # 托管块体哈希：与 Get-ManagedBlockBody 提取口径对齐（UTF8 字节）
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($S)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash)).Replace('-', '')
}
function Get-ManagedBlockBody([string]$Raw, [string]$Begin, [string]$End) {
    # begin/end 标记行之间的块体（与写入格式 "`n<begin>`n<Content>`n<end>`n" 对齐）；未找到→$null
    $pattern = '(?ms)' + [regex]::Escape($Begin) + '\r?\n(?<body>.*?)\r?\n' + [regex]::Escape($End)
    $m = [regex]::Match($Raw, $pattern)
    if (-not $m.Success) { return $null }
    return $m.Groups['body'].Value
}
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
    # ownership 也是持久 lifecycle provenance：CQS 创建过 → 永远 cqs（Rule A，绝不降级）
    if ($New.ownership -ne 'cqs' -and $Prev.ownership -eq 'cqs') { $New.ownership = 'cqs' }
    # 本轮未产生新值 → 沿用旧值：backup 身份只有第一份（origin），hash 只记 CQS 最近一次落盘内容
    if (-not $New.backup -and $Prev.backup) { $New.backup = $Prev.backup }
    if (-not $New.installed_hash -and $Prev.installed_hash) { $New.installed_hash = $Prev.installed_hash }
    if (-not $New.managed_block_id -and $Prev.managed_block_id) { $New.managed_block_id = $Prev.managed_block_id }
    if (-not $New.installed_block_hash -and $Prev.installed_block_hash) { $New.installed_block_hash = $Prev.installed_block_hash }
    return $New
}

# 追加带标记的托管块；幂等：已有该块则跳过。
# 所有返回条目带所有权字段（ownership/created_by_cqs/modified_by_cqs/managed_block_id）——
# 卸载据此区分「CQS 创建 / CQS 改过 / 用户原有」，绝不按 hash 猜所有权。
# -Prev 为旧 manifest 中同 dest 的条目（生命周期幂等合并，重复安装不丢 provenance）。
function Add-ManagedBlock([string]$Path, [string]$Id, [string]$Content, [bool]$DryRun, $Prev) {
    $begin = "<!-- cqs-managed-block:$Id begin -->"
    $end   = "<!-- cqs-managed-block:$Id end -->"
    # 块体哈希必须与「写入后从文件提取」的字节一致：把合成块串喂给同一提取函数，
    # 避免模板行尾（LF/CRLF）造成写时哈希与重装时提取哈希不一致。
    $contentHash = Get-StringSha256 (Get-ManagedBlockBody -Raw "`n$begin`n$Content`n$end`n" -Begin $begin -End $end)
    $prevCreated = ($null -ne $Prev -and [bool]$Prev.created_by_cqs)
    $existed = Test-Path $Path
    if ($existed) {
        $raw = "$(Get-Content $Path -Raw -Encoding UTF8)"
        if ($raw.Contains($begin)) {
            # 块已存在：按 installed_block_hash 区分 幂等 skip / 用户改过（不覆盖）/ 模板升级
            $ownership = 'cqs'; $created = $true; $modified = $false
            if (-not $prevCreated) { $ownership = 'user'; $created = $false; $modified = $true }
            $prevHash = $null
            if ($null -ne $Prev -and $Prev.installed_block_hash) { $prevHash = [string]$Prev.installed_block_hash }
            if ($null -eq $prevHash) {
                Write-Host "托管块 $Id 存在但 manifest 无 installed_block_hash（旧版本安装），无法安全验证，保留不覆盖: $Path"
                return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='block-unverified';managed_block_id=$Id;ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified})
            }
            $body = Get-ManagedBlockBody -Raw $raw -Begin $begin -End $end
            if ($null -eq $body -or (Get-StringSha256 $body) -ne $prevHash) {
                Write-Host "托管块 $Id 已被用户修改，保留不覆盖（如需升级请先手动处理该块）: $Path"
                return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='block-user-modified';managed_block_id=$Id;ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified})
            }
            if ($contentHash -eq $prevHash) {
                return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='block-present';managed_block_id=$Id;ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified})
            }
            # 块体未被用户修改且模板已升级 → 替换块体（同一 txn：先快照后摘旧写新）
            if ($DryRun) { Write-Host "dry-run: 将升级托管块 ${Id}: $Path"; return @{action='skip';dest=$Path;dry=$true;reason='block-upgrade'} }
            $txnBackup = Get-UniqueBackupPath $Path; Copy-Item $Path $txnBackup -Force
            Remove-ManagedBlock -Path $Path -Id $Id -Begin $begin -End $end | Out-Null
            Add-Content -Path $Path -Value "`n$begin`n$Content`n$end`n" -Encoding UTF8
            $backup = $null
            if ($null -ne $Prev -and $Prev.backup) { $backup = $Prev.backup }
            return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$backup;managed_block_id=$Id;ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified;installed_block_hash=$contentHash;created_this_run=$false;backup_created_this_run=$false;txn_backup_this_run=$txnBackup})
        }
    }
    $block = "`n$begin`n$Content`n$end`n"
    if ($DryRun) { return @{action='append';dest=$Path;dry=$true} }
    $backup = $null
    $backupCreatedThisRun = $false
    $txnBackup = $null
    if ($existed) {
        if ($prevCreated) {
            $txnBackup = Get-UniqueBackupPath $Path; Copy-Item $Path $txnBackup -Force
        } elseif ($null -ne $Prev -and $Prev.backup) {
            $backup = $Prev.backup
            $txnBackup = Get-UniqueBackupPath $Path; Copy-Item $Path $txnBackup -Force
        } else {
            $backup = Get-UniqueBackupPath $Path; Copy-Item $Path $backup -Force; $backupCreatedThisRun = $true
        }
    }
    Add-Content -Path $Path -Value $block -Encoding UTF8
    $ownership = 'cqs'; $created = $true; $modified = $false
    if ($existed -and -not $prevCreated) { $ownership = 'user'; $created = $false; $modified = $true }
    return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$backup;managed_block_id=$Id;ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified;installed_block_hash=$contentHash;created_this_run=(-not $existed);backup_created_this_run=$backupCreatedThisRun;txn_backup_this_run=$txnBackup})
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
    $toml = Get-Content (Join-Path (Get-SourceRoot) 'global\config-agents.toml') -Raw -Encoding UTF8
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
    # 期望值自身校验（drift guard）：官方 schema minimum=1（codex-rs schemars(range(min=1)) + 运行时验证拒绝 0）
    $threadsRaw = $desired['max_concurrent_threads_per_session'].raw
    if ($threadsRaw -notmatch '^\d+$' -or [int]$threadsRaw -lt 1) {
        throw "global/config-agents.toml 期望 max_concurrent_threads_per_session 非法（必须 ≥ 1）: $threadsRaw"
    }
    return $desired
}

function Get-AgentsReconcilePlan([string]$Raw, [hashtable]$Desired, [string]$PrevInstalledBlockHash) {
    # 返回: table_exists / header_index / states(key→add|adopt|adopt_stricter|conflict|region) /
    #       current(region 外用户 key→原始值) / writer_supported / nl /
    #       markers_exist / region_hash / region_upgrade / region_unverified / region_modified / duplicates
    # CQS-owned = markers 之间的 region（installed_block_hash 判定：未改→可升级，改了→conflict）；
    # region 外同名 key = duplicate → conflict。期望 region keys = desired 中不在 region 外的 key。
    $plan = @{ table_exists = $false; header_index = -1; states = @{}; current = @{}
               writer_supported = $true; markers_exist = $false; region_hash = $null
               region_upgrade = $false; region_unverified = $false; region_modified = $false; duplicates = @() }
    $begin = '# --- codex-quota-saver managed [agents] begin ---'
    $end   = '# --- codex-quota-saver managed [agents] end ---'
    $plan.nl = "`r`n"; if (-not $Raw.Contains("`r`n")) { $plan.nl = "`n" }
    $lines = $Raw -split "`r?`n"
    # 先定位 markers：整文件形状里 [agents] 表头位于托管区内，不能当作外层表头
    $beginIdx = -1; $endIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq $begin -and $beginIdx -lt 0) { $beginIdx = $i }
        elseif ($beginIdx -ge 0 -and $lines[$i].Trim() -eq $end -and $endIdx -lt 0) { $endIdx = $i }
    }
    # begin 标记可能位于表头之前（整文件形状）→ 扫描起点之前就要记录 markers 存在
    if ($beginIdx -ge 0) { $plan.markers_exist = $true }
    # 外层表头 = 托管区外的第一个 [agents] 行；没有则回退到托管区内的表头（整文件形状）
    $headerIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[agents\]\s*(#.*)?$') {
            $insideRegion = ($beginIdx -ge 0 -and $i -gt $beginIdx -and ($endIdx -lt 0 -or $i -lt $endIdx))
            if (-not $insideRegion) { $headerIdx = $i; break }
        }
    }
    if ($headerIdx -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[agents\]\s*(#.*)?$') { $headerIdx = $i; break }
        }
    }
    if ($headerIdx -ge 0) {
        $plan.table_exists = $true
        $plan.header_index = $headerIdx
        $spanEnd = $lines.Count
        for ($j = $headerIdx + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^\s*\[') { $spanEnd = $j; break }
        }
        # 整文件形状：begin marker 在表头之前 → 扫描起点即处于托管区内
        $inside = ($beginIdx -ge 0 -and $beginIdx -lt $headerIdx)
        $regionKeys = @{}
        for ($j = $headerIdx + 1; $j -lt $spanEnd; $j++) {
            $ln = $lines[$j]
            if ($ln.Trim() -eq $begin) { $plan.markers_exist = $true; $inside = $true; continue }
            if ($inside -and $ln.Trim() -eq $end) { $inside = $false; continue }
            if ($ln -match '^\s*(#.*)?$') { continue }
            if ($ln -match '^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+?)\s*(?:#.*)?$') {
                $key = $Matches[1]
                if ($inside) {
                    if ($regionKeys.ContainsKey($key) -or $plan.current.ContainsKey($key)) {
                        if ($plan.duplicates -notcontains $key) { $plan.duplicates += $key }
                    }
                    $regionKeys[$key] = $Matches[2].Trim()
                } else {
                    if ($regionKeys.ContainsKey($key)) {
                        if ($plan.duplicates -notcontains $key) { $plan.duplicates += $key }
                    }
                    $plan.current[$key] = $Matches[2].Trim()
                }
            } else {
                if (-not $inside) { $plan.writer_supported = $false }   # 多行值等无法可靠定位 → fail-safe 人工
            }
        }
        if ($plan.markers_exist) {
            $body = Get-ManagedBlockBody -Raw $Raw -Begin $begin -End $end
            if ($null -eq $body) { $plan.writer_supported = $false } else { $plan.region_hash = Get-StringSha256 $body }
        }
    }
    foreach ($k in $Desired.Keys) {
        $d = $Desired[$k]
        if ($plan.current.ContainsKey($k)) {
            # region 外用户 key：现有四态规则
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
                elseif ($curInt -lt 1) { $plan.states[$k] = 'conflict' }   # 官方 schema minimum=1（0 是启动错误、-1 非法）
                elseif ($curInt -lt $desiredInt) { $plan.states[$k] = 'adopt_stricter' }
                else { $plan.states[$k] = 'conflict' }
            } else {
                if ($curNorm -eq $d.raw.Trim('"')) { $plan.states[$k] = 'adopt' }
                else { $plan.states[$k] = 'conflict' }
            }
        } elseif ($plan.markers_exist) {
            # key 位于 CQS region：region 未改时由 region 升级逻辑统一处理
            $plan.states[$k] = 'region'
        } else {
            $plan.states[$k] = 'add'
        }
    }
    # region 决策：markers 存在且 span 可解析时按 installed_block_hash 区分
    if ($plan.markers_exist -and $plan.writer_supported) {
        if ([string]::IsNullOrEmpty($PrevInstalledBlockHash)) {
            $plan.region_unverified = $true
        } elseif ($plan.region_hash -ne $PrevInstalledBlockHash) {
            $plan.region_modified = $true
        } else {
            $regionKeysDesired = @($Desired.Keys | Where-Object { -not $plan.current.ContainsKey($_) })
            $bodyRaw = Get-ManagedBlockBody -Raw $Raw -Begin $begin -End $end
            $whole = ($null -ne $bodyRaw -and $bodyRaw.TrimStart().StartsWith('[agents]'))
            $nl = $plan.nl
            $newHash = $null
            if ($whole) {
                $keysText = (($regionKeysDesired | ForEach-Object { "$_ = $($Desired[$_].raw)" }) -join "`n")
                $newHash = Get-StringSha256 (Get-ManagedBlockBody -Raw "`n$begin`n[agents]`n$keysText`n$end`n" -Begin $begin -End $end)
            } else {
                $regionText = (($regionKeysDesired | ForEach-Object { "$_ = $($Desired[$_].raw)" }) -join $nl)
                $newHash = Get-StringSha256 (Get-ManagedBlockBody -Raw "`n$begin$nl$regionText$nl$end`n" -Begin $begin -End $end)
            }
            if ($null -eq $newHash -or $newHash -ne $plan.region_hash) { $plan.region_upgrade = $true }
        }
    }
    return $plan
}

function Get-AgentsKeyImpact([string]$Key) {
    switch ($Key) {
        'enabled' { return 'CQS 依赖多代理协作（Luna worker 子代理），enabled=false 会让 [agents] 失效' }
        'default_subagent_model' { return 'CQS 无法保证 Luna 默认子代理路由（期望 gpt-5.6-luna）' }
        'default_subagent_reasoning_effort' { return 'CQS 交接质量依赖 max 推理档' }
        'max_concurrent_threads_per_session' { return '线程上限必须满足 1 ≤ 值 ≤ CQS 期望上限 6（官方 schema minimum=1；超出破坏额度节省不变量）' }
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
    $prevCreated = ($null -ne $Prev -and [bool]$Prev.created_by_cqs)
    $prevHash = $null
    if ($null -ne $Prev -and $Prev.installed_block_hash) { $prevHash = [string]$Prev.installed_block_hash }
    $existed = Test-Path $Path
    if (-not $existed) {
        # 文件不存在：整块创建（CQS 拥有整个表）
        if ($DryRun) { return @{action='append';dest=$Path;dry=$true} }
        $block = New-AgentsManagedBlock $desired
        Add-Content -Path $Path -Value $block -Encoding UTF8
        $regionHash = Get-StringSha256 (Get-ManagedBlockBody -Raw $block -Begin $begin -End $end)
        return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$null;managed_block_id='agents-toml';ownership='cqs';created_by_cqs=$true;modified_by_cqs=$false;installed_block_hash=$regionHash;created_this_run=$true;backup_created_this_run=$false})
    }
    $raw = "$(Get-Content $Path -Raw -Encoding UTF8)"
    $plan = Get-AgentsReconcilePlan -Raw $raw -Desired $desired -PrevInstalledBlockHash $prevHash
    if (-not $plan.table_exists) {
        # 文件存在但无 [agents] 表：整块 append（用户文件 → 备份 + user ownership）
        if ($DryRun) { return @{action='append';dest=$Path;dry=$true} }
        $backup = $null; $backupCreatedThisRun = $false; $txnBackup = $null
        if ($prevCreated) {
            $txnBackup = Get-UniqueBackupPath $Path; Copy-Item $Path $txnBackup -Force
        } elseif ($null -ne $Prev -and $Prev.backup) {
            $backup = $Prev.backup
            $txnBackup = Get-UniqueBackupPath $Path; Copy-Item $Path $txnBackup -Force
        } else {
            $backup = Get-UniqueBackupPath $Path; Copy-Item $Path $backup -Force; $backupCreatedThisRun = $true
        }
        $block = New-AgentsManagedBlock $desired
        Add-Content -Path $Path -Value $block -Encoding UTF8
        $regionHash = Get-StringSha256 (Get-ManagedBlockBody -Raw $block -Begin $begin -End $end)
        $ownership = 'cqs'; $created = $true; $modified = $false
        if (-not $prevCreated) { $ownership = 'user'; $created = $false; $modified = $true }
        return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$backup;managed_block_id='agents-toml';ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified;installed_block_hash=$regionHash;created_this_run=$false;backup_created_this_run=$backupCreatedThisRun;txn_backup_this_run=$txnBackup})
    }
    $conflictKeys = @($plan.states.GetEnumerator() | Where-Object { $_.Value -eq 'conflict' })
    if ($DryRun) {
        Write-Host '[agents] reconcile 计划：'
        foreach ($k in $desired.Keys) {
            $st = $plan.states[$k]
            if ($st -eq 'add') { Write-Host "  ADD              $k = $($desired[$k].raw)" }
            elseif ($st -eq 'adopt') { Write-Host "  ADOPT            $k（已一致，不修改）" }
            elseif ($st -eq 'adopt_stricter') { Write-Host "  ADOPT_STRICTER   $k = $($plan.current[$k])（保留用户更严值）" }
            elseif ($st -eq 'region') { Write-Host "  REGION           $k（CQS 托管键）" }
            elseif ($st -eq 'conflict') { Write-Host "  CONFLICT         $k（当前 $($plan.current[$k])，CQS 期望 $($desired[$k].raw)）" }
        }
        if ($plan.region_upgrade) { Write-Host '  UPGRADE_REGION   托管键区将升级为新期望值' }
        return @{action='skip';dest=$Path;dry=$true;reason='agents-reconcile-plan'}
    }
    if (-not $plan.writer_supported) {
        Write-Host "config.toml [agents] 段含无法可靠解析的内容，跳过自动修改（fail-safe），请人工处理: $Path"
        return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='agents-manual';managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$false})
    }
    if ($plan.duplicates.Count -gt 0) {
        Write-Host "config.toml [agents] 重复 key（region 内外同名，TOML 非法）: $($plan.duplicates -join ', ')"
        throw "[agents] duplicate key——安装已在任何修改前终止；请人工处理后重试"
    }
    if ($conflictKeys.Count -gt 0 -or $plan.region_modified) {
        Write-Host "config.toml [agents] 冲突（fail-fast）："
        if ($plan.region_modified) { Write-Host '  CQS managed [agents] 托管区已被手动修改，不覆盖（请人工处理该区域）' }
        Write-AgentsConflictReport $plan $desired
        throw "[agents] config conflict——安装终止；请调整 config.toml 后重试"
    }
    foreach ($k in $desired.Keys) {
        if ($plan.states[$k] -eq 'adopt_stricter') {
            Write-Host "已采纳用户更严值 [agents].$k = $($plan.current[$k])（满足 CQS 不变量，不覆盖）"
        }
    }
    if ($plan.region_upgrade) {
        # 托管区未修改且 desired 变了 → 摘旧 region 写新 region（同一 txn 内；backup 身份只保留 origin）
        $txnBackup = Get-UniqueBackupPath $Path; Copy-Item $Path $txnBackup -Force
        Remove-ManagedBlock -Path $Path -Id 'agents-toml' -Begin $begin -End $end | Out-Null
        $raw2 = "$(Get-Content $Path -Raw -Encoding UTF8)"
        $regionKeysDesired = @($desired.Keys | Where-Object { -not $plan.current.ContainsKey($_) })
        $backup = $null
        if ($null -ne $Prev -and $Prev.backup) { $backup = $Prev.backup }
        $ownership = 'cqs'; $created = $true; $modified = $false
        if (-not $prevCreated) { $ownership = 'user'; $created = $false; $modified = $true }
        $regionHash = $null
        if ($raw2 -match '(?m)^\s*\[agents\]\s*(#.*)?$') {
            # keys-only 形状（表头在 region 外）：表头后插 markers + 新 region keys
            $nl = $plan.nl
            $lines2 = $raw2 -split "`r?`n"
            $newLines = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $lines2.Count; $i++) {
                [void]$newLines.Add($lines2[$i])
                if ($lines2[$i] -match '^\s*\[agents\]\s*(#.*)?$') {
                    [void]$newLines.Add($begin)
                    foreach ($k in $regionKeysDesired) { [void]$newLines.Add("$k = $($desired[$k].raw)") }
                    [void]$newLines.Add($end)
                }
            }
            Set-Content -Path $Path -Value ($newLines -join $nl) -Encoding UTF8
            $regionText = (($regionKeysDesired | ForEach-Object { "$_ = $($desired[$_].raw)" }) -join $nl)
            $regionHash = Get-StringSha256 (Get-ManagedBlockBody -Raw "`n$begin$nl$regionText$nl$end`n" -Begin $begin -End $end)
        } else {
            # 整文件形状（region 内含 [agents] 表头）：整块重建（LF，与 New-AgentsManagedBlock 一致）
            $keysText = (($regionKeysDesired | ForEach-Object { "$_ = $($desired[$_].raw)" }) -join "`n")
            $block = "`n$begin`n[agents]`n$keysText`n$end`n"
            Add-Content -Path $Path -Value $block -Encoding UTF8
            $regionHash = Get-StringSha256 (Get-ManagedBlockBody -Raw $block -Begin $begin -End $end)
        }
        return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$backup;managed_block_id='agents-toml';ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified;installed_block_hash=$regionHash;created_this_run=$false;backup_created_this_run=$false;txn_backup_this_run=$txnBackup})
    }
    if ($plan.markers_exist) {
        if ($plan.region_unverified) {
            Write-Host "config.toml [agents] 托管区存在但 manifest 无 installed_block_hash（旧版本安装），无法安全验证，保留不覆盖: $Path"
            return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='agents-unverified';managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$false})
        }
        # region 未改、desired 未变 → 幂等 adopt（含 hash 沿用）
        return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='agents-adopted';managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$false})
    }
    $addKeys = @($desired.Keys | Where-Object { $plan.states[$_] -eq 'add' })
    if ($addKeys.Count -eq 0) {
        return (Merge-ManifestEntry $Prev @{action='skip';dest=$Path;reason='agents-adopted';managed_block_id='agents-toml';ownership='user';created_by_cqs=$false;modified_by_cqs=$false})
    }
    # 文本补丁：表头后插 markers + 缺失 keys（markers 不存在才走到这里；绝不整文件序列化；保留换行风格）
    $nl = $plan.nl
    $lines = $raw -split "`r?`n"
    $newLines = New-Object System.Collections.ArrayList
    for ($i = 0; $i -le $plan.header_index; $i++) { [void]$newLines.Add($lines[$i]) }
    [void]$newLines.Add($begin)
    foreach ($k in $desired.Keys) { if ($plan.states[$k] -eq 'add') { [void]$newLines.Add("$k = $($desired[$k].raw)") } }
    [void]$newLines.Add($end)
    for ($i = $plan.header_index + 1; $i -lt $lines.Count; $i++) { [void]$newLines.Add($lines[$i]) }
    $backup = $null; $backupCreatedThisRun = $false; $txnBackup = $null
    if ($prevCreated) {
        $txnBackup = Get-UniqueBackupPath $Path; Copy-Item $Path $txnBackup -Force
    } elseif ($null -ne $Prev -and $Prev.backup) {
        $backup = $Prev.backup
        $txnBackup = Get-UniqueBackupPath $Path; Copy-Item $Path $txnBackup -Force
    } else {
        $backup = Get-UniqueBackupPath $Path; Copy-Item $Path $backup -Force; $backupCreatedThisRun = $true
    }
    Set-Content -Path $Path -Value ($newLines -join $nl) -Encoding UTF8
    $regionText = (($addKeys | ForEach-Object { "$_ = $($desired[$_].raw)" }) -join $nl)
    $regionHash = Get-StringSha256 (Get-ManagedBlockBody -Raw "`n$begin$nl$regionText$nl$end`n" -Begin $begin -End $end)
    $ownership = 'cqs'; $created = $true; $modified = $false
    if (-not $prevCreated) { $ownership = 'user'; $created = $false; $modified = $true }
    return (Merge-ManifestEntry $Prev @{action='append';dest=$Path;backup=$backup;managed_block_id='agents-toml';ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified;installed_block_hash=$regionHash;created_this_run=$false;backup_created_this_run=$backupCreatedThisRun;txn_backup_this_run=$txnBackup})
}

function Assert-AgentsPreflight([string]$ConfigPath, $Prev) {
    # 任何 filesystem mutation 之前：config.toml [agents] 冲突/无法解析/托管区被改 → fail-fast 终止
    if (-not (Test-Path $ConfigPath)) { return }
    $desired = Get-AgentsDesiredState
    $prevHash = $null
    if ($null -ne $Prev -and $Prev.installed_block_hash) { $prevHash = [string]$Prev.installed_block_hash }
    $plan = Get-AgentsReconcilePlan -Raw "$(Get-Content $ConfigPath -Raw -Encoding UTF8)" -Desired $desired -PrevInstalledBlockHash $prevHash
    if (-not $plan.table_exists) { return }
    $conflictKeys = @($plan.states.GetEnumerator() | Where-Object { $_.Value -eq 'conflict' })
    if (-not $plan.writer_supported -or $conflictKeys.Count -gt 0 -or $plan.region_modified -or $plan.duplicates.Count -gt 0) {
        Write-Host "config.toml [agents] 冲突（fail-fast，任何修改前终止）："
        if ($plan.region_modified) { Write-Host '  CQS managed [agents] 托管区已被手动修改（请人工处理该区域）' }
        if ($plan.duplicates.Count -gt 0) { Write-Host "  重复 key（region 内外同名，TOML 非法）: $($plan.duplicates -join ', ')" }
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
    # 覆盖前恰好快照一次，角色由 lifecycle provenance 决定（filesystem existence 只是 observation）：
    #  - 用户文件首次被 CQS 覆盖（无 origin）→ 快照即 origin（进 manifest，卸载恢复用）
    #  - 已有 origin（升级）或 dest 是 CQS 自己创建的 → 快照是 txn（仅本轮回滚用，成功后消费，绝不进 manifest）
    $prevCreated = ($null -ne $Prev -and [bool]$Prev.created_by_cqs)
    $backup = $null
    $backupCreatedThisRun = $false
    $txnBackup = $null
    if ($existed) {
        if ($prevCreated) {
            $txnBackup = Get-UniqueBackupPath $Dest; Copy-Item $Dest $txnBackup -Force
        } elseif ($null -ne $Prev -and $Prev.backup) {
            $backup = $Prev.backup
            $txnBackup = Get-UniqueBackupPath $Dest; Copy-Item $Dest $txnBackup -Force
        } else {
            $backup = Get-UniqueBackupPath $Dest; Copy-Item $Dest $backup -Force; $backupCreatedThisRun = $true
        }
    }
    Copy-Item $Src $Dest -Force
    $ownership = 'cqs'; $created = $true; $modified = $false
    if ($existed -and -not $prevCreated) { $ownership = 'user'; $created = $false; $modified = $true }
    return (Merge-ManifestEntry $Prev @{action='copy';dest=$Dest;src=$Src;ownership=$ownership;created_by_cqs=$created;modified_by_cqs=$modified;backup=$backup;installed_hash=(Get-Sha256 $Dest);created_this_run=(-not $existed);backup_created_this_run=$backupCreatedThisRun;txn_backup_this_run=$txnBackup})
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
    # 生命周期幂等：先读旧 manifest（persistent provenance ledger），本轮 observation 与之合并；
    # preflight 需要 agents-toml 条目的 installed_block_hash（region 是否被改的判定依据）
    $manifestPath = Get-ManifestPath $CodexHome
    $prevByDest = @{}
    if (-not $DryRun) {
        foreach ($e in @(Read-Manifest -Path $manifestPath)) {
            if ($e.dest) { $prevByDest[[string]$e.dest] = $e }
        }
    }
    $globalAgents = Join-Path $CodexHome 'AGENTS.md'
    $codexConfig  = Join-Path $CodexHome 'config.toml'
    # preflight（任何 filesystem mutation 之前）：config.toml [agents] 冲突 → fail-fast
    if (-not $DryRun) { Assert-AgentsPreflight $codexConfig $prevByDest[$codexConfig] }
    # 全新环境：先确保 CODEX_HOME 目录存在（dry-run 不落任何文件）
    if (-not $DryRun) {
        if (-not (Test-Path $CodexHome)) { New-Item -ItemType Directory -Force $CodexHome | Out-Null }
        if (-not (Test-Path (Join-Path $CodexHome 'agents'))) { New-Item -ItemType Directory -Force (Join-Path $CodexHome 'agents') | Out-Null }
    }
    $workerDest   = Join-Path $CodexHome 'agents\luna-worker.toml'
    $projectDot   = Join-Path $ProjectPath '.codex'

    $Staged = New-Object System.Collections.ArrayList
    $srcRoot = Get-SourceRoot
    try {
        # 1) 全局 AGENTS：子代理硬规则（托管块）
        $Staged.Add((Add-ManagedBlock -Path $globalAgents -Id 'global-agents' -Content (Get-Content (Join-Path $srcRoot 'global\AGENTS.md') -Raw -Encoding UTF8) -DryRun:$DryRun -Prev $prevByDest[$globalAgents])) | Out-Null
        Test-FailAfter 1
        # 2) 全局 config.toml：[agents] 段
        $Staged.Add((Merge-AgentsToml -Path $codexConfig -DryRun:$DryRun -Prev $prevByDest[$codexConfig])) | Out-Null
        Test-FailAfter 2
        # 3) 全局 luna-worker 定义
        $Staged.Add((Install-File -Src (Join-Path $srcRoot 'global\agents\luna-worker.toml') -Dest $workerDest -SkipIfExists $false -OverwriteIfChanged $true -DryRun:$DryRun -Prev $prevByDest[$workerDest])) | Out-Null
        Test-FailAfter 3
        # 4) 项目级协议 → <project>/AGENTS.md（托管块合并：已存在追加、不存在创建；
        #    协议文本 source of truth = project/AGENTS.md，installer 内不复制第二份）
        $projAgents = Join-Path $ProjectPath 'AGENTS.md'
        $Staged.Add((Add-ManagedBlock -Path $projAgents -Id 'project-protocol' -Content (Get-Content (Join-Path $srcRoot 'project\AGENTS.md') -Raw -Encoding UTF8) -DryRun:$DryRun -Prev $prevByDest[$projAgents])) | Out-Null
        Test-FailAfter 4
        # 5) 项目级 .codex 三件（config/next-step 已存在则跳过；skill 按内容更新）
        $dotConfig = Join-Path $projectDot 'config.toml'
        $Staged.Add((Install-File -Src (Join-Path $srcRoot 'project\dot-codex\config.toml') -Dest $dotConfig -SkipIfExists $true -OverwriteIfChanged $false -DryRun:$DryRun -Prev $prevByDest[$dotConfig])) | Out-Null
        Test-FailAfter 5
        $dotNext = Join-Path $projectDot 'next-step.md'
        $Staged.Add((Install-File -Src (Join-Path $srcRoot 'project\dot-codex\next-step.md') -Dest $dotNext -SkipIfExists $true -OverwriteIfChanged $false -DryRun:$DryRun -Prev $prevByDest[$dotNext])) | Out-Null
        Test-FailAfter 6
        $skillDest = Join-Path $projectDot 'skills\luna-routing\SKILL.md'
        $Staged.Add((Install-File -Src (Join-Path $srcRoot 'project\dot-codex\skills\luna-routing\SKILL.md') -Dest $skillDest -SkipIfExists $false -OverwriteIfChanged $true -DryRun:$DryRun -Prev $prevByDest[$skillDest])) | Out-Null
        Test-FailAfter 7

        if ($DryRun) {
            Write-Host '[dry-run] 将执行：'
            $Staged | ForEach-Object { Write-Host "  $($_.action) -> $($_.dest) $($_.reason)" }
            return
        }
        # 提交点：剥离 run-scoped 字段后原子写 manifest。
        # $Staged 原条目保留 txn 路径——若 Write-Manifest 抛错，catch 仍能按 txn 回滚。
        $clean = @()
        foreach ($e in @($Staged)) {
            $c = @{}
            foreach ($k in $e.Keys) {
                if ($k -in @('created_this_run', 'backup_created_this_run', 'txn_backup_this_run')) { continue }
                $c[$k] = $e[$k]
            }
            $clean += $c
        }
        Write-Manifest -Path $manifestPath -Entries $clean
        # 提交成功后消费 txn 快照（升级前状态快照不再需要；失败路径由 catch 回滚并消费）
        foreach ($e in @($Staged)) {
            if ($e.txn_backup_this_run -and (Test-Path $e.txn_backup_this_run)) { Remove-Item $e.txn_backup_this_run -Force }
        }
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
            } elseif ($e.txn_backup_this_run -and (Test-Path $e.txn_backup_this_run)) {
                Copy-Item $e.txn_backup_this_run $e.dest -Force
                Remove-Item $e.txn_backup_this_run -Force
                Write-Host "  已回滚(升级前版本): $($e.dest)"
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
