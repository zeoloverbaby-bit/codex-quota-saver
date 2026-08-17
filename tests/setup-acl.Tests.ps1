# tests/setup-acl.Tests.ps1 —— Pester 5（Windows 专属：icacls 真实验证）
# 回归锚点：v1.6.0 曾把 launcher 收成 (R,W)，缺执行位导致双击 start-bridge.local.bat 报「无法访问」。
Describe 'Tighten-Acl' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . "$repoRoot/bridge/acl.ps1"
        $who = whoami
        $execRight = [System.Security.AccessControl.FileSystemRights]::ExecuteFile
    }
    It 'launcher 权限 (RX,W) 含执行位——双击 .bat 不被 Windows 拦下' {
        $f = New-Item -ItemType File "$TestDrive/launcher.bat"
        Tighten-Acl -Path $f.FullName -Rights '(RX,W)'
        $acl = Get-Acl $f.FullName
        $rule = $acl.Access | Where-Object { $_.IdentityReference.Value -eq $who } | Select-Object -First 1
        $rule | Should -Not -BeNullOrEmpty
        ($rule.FileSystemRights -band $execRight) -ne 0 | Should -BeTrue
        $acl.AreAccessRulesProtected | Should -BeTrue   # 继承已移除
    }
    It 'secrets 权限默认 (R,W) 无执行位——secrets 不会被当脚本运行' {
        $f = New-Item -ItemType File "$TestDrive/secrets.env"
        Tighten-Acl -Path $f.FullName
        $acl = Get-Acl $f.FullName
        $rule = $acl.Access | Where-Object { $_.IdentityReference.Value -eq $who } | Select-Object -First 1
        $rule | Should -Not -BeNullOrEmpty
        ($rule.FileSystemRights -band $execRight) -eq 0 | Should -BeTrue
        $acl.AreAccessRulesProtected | Should -BeTrue
    }
}

Describe 'Launcher 模板回归（v1.6.2：env 加载 + 二重启动防护；v1.6.4：预热行）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
        $shSource = Get-Content "$repoRoot/bridge/setup.sh" -Raw -Encoding UTF8
    }
    It 'env 文件内容模板纯 ASCII（2026-08-17 根因：非 ASCII 字节破坏 cmd for /f 在 GBK 系统的读取，变量全部加载失败）' {
        $line = ($setupSource -split "`n" | Where-Object { $_ -match 'Write-Utf8NoBom \$EnvFile' }) -join "`n"
        $line | Should -Not -BeNullOrEmpty
        $matched = $line -match 'Write-Utf8NoBom \$EnvFile "(?<lit>[^"]*)"'
        $matched | Should -BeTrue
        ([regex]::Matches($Matches['lit'], '[-￿]')).Count | Should -Be 0
    }
    It 'launcher for /f 模式能从 env 文件加载变量（eol=# 跳过注释 + set 引号）' {
        $envFile = "$TestDrive/secrets.local.env"
        [System.IO.File]::WriteAllText($envFile, "# comment line - ASCII`r`nCQS_OAUTH_PASSWORD=testpw123`r`nCQS_UPSTREAM_TOKEN=testtok456`r`n", (New-Object System.Text.ASCIIEncoding))
        $outFile = "$TestDrive/result.txt"
        $bat = "$TestDrive/loadtest.bat"
        $batContent = @'
@echo off
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("{0}") do set "%%a=%%b"
if defined CQS_UPSTREAM_TOKEN (echo TOKEN_OK>"{1}") else (echo TOKEN_MISSING>"{1}")
'@ -f $envFile, $outFile
        [System.IO.File]::WriteAllText($bat, $batContent, (New-Object System.Text.ASCIIEncoding))
        & cmd.exe /c $bat | Out-Null
        (Get-Content $outFile -Raw).Trim() | Should -Be 'TOKEN_OK'
    }
    It 'launcher 模板含二重启动防护（端口占用时提示而不是抢端口报错）' {
        $setupSource -match 'netstat -ano \| findstr' | Should -BeTrue
        $setupSource -match 'Bridge is already running' | Should -BeTrue
    }
    It 'launcher 模板含预热行（v1.6.4：延迟 15s 自动打开浏览器到密码页——ngrok 拦截页的「点一次」从用到时提前到启动时，官方禁止技术手段跳过）' {
        $setupSource -match 'WindowStyle Hidden' | Should -BeTrue
        $setupSource -match 'Start-Sleep -Seconds 15' | Should -BeTrue
        $setupSource -match 'https://\$Domain/auth/login' | Should -BeTrue
        $shSource -match 'xdg-open "https://\$DOMAIN/auth/login"' | Should -BeTrue
        $shSource -match 'sleep 15' | Should -BeTrue
    }
    It '二重启动防护功能：端口占用时提示 already running 并退出（块内 echo 无括号——括号会提前终结 if 块，2026-08-17 实测根因）' {
        $job = Start-Job -ScriptBlock {
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 18876)
            $l.Start()
            Start-Sleep -Seconds 30
        }
        try {
            Start-Sleep -Seconds 2
            $bat = "$TestDrive/guardtest.bat"
            $batContent = @'
@echo off
netstat -ano | findstr ":18876 " | findstr LISTENING >nul 2>&1
if not errorlevel 1 (
  echo Bridge is already running - port 18876 in use. Do NOT start it twice.
  echo To restart: close all three windows first, then run this file again.
  pause
  exit /b 1
)
echo NO_GUARD_FIRED
'@
            [System.IO.File]::WriteAllText($bat, $batContent, (New-Object System.Text.ASCIIEncoding))
            # 喂空 stdin：非交互环境里 pause 会等按键，管道 EOF 使其立即返回
            $output = ('' | & cmd.exe /c $bat 2>&1 | Out-String)
            $output -match 'already running' | Should -BeTrue
            $output -match 'NO_GUARD_FIRED' | Should -BeFalse
        } finally {
            Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

Describe 'Secrets 生成（防越界 NUL）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . "$repoRoot/bridge/secrets.ps1"
    }
    It 'New-Password 200 次全部为 16 位字母数字（2026-08-17 根因：模数 59 > 字母表 57，越界索引产出 NUL，实测 42% 概率）' {
        $bad = 0
        for ($i = 0; $i -lt 200; $i++) {
            $pw = New-Password
            if ($pw -notmatch '^[A-Za-z0-9]{16}$') { $bad++ }
        }
        $bad | Should -Be 0
    }
    It 'New-Token 为 64 位小写 hex' {
        (New-Token) -match '^[0-9a-f]{64}$' | Should -BeTrue
    }
}

