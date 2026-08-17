# tests/test_guard.py —— bridge-guard 单测（mcp SDK 2.0：构造器注入 + 内存流）
"""白名单过滤 / write_next_step 固定路径 / 认证判定。
上游用内存流假 MCP server（read_file 只读 + apply_patch 写），guard 挂在其后。
"""
import asyncio
import contextlib
import os
import sys

import pytest

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


def test_write_next_step_symlink_rejected_via_call_tool_is_error_and_session_survives(tmp_path):
    """威胁 A 必须经 MCP 层返回 is_error=True 工具结果（而非协议层 JSON-RPC 错误），
    且同一会话后续只读工具仍可用——安全拒绝不得变成 bridge 可用性故障。"""
    async def scenario():
        ws = tmp_path / "repo"
        ws.mkdir()
        outside = tmp_path / "outside"
        outside.mkdir()
        _symlink_or_skip(outside, ws / ".codex", target_is_directory=True)
        async with _guard_session(str(ws)) as (client, guard):
            r = await client.call_tool("write_next_step", {"content": "escape"})
            assert r.is_error is True
            assert "拒绝" in r.content[0].text
            # 会话存活：后续允许的只读工具照常工作
            ok = await client.call_tool("read_file", {"path": "a"})
            assert ok.is_error is False
            assert ok.content[0].text == "ok:read_file"
        assert not (outside / "next-step.md").exists()
    _run(scenario())


def test_write_next_step_file_symlink_rejected_via_call_tool_is_error(tmp_path):
    """威胁 B（next-step.md 本身是指向外部的符号链接）同样经 MCP 层返回 is_error=True。"""
    async def scenario():
        ws = tmp_path / "repo"
        (ws / ".codex").mkdir(parents=True)
        victim = tmp_path / "victim.md"
        victim.write_text("SECRET", encoding="utf-8")
        _symlink_or_skip(victim, ws / ".codex" / "next-step.md")
        async with _guard_session(str(ws)) as (client, guard):
            r = await client.call_tool("write_next_step", {"content": "overwrite"})
            assert r.is_error is True
            assert "拒绝" in r.content[0].text
            ok = await client.call_tool("read_file", {"path": "a"})
            assert ok.is_error is False
        assert victim.read_text(encoding="utf-8") == "SECRET"
    _run(scenario())


def test_write_next_step_function_fixed_path(tmp_path):
    ws = tmp_path / "repo"
    n = guard_lib.write_next_step(str(ws), "# hello\nnext")
    p = ws / ".codex" / "next-step.md"
    assert p.read_text(encoding="utf-8") == "# hello\nnext"
    assert n > 0


# ---- 物理边界：logical path 固定 ≠ physical target 固定（symlink escape 防逃逸）----

def _symlink_or_skip(src, dst, target_is_directory=False):
    """尽力创建链接；Windows 无特权时：目录回退 junction（mklink /J 免特权），文件链接则 skip。"""
    try:
        dst.symlink_to(src, target_is_directory=target_is_directory)
        return
    except (OSError, NotImplementedError) as exc:
        if os.name == "nt" and target_is_directory:
            import subprocess
            try:
                subprocess.run(["cmd", "/c", "mklink", "/J", str(dst), str(src)],
                               check=True, capture_output=True)
                return
            except subprocess.CalledProcessError:
                pytest.skip(f"目录链接不可用: {exc}")
        if os.name == "nt":
            pytest.skip(f"symlink 不可用（Windows 特权限制）: {exc}")
        raise


def test_write_next_step_rejects_codex_dir_symlink(tmp_path):
    """威胁 A：<workspace>/.codex 指向外部目录——必须拒绝，外部目录不得出现新文件。"""
    ws = tmp_path / "repo"
    ws.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    _symlink_or_skip(outside, ws / ".codex", target_is_directory=True)
    with pytest.raises(guard_lib.NextStepWriteError):
        guard_lib.write_next_step(str(ws), "escape")
    assert not (outside / "next-step.md").exists()


def test_write_next_step_rejects_file_symlink(tmp_path):
    """威胁 B：next-step.md 本身指向外部文件——必须拒绝，外部文件内容字节不变。"""
    ws = tmp_path / "repo"
    (ws / ".codex").mkdir(parents=True)
    victim = tmp_path / "victim.md"
    victim.write_text("SECRET", encoding="utf-8")
    _symlink_or_skip(victim, ws / ".codex" / "next-step.md")
    with pytest.raises(guard_lib.NextStepWriteError):
        guard_lib.write_next_step(str(ws), "overwrite")
    assert victim.read_text(encoding="utf-8") == "SECRET"


