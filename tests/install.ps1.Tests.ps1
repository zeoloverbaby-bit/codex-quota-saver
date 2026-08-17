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

Describe 'Get-AgentsReconcilePlan（key 级语义分类：add/adopt/adopt_stricter/conflict）' {
    BeforeAll { $script:desired = Get-AgentsDesiredState }
    It 'Get-AgentsDesiredState 与 global/config-agents.toml 一致（source of truth 防漂移）' {
        $d = $script:desired
        $d['enabled'].raw | Should -Be 'true'
        $d['default_subagent_model'].raw | Should -Be '"gpt-5.6-luna"'
        $d['default_subagent_reasoning_effort'].raw | Should -Be '"max"'
        $d['max_concurrent_threads_per_session'].raw | Should -Be '6'
    }
    It '无 [agents] 表：table_exists=false，全部视为 add' {
        $p = Get-AgentsReconcilePlan -Raw "model = `"x`"`n" -Desired $script:desired
        $p.table_exists | Should -BeFalse
        $p.states['default_subagent_model'] | Should -Be 'add'
    }
    It '相同值 adopt、缺失 add、更严 adopt_stricter（不变量 ≤6 满足）' {
        $raw = @"
[agents]
enabled = true
default_subagent_model = "gpt-5.6-luna"
max_concurrent_threads_per_session = 4

[mcp_servers.foo]
url = "x"
"@
        $p = Get-AgentsReconcilePlan -Raw $raw -Desired $script:desired
        $p.states['enabled'] | Should -Be 'adopt'
        $p.states['default_subagent_model'] | Should -Be 'adopt'
        $p.states['default_subagent_reasoning_effort'] | Should -Be 'add'
        $p.states['max_concurrent_threads_per_session'] | Should -Be 'adopt_stricter'
    }
    It '破坏 CQS 不变量 → conflict（模型名不同 / 线程数 >6 / enabled=false）' {
        $p1 = Get-AgentsReconcilePlan -Raw "[agents]`ndefault_subagent_model = `"other-model`"`n" -Desired $script:desired
        $p1.states['default_subagent_model'] | Should -Be 'conflict'
        $p2 = Get-AgentsReconcilePlan -Raw "[agents]`nmax_concurrent_threads_per_session = 8`n" -Desired $script:desired
        $p2.states['max_concurrent_threads_per_session'] | Should -Be 'conflict'
        $p3 = Get-AgentsReconcilePlan -Raw "[agents]`nenabled = false`n" -Desired $script:desired
        $p3.states['enabled'] | Should -Be 'conflict'
    }
    It 'span 内存在无法可靠解析的行 → writer_supported=false（fail-safe 人工）' {
        $p = Get-AgentsReconcilePlan -Raw "[agents]`nenabled = `"multi`nline`"`n" -Desired $script:desired
        $p.writer_supported | Should -BeFalse
    }
}

