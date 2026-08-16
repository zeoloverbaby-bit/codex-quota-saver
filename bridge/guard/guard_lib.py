# bridge/guard/guard_lib.py —— bridge-guard 纯逻辑层（HTTP 无关，便于单测）
"""mcp SDK 2.0 构造器注入风格。教训（2026-08-16）：
- tools/list 不得声明 output_schema、响应不含 structured_content（OpenAI 连接器 TaskGroup 崩溃相关）
- 白名单外的工具调用返回 is_error=True 的标准错误结果，不抛异常、不转发
"""
import os

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


def write_next_step(workspace: str, content: str) -> int:
    """硬编码：只能写 <workspace>/.codex/next-step.md。返回写入字符数。"""
    if not workspace:
        raise ValueError("workspace not configured")
    p = os.path.join(workspace, NEXT_STEP_REL)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(content)
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