def test_write_next_step_workspace_symlink_writes_inside_real_workspace(tmp_path):
    """workspace 路径本身是 symlink（合法部署形态）：canonicalize 后照常写入真实目录。"""
    real_ws = tmp_path / "real-ws"
    real_ws.mkdir()
    ws_link = tmp_path / "ws-link"
    _symlink_or_skip(real_ws, ws_link, target_is_directory=True)
    n = guard_lib.write_next_step(str(ws_link), "# v1")
    p = real_ws / ".codex" / "next-step.md"
    assert p.read_text(encoding="utf-8") == "# v1"
    assert n > 0


# ---- 工具契约：锚定 coding-tools-mcp 0.3.0 真实目录（TOOL_REGISTRY server.py:570-697）----
# 上游升级（目录增删/改名）时必须先更新本契约再改 allowlist——本测试是防漂移锚点。

UPSTREAM_030_CATALOG = {
    # name -> read_only（官方 ToolSpec 标注）
    "server_info": True, "check_exec_environment": True,
    "read_file": True, "list_dir": True, "list_files": True, "search_text": True,
    "apply_patch": False, "exec_command": False, "write_stdin": False,
    "kill_command": False, "read_output": True,
    "git_status": True, "git_diff": True, "git_log": True, "git_show": True, "git_blame": True,
    "request_permissions": True, "view_image": True,
}

# Capability Taxonomy：Planner 最小充分认知权限（repository_read + git_read）+ handoff
PLANNER_ALLOWED = {
    "server_info", "read_file", "list_dir", "list_files", "search_text", "view_image",
    "git_status", "git_diff", "git_log", "git_show", "git_blame",
}
# diagnostics（execution runtime state / mutation 通道）+ mutation/process control：协议层不存在
FORBIDDEN = set(UPSTREAM_030_CATALOG) - PLANNER_ALLOWED


@contextlib.asynccontextmanager
async def _guard_session_catalog(workspace):
    """假上游按 0.3.0 完整 18 工具目录注册；记录被 guard 转发的调用（禁止工具必须零转发）。"""
    calls = []

    async def on_list_tools(ctx, params):
        return ListToolsResult(tools=[
            Tool(name=n, description=f"0.3.0 tool {n}",
                 input_schema={"type": "object", "properties": {}})
            for n in sorted(UPSTREAM_030_CATALOG)
        ])

    async def on_call_tool(ctx, params):
        calls.append(params.name)
        return CallToolResult(content=[TextContent(type="text", text=f"ok:{params.name}")], is_error=False)

    fake = Server("fake-upstream-030", on_list_tools=on_list_tools, on_call_tool=on_call_tool)
    async with create_client_server_memory_streams() as (client_streams, server_streams):
        fake_task = asyncio.create_task(fake.run(*server_streams, fake.create_initialization_options()))
        async with ClientSession(*client_streams) as upstream_client:
            await upstream_client.initialize()
            guard = guard_lib.make_guard(upstream_client, allowlist=PLANNER_ALLOWED, workspace=workspace)
            async with create_client_server_memory_streams() as (gc, gs):
                guard_task = asyncio.create_task(guard.run(*gs, guard.create_initialization_options()))
                async with ClientSession(*gc) as guard_client:
                    await guard_client.initialize()
                    yield guard_client, calls
                guard_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await guard_task
        fake_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await fake_task


def test_tools_list_is_exact_planner_contract_against_030_catalog(tmp_path):
    """tools/list == repository_read + git_read（11）+ write_next_step；目录锚定 0.3.0。"""
    async def scenario():
        async with _guard_session_catalog(str(tmp_path)) as (client, calls):
            tools = {t.name for t in (await client.list_tools()).tools}
            assert tools == PLANNER_ALLOWED | {"write_next_step"}
            for t in (await client.list_tools()).tools:
                assert t.output_schema is None
    _run(scenario())


def test_forbidden_tools_error_without_forwarding(tmp_path):
    """白名单外工具（含 read_output/request_permissions 等 read 名）强调用 is_error 且零转发。"""
    async def scenario():
        async with _guard_session_catalog(str(tmp_path)) as (client, calls):
            for name in sorted(FORBIDDEN):
                r = await client.call_tool(name, {})
                assert r.is_error is True, name
                assert "not allowed" in r.content[0].text, name
            assert calls == []  # 上游零转发：禁止工具在协议层不存在
    _run(scenario())


def test_planner_allowed_tools_forwarded(tmp_path):
    async def scenario():
        async with _guard_session_catalog(str(tmp_path)) as (client, calls):
            for name in sorted(PLANNER_ALLOWED):
                r = await client.call_tool(name, {})
                assert r.is_error is False, name
                assert r.content[0].text == f"ok:{name}"
            assert sorted(calls) == sorted(PLANNER_ALLOWED)
    _run(scenario())
