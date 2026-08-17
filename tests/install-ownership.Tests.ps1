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
    It '用户原有文件（skip）install→uninstall 后必须原样保留（P0 回归）' {
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
