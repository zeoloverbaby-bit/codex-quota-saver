# tests/install.ps1.Tests.ps1 —— Pester 5
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . "$repoRoot/install.ps1"   # 点源：底部 main 守卫不执行
}

Describe 'Add-ManagedBlock / Remove-ManagedBlock' {
    It '追加带标记块且幂等（第二次不重复追加）' {
        $f = New-Item -ItemType File "$TestDrive/agents-a.md"
        Add-ManagedBlock -Path $f -Id 'global-agents' -Content 'hello' -DryRun:$false | Out-Null
        Add-ManagedBlock -Path $f -Id 'global-agents' -Content 'hello' -DryRun:$false | Out-Null
        $c = Get-Content $f -Raw
        ($c | Select-String -AllMatches 'hello').Matches.Count | Should -Be 1
        ($c -match 'cqs-managed-block:global-agents') | Should -BeTrue
    }
    It 'Remove-ManagedBlock 精确移除块且不伤块外内容' {
        $f = New-Item -ItemType File "$TestDrive/agents-b.md"
        Set-Content $f -Value "keep`n" -Encoding UTF8
        Add-ManagedBlock -Path $f -Id 'x' -Content 'managed' -DryRun:$false | Out-Null
        Remove-ManagedBlock -Path $f -Id 'x'
        (Get-Content $f -Raw).Trim() | Should -Be 'keep'
    }
}

Describe 'Merge-AgentsToml' {
    It '已有 [agents] 段时跳过且不备份' {
        $f = New-Item -ItemType File "$TestDrive/config-a.toml"
        Set-Content $f -Value "[agents]`nenabled = true`n" -Encoding UTF8
        Merge-AgentsToml -Path $f -DryRun:$false | Out-Null
        (Get-ChildItem "$TestDrive/*.bak*").Count | Should -Be 0
    }
    It '无 [agents] 段时追加并生成备份' {
        $f = New-Item -ItemType File "$TestDrive/config-b.toml"
        Set-Content $f -Value "model = `"x`"`n" -Encoding UTF8
        Merge-AgentsToml -Path $f -DryRun:$false | Out-Null
        (Get-Content $f -Raw) -match 'default_subagent_model' | Should -BeTrue
        (Get-ChildItem "$TestDrive/*.bak*").Count | Should -Be 1
    }
}

Describe 'Manifest 往返' {
    It 'Write-然后 Read 得到相同条目' {
        $m = "$TestDrive/manifest.json"
        Write-Manifest -Path $m -Entries @(@{action='copy';dest="$TestDrive/a.md";src='x';backup=''})
        @(Read-Manifest -Path $m).Count | Should -Be 1
    }
    It '无 manifest 时 Read 返回空数组' {
        @(Read-Manifest -Path "$TestDrive/nope.json").Count | Should -Be 0
    }
}

Describe 'Invoke-Main 参数面' {
    It '缺少 -ProjectPath 报错退出' {
        { Invoke-Main -DryRun } | Should -Throw
    }
    It '-DryRun 不落任何文件' {
        $dest = New-Item -ItemType Directory "$TestDrive/proj"
        Invoke-Main -ProjectPath $dest.FullName -CodexHome "$TestDrive/codex" -DryRun | Out-Null
        (Test-Path "$TestDrive/codex") | Should -BeFalse
    }
}