Describe 'Merge-AgentsToml（key 级 reconciliation）' {
    It '已有部分 [agents] 表：缺失 key 以 managed markers 插入现有表内，不产生第二个表（Case B）' {
        $f = New-Item -ItemType File "$TestDrive/config-b.toml"
        Set-Content $f -Value "[agents]`nenabled = true`n" -Encoding UTF8
        Merge-AgentsToml -Path $f -DryRun:$false | Out-Null
        $raw = Get-Content $f -Raw -Encoding UTF8
        ([regex]::Matches($raw, '(?m)^\s*\[agents\]')).Count | Should -Be 1
        $raw -match 'default_subagent_model = "gpt-5.6-luna"' | Should -BeTrue
        $raw -match 'default_subagent_reasoning_effort = "max"' | Should -BeTrue
        $raw -match 'max_concurrent_threads_per_session = 6' | Should -BeTrue
        ([regex]::Matches($raw, '(?m)^\s*enabled\s*=')).Count | Should -Be 1
        $raw -match 'managed \[agents\] begin' | Should -BeTrue
        (Get-ChildItem "$TestDrive/config-b.toml.bak*").Count | Should -Be 1
    }
    It 'conflict：fail-fast 抛错、原文件字节不变、不产生备份（Case D）' {
        $f = New-Item -ItemType File "$TestDrive/config-d.toml"
        Set-Content $f -Value "[agents]`ndefault_subagent_model = `"other-model`"`n" -Encoding UTF8
        $before = Get-Content $f -Raw -Encoding UTF8
        { Merge-AgentsToml -Path $f -DryRun:$false } | Should -Throw
        (Get-Content $f -Raw -Encoding UTF8) | Should -Be $before
        (Get-ChildItem "$TestDrive/config-d.toml.bak*").Count | Should -Be 0
    }
    It 'mixed：adopt + adopt_stricter + add——只插缺失 key，保留用户更严值（Case E）' {
        $f = New-Item -ItemType File "$TestDrive/config-e.toml"
        Set-Content $f -Value @"
[agents]
enabled = true
default_subagent_model = "gpt-5.6-luna"
max_concurrent_threads_per_session = 4
"@ -Encoding UTF8
        Merge-AgentsToml -Path $f -DryRun:$false | Out-Null
        $raw = Get-Content $f -Raw -Encoding UTF8
        ([regex]::Matches($raw, '(?m)^\s*max_concurrent_threads_per_session\s*=')).Count | Should -Be 1
        $raw -match 'max_concurrent_threads_per_session = 4' | Should -BeTrue
        $raw -match 'max_concurrent_threads_per_session = 6' | Should -BeFalse
        $raw -match 'default_subagent_reasoning_effort = "max"' | Should -BeTrue
        ([regex]::Matches($raw, '(?m)^\s*default_subagent_model\s*=')).Count | Should -Be 1
    }
    It '无 [agents] 段时追加并生成备份' {
        $f = New-Item -ItemType File "$TestDrive/config-f.toml"
        Set-Content $f -Value "model = `"x`"`n" -Encoding UTF8
        Merge-AgentsToml -Path $f -DryRun:$false | Out-Null
        (Get-Content $f -Raw) -match 'default_subagent_model' | Should -BeTrue
        (Get-ChildItem "$TestDrive/config-f.toml.bak*").Count | Should -Be 1
    }
    It 'TOML 托管段可被带自定义标记的 Remove-ManagedBlock 摘除' {
        $f = New-Item -ItemType File "$TestDrive/config-g.toml"
        Merge-AgentsToml -Path $f -DryRun:$false | Out-Null
        Remove-ManagedBlock -Path $f -Id 'agents-toml' -Begin '# --- codex-quota-saver managed [agents] begin ---' -End '# --- codex-quota-saver managed [agents] end ---'
        (Get-Content $f -Raw) -match 'default_subagent_model' | Should -BeFalse
    }
}

Describe 'conflict preflight：任何 filesystem mutation 之前终止' {
    It 'config.toml 冲突 → Invoke-Main 抛错且零落盘（无目录/无文件/无 manifest）' {
        $codex = "$TestDrive/codex-conflict"
        New-Item -ItemType Directory -Force $codex | Out-Null
        $cfg = New-Item -ItemType File "$codex/config.toml"
        Set-Content $cfg -Value "[agents]`ndefault_subagent_model = `"other-model`"`n" -Encoding UTF8
        $before = Get-Content $cfg -Raw -Encoding UTF8
        $proj = New-Item -ItemType Directory "$TestDrive/proj-conflict"
        { Invoke-Main -ProjectPath $proj.FullName -CodexHome $codex } | Should -Throw
        (Get-Content $cfg -Raw -Encoding UTF8) | Should -Be $before
        (Test-Path "$codex/AGENTS.md") | Should -BeFalse
        (Test-Path "$codex/agents") | Should -BeFalse
        (Test-Path "$codex/.codex-quota-saver-manifest.json") | Should -BeFalse
        (Test-Path "$proj.FullName/AGENTS.md") | Should -BeFalse
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
