# bridge/secrets.ps1 —— 密钥生成（本文件必须 UTF-8 带 BOM；被 setup.ps1 点源引用，被 tests/setup-acl.Tests.ps1 直接测试）
# 2026-08-17 根因：原 New-Password 用固定模数 59 但字母表实际 57 字符，
# 越界索引返回 $null → NUL 字符混入密码（实测 42% 概率）→ NUL 字节写进 env 文件
# → cmd 的 for /f 文本模式读到 NUL 即停止 → 全部环境变量加载失败。
# 修复：按字母表实际长度取模 + 拒绝采样上限 = floor(255/n)*n，杜绝越界。
function New-Token {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] 32
    $rng.GetBytes($buf)
    return (-join ($buf | ForEach-Object { $_.ToString('x2') }))
}
function New-Password {
    param([int]$Length = 16)
    # 57 字符字母表（去易混 0O1lI）；拒绝采样保证均匀且索引永不越界
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $n = $alphabet.Length
    $limit = [math]::Floor(255 / $n) * $n
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $chars = New-Object System.Collections.Generic.List[char]
    while ($chars.Count -lt $Length) {
        $b = New-Object byte[] 1
        $rng.GetBytes($b)
        if ($b[0] -ge $limit) { continue }
        $chars.Add($alphabet[$b[0] % $n])
    }
    return (-join $chars)
}
