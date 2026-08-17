# bridge/acl.ps1 —— ACL 收紧辅助（本文件必须 UTF-8 带 BOM；被 setup.ps1 点源引用，被 tests/setup-acl.Tests.ps1 直接测试）
# Rights 语义（icacls 语法）：
#   '(R,W)'  secrets 类（只被读取，永不执行）——默认值
#   '(RX,W)' launcher 类（需双击执行）：Windows 资源管理器双击 .bat 要求执行权限，
#            缺 X 会报「Windows 无法访问指定设备、路径或文件。你可能没有适当的权限访问该项目」
function Tighten-Acl([string]$Path, [string]$Rights = '(R,W)') {
    icacls $Path /inheritance:r /grant:r "${env:USERNAME}:$Rights" | Out-Null
}
