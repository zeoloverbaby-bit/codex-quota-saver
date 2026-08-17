# tests/install-ownership.Tests.ps1 —— Pester 5
# 回归锚点（2026-08-17 P0）：manifest 只记 hash 不记所有权，卸载把「hash 没变」当成「CQS 装的」——
# 用户原有文件被 skip 后，uninstall 会按 hash 相等删除它（实测命中 <project>/AGENTS.md）。
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . "$repoRoot/install.ps1"   # 点源：底部 main 守卫不执行
}

Describe 'Install-File ownership 字段' {
    It 'skip（已存在）条目标记 ownership=user，不携带 installed_hash' {
        $f = New-Item -ItemType File "$TestDrive/existing.md"
        Set-Content $f -Value 'USER CONTENT' -Encoding UTF8
        $src = New-Item -ItemType File "$TestDrive/src.md"
        $e = Install-File -Src $src.FullName -Dest $f.FullName -SkipIfExists $true -OverwriteIfChanged $false -DryRun $false
        $e.ownership | Should -Be 'user'
        $e.created_by_cqs | Should -Be $false
        $e.modified_by_cqs | Should -Be $false
        $e.installed_hash | Should -BeNullOrEmpty
    }
    It 'copy（新建）条目标记 ownership=cqs 且记录 installed_hash' {
        $d = "$TestDrive/new.md"
        $src = New-Item -ItemType File "$TestDrive/src2.md"
        Set-Content $src -Value 'X' -Encoding UTF8
        $e = Install-File -Src $src.FullName -Dest $d -SkipIfExists $false -OverwriteIfChanged $true -DryRun $false
        $e.ownership | Should -Be 'cqs'
        $e.created_by_cqs | Should -Be $true
        $e.modified_by_cqs | Should -Be $false
        $e.installed_hash | Should -Be (Get-Sha256 $d)
    }
    It 'copy（覆盖既有）条目标记 modified_by_cqs=true 且有 backup' {
        $f = New-Item -ItemType File "$TestDrive/overwrite.md"
        Set-Content $f -Value 'ORIGINAL' -Encoding UTF8
        $src = New-Item -ItemType File "$TestDrive/src3.md"
        Set-Content $src -Value 'CQS' -Encoding UTF8
        $e = Install-File -Src $src.FullName -Dest $f.FullName -SkipIfExists $false -OverwriteIfChanged $true -DryRun $false
        $e.ownership | Should -Be 'user'
        $e.created_by_cqs | Should -Be $false
        $e.modified_by_cqs | Should -Be $true
        $e.backup | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-Uninstall ownership 规则' {
    It '用户原有 project/AGENTS.md install→uninstall 后必须原样保留（P0 回归）' {
        $proj = New-Item -ItemType Directory "$TestDrive/proj"
        $agents = Join-Path $proj.FullName 'AGENTS.md'
        Set-Content $agents -Value 'USER CONTENT' -Encoding UTF8
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex"
        Invoke-Main -Uninstall -CodexHome "$TestDrive/codex"
        (Test-Path $agents) | Should -BeTrue
        (Get-Content $agents -Raw -Encoding UTF8).Trim() | Should -Be 'USER CONTENT'
    }
    It 'CQS 创建文件未改动时 uninstall 允许删除' {
        $proj = New-Item -ItemType Directory "$TestDrive/proj2"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex2"
        $agents = Join-Path $proj.FullName 'AGENTS.md'
        (Test-Path $agents) | Should -BeTrue
        Invoke-Main -Uninstall -CodexHome "$TestDrive/codex2"
        (Test-Path $agents) | Should -BeFalse
    }
    It '旧格式 manifest 条目（无所有权信息）保守跳过不删除' {
        $m = "$TestDrive/codex3/.codex-quota-saver-manifest.json"
        $f = New-Item -ItemType File "$TestDrive/legacy.md"
        Set-Content $f -Value 'LEGACY' -Encoding UTF8
        New-Item -ItemType Directory -Force (Split-Path $m) | Out-Null
        Write-Manifest -Path $m -Entries @(@{action='copy'; dest=$f.FullName; sha256=(Get-Sha256 $f.FullName)})
        Invoke-Uninstall -CodexHome "$TestDrive/codex3"
        (Test-Path $f.FullName) | Should -BeTrue
        (Get-Content $f.FullName -Raw -Encoding UTF8).Trim() | Should -Be 'LEGACY'
    }
}

Describe '项目级协议 managed block merge（三层协议必须装进已有 AGENTS.md）' {
    It '用户已有 project/AGENTS.md：install 追加托管块（Case 1），uninstall 摘块且文件保留' {
        $proj = New-Item -ItemType Directory "$TestDrive/proj-merge"
        $agents = Join-Path $proj.FullName 'AGENTS.md'
        Set-Content $agents -Value 'USER CONTENT' -Encoding UTF8
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex-merge"
        $raw = Get-Content $agents -Raw -Encoding UTF8
        $raw -match 'USER CONTENT' | Should -BeTrue
        $raw -match 'cqs-managed-block:project-protocol' | Should -BeTrue
        $raw -match '三层协作协议' | Should -BeTrue
        Invoke-Main -Uninstall -CodexHome "$TestDrive/codex-merge"
        (Test-Path $agents) | Should -BeTrue
        (Get-Content $agents -Raw -Encoding UTF8).Trim() | Should -Be 'USER CONTENT'
    }
    It '重复安装幂等：协议块不重复插入' {
        $proj = New-Item -ItemType Directory "$TestDrive/proj-merge2"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex-merge2"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex-merge2"
        $raw = Get-Content (Join-Path $proj.FullName 'AGENTS.md') -Raw -Encoding UTF8
        ([regex]::Matches($raw, 'cqs-managed-block:project-protocol begin')).Count | Should -Be 1
    }
    It 'CQS 创建后用户加内容：uninstall 摘块保留用户新增（Case 4）' {
        $proj = New-Item -ItemType Directory "$TestDrive/proj-add"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex-add"
        $agents = Join-Path $proj.FullName 'AGENTS.md'
        Add-Content -Path $agents -Value 'USER NEW CONTENT' -Encoding UTF8
        Invoke-Main -Uninstall -CodexHome "$TestDrive/codex-add"
        (Test-Path $agents) | Should -BeTrue
        $raw = Get-Content $agents -Raw -Encoding UTF8
        $raw -match 'cqs-managed-block' | Should -BeFalse
        $raw -match '三层协作协议' | Should -BeFalse
        $raw -match 'USER NEW CONTENT' | Should -BeTrue
    }
}

Describe 'CQS 覆盖文件卸载恢复（真 rollback，不靠 hash 删文件）' {
    It '覆盖用户原文件且未再改动：uninstall 恢复 ORIGINAL 且消费 backup（Case 5）' {
        $codex = "$TestDrive/codex-rollback"
        New-Item -ItemType Directory -Force "$codex/agents" | Out-Null
        $worker = New-Item -ItemType File "$codex/agents/luna-worker.toml"
        Set-Content $worker -Value 'ORIGINAL' -Encoding UTF8
        $proj = New-Item -ItemType Directory "$TestDrive/proj-rollback"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        # install 覆盖后文件是 CQS 版本，且生成 backup
        (Get-Content $worker -Raw -Encoding UTF8) -match 'ORIGINAL' | Should -BeFalse
        (Get-ChildItem "$codex/agents/*.bak*").Count | Should -Be 1
        Invoke-Main -Uninstall -CodexHome $codex
        # 真恢复：当前文件回到 ORIGINAL，backup 被消费（不是删除文件留备份）
        (Get-Content $worker -Raw -Encoding UTF8).Trim() | Should -Be 'ORIGINAL'
        (Get-ChildItem "$codex/agents/*.bak*").Count | Should -Be 0
    }
    It '覆盖后用户又修改：uninstall 不覆盖用户修改、保留两者并提示人工（Case 6）' {
        $codex = "$TestDrive/codex-rollback2"
        New-Item -ItemType Directory -Force "$codex/agents" | Out-Null
        $worker = New-Item -ItemType File "$codex/agents/luna-worker.toml"
        Set-Content $worker -Value 'ORIGINAL' -Encoding UTF8
        $proj = New-Item -ItemType Directory "$TestDrive/proj-rollback2"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Set-Content $worker -Value 'USER MODIFIED VERSION' -Encoding UTF8
        Invoke-Main -Uninstall -CodexHome $codex
        # 当前文件保持用户修改版本，backup 保留，绝不自动覆盖
        (Get-Content $worker -Raw -Encoding UTF8).Trim() | Should -Be 'USER MODIFIED VERSION'
        (Get-ChildItem "$codex/agents/*.bak*").Count | Should -Be 1
    }
}

Describe '重复安装所有权保持（P0：install×N→uninstall 与 install→uninstall 等价）' {
    It 'Case A：覆盖用户文件 ×2 → uninstall 恢复 ORIGINAL 且消费备份' {
        $codex = "$TestDrive/codex-repA"
        New-Item -ItemType Directory -Force "$codex/agents" | Out-Null
        $worker = New-Item -ItemType File "$codex/agents/luna-worker.toml"
        Set-Content $worker -Value 'ORIGINAL' -Encoding UTF8
        $proj = New-Item -ItemType Directory "$TestDrive/proj-repA"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        $bakAfter1 = (Get-ChildItem "$codex/agents/*.bak*" | Select-Object -First 1).FullName
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        # provenance 未丢失：modified/backup/hash 均保留，且没有生成第二个备份
        $m = @(Read-Manifest -Path (Get-ManifestPath $codex))
        $e = $m | Where-Object { $_.dest -eq $worker.FullName }
        $e.modified_by_cqs | Should -BeTrue
        $e.backup | Should -Be $bakAfter1
        $e.installed_hash | Should -Be (Get-Sha256 $worker.FullName)
        (Get-ChildItem "$codex/agents/*.bak*").Count | Should -Be 1
        Invoke-Main -Uninstall -CodexHome $codex
        (Get-Content $worker -Raw -Encoding UTF8).Trim() | Should -Be 'ORIGINAL'
        (Get-ChildItem "$codex/agents/*.bak*").Count | Should -Be 0
    }
    It 'Case B：CQS 创建文件 ×2 → uninstall 全部移除（不留空壳）' {
        $proj = New-Item -ItemType Directory "$TestDrive/proj-repB"
        $codex = "$TestDrive/codex-repB"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Invoke-Main -Uninstall -CodexHome $codex
        (Test-Path (Join-Path $proj.FullName 'AGENTS.md')) | Should -BeFalse
        (Test-Path (Join-Path $proj.FullName '.codex/config.toml')) | Should -BeFalse
        (Test-Path (Join-Path $proj.FullName '.codex/next-step.md')) | Should -BeFalse
        (Test-Path "$codex/AGENTS.md") | Should -BeFalse
        (Test-Path "$codex/config.toml") | Should -BeFalse
        (Test-Path "$codex/agents/luna-worker.toml") | Should -BeFalse
    }
    It 'Case C：用户已有 project/AGENTS.md + 托管块 ×2 → uninstall 只剩 USER CONTENT' {
        $proj = New-Item -ItemType Directory "$TestDrive/proj-repC"
        $agents = Join-Path $proj.FullName 'AGENTS.md'
        Set-Content $agents -Value 'USER CONTENT' -Encoding UTF8
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex-repC"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex-repC"
        Invoke-Main -Uninstall -CodexHome "$TestDrive/codex-repC"
        (Test-Path $agents) | Should -BeTrue
        (Get-Content $agents -Raw -Encoding UTF8).Trim() | Should -Be 'USER CONTENT'
    }
    It 'Case D：CQS 创建 AGENTS + 用户追加内容 ×2 → uninstall 摘块保留用户内容、无空壳' {
        $proj = New-Item -ItemType Directory "$TestDrive/proj-repD"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex-repD"
        $agents = Join-Path $proj.FullName 'AGENTS.md'
        Add-Content -Path $agents -Value 'USER NEW CONTENT' -Encoding UTF8
        Invoke-Main -ProjectPath $proj.FullName -CodexHome "$TestDrive/codex-repD"
        Invoke-Main -Uninstall -CodexHome "$TestDrive/codex-repD"
        (Test-Path $agents) | Should -BeTrue
        $raw = Get-Content $agents -Raw -Encoding UTF8
        $raw -match 'cqs-managed-block' | Should -BeFalse
        $raw -match 'USER NEW CONTENT' | Should -BeTrue
    }
    It 'Case E：ORIGINAL → install → 用户修改 → install 不得再覆盖 → uninstall 保留用户版与备份' {
        $codex = "$TestDrive/codex-repE"
        New-Item -ItemType Directory -Force "$codex/agents" | Out-Null
        $worker = New-Item -ItemType File "$codex/agents/luna-worker.toml"
        Set-Content $worker -Value 'ORIGINAL' -Encoding UTF8
        $proj = New-Item -ItemType Directory "$TestDrive/proj-repE"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Set-Content $worker -Value 'USER MODIFIED VERSION' -Encoding UTF8
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex   # 二次安装：绝不覆盖用户修改
        (Get-Content $worker -Raw -Encoding UTF8).Trim() | Should -Be 'USER MODIFIED VERSION'
        (Get-ChildItem "$codex/agents/*.bak*").Count | Should -Be 1
        Invoke-Main -Uninstall -CodexHome $codex
        (Get-Content $worker -Raw -Encoding UTF8).Trim() | Should -Be 'USER MODIFIED VERSION'
        (Get-ChildItem "$codex/agents/*.bak*").Count | Should -Be 1
    }
    It 'Case F：install×3 → uninstall 与 ×1 等价（provenance 不随次数衰减）' {
        $codex = "$TestDrive/codex-repF"
        New-Item -ItemType Directory -Force "$codex/agents" | Out-Null
        $worker = New-Item -ItemType File "$codex/agents/luna-worker.toml"
        Set-Content $worker -Value 'ORIGINAL' -Encoding UTF8
        $proj = New-Item -ItemType Directory "$TestDrive/proj-repF"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Invoke-Main -Uninstall -CodexHome $codex
        (Get-Content $worker -Raw -Encoding UTF8).Trim() | Should -Be 'ORIGINAL'
        (Get-ChildItem "$codex/agents/*.bak*").Count | Should -Be 0
    }
    It '已有 [agents] 表 install×2 → uninstall：markers 摘除、用户 key 原样（reconcile Case F）' {
        $codex = "$TestDrive/codex-agF"
        New-Item -ItemType Directory -Force $codex | Out-Null
        $cfg = New-Item -ItemType File "$codex/config.toml"
        Set-Content $cfg -Value "[agents]`nenabled = true`n" -Encoding UTF8
        $proj = New-Item -ItemType Directory "$TestDrive/proj-agF"
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        Invoke-Main -Uninstall -CodexHome $codex
        (Get-Content $cfg -Raw -Encoding UTF8).Trim() | Should -Be "[agents]`nenabled = true"
    }
}

Describe '备份身份与生命周期合并规则（Persistent Provenance Ledger）' {
    It 'Merge-ManifestEntry：created/modified 只增不减，backup/hash 本轮未新写则沿用旧值' {
        $prev = @{dest='d';ownership='user';created_by_cqs=$true;modified_by_cqs=$true;backup='d.bak-1';installed_hash='ABC'}
        $new  = @{action='skip';dest='d';reason='identical';ownership='user';created_by_cqs=$false;modified_by_cqs=$false}
        $m = Merge-ManifestEntry $prev $new
        $m.created_by_cqs | Should -BeTrue
        $m.modified_by_cqs | Should -BeTrue
        $m.backup | Should -Be 'd.bak-1'
        $m.installed_hash | Should -Be 'ABC'
    }
    It 'Merge-ManifestEntry：本轮真实新写入的 hash 不被旧值覆盖' {
        $prev = @{dest='d';modified_by_cqs=$true;backup='d.bak-1';installed_hash='ABC'}
        $new  = @{action='copy';dest='d';modified_by_cqs=$true;installed_hash='NEW'}
        $m = Merge-ManifestEntry $prev $new
        $m.installed_hash | Should -Be 'NEW'
    }
    It 'Get-UniqueBackupPath：base 被占用时追加序号，绝不覆盖既有备份（同秒冲突防护）' {
        $dest = "$TestDrive/u.md"
        $base = "$dest.bak-$(Get-Timestamp)"
        Set-Content -Path $base -Value 'ORIGINAL' -Encoding UTF8
        $p = Get-UniqueBackupPath $dest
        $p | Should -Not -Be $base
        $p | Should -BeLike "$base-*"
    }
}

# ---- Cross-version upgrade（S1→S2/S3）：lifecycle provenance 不随版本升级衰减 ----
# source 树通过 CQS_TEST_SOURCE_ROOT seam 指向 staged 副本（S1/S2/S3），
# 不修改仓库真实 global/ + project/ 树。txn 快照（覆盖前本轮状态）成功后必须消费。
Describe 'Cross-version upgrade（S1→S2/S3 生命周期）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        function New-SourceStage([string]$Root, [string]$Name) {
            $s = Join-Path $Root $Name
            Copy-Item (Join-Path $repoRoot 'global') (Join-Path $s 'global') -Recurse
            Copy-Item (Join-Path $repoRoot 'project') (Join-Path $s 'project') -Recurse
            return $s
        }
        function Copy-SourceStage([string]$Src, [string]$DstRoot, [string]$Name) {
            $d = Join-Path $DstRoot $Name
            Copy-Item "$Src\global" "$d\global" -Recurse
            Copy-Item "$Src\project" "$d\project" -Recurse
            return $d
        }
        function Invoke-WithSource([string]$Source, [scriptblock]$Body) {
            $env:CQS_TEST_SOURCE_ROOT = $Source
            try { & $Body } finally { Remove-Item Env:\CQS_TEST_SOURCE_ROOT -ErrorAction SilentlyContinue }
        }
    }

    It 'Upgrade Case A：USER → S1 → S2 → uninstall → USER（origin 身份贯穿升级）' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-a"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        Set-Content (Join-Path $s2 'global\agents\luna-worker.toml') -Value 'LUNA WORKER V2' -Encoding UTF8
        $ref = New-Item -ItemType File "$TestDrive/ref-user-original"
        Set-Content $ref -Value 'USER ORIGINAL' -Encoding UTF8
        $codex = Join-Path $TestDrive 'codex-up-a'
        New-Item -ItemType Directory (Join-Path $codex 'agents') -Force | Out-Null
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-up-a')
        $worker = Join-Path $codex 'agents\luna-worker.toml'
        Copy-Item $ref $worker -Force
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s1 'global\agents\luna-worker.toml'))
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 1
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s2 'global\agents\luna-worker.toml'))
        # origin 仍只有一份（txn 成功已消费）；installed_hash 前进到 S2
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 1
        $e = @(Read-Manifest -Path (Get-ManifestPath $codex)) | Where-Object { $_.dest -eq $worker }
        $e.backup | Should -Not -BeNullOrEmpty
        $e.installed_hash | Should -Be (Get-Sha256 (Join-Path $s2 'global\agents\luna-worker.toml'))
        Invoke-Main -Uninstall -CodexHome $codex
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 $ref)
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 0
    }

    It 'Upgrade Case B：missing → S1 → S2 → uninstall → missing（CQS-created 不被重分类）' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-b"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        Set-Content (Join-Path $s2 'global\agents\luna-worker.toml') -Value 'LUNA WORKER V2' -Encoding UTF8
        $codex = Join-Path $TestDrive 'codex-up-b'
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-up-b')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $worker = Join-Path $codex 'agents\luna-worker.toml'
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s2 'global\agents\luna-worker.toml'))
        $e = @(Read-Manifest -Path (Get-ManifestPath $codex)) | Where-Object { $_.dest -eq $worker }
        $e.created_by_cqs | Should -BeTrue
        $e.ownership | Should -Be 'cqs'
        $e.backup | Should -BeNullOrEmpty
        # CQS-created 升级：绝不铸造假 origin；txn 已消费 → 零 .bak
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 0
        Invoke-Main -Uninstall -CodexHome $codex
        (Test-Path $worker) | Should -BeFalse
        (Test-Path (Get-ManifestPath $codex)) | Should -BeFalse
    }

    It 'Upgrade Case C：USER → S1 → S2 → S3 → uninstall → USER（多版本不衰减）' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-c"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        $s3 = Copy-SourceStage $s1 $stage.FullName 's3'
        Set-Content (Join-Path $s2 'global\agents\luna-worker.toml') -Value 'LUNA WORKER V2' -Encoding UTF8
        Set-Content (Join-Path $s3 'global\agents\luna-worker.toml') -Value 'LUNA WORKER V3' -Encoding UTF8
        $ref = New-Item -ItemType File "$TestDrive/ref-user-original-c"
        Set-Content $ref -Value 'USER ORIGINAL' -Encoding UTF8
        $codex = Join-Path $TestDrive 'codex-up-c'
        New-Item -ItemType Directory (Join-Path $codex 'agents') -Force | Out-Null
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-up-c')
        $worker = Join-Path $codex 'agents\luna-worker.toml'
        Copy-Item $ref $worker -Force
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        Invoke-WithSource $s3 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s3 'global\agents\luna-worker.toml'))
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 1
        Invoke-Main -Uninstall -CodexHome $codex
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 $ref)
    }

    It 'Upgrade Case D：missing → S1 → S2 → S3 → uninstall → missing' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-d"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        $s3 = Copy-SourceStage $s1 $stage.FullName 's3'
        Set-Content (Join-Path $s2 'global\agents\luna-worker.toml') -Value 'LUNA WORKER V2' -Encoding UTF8
        Set-Content (Join-Path $s3 'global\agents\luna-worker.toml') -Value 'LUNA WORKER V3' -Encoding UTF8
        $codex = Join-Path $TestDrive 'codex-up-d'
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-up-d')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        Invoke-WithSource $s3 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $worker = Join-Path $codex 'agents\luna-worker.toml'
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s3 'global\agents\luna-worker.toml'))
        $e = @(Read-Manifest -Path (Get-ManifestPath $codex)) | Where-Object { $_.dest -eq $worker }
        $e.created_by_cqs | Should -BeTrue
        $e.backup | Should -BeNullOrEmpty
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 0
        Invoke-Main -Uninstall -CodexHome $codex
        (Test-Path $worker) | Should -BeFalse
    }

    It 'Upgrade Case E：USER → S1 → 升级 S2 失败 → 恢复 S1（不楔死、origin 完好）' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-e"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        Set-Content (Join-Path $s2 'global\agents\luna-worker.toml') -Value 'LUNA WORKER V2' -Encoding UTF8
        $ref = New-Item -ItemType File "$TestDrive/ref-user-original-e"
        Set-Content $ref -Value 'USER ORIGINAL' -Encoding UTF8
        $codex = Join-Path $TestDrive 'codex-up-e'
        New-Item -ItemType Directory (Join-Path $codex 'agents') -Force | Out-Null
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-up-e')
        $worker = Join-Path $codex 'agents\luna-worker.toml'
        Copy-Item $ref $worker -Force
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $manifest = Get-ManifestPath $codex
        $before = Get-Content $manifest -Raw -Encoding UTF8
        try {
            $env:CQS_TEST_SOURCE_ROOT = $s2
            $env:CQS_TEST_FAIL_AFTER = '3'
            { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex } | Should -Throw
        } finally {
            Remove-Item Env:\CQS_TEST_SOURCE_ROOT -ErrorAction SilentlyContinue
            Remove-Item Env:\CQS_TEST_FAIL_AFTER -ErrorAction SilentlyContinue
        }
        # transaction invariant：文件系统 = S1，manifest = S1，origin 备份完好
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s1 'global\agents\luna-worker.toml'))
        (Get-Content $manifest -Raw -Encoding UTF8) | Should -Be $before
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 1
        # 不楔死：重试升级可完成；uninstall 恢复 USER ORIGINAL
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s2 'global\agents\luna-worker.toml'))
        Invoke-Main -Uninstall -CodexHome $codex
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 $ref)
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 0
    }

    It 'Upgrade Case F：missing → S1 → 升级 S2 失败 → 恢复 S1 且 created_by_cqs 保持' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-f"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        Set-Content (Join-Path $s2 'global\agents\luna-worker.toml') -Value 'LUNA WORKER V2' -Encoding UTF8
        $codex = Join-Path $TestDrive 'codex-up-f'
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-up-f')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $worker = Join-Path $codex 'agents\luna-worker.toml'
        $manifest = Get-ManifestPath $codex
        $before = Get-Content $manifest -Raw -Encoding UTF8
        try {
            $env:CQS_TEST_SOURCE_ROOT = $s2
            $env:CQS_TEST_FAIL_AFTER = '3'
            { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex } | Should -Throw
        } finally {
            Remove-Item Env:\CQS_TEST_SOURCE_ROOT -ErrorAction SilentlyContinue
            Remove-Item Env:\CQS_TEST_FAIL_AFTER -ErrorAction SilentlyContinue
        }
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s1 'global\agents\luna-worker.toml'))
        (Get-Content $manifest -Raw -Encoding UTF8) | Should -Be $before
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 0
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        (Get-Sha256 $worker) | Should -Be (Get-Sha256 (Join-Path $s2 'global\agents\luna-worker.toml'))
        Invoke-Main -Uninstall -CodexHome $codex
        (Test-Path $worker) | Should -BeFalse
    }
}

