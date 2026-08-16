# tests/test_guard.py —— bridge-guard 单测（mcp SDK 2.0：构造器注入 + 内存流）
"""白名单过滤 / write_next_step 固定路径 / 认证判定。
上游用内存流假 MCP server（read_file 只读 + apply_patch 写），guard 挂在其后。
"""
import asyncio
import contextlib
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge", "guard"))
import guard_lib  # noqa: E402

from mcp.server.lowlevel import Server  # noqa: E402
from mcp.client.session import ClientSession  # noqa: E402
from mcp.shared.memory import create_client_server_memory_streams  # noqa: E402
from mcp.types import Tool, TextContent, ListToolsResult, CallToolResult  # noqa: E402


async def _fake_upstream():
    async def on_list_tools(ctx, params):
        return ListToolsResult(tools=[
            Tool(name="read_file", description="read",
                 input_schema={"type": "object", "properties": {"path": {"type": "string"}}}),
            Tool(name="apply_patch", description="write",
                 input_schema={"type": "object", "properties": {"patch": {"type": "string"}}}),
        ])

    async def on_call_tool(ctx, params):
        return CallToolResult(content=[TextContent(type="text", text=f"ok:{params.name}")], is_error=False)

    return Server("fake-upstream", on_list_tools=on_list_tools, on_call_tool=on_call_tool)


@contextlib.asynccontextmanager
async def _guard_session(workspace):
    """起假上游 + 真 guard，返回可调用 guard 的 client。
    SDK 2.0：Server.run 是普通 async 函数（后台任务 + cancel）；
    ClientSession 是异步上下文管理器（async with 才启动 dispatcher）。"""
    async with create_client_server_memory_streams() as (client_streams, server_streams):
        fake = await _fake_upstream()
        fake_task = asyncio.create_task(fake.run(*server_streams, fake.create_initialization_options()))
        async with ClientSession(*client_streams) as upstream_client:
            await upstream_client.initialize()
            guard = guard_lib.make_guard(upstream_client, allowlist={"read_file"}, workspace=workspace)
            async with create_client_server_memory_streams() as (gc, gs):
                guard_task = asyncio.create_task(guard.run(*gs, guard.create_initialization_options()))
                async with ClientSession(*gc) as guard_client:
                    await guard_client.initialize()
                    yield guard_client, guard
                guard_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await guard_task
        fake_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await fake_task


def _run(scenario):
    return asyncio.run(scenario)


def test_list_only_allowlist_plus_write_next_step_no_schema(tmp_path):
    async def scenario():
        async with _guard_session(str(tmp_path)) as (client, guard):
            tools = {t.name: t for t in (await client.list_tools()).tools}
            assert set(tools) == {"read_file", "write_next_step"}
            assert "apply_patch" not in tools
            for t in tools.values():
                assert t.output_schema is None
    _run(scenario())


def test_call_allowed_forwarded_and_blocked_is_error(tmp_path):
    async def scenario():
        async with _guard_session(str(tmp_path)) as (client, guard):
            ok = await client.call_tool("read_file", {"path": "a"})
            assert ok.is_error is False
            assert ok.content[0].text == "ok:read_file"
            blocked = await client.call_tool("apply_patch", {"patch": "x"})
            assert blocked.is_error is True
            assert "not allowed" in blocked.content[0].text
    _run(scenario())


def test_write_next_step_via_tool_writes_fixed_path_only(tmp_path):
    async def scenario():
        async with _guard_session(str(tmp_path)) as (client, guard):
            r = await client.call_tool("write_next_step", {"content": "# hello\nnext"})
            assert r.is_error is False
        p = tmp_path / ".codex" / "next-step.md"
        assert p.read_text(encoding="utf-8") == "# hello\nnext"
        # 覆盖式
        async with _guard_session(str(tmp_path)) as (client, guard):
            await client.call_tool("write_next_step", {"content": "v2"})
        assert p.read_text(encoding="utf-8") == "v2"
    _run(scenario())


def test_write_next_step_ignores_extra_path_argument(tmp_path):
    """传 path 参数必须被忽略——路径只能由服务端固定。"""
    async def scenario():
        async with _guard_session(str(tmp_path)) as (client, guard):
            r = await client.call_tool("write_next_step",
                                       {"content": "v3", "path": str(tmp_path / "evil.md")})
            assert r.is_error is False
        assert (tmp_path / ".codex" / "next-step.md").read_text(encoding="utf-8") == "v3"
        assert not (tmp_path / "evil.md").exists()
    _run(scenario())


def test_write_next_step_function_fixed_path(tmp_path):
    ws = tmp_path / "repo"
    n = guard_lib.write_next_step(str(ws), "# hello\nnext")
    p = ws / ".codex" / "next-step.md"
    assert p.read_text(encoding="utf-8") == "# hello\nnext"
    assert n > 0


def test_token_verifier():
    async def scenario():
        v = guard_lib.GuardTokenVerifier("secret")
        assert await v.verify_token("secret") is not None
        assert await v.verify_token("wrong") is None
        assert await v.verify_token("") is None
    _run(scenario())
