# bridge/guard/guard_lib.py —— bridge-guard 纯逻辑层（HTTP 无关，便于单测）
"""mcp SDK 2.0 构造器注入风格。教训（2026-08-16）：
- tools/list 不得声明 output_schema、响应不含 structured_content（OpenAI 连接器 TaskGroup 崩溃相关）
- 白名单外的工具调用返回 is_error=True 的标准错误结果，不抛异常、不转发
"""
import contextlib
import os
import tempfile

from mcp.server.lowlevel import Server
from mcp.types import Tool, TextContent, ListToolsResult, CallToolResult

NEXT_STEP_REL = os.path.join(".codex", "next-step.md")

WRITE_NEXT_STEP_TOOL = Tool(
    name="write_next_step",
    description=(
        "全量覆盖写 .codex/next-step.md（服务端固定路径，不接受任意路径参数）。"
        "分析层用它给执行层下达唯一下一步指令：当前状态/下一步任务/验证步骤/风险提示。"
    ),
    input_schema={
        "type": "object",
        "properties": {"content": {"type": "string", "description": "next-step.md 全文"}},
        "required": ["content"],
    },
)


class NextStepWriteError(Exception):
    """write_next_step 的安全拒绝：物理目标不是 workspace 内的普通文件。"""


def write_next_step(workspace: str, content: str) -> int:
    """硬编码：只能写 <workspace>/.codex/next-step.md。返回写入字符数。

    物理边界（fail-closed）：
    - .codex 或 next-step.md 是符号链接 → 拒绝（绝不 follow）；
    - 解析后的真实父目录必须仍位于 canonical workspace 内——兜底 Windows
      junction（islink 对 junction 返回 False，但 realpath 会解析它）；
    - 同目录临时文件 + fsync + os.replace 原子写入：不留半文件，且 rename
      替换的是目录项本身、不会跟随目标链接。
    注：检查与写入之间仍有 TOCTOU 窗口；威胁模型是"仓库内已存在的静态链接"，
    并发本地攻击者的竞态属已知残余风险（见 SECURITY.md）。
    """
    if not workspace:
        raise ValueError("workspace not configured")
    canonical_ws = os.path.realpath(workspace)
    target_dir = os.path.join(canonical_ws, ".codex")
    p = os.path.join(target_dir, "next-step.md")
    if os.path.islink(target_dir):
        raise NextStepWriteError(".codex 是符号链接：拒绝写入（可能指向 workspace 外）")
    if os.path.islink(p):
        raise NextStepWriteError("next-step.md 是符号链接：拒绝覆盖链接目标")
    os.makedirs(target_dir, exist_ok=True)
    resolved_parent = os.path.realpath(target_dir)
    if not (resolved_parent == canonical_ws or resolved_parent.startswith(canonical_ws + os.sep)):
        raise NextStepWriteError("目标目录解析后超出 workspace 边界，拒绝写入")
    fd, tmp_name = tempfile.mkstemp(dir=resolved_parent, prefix=".next-step.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, os.path.join(resolved_parent, "next-step.md"))
    except BaseException:
        with contextlib.suppress(OSError):
            os.remove(tmp_name)
        raise
    return len(content)


def make_guard(upstream_session, allowlist: set, workspace: str) -> Server:
    """upstream_session = 已 initialize 的 mcp.client.session.ClientSession。
    白名单外的上游工具在协议层不存在；write_next_step 由 guard 自实现。
    """

    async def on_list_tools(ctx, params):
        up = {t.name: t for t in (await upstream_session.list_tools()).tools}
        exposed = [up[n] for n in sorted(allowlist) if n in up]
        exposed.append(WRITE_NEXT_STEP_TOOL)
        return ListToolsResult(tools=exposed)

    async def on_call_tool(ctx, params):
        name = params.name
        arguments = params.arguments or {}
        if name == "write_next_step":
            # 只读 content；任何 path 参数一律忽略——路径由服务端固定
            n = write_next_step(workspace, arguments.get("content", ""))
            return CallToolResult(
                content=[TextContent(type="text", text=f"written {n} chars to {NEXT_STEP_REL}")],
                is_error=False,
            )
        if name not in allowlist:
            return CallToolResult(
                content=[TextContent(type="text", text=f"tool not allowed by bridge-guard allowlist: {name}")],
                is_error=True,
            )
        return await upstream_session.call_tool(name, arguments)

    return Server("bridge-guard", on_list_tools=on_list_tools, on_call_tool=on_call_tool)
