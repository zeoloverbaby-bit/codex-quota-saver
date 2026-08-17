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
