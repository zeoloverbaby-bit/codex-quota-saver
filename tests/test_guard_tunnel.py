# tests/test_guard_tunnel.py —— auth_mode=public|tunnel 条件式配置与 fail-closed loopback（PoC-B）
"""覆盖 Secure MCP Tunnel PoC-B 的最小验收：
1. legacy/default：config 无 auth_mode → public，PUBLIC keys 仍然必需
2. explicit public：行为不变（PUBLIC keys 必需）
3. tunnel 合法 config：COMMON keys + loopback host → 校验通过，且不要求 PUBLIC keys
4. tunnel 不要求 CQS_OAUTH_PASSWORD（环境 preflight）
5. tunnel fail-closed：host=0.0.0.0 与一个非 loopback IP（192.0.2.10，TEST-NET-1）
6. unknown auth_mode → fail-fast
7. capability contract：tunnel 模式经 make_guard 后的 app 依然
   tools/list == exact planner contract + write_next_step；apply_patch/exec_command 类
   工具在协议层不存在（复用 0.3.0 catalog 锚定，同 test_guard.py 口径）
"""
import asyncio
import contextlib
import json
import os
import sys

import httpx2
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge", "guard"))
import guard  # noqa: E402
import guard_lib  # noqa: E402

from mcp.client.session import ClientSession  # noqa: E402
from mcp.client.streamable_http import streamable_http_client  # noqa: E402
from mcp.server.lowlevel import Server  # noqa: E402
from mcp.shared.memory import create_client_server_memory_streams  # noqa: E402
from mcp.types import CallToolResult, ListToolsResult, TextContent, Tool  # noqa: E402

TUNNEL_MCP = "http://127.0.0.1:8766/mcp"


def _base_cfg(**overrides):
    cfg = {
        "host": "127.0.0.1",
        "port": 8766,
        "workspace": "C:/Temp/cqs-tunnel-poc",
        "upstream_url": "http://127.0.0.1:8765/mcp",
        "upstream_token_env": "CQS_UPSTREAM_TOKEN",
        "allowlist": ["server_info", "read_file", "view_image"],
    }
    cfg.update(overrides)
    return cfg


def _public_cfg(**overrides):
    cfg = _base_cfg(
        public_url="https://public.example.com",
        oauth_password_env="CQS_OAUTH_PASSWORD",
        oauth_state_file="state/oauth_state.json",
    )
    cfg.update(overrides)
    return cfg


def _write_cfg(tmp_path, cfg):
    p = tmp_path / "guard_config.json"
    p.write_text(json.dumps(cfg), encoding="utf-8")
    return str(p)


# ---- 1. legacy / default compatibility ----

def test_legacy_config_without_auth_mode_is_public_and_requires_oauth_keys(tmp_path):
    """旧 config 不含 auth_mode → 解释为 public → OAuth-required keys 仍然要求存在。"""
    legacy = _base_cfg()  # 没有 auth_mode，也没有 public_url 等
    with pytest.raises(SystemExit) as exc:
        guard.load_config(_write_cfg(tmp_path, legacy))
    assert "public" in str(exc.value)
    assert "public_url" in str(exc.value)

    full_legacy = _public_cfg()
    loaded = guard.load_config(_write_cfg(tmp_path, full_legacy))
    assert guard.resolve_auth_mode(loaded) == "public"


# ---- 2. explicit public ----

def test_explicit_public_requires_public_keys(tmp_path):
    with pytest.raises(SystemExit) as exc:
        guard.load_config(_write_cfg(tmp_path, {**_base_cfg(), "auth_mode": "public"}))
    assert "public" in str(exc.value)
    assert "public_url" in str(exc.value)

    loaded = guard.load_config(_write_cfg(tmp_path, {**_public_cfg(), "auth_mode": "public"}))
    assert guard.resolve_auth_mode(loaded) == "public"


# ---- 3. tunnel config validation ----