Describe 'OAuth state 目录权限（token_secret + 客户端注册表落盘处，Windows 继承已移除）' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . "$repoRoot/bridge/acl.ps1"
        $setupSource = Get-Content "$repoRoot/bridge/setup.ps1" -Raw -Encoding UTF8
        $shSource = Get-Content "$repoRoot/bridge/setup.sh" -Raw -Encoding UTF8
        $who = whoami
    }
    It 'Tighten-Acl 用于目录：继承移除，且其后新建的子文件 ACL 只含当前用户（无 broad ACE）' {
        $dir = New-Item -ItemType Directory "$TestDrive/state-dir"
        Tighten-Acl -Path $dir.FullName -Rights '(R,W)'
        $acl = Get-Acl $dir.FullName
        $acl.AreAccessRulesProtected | Should -BeTrue
        $child = New-Item -ItemType File "$($dir.FullName)/child.json"
        $childAcl = Get-Acl $child.FullName
        # 不是 world-readable 等价状态：无 Everyone / Users / Authenticated Users
        $broad = $childAcl.Access | Where-Object { $_.IdentityReference.Value -match 'Everyone|BUILTIN\\Users|Authenticated Users' }
        $broad.Count | Should -Be 0
        # 当前用户仍可读写
        $mine = $childAcl.Access | Where-Object { $_.IdentityReference.Value -eq $who }
        $mine | Should -Not -BeNullOrEmpty
        (($mine.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0) | Should -BeTrue
        (($mine.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write) -ne 0) | Should -BeTrue
    }
    It 'setup.ps1 建 guard\state 目录并收紧 ACL、旧 oauth_state.json 迁移、配置指向 state/' {
        $setupSource -match 'guard\\state' | Should -BeTrue
        $setupSource -match 'Tighten-Acl \$StateDir' | Should -BeTrue
        $setupSource -match 'Move-Item \$LegacyOAuthState' | Should -BeTrue
        $setupSource -match 'state/oauth_state\.json' | Should -BeTrue
    }
    It 'setup.sh 建 state 目录 chmod 700、迁移旧状态、配置指向 state/' {
        $shSource -match 'OAUTH_STATE_DIR=' | Should -BeTrue
        $shSource -match 'chmod 700 "\$OAUTH_STATE_DIR"' | Should -BeTrue
        $shSource -match 'mv "\$LEGACY_OAUTH_STATE"' | Should -BeTrue
        $shSource -match 'state/oauth_state\.json' | Should -BeTrue
    }
}