# ---- Managed block 版本升级（installed_block_hash）：块体未被用户修改才可升级 ----
Describe 'Managed block 版本升级（installed_block_hash）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        function New-SourceStage([string]$Root, [string]$Name) {
            $s = Join-Path $Root $Name
            Copy-Item (Join-Path $repoRoot 'global') (Join-Path $s 'global') -Recurse
            Copy-Item (Join-Path $repoRoot 'project') (Join-Path $s 'project') -Recurse
            return $s
        }
        function Copy-SourceStage([string]$Src, [string]$DstRoot, [string]$Name) {
            $d = Join-Path $DstRoot $Name
            Copy-Item "$Src\global" "$d\global" -Recurse
            Copy-Item "$Src\project" "$d\project" -Recurse
            return $d
        }
        function Invoke-WithSource([string]$Source, [scriptblock]$Body) {
            $env:CQS_TEST_SOURCE_ROOT = $Source
            try { & $Body } finally { Remove-Item Env:\CQS_TEST_SOURCE_ROOT -ErrorAction SilentlyContinue }
        }
    }

    It 'Case G：用户内容 + CQS 块 S1 → 模板升级 S2 → 块升级、用户内容不变、卸载只剩用户内容' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-g"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        Set-Content (Join-Path $s1 'global\AGENTS.md') -Value 'LUNA PROTOCOL V1' -Encoding UTF8
        Set-Content (Join-Path $s2 'global\AGENTS.md') -Value 'LUNA PROTOCOL V2' -Encoding UTF8
        $codex = Join-Path $TestDrive 'codex-mb-g'
        New-Item -ItemType Directory $codex -Force | Out-Null
        $f = Join-Path $codex 'AGENTS.md'
        Set-Content $f -Value 'USER AGENTS' -Encoding UTF8
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-mb-g')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        "$(Get-Content $f -Raw -Encoding UTF8)" | Should -Match 'LUNA PROTOCOL V1'
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $raw = "$(Get-Content $f -Raw -Encoding UTF8)"
        $raw | Should -Match 'LUNA PROTOCOL V2'
        $raw | Should -Not -Match 'LUNA PROTOCOL V1'
        $raw | Should -Match 'USER AGENTS'
        ([regex]::Matches($raw, [regex]::Escape('<!-- cqs-managed-block:global-agents begin -->'))).Count | Should -Be 1
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 1
        $e = @(Read-Manifest -Path (Get-ManifestPath $codex)) | Where-Object { $_.dest -eq $f }
        $e.installed_block_hash | Should -Not -BeNullOrEmpty
        Invoke-Main -Uninstall -CodexHome $codex
        "$(Get-Content $f -Raw -Encoding UTF8)".Trim() | Should -Be 'USER AGENTS'
    }

    It 'Case H：用户编辑块内 → S2 尝试 → 不覆盖 + block-user-modified' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-h"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        Set-Content (Join-Path $s1 'global\AGENTS.md') -Value 'LUNA PROTOCOL V1' -Encoding UTF8
        Set-Content (Join-Path $s2 'global\AGENTS.md') -Value 'LUNA PROTOCOL V2' -Encoding UTF8
        $codex = Join-Path $TestDrive 'codex-mb-h'
        New-Item -ItemType Directory $codex -Force | Out-Null
        $f = Join-Path $codex 'AGENTS.md'
        Set-Content $f -Value 'USER AGENTS' -Encoding UTF8
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-mb-h')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        # 用户编辑块内（保留 markers）
        $edited = "$(Get-Content $f -Raw -Encoding UTF8)".Replace('LUNA PROTOCOL V1', 'USER EDIT INSIDE BLOCK')
        Set-Content $f -Value $edited -Encoding UTF8
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $raw = "$(Get-Content $f -Raw -Encoding UTF8)"
        $raw | Should -Match 'USER EDIT INSIDE BLOCK'
        $raw | Should -Not -Match 'LUNA PROTOCOL V2'
        $e = @(Read-Manifest -Path (Get-ManifestPath $codex)) | Where-Object { $_.dest -eq $f }
        $e.reason | Should -Be 'block-user-modified'
        @(Get-ChildItem $codex -Recurse -Filter '*.bak-*').Count | Should -Be 1
        Invoke-Main -Uninstall -CodexHome $codex
        "$(Get-Content $f -Raw -Encoding UTF8)".Trim() | Should -Be 'USER AGENTS'
    }
}