def test_tunnel_config_loopback_common_only_validates(tmp_path):
    """auth_mode=tunnel + loopback host + COMMON keys、无 public_url/oauth_password_env/
    oauth_state_file → config validation 成功。"""
    cfg = {**_base_cfg(), "auth_mode": "tunnel"}
    loaded = guard.load_config(_write_cfg(tmp_path, cfg))
    assert guard.resolve_auth_mode(loaded) == "tunnel"


def test_tunnel_config_missing_common_key_fails(tmp_path):
    for missing in guard.COMMON_REQUIRED:
        cfg = {**_base_cfg(), "auth_mode": "tunnel"}
        cfg.pop(missing)
        with pytest.raises(SystemExit) as exc:
            guard.load_config(_write_cfg(tmp_path, cfg))
        assert missing in str(exc.value), missing


# ---- 4. tunnel environment preflight（不要求 CQS_OAUTH_PASSWORD）----

def test_tunnel_env_preflight_requires_upstream_token_only():
    cfg = {**_base_cfg(), "auth_mode": "tunnel"}
    assert guard.required_env_names(cfg, "tunnel") == ["CQS_UPSTREAM_TOKEN"]

    public = _public_cfg()
    assert guard.required_env_names(public, "public") == ["CQS_UPSTREAM_TOKEN", "CQS_OAUTH_PASSWORD"]


def test_tunnel_env_preflight_does_not_fail_without_oauth_password():
    """tunnel mode 没有 CQS_OAUTH_PASSWORD → environment preflight 不失败。"""
    cfg = {**_base_cfg(), "auth_mode": "tunnel"}
    assert "CQS_OAUTH_PASSWORD" not in guard.required_env_names(cfg, "tunnel")


# ---- 5. tunnel fail-closed network binding ----

@pytest.mark.parametrize("bad_host", ["0.0.0.0", "192.0.2.10", "::", "localhost", "10.0.0.5"])
def test_tunnel_non_loopback_host_fails_fast(tmp_path, bad_host):
    cfg = {**_base_cfg(), "auth_mode": "tunnel", "host": bad_host}
    with pytest.raises(SystemExit) as exc:
        guard.load_config(_write_cfg(tmp_path, cfg))
    assert "loopback" in str(exc.value) or "localhost" in str(exc.value)


@pytest.mark.parametrize("good_host", ["127.0.0.1", "::1"])
def test_tunnel_loopback_host_passes(tmp_path, good_host):
    cfg = {**_base_cfg(), "auth_mode": "tunnel", "host": good_host}
    loaded = guard.load_config(_write_cfg(tmp_path, cfg))
    assert guard.resolve_auth_mode(loaded) == "tunnel"


# ---- 6. unknown auth_mode ----

def test_unknown_auth_mode_fails_fast(tmp_path):
    cfg = {**_base_cfg(), "auth_mode": "magic"}
    with pytest.raises(SystemExit) as exc:
        guard.load_config(_write_cfg(tmp_path, cfg))
    assert "magic" in str(exc.value)


# ---- 7. capability contract（tunnel 模式 app 层）----

@contextlib.asynccontextmanager
async def _run_lifespan(app):
    startup = asyncio.Event()
    shutdown = asyncio.Event()

    async def receive():
        if not startup.is_set():
            return {"type": "lifespan.startup"}
        await shutdown.wait()
        return {"type": "lifespan.shutdown"}

    async def send(message):
        if message["type"] == "lifespan.startup.complete":
            startup.set()
        elif message["type"] == "lifespan.startup.failed":
            raise RuntimeError(f"lifespan startup failed: {message.get('message')}")

    task = asyncio.create_task(app({"type": "lifespan", "asgi": {"version": "3.0"}}, receive, send))
    await asyncio.wait_for(startup.wait(), timeout=15)
    try:
        yield
    finally:
        shutdown.set()
        await asyncio.wait_for(task, timeout=15)


