# bridge/acl.ps1 —— ACL 收紧辅助（本文件必须 UTF-8 带 BOM；被 setup.ps1 点源引用，被 tests/setup-acl.Tests.ps1 直接测试）
# Rights 语义（icacls 语法）：
#   '(R,W)'  secrets 类（只被读取，永不执行）——默认值
#   '(RX,W)' launcher 类（需双击执行）：Windows 资源管理器双击 .bat 要求执行权限，
#            缺 X 会报「Windows 无法访问指定设备、路径或文件。你可能没有适当的权限访问该项目」
function Tighten-Acl([string]$Path, [string]$Rights = '(R,W)') {
    if (Test-Path $Path -PathType Container) {
        # 目录：ACE 必须带 (OI)(CI) 继承标志——新建子文件才继承当前用户专用权限。
        # 否则子文件拿创建进程 token 的默认 DACL（含 SYSTEM FullControl + 登录会话 SID），
        # 目录收紧形同虚设（2026-08-17 实测取证）。
        # 补 D（Delete）：目录内文件需要能被当前用户删除（如删 oauth_state.json 重新授权），
        # 纯 (R,W) 缺 Delete——连 owner 自己都删不掉（实测 Access denied）。
        # 注意 icacls 不接受嵌套括号（(R,W),D 会 Invalid）——先把 $Rights 外层括号剥掉再组合。
        $inner = $Rights.Trim('()')
        icacls $Path /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)($inner,D)" | Out-Null
    } else {
        icacls $Path /inheritance:r /grant:r "${env:USERNAME}:$Rights" | Out-Null
    }
}
