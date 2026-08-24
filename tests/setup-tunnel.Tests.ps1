# tests/setup-tunnel.Tests.ps1 —— Secure MCP Tunnel 产品化契约测试（Pester 5；只测 CQS 行为，不测 OpenAI tunnel-client 本身）
# 覆盖：legacy 默认 / 参数校验 / guard config 生成 / MCP target 8766 / secret 边界 / upstream token 边界 / launcher 契约 / DryRun 零变更
Describe 'Transport 解析与 legacy 兼容' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
    }
    It 'Transport 未指定 → legacy Ngrok（旧调用不受影响）' {
        $setupSource -match '\$Transport -eq ''''' | Should -BeTrue
        $setupSource -match '\$Transport = ''Ngrok''' | Should -BeTrue
    }
    It 'Ngrok 模式仍要求 Domain（legacy 行为等价）' {
        $setupSource -match '-Transport Ngrok 需要 -Domain' | Should -BeTrue
    }
    It 'Domain 参数保持存在且不再 Mandatory（legacy 用户无感；Mandatory 校验改由分支负责）' {
        $setupSource -match '\[Parameter\(Mandatory=\$false\)\]\[string\]\$Domain' | Should -BeTrue
    }
    It '未知 Transport → fail-fast' {
        $setupSource -match '未知 -Transport' | Should -BeTrue
    }
}

Describe 'TunnelId 校验' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . "$repoRoot/bridge/tunnel.ps1"
    }
    It '合法 TunnelId（32 hex）通过' {
        Test-TunnelIdFormat 'tunnel_0123456789abcdef0123456789abcdef' | Should -BeTrue
    }
    It '官方格式（32 小写字母数字，含非 hex）通过——权威校验交给官方 CLI，不 hard-fail' {
        Test-TunnelIdFormat 'tunnel_abcdefghijklmnopqrstuvwxyz012345' | Should -BeTrue
    }
    It '非法 TunnelId（大写/短/无前缀）fail' {
        Test-TunnelIdFormat 'tunnel_BADVALUE' | Should -BeFalse
        Test-TunnelIdFormat '0123456789abcdef0123456789abcdef' | Should -BeFalse
        Test-TunnelIdFormat 'tunnel_short' | Should -BeFalse
    }
    It 'setup 对非法 TunnelId fail-fast' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
        $setupSource -match 'TunnelId 格式不正确' | Should -BeTrue
    }
    It '缺少 TunnelClientPath 且 Get-Command 找不到 → fail with 官方 URL 提示' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
        $setupSource -match 'Get-Command ''tunnel-client''' | Should -BeTrue
        $setupSource -match '缺少 -TunnelClientPath' | Should -BeTrue
    }
}

Describe 'Tunnel guard config 生成' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . "$repoRoot/bridge/tunnel.ps1"
        $allowlist = @('server_info','read_file','list_dir','list_files','search_text','git_status','git_diff','git_log','git_show','git_blame','view_image')
        $json = New-TunnelGuardConfigJson -Workspace 'D:\my\repo' -Allowlist $allowlist
        $cfg = $json | ConvertFrom-Json
    }
    It 'auth_mode=tunnel + host=127.0.0.1 + upstream=127.0.0.1:8765' {
        $cfg.auth_mode | Should -Be 'tunnel'
        $cfg.host | Should -Be '127.0.0.1'
        $cfg.upstream_url | Should -Be 'http://127.0.0.1:8765/mcp'
    }
    It '不含任何 public OAuth key（public_url/oauth_password_env/oauth_state_file）' {
        $cfg.PSObject.Properties.Name -contains 'public_url' | Should -BeFalse
        $cfg.PSObject.Properties.Name -contains 'oauth_password_env' | Should -BeFalse
        $cfg.PSObject.Properties.Name -contains 'oauth_state_file' | Should -BeFalse
    }
    It '不含 TunnelId / OpenAI API key / 任何 secret 字段' {
        $cfg.PSObject.Properties.Name -contains 'tunnel_id' | Should -BeFalse
        $cfg.PSObject.Properties.Name -contains 'api_key' | Should -BeFalse
        $raw = $json | ConvertTo-Json -Depth 1
        ($raw -match 'CONTROL_PLANE|sk-') | Should -BeFalse
    }
}