UPSTREAM_030_CATALOG = {
    "server_info": True, "check_exec_environment": True,
    "read_file": True, "list_dir": True, "list_files": True, "search_text": True,
    "apply_patch": False, "exec_command": False, "write_stdin": False,
    "kill_command": False, "read_output": True,
    "git_status": True, "git_diff": True, "git_log": True, "git_show": True, "git_blame": True,
    "request_permissions": True, "view_image": True,
}

PLANNER_ALLOWED = {
    "server_info", "read_file", "list_dir", "list_files", "search_text", "view_image",
    "git_status", "git_diff", "git_log", "git_show", "git_blame",
}
FORBIDDEN = set(UPSTREAM_030_CATALOG) - PLANNER_ALLOWED


async def _fake_upstream_030():
    async def on_list_tools(ctx, params):
        return ListToolsResult(tools=[
            Tool(name=n, description=f"0.3.0 tool {n}",
                 input_schema={"type": "object", "properties": {}})
            for n in sorted(UPSTREAM_030_CATALOG)
        ])

    async def on_call_tool(ctx, params):
        return CallToolResult(content=[TextContent(type="text", text=f"ok:{params.name}")], is_error=False)

    return Server("fake-upstream-030", on_list_tools=on_list_tools, on_call_tool=on_call_tool)


@contextlib.asynccontextmanager
async def _tunnel_http_guard(tmp_path):
    """tunnel 模式现场接线复刻：guard.streamable_http_app 不传 token_verifier / auth /
    custom_starlette_routes，只传 loopback transport_security。"""
    async with create_client_server_memory_streams() as (client_streams, server_streams):
        fake = await _fake_upstream_030()
        fake_task = asyncio.create_task(fake.run(*server_streams, fake.create_initialization_options()))
        async with ClientSession(*client_streams) as upstream:
            await upstream.initialize()
            guard_app = guard_lib.make_guard(
                upstream, allowlist=PLANNER_ALLOWED, workspace=str(tmp_path))
            app = guard_app.streamable_http_app(
                streamable_http_path="/mcp",
                host="127.0.0.1",
                transport_security=guard.LOOPBACK_TRANSPORT_SECURITY,
            )
            async with _run_lifespan(app):
                yield app
        fake_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await fake_task


def test_tunnel_app_contract_and_forbidden_tools(tmp_path):
    """tunnel 模式最终依然经 make_guard：tools/list == exact planner contract +
    write_next_step；forbidden（apply_patch/exec_command/write_stdin/kill_command/
    read_output/request_permissions）不可见，直接调用 is_error 且零转发；write_next_step 可用。"""
    async def scenario():
        async with _tunnel_http_guard(tmp_path) as app:
            transport = httpx2.ASGITransport(app=app)
            http = httpx2.AsyncClient(transport=transport)
            async with streamable_http_client(TUNNEL_MCP, http_client=http) as streams:
                r_stream, w_stream = streams
                async with ClientSession(r_stream, w_stream) as c:
                    await c.initialize()
                    tools = {t.name for t in (await c.list_tools()).tools}
                    assert tools == PLANNER_ALLOWED | {"write_next_step"}
                    for t in (await c.list_tools()).tools:
                        assert t.output_schema is None
                    # allowed forwarded
                    r = await c.call_tool("read_file", {"path": "a"})
                    assert r.is_error is False and r.content[0].text == "ok:read_file"
                    # forbidden：is_error 且不转发（本测试上游会返回 ok:*，若被转发
                    # is_error 会是 False，因此 is_error=True 本身就证明零转发）
                    for name in sorted(FORBIDDEN):
                        blocked = await c.call_tool(name, {})
                        assert blocked.is_error is True, name
                        assert "not allowed" in blocked.content[0].text, name
                    # write_next_step 完整可用
                    w = await c.call_tool("write_next_step", {"content": "# tunnel poc"})
                    assert w.is_error is False
            assert (tmp_path / ".codex" / "next-step.md").read_text(encoding="utf-8") == "# tunnel poc"

    asyncio.run(scenario())