# ---- agents reconciliation ownership-aware：markers 内 = CQS-owned（可升级），markers 外 = user-owned ----
Describe 'agents reconciliation ownership-aware 升级（CQS region vs user keys）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        function New-SourceStage([string]$Root, [string]$Name) {
            $s = Join-Path $Root $Name
            Copy-Item (Join-Path $repoRoot 'global') (Join-Path $s 'global') -Recurse
            Copy-Item (Join-Path $repoRoot 'project') (Join-Path $s 'project') -Recurse
            return $s
        }
        function Copy-SourceStage([string]$Src, [string]$DstRoot, [string]$Name) {
            $d = Join-Path $DstRoot $Name
            Copy-Item "$Src\global" "$d\global" -Recurse
            Copy-Item "$Src\project" "$d\project" -Recurse
            return $d
        }
        function Invoke-WithSource([string]$Source, [scriptblock]$Body) {
            $env:CQS_TEST_SOURCE_ROOT = $Source
            try { & $Body } finally { Remove-Item Env:\CQS_TEST_SOURCE_ROOT -ErrorAction SilentlyContinue }
        }
        function Set-DesiredThreads([string]$Tree, [string]$Value) {
            $t = Join-Path $Tree 'global\config-agents.toml'
            (Get-Content $t -Raw -Encoding UTF8) -replace 'max_concurrent_threads_per_session = \d+', "max_concurrent_threads_per_session = $Value" | Set-Content $t -Encoding UTF8
        }
    }

    It 'Case I：CQS-owned key threads=6 → S2 desired 4 → 升级、用户 key 不动' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-i"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        Set-DesiredThreads $s2 '4'
        $codex = Join-Path $TestDrive 'codex-ag-i'
        New-Item -ItemType Directory $codex -Force | Out-Null
        $cfg = Join-Path $codex 'config.toml'
        Set-Content $cfg -Value "[agents]`nenabled = true" -Encoding UTF8
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-ag-i')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        "$(Get-Content $cfg -Raw -Encoding UTF8)" | Should -Match 'max_concurrent_threads_per_session = 6'
        Invoke-WithSource $s2 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $raw = "$(Get-Content $cfg -Raw -Encoding UTF8)"
        $raw | Should -Match 'max_concurrent_threads_per_session = 4'
        $raw | Should -Not -Match 'max_concurrent_threads_per_session = 6'
        ([regex]::Matches($raw, '(?m)^\s*enabled\s*=')).Count | Should -Be 1
        ([regex]::Matches($raw, '(?m)^\s*max_concurrent_threads_per_session\s*=')).Count | Should -Be 1
        ([regex]::Matches($raw, [regex]::Escape('# --- codex-quota-saver managed [agents] begin ---'))).Count | Should -Be 1
        $e = @(Read-Manifest -Path (Get-ManifestPath $codex)) | Where-Object { $_.dest -eq $cfg }
        $e.installed_block_hash | Should -Not -BeNullOrEmpty
        Invoke-Main -Uninstall -CodexHome $codex
        "$(Get-Content $cfg -Raw -Encoding UTF8)".Trim() | Should -Be "[agents]`nenabled = true"
    }

    It 'Case J：user-owned threads=6 → S2 desired 4 → CONFLICT fail-fast、零 mutation' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-j"
        $s1 = New-SourceStage $stage.FullName 's1'
        $s2 = Copy-SourceStage $s1 $stage.FullName 's2'
        Set-DesiredThreads $s2 '4'
        $codex = Join-Path $TestDrive 'codex-ag-j'
        New-Item -ItemType Directory $codex -Force | Out-Null
        $cfg = Join-Path $codex 'config.toml'
        Set-Content $cfg -Value "[agents]`nmax_concurrent_threads_per_session = 6" -Encoding UTF8
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-ag-j')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $cfgBefore = Get-Content $cfg -Raw -Encoding UTF8
        $manBefore = Get-Content (Get-ManifestPath $codex) -Raw -Encoding UTF8
        try {
            $env:CQS_TEST_SOURCE_ROOT = $s2
            { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex } | Should -Throw
        } finally {
            Remove-Item Env:\CQS_TEST_SOURCE_ROOT -ErrorAction SilentlyContinue
        }
        (Get-Content $cfg -Raw -Encoding UTF8) | Should -Be $cfgBefore
        (Get-Content (Get-ManifestPath $codex) -Raw -Encoding UTF8) | Should -Be $manBefore
    }

    It 'duplicate key：region 内 + region 外同名 → CONFLICT fail-fast、零 mutation' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-dup"
        $s1 = New-SourceStage $stage.FullName 's1'
        $codex = Join-Path $TestDrive 'codex-ag-dup'
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-ag-dup')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        $cfg = Join-Path $codex 'config.toml'
        # region 之后追加用户同名 key
        Add-Content $cfg -Value "`nmax_concurrent_threads_per_session = 6" -Encoding UTF8
        $cfgBefore = Get-Content $cfg -Raw -Encoding UTF8
        { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex } | Should -Throw
        (Get-Content $cfg -Raw -Encoding UTF8) | Should -Be $cfgBefore
    }

    It 'threads=0（user key）：安装不能成功（conflict fail-fast、零 mutation）' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-z"
        $s1 = New-SourceStage $stage.FullName 's1'
        $codex = Join-Path $TestDrive 'codex-ag-zero'
        New-Item -ItemType Directory $codex -Force | Out-Null
        $cfg = Join-Path $codex 'config.toml'
        Set-Content $cfg -Value "[agents]`nmax_concurrent_threads_per_session = 0" -Encoding UTF8
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-ag-zero')
        $cfgBefore = Get-Content $cfg -Raw -Encoding UTF8
        try {
            $env:CQS_TEST_SOURCE_ROOT = $s1
            { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex } | Should -Throw
        } finally {
            Remove-Item Env:\CQS_TEST_SOURCE_ROOT -ErrorAction SilentlyContinue
        }
        (Get-Content $cfg -Raw -Encoding UTF8) | Should -Be $cfgBefore
        (Test-Path (Get-ManifestPath $codex)) | Should -BeFalse
    }

    It 'threads=1（user key）：更严且合法 → adopt_stricter、安装成功' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-one"
        $s1 = New-SourceStage $stage.FullName 's1'
        $codex = Join-Path $TestDrive 'codex-ag-one'
        New-Item -ItemType Directory $codex -Force | Out-Null
        $cfg = Join-Path $codex 'config.toml'
        Set-Content $cfg -Value "[agents]`nmax_concurrent_threads_per_session = 1" -Encoding UTF8
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-ag-one')
        Invoke-WithSource $s1 { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex }
        "$(Get-Content $cfg -Raw -Encoding UTF8)" | Should -Match 'max_concurrent_threads_per_session = 1'
        "$(Get-Content $cfg -Raw -Encoding UTF8)" | Should -Not -Match 'max_concurrent_threads_per_session = 6'
    }

    It 'desired 自身非法（threads=0 的 source of truth）→ 安装拒绝启动（drift guard）' {
        $stage = New-Item -ItemType Directory "$TestDrive/src-drift"
        $s1 = New-SourceStage $stage.FullName 's1'
        Set-DesiredThreads $s1 '0'
        $codex = Join-Path $TestDrive 'codex-ag-drift'
        $proj = New-Item -ItemType Directory (Join-Path $TestDrive 'proj-ag-drift')
        try {
            $env:CQS_TEST_SOURCE_ROOT = $s1
            { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex } | Should -Throw
        } finally {
            Remove-Item Env:\CQS_TEST_SOURCE_ROOT -ErrorAction SilentlyContinue
        }
    }
}