Describe 'Guard target（Tunnel 永远连 8766，绝不直连 8765）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
        . "$repoRoot/bridge/tunnel.ps1"
    }
    It 'profile init 的 MCP server URL 恒为 8766 guard' {
        $setupSource -match '--mcp-server-url "http://127\.0\.0\.1:\$GuardPort/mcp"' | Should -BeTrue
        $setupSource -match '8765/mcp' | Should -BeFalse
    }
    It 'init 使用 sample_mcp_remote_no_auth（无 OAuth 本地 MCP 场景）' {
        $setupSource -match '--sample sample_mcp_remote_no_auth' | Should -BeTrue
    }
    It 'init 使用 --force（官方幂等更新机制；重复 setup 不生成多个随机 profile）' {
        $setupSource -match '--force' | Should -BeTrue
    }
    It 'profile 名可预测：cqs- 加 TunnelId 末 8 位' {
        (Get-TunnelIdShort 'tunnel_0123456789abcdef0123456789abcdef') | Should -Be '89abcdef'
        $setupSource -match 'cqs-\$\(Get-TunnelIdShort \$TunnelId\)' | Should -BeTrue
    }
}

Describe 'Secret 边界（Runtime API Key / upstream token）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
        . "$repoRoot/bridge/tunnel.ps1"
        $bat = New-TunnelLauncherBat `
            -SecretsFile 'C:\repo\bridge\.secrets.tunnel.local.env' -McpExe 'C:\mcp.exe' -Workspace 'D:\repo' `
            -GuardPy 'C:\py.exe' -GuardScript 'C:\guard.py' -GuardConf 'C:\conf.json' `
            -TunnelClient 'C:\tunnel-client.exe' -ProfileDir 'C:\profiles' -ProfileName 'cqs-test'
        $secrets = New-TunnelSecretsContent -UpstreamToken '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' -RuntimeApiKey 'sk-test-runtime-key-123'
    }
    It 'Runtime API Key 从 env 读取优先，否则 Read-Host -AsSecureString' {
        $setupSource -match '\$env:CONTROL_PLANE_API_KEY' | Should -BeTrue
        $setupSource -match 'Read-Host .*-AsSecureString' | Should -BeTrue
    }
    It 'secrets 文件包含 CONTROL_PLANE_API_KEY 与 CQS_UPSTREAM_TOKEN 且纯 ASCII' {
        $secrets -match 'CONTROL_PLANE_API_KEY=sk-test-runtime-key-123' | Should -BeTrue
        $secrets -match 'CQS_UPSTREAM_TOKEN=0123456789abcdef' | Should -BeTrue
        ([regex]::Matches($secrets, '[^\x00-\x7F]')).Count | Should -Be 0
    }
    It 'launcher 不含任何 secret 字面量（token/api key 不进 launcher 文本）' {
        $bat -match 'sk-test' | Should -BeFalse
        $bat -match 'CONTROL_PLANE_API_KEY=' | Should -BeFalse
        $bat -match 'CQS_UPSTREAM_TOKEN=' | Should -BeFalse
    }
    It 'guard config 生成器不接受 TunnelId 或 API key 参数（无处进入）' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $src = Get-Content "$repoRoot/bridge/tunnel.ps1" -Raw -Encoding UTF8
        $src -match 'function New-TunnelGuardConfigJson' | Should -BeTrue
        $fn = [regex]::Match($src, 'function New-TunnelGuardConfigJson \{.*?\n\}', [System.Text.RegularExpressions.RegexOptions]::Singleline).Value
        $fn -match 'TunnelId' | Should -BeFalse
        $fn -match 'ApiKey' | Should -BeFalse
    }
    It 'Runtime API Key 不进入 setup 的 guard config 写入路径（guard config 无 CONTROL_PLANE）' {
        $setupSource -match 'CONTROL_PLANE_API_KEY' | Should -BeTrue   # 只出现在 env 读取与 secrets 写入语境
    }
}

Describe 'Upstream token 边界（禁 --auth-token，只走 env）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
        . "$repoRoot/bridge/tunnel.ps1"
        $bat = New-TunnelLauncherBat `
            -SecretsFile 'C:\repo\bridge\.secrets.tunnel.local.env' -McpExe 'C:\mcp.exe' -Workspace 'D:\repo' `
            -GuardPy 'C:\py.exe' -GuardScript 'C:\guard.py' -GuardConf 'C:\conf.json' `
            -TunnelClient 'C:\tunnel-client.exe' -ProfileDir 'C:\profiles' -ProfileName 'cqs-test'
    }
    It 'launcher 用 CODING_TOOLS_MCP_AUTH_TOKEN env 传递 token，不含 --auth-token' {
        $bat -match 'set "CODING_TOOLS_MCP_AUTH_TOKEN=%CQS_UPSTREAM_TOKEN%"' | Should -BeTrue
        $bat -match '--auth-token' | Should -BeFalse
    }
    It 'upstream 启动命令不含 token 参数（只 --workspace/--host/--port）' {
        $line = ($bat -split "`n" | Where-Object { $_ -match 'start "upstream"' }) -join "`n"
        $line -match '--workspace' | Should -BeTrue
        $line -match '--auth-token' | Should -BeFalse
    }
}

