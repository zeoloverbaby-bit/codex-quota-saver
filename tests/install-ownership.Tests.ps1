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