Describe 'partial failure：中途失败不丢旧 manifest、已改资源回滚、绝不打印成功' {
    It '第 3 步注入失败：抛错、旧 manifest 字节不变、本轮改动回滚（Pester）' {
        $codex = "$TestDrive/codex-fail"
        New-Item -ItemType Directory -Force $codex | Out-Null
        $proj = New-Item -ItemType Directory "$TestDrive/proj-fail"
        # 先做一次干净安装，形成旧 manifest 基线
        Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex
        $manifest = Get-ManifestPath $codex
        $before = Get-Content $manifest -Raw -Encoding UTF8
        # 制造「本次运行真实 mutation」场景：块被移除、两个文件被删
        Set-Content "$codex/AGENTS.md" -Value 'USER AGENTS' -Encoding UTF8
        Remove-Item "$codex/config.toml" -Force
        Remove-Item "$codex/agents/luna-worker.toml" -Force
        $env:CQS_TEST_FAIL_AFTER = '3'
        try {
            { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex } | Should -Throw
            # 旧 manifest 原样保留；本轮 mutation 已回滚
            (Get-Content $manifest -Raw -Encoding UTF8) | Should -Be $before
            (Get-Content "$codex/AGENTS.md" -Raw -Encoding UTF8).Trim() | Should -Be 'USER AGENTS'
            (Test-Path "$codex/config.toml") | Should -BeFalse
            (Test-Path "$codex/agents/luna-worker.toml") | Should -BeFalse
            (Get-ChildItem "$codex/*.bak*").Count | Should -Be 0
        } finally {
            Remove-Item Env:\CQS_TEST_FAIL_AFTER -ErrorAction SilentlyContinue
        }
    }
}