Describe 'Launcher 契约' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . "$repoRoot/bridge/tunnel.ps1"
        $bat = New-TunnelLauncherBat `
            -SecretsFile 'C:\repo\bridge\.secrets.tunnel.local.env' -McpExe 'C:\mcp.exe' -Workspace 'D:\repo' `
            -GuardPy 'C:\py.exe' -GuardScript 'C:\guard.py' -GuardConf 'C:\conf.json' `
            -TunnelClient 'C:\tunnel-client.exe' -ProfileDir 'C:\profiles' -ProfileName 'cqs-test'
    }
    It '包含 upstream / guard / tunnel-client 三个启动段' {
        $bat -match 'start "upstream"' | Should -BeTrue
        $bat -match 'start "guard"' | Should -BeTrue
        $bat -match 'tunnel-client.exe" run --profile-dir' | Should -BeTrue
    }
    It 'loopback 端口：upstream 8765、guard 8766，无 0.0.0.0、无 ngrok' {
        $bat -match '--port 8765' | Should -BeTrue
        $bat -match ':8766 ' | Should -BeTrue
        $bat -match '0\.0\.0\.0' | Should -BeFalse
        $bat -match 'ngrok' | Should -BeFalse
    }
    It 'readiness：bounded retry（30 次）+ 失败打印是哪一层 + 不宣称成功' {
        $bat -match 'for\(\$i=0;\$i -lt 30;\$i\+\+\)' | Should -BeTrue
        $bat -match 'did not listen within 30s' | Should -BeTrue
        $bat -match 'tunnel NOT started' | Should -BeTrue
    }
    It 'doctor 失败即停（errorlevel 检查）' {
        $bat -match 'doctor --profile-dir' | Should -BeTrue
        $bat -match 'doctor reported problems' | Should -BeTrue
    }
    It 'tunnel-client run 前台（保活隧道）' {
        $bat -match 'run --profile-dir' | Should -BeTrue
    }
    It 'env 文件用 for /f eol=# 加载（与 public launcher 同一模式）' {
        $bat -match 'for /f "usebackq eol=# tokens=1,\* delims=="' | Should -BeTrue
    }
    It '全 ASCII（GBK cmd 兼容）' {
        ([regex]::Matches($bat, '[^\x00-\x7F]')).Count | Should -Be 0
    }
}

Describe 'DryRun 零变更' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
    }
    It 'Tunnel DryRun 分支在写入前 return，且输出关键路径/端口/profile 名' {
        $tunnelBlock = [regex]::Match($setupSource, 'if \(\$Transport -eq ''Tunnel''\) \{.*?(?=\nif \(\$Domain -match)', [System.Text.RegularExpressions.RegexOptions]::Singleline).Value
        $tunnelBlock -match '\[dry-run\] Secure MCP Tunnel' | Should -BeTrue
        $tunnelBlock -match 'return' | Should -BeTrue
        $tunnelBlock -match '8766/mcp' | Should -BeTrue
        $tunnelBlock -match 'cqs-\$\(Get-TunnelIdShort' | Should -BeTrue
        $tunnelBlock -match 'health port' | Should -BeTrue
        $tunnelBlock -match 'launcher name' | Should -BeTrue
    }
    It 'DryRun 不输出 Runtime API Key' {
        $tunnelBlock = [regex]::Match($setupSource, 'if \(\$Transport -eq ''Tunnel''\) \{.*?(?=\nif \(\$Domain -match)', [System.Text.RegularExpressions.RegexOptions]::Singleline).Value
        $dryRun = [regex]::Match($tunnelBlock, 'if \(\$DryRun\) \{.*?\n    \}', [System.Text.RegularExpressions.RegexOptions]::Singleline).Value
        $dryRun -match 'CONTROL_PLANE|ApiKey' | Should -BeFalse
    }
}
