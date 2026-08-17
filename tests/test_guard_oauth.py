# tests/test_guard_oauth.py —— guard 自建 OAuth 2.1 授权服务器测试
"""覆盖：DCR 注册 → authorize 重定向 → 密码页（错密码 401 / 对密码发码）→ PKCE token 交换
→ Bearer 调 MCP（白名单 + write_next_step）→ 无 token / 坏 token 401 → 重启免疫。
HTTP 层用 httpx2.ASGITransport 进程内跑真 Starlette app（lifespan 手动驱动）。
"""
import asyncio
import base64
import contextlib
import hashlib
import os
import secrets
import stat
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import httpx2
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge", "guard"))
import guard  # noqa: E402
import guard_lib  # noqa: E402
import oauth_provider  # noqa: E402

from mcp.client.session import ClientSession  # noqa: E402
from mcp.client.streamable_http import streamable_http_client  # noqa: E402
from mcp.server.auth.provider import (  # noqa: E402
    AuthorizationCode,
    AuthorizationParams,
    AuthorizeError,
    ProviderTokenVerifier,
    RegistrationError,
)
from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions  # noqa: E402
from mcp.server.lowlevel import Server  # noqa: E402
from mcp.shared.auth import OAuthClientInformationFull  # noqa: E402
from mcp.shared.memory import create_client_server_memory_streams  # noqa: E402
from mcp.types import CallToolResult, ListToolsResult, TextContent, Tool  # noqa: E402

ISSUER = "http://localhost:8766"
RESOURCE = "http://localhost:8766/mcp"
PUBLIC_ISSUER = "https://public.example.com"
PUBLIC_RESOURCE = "https://public.example.com/mcp"
PASSWORD_ENV = "CQS_TEST_OAUTH_PASSWORD"
PASSWORD = "hunter2-test"
CALLBACK = "http://localhost:3000/callback"


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
async def _run_lifespan(app):
    """httpx2.ASGITransport 不跑 lifespan——手动驱动（等同 asgi-lifespan 的最小实现）。"""
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


@contextlib.asynccontextmanager
async def _http_guard(tmp_path):
    """假上游（内存流）+ 真 guard OAuth app（ASGI 进程内）。"""
    os.environ[PASSWORD_ENV] = PASSWORD
    state_path = str(tmp_path / "state" / "oauth_state.json")
    async with create_client_server_memory_streams() as (client_streams, server_streams):
        fake = await _fake_upstream()
        fake_task = asyncio.create_task(fake.run(*server_streams, fake.create_initialization_options()))
        async with ClientSession(*client_streams) as upstream:
            await upstream.initialize()
            guard = guard_lib.make_guard(upstream, allowlist={"read_file"}, workspace=str(tmp_path))
            provider = oauth_provider.GuardOAuthProvider(
                state_path=state_path, issuer=ISSUER, resource_url=RESOURCE, password_env=PASSWORD_ENV)
            auth = AuthSettings(issuer_url=ISSUER, resource_server_url=RESOURCE)
            app = guard.streamable_http_app(
                streamable_http_path="/mcp",
                host="localhost",
                token_verifier=ProviderTokenVerifier(provider),
                auth=auth,
                custom_starlette_routes=(
                    oauth_provider.create_guard_auth_routes(provider, ISSUER, ClientRegistrationOptions(enabled=True))
                    + oauth_provider.create_login_routes(provider)
                ),
            )
            async with _run_lifespan(app):
                yield app, provider
        fake_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await fake_task


def _pkce():
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    return verifier, challenge


def _parse_redirect(location: str):
    parsed = urlparse(location)
    return {k: v[0] for k, v in parse_qs(parsed.query).items()}


async def _do_oauth_flow(http, client_id, verifier, challenge, password):
    """DCR 之后的部分：authorize → 登录 → code → token。返回 access_token。"""
    r = await http.get("/authorize", params={
        "response_type": "code", "client_id": client_id, "redirect_uri": CALLBACK,
        "code_challenge": challenge, "code_challenge_method": "S256", "state": "st123",
    }, follow_redirects=False)
    assert r.status_code == 302, r.text
    login_url = r.headers["location"]
    assert "/auth/login?request=" in login_url
    key = login_url.split("request=", 1)[1]
    assert "password" in (await http.get(login_url)).text
    r = await http.post("/auth/login", data={"request": key, "password": password}, follow_redirects=False)
    assert r.status_code == 302, r.text
    q = _parse_redirect(r.headers["location"])
    assert q.get("state") == "st123" and "code" in q
    r = await http.post("/token", data={
        "grant_type": "authorization_code", "code": q["code"],
        "redirect_uri": CALLBACK, "client_id": client_id, "code_verifier": verifier,
    })
    assert r.status_code == 200, r.text
    tok = r.json()
    assert tok["token_type"] == "Bearer" and tok["access_token"]
    return tok["access_token"]


def test_full_oauth_flow_end_to_end(tmp_path):
    async def scenario():
        async with _http_guard(tmp_path) as (app, provider):
            transport = httpx2.ASGITransport(app=app)
            async with httpx2.AsyncClient(transport=transport, base_url=ISSUER) as http:
                # 1. DCR 注册 public client（none）
                r = await http.post("/register", json={
                    "redirect_uris": [CALLBACK],
                    "token_endpoint_auth_method": "none",
                    "grant_types": ["authorization_code"],
                    "response_types": ["code"],
                    "client_name": "pytest-client",
                })
                assert r.status_code == 201, r.text
                client_id = r.json()["client_id"]

                # 2. well-known 元数据广告 none（ChatGPT 连接器 public client 需要）
                meta = (await http.get("/.well-known/oauth-authorization-server")).json()
                assert "none" in meta["token_endpoint_auth_methods_supported"]

                verifier, challenge = _pkce()

                # 3. 错密码 → 401，且同一请求可重试（不烧掉 pending）
                r = await http.get("/authorize", params={
                    "response_type": "code", "client_id": client_id, "redirect_uri": CALLBACK,
                    "code_challenge": challenge, "code_challenge_method": "S256",
                }, follow_redirects=False)
                key = r.headers["location"].split("request=", 1)[1]
                r = await http.post("/auth/login", data={"request": key, "password": "wrong"}, follow_redirects=False)
                assert r.status_code == 401
                r = await http.post("/auth/login", data={"request": key, "password": PASSWORD}, follow_redirects=False)
                assert r.status_code == 302

                # 4. 完整 OAuth 流程拿 token
                token = await _do_oauth_flow(http, client_id, verifier, challenge, PASSWORD)

                # 5. Bearer 调 MCP：白名单 + write_next_step
                mcp_http = httpx2.AsyncClient(
                    transport=transport, headers={"Authorization": f"Bearer {token}"})
                async with streamable_http_client(RESOURCE, http_client=mcp_http) as streams:
                    r_stream, w_stream = streams
                    async with ClientSession(r_stream, w_stream) as c:
                        await c.initialize()
                        tools = {t.name for t in (await c.list_tools()).tools}
                        assert tools == {"read_file", "write_next_step"}
                        ok = await c.call_tool("read_file", {"path": "a"})
                        assert ok.is_error is False and ok.content[0].text == "ok:read_file"
                        blocked = await c.call_tool("apply_patch", {"patch": "x"})
                        assert blocked.is_error is True
                        w = await c.call_tool("write_next_step", {"content": "# v1"})
                        assert w.is_error is False
                assert (tmp_path / ".codex" / "next-step.md").read_text(encoding="utf-8") == "# v1"

    asyncio.run(scenario())


def test_mcp_without_token_rejected(tmp_path):
    async def scenario():
        async with _http_guard(tmp_path) as (app, provider):
            transport = httpx2.ASGITransport(app=app)
            http = httpx2.AsyncClient(transport=transport)
            with pytest.raises(Exception):
                async with streamable_http_client(RESOURCE, http_client=http) as streams:
                    r_stream, w_stream = streams
                    async with ClientSession(r_stream, w_stream) as c:
                        await c.initialize()

    asyncio.run(scenario())


def test_mcp_with_bad_token_rejected(tmp_path):
    async def scenario():
        async with _http_guard(tmp_path) as (app, provider):
            transport = httpx2.ASGITransport(app=app)
            http = httpx2.AsyncClient(transport=transport, headers={"Authorization": "Bearer nope"})
            with pytest.raises(Exception):
                async with streamable_http_client(RESOURCE, http_client=http) as streams:
                    r_stream, w_stream = streams
                    async with ClientSession(r_stream, w_stream) as c:
                        await c.initialize()

    asyncio.run(scenario())


def test_provider_restart_immunity(tmp_path):
    """注册表 + token_secret 落盘：模拟重启（新建 Provider 实例）后，客户端与旧 token 都仍有效。"""
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        state = str(tmp_path / "oauth_state.json")
        kw = dict(state_path=state, issuer=ISSUER, resource_url=RESOURCE, password_env=PASSWORD_ENV)
        p1 = oauth_provider.GuardOAuthProvider(**kw)
        client = OAuthClientInformationFull.model_validate({
            "client_id": "client-1", "redirect_uris": [CALLBACK],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code"], "response_types": ["code"],
        })
        await p1.register_client(client)
        code = AuthorizationCode(
            code="c1", scopes=["mcp"], expires_at=time.time() + 300, client_id="client-1",
            code_challenge="x", redirect_uri=CALLBACK, redirect_uri_provided_explicitly=True)
        tok = await p1.exchange_authorization_code(client, code)

        # “重启”
        p2 = oauth_provider.GuardOAuthProvider(**kw)
        got = await p2.get_client("client-1")
        assert got is not None and got.client_id == "client-1"
        verified = await p2.load_access_token(tok.access_token)
        assert verified is not None and verified.client_id == "client-1"
        assert verified.scopes == ["mcp"]

    asyncio.run(scenario())


def test_provider_token_wrong_secret_rejected(tmp_path):
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        p1 = oauth_provider.GuardOAuthProvider(
            state_path=str(tmp_path / "s1.json"), issuer=ISSUER, resource_url=RESOURCE,
            password_env=PASSWORD_ENV)
        client = OAuthClientInformationFull.model_validate({
            "client_id": "c", "redirect_uris": [CALLBACK], "token_endpoint_auth_method": "none"})
        await p1.register_client(client)
        code = AuthorizationCode(code="c2", scopes=[], expires_at=time.time() + 300,
                                 client_id="c", code_challenge="x", redirect_uri=CALLBACK,
                                 redirect_uri_provided_explicitly=True)
        tok = await p1.exchange_authorization_code(client, code)
        # 不同 state 文件 → 不同密钥 → 拒绝
        p2 = oauth_provider.GuardOAuthProvider(
            state_path=str(tmp_path / "s2.json"), issuer=ISSUER, resource_url=RESOURCE,
            password_env=PASSWORD_ENV)
        assert await p2.load_access_token(tok.access_token) is None

    asyncio.run(scenario())


def test_provider_expired_token_rejected(tmp_path):
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        p = oauth_provider.GuardOAuthProvider(
            state_path=str(tmp_path / "s.json"), issuer=ISSUER, resource_url=RESOURCE,
            password_env=PASSWORD_ENV, ttl=-1)
        client = OAuthClientInformationFull.model_validate({
            "client_id": "c", "redirect_uris": [CALLBACK], "token_endpoint_auth_method": "none"})
        code = AuthorizationCode(code="c3", scopes=[], expires_at=time.time() + 300,
                                 client_id="c", code_challenge="x", redirect_uri=CALLBACK,
                                 redirect_uri_provided_explicitly=True)
        tok = await p.exchange_authorization_code(client, code)
        assert await p.load_access_token(tok.access_token) is None

    asyncio.run(scenario())


def test_provider_code_single_use_and_refresh_unsupported(tmp_path):
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        p = oauth_provider.GuardOAuthProvider(
            state_path=str(tmp_path / "s.json"), issuer=ISSUER, resource_url=RESOURCE,
            password_env=PASSWORD_ENV)
        client = OAuthClientInformationFull.model_validate({
            "client_id": "c", "redirect_uris": [CALLBACK], "token_endpoint_auth_method": "none"})
        code = AuthorizationCode(code="c4", scopes=[], expires_at=time.time() + 300,
                                 client_id="c", code_challenge="x", redirect_uri=CALLBACK,
                                 redirect_uri_provided_explicitly=True)
        p._codes["c4"] = code  # 模拟 complete_authorization 签发
        assert await p.load_authorization_code(client, "c4") is not None
        assert await p.load_authorization_code(client, "c4") is None  # 一次性
        assert await p.load_refresh_token(client, "whatever") is None
        with pytest.raises(Exception):
            await p.exchange_refresh_token(client, "whatever", [])

    asyncio.run(scenario())


def test_build_transport_security_allows_public_host():
    """guard.build_transport_security：公网域名 + 回环放行，其他 Host 421，POST 非 JSON 400。
    2026-08-17 现场：SDK 自动只放行回环 Host，公网 Host 全被 421 拒。"""
    async def scenario():
        from starlette.requests import Request

        from mcp.server.transport_security import TransportSecurityMiddleware

        ts = guard.build_transport_security(PUBLIC_ISSUER)
        assert ts.enable_dns_rebinding_protection is True
        assert "public.example.com" in ts.allowed_hosts
        assert "public.example.com:*" in ts.allowed_hosts

        mw = TransportSecurityMiddleware(ts)

        def make_request(host, content_type="application/json"):
            return Request({"type": "http", "headers": [
                (b"host", host.encode()), (b"content-type", content_type.encode()),
            ]})

        assert await mw.validate_request(make_request("public.example.com"), is_post=True) is None
        assert await mw.validate_request(make_request("public.example.com:443"), is_post=True) is None
        assert await mw.validate_request(make_request("127.0.0.1:8766"), is_post=True) is None
        evil = await mw.validate_request(make_request("evil.example.com"), is_post=True)
        assert evil is not None and evil.status_code == 421
        bad_ct = await mw.validate_request(make_request("public.example.com", "text/plain"), is_post=True)
        assert bad_ct is not None and bad_ct.status_code == 400

    asyncio.run(scenario())


@contextlib.asynccontextmanager
async def _http_guard_public(tmp_path):
    """guard.py 现场接线复刻：host=localhost + 显式 transport_security（放行公网域名）。
    经 ASGITransport 以 PUBLIC_ISSUER 为 base_url → scope 的 Host 头是公网域名。"""
    os.environ[PASSWORD_ENV] = PASSWORD
    state_path = str(tmp_path / "state" / "oauth_state.json")
    async with create_client_server_memory_streams() as (client_streams, server_streams):
        fake = await _fake_upstream()
        fake_task = asyncio.create_task(fake.run(*server_streams, fake.create_initialization_options()))
        async with ClientSession(*client_streams) as upstream:
            await upstream.initialize()
            guard_app = guard_lib.make_guard(upstream, allowlist={"read_file"}, workspace=str(tmp_path))
            provider = oauth_provider.GuardOAuthProvider(
                state_path=state_path, issuer=PUBLIC_ISSUER, resource_url=PUBLIC_RESOURCE,
                password_env=PASSWORD_ENV)
            auth = AuthSettings(issuer_url=PUBLIC_ISSUER, resource_server_url=PUBLIC_RESOURCE)
            app = guard_app.streamable_http_app(
                streamable_http_path="/mcp",
                host="localhost",
                token_verifier=ProviderTokenVerifier(provider),
                auth=auth,
                custom_starlette_routes=(
                    oauth_provider.create_guard_auth_routes(
                        provider, PUBLIC_ISSUER, ClientRegistrationOptions(enabled=True))
                    + oauth_provider.create_login_routes(provider)
                ),
                transport_security=guard.build_transport_security(PUBLIC_ISSUER),
            )
            async with _run_lifespan(app):
                yield app, provider
        fake_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await fake_task


def test_mcp_via_public_host_allowed(tmp_path):
    """回归：公网 Host 下完整 OAuth + MCP 流程必须走通。
    不修复时 /mcp 会被 SDK 默认的 DNS-rebinding 防护 421 拒绝（现场：ChatGPT 连接器
    /token 200 后 /mcp 全 421「Invalid Host header」，工具列表为空）。"""
    async def scenario():
        async with _http_guard_public(tmp_path) as (app, provider):
            transport = httpx2.ASGITransport(app=app)
            async with httpx2.AsyncClient(transport=transport, base_url=PUBLIC_ISSUER) as http:
                r = await http.post("/register", json={
                    "redirect_uris": [CALLBACK],
                    "token_endpoint_auth_method": "none",
                    "grant_types": ["authorization_code"],
                    "response_types": ["code"],
                    "client_name": "pytest-public-host",
                })
                assert r.status_code == 201, r.text
                client_id = r.json()["client_id"]
                verifier, challenge = _pkce()
                token = await _do_oauth_flow(http, client_id, verifier, challenge, PASSWORD)
                mcp_http = httpx2.AsyncClient(
                    transport=transport, headers={"Authorization": f"Bearer {token}"})
                async with streamable_http_client(PUBLIC_RESOURCE, http_client=mcp_http) as streams:
                    r_stream, w_stream = streams
                    async with ClientSession(r_stream, w_stream) as c:
                        await c.initialize()
                        tools = {t.name for t in (await c.list_tools()).tools}
                        assert tools == {"read_file", "write_next_step"}

    asyncio.run(scenario())


def test_state_dir_and_file_restrictive_modes_posix(tmp_path):
    """OAuth state 落盘权限边界（POSIX）：state 目录 0700、state 文件 0600。
    Windows 的 ACL 由 bridge/setup.* 收紧（Pester 侧验证继承移除），os.chmod 对 ACL 无效。
    state 目录/文件含 token_secret + 客户端注册表——其他用户不可读写。"""
    if os.name == "nt":
        pytest.skip("POSIX-only mode bits; Windows ACL covered by Pester tests")
    state_path = str(tmp_path / "guard" / "state" / "oauth_state.json")
    oauth_provider.GuardOAuthProvider(
        state_path=state_path, issuer=ISSUER, resource_url=RESOURCE, password_env=PASSWORD_ENV)
    assert stat.S_IMODE(os.stat(state_path).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(os.path.dirname(state_path)).st_mode) == 0o700


# ---- bounded transient state：公网入口资源上限（clients 落盘 / pending+codes 内存）----

def _mk_oauth_client(cid="c"):
    return OAuthClientInformationFull.model_validate({
        "client_id": cid, "redirect_uris": [CALLBACK],
        "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code"], "response_types": ["code"],
    })


def _mk_auth_params():
    return AuthorizationParams(
        state="st", scopes=["mcp"], code_challenge="x",
        redirect_uri=CALLBACK, redirect_uri_provided_explicitly=True)


def _mk_provider(tmp_path, name="s.json"):
    return oauth_provider.GuardOAuthProvider(
        state_path=str(tmp_path / name), issuer=ISSUER, resource_url=RESOURCE,
        password_env=PASSWORD_ENV)


def test_delete_state_file_while_running_keeps_tokens_valid(tmp_path):
    """撤销口径锚定（与 SECURITY.md 文档一致）：进程运行中删除 oauth_state.json 不撤销任何
    token——内存密钥继续验签，且下一次注册会以同一密钥重建文件。
    立即撤销全部 token 的唯一操作 = 停桥 → 删除文件 → 重启（新随机密钥 → 旧 JWT 验签失败）。"""
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        state = str(tmp_path / "oauth_state.json")
        kw = dict(state_path=state, issuer=ISSUER, resource_url=RESOURCE, password_env=PASSWORD_ENV)
        p = oauth_provider.GuardOAuthProvider(**kw)
        client = _mk_oauth_client("c1")
        await p.register_client(client)
        code = AuthorizationCode(code="c9", scopes=["mcp"], expires_at=time.time() + 300,
                                 client_id="c1", code_challenge="x", redirect_uri=CALLBACK,
                                 redirect_uri_provided_explicitly=True)
        tok = await p.exchange_authorization_code(client, code)
        os.remove(state)   # 运行中删除：不撤销（密钥在内存）
        assert await p.load_access_token(tok.access_token) is not None
        await p.register_client(_mk_oauth_client("c2"))   # 触发 _save_state → 同一密钥重建文件
        assert os.path.exists(state)
        assert await p.load_access_token(tok.access_token) is not None
        # 不删文件直接重启：同一密钥，token 仍有效（与「删除后重启」形成对照）
        p2 = oauth_provider.GuardOAuthProvider(**kw)
        assert await p2.load_access_token(tok.access_token) is not None
        # 删除后重启：新随机密钥 → 旧 JWT 全部失效
        os.remove(state)
        p3 = oauth_provider.GuardOAuthProvider(**kw)
        assert await p3.load_access_token(tok.access_token) is None

    asyncio.run(scenario())


def test_client_limit_refusal_preserves_existing(tmp_path, monkeypatch):
    """MAX_CLIENTS 上限：拒绝新 DCR 时绝不驱逐既有合法 client；拒绝不落盘，重启免疫不受影响。"""
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        state = str(tmp_path / "oauth_state.json")
        kw = dict(state_path=state, issuer=ISSUER, resource_url=RESOURCE, password_env=PASSWORD_ENV)
        p = oauth_provider.GuardOAuthProvider(**kw)
        await p.register_client(_mk_oauth_client("c1"))
        monkeypatch.setattr(oauth_provider, "MAX_CLIENTS", 1)
        with pytest.raises(RegistrationError):
            await p.register_client(_mk_oauth_client("c2"))
        assert await p.get_client("c1") is not None
        # 拒绝不落盘 + 重启免疫：重载后仍恰好 1 个 client
        p2 = oauth_provider.GuardOAuthProvider(**kw)
        assert await p2.get_client("c1") is not None
        assert len(p2._clients) == 1

    asyncio.run(scenario())


def test_pending_ttl_pruned_on_next_authorize(tmp_path, monkeypatch):
    """过期 pending 不无限积累：下一次 authorize 惰性清扫。"""
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        p = _mk_provider(tmp_path)
        client = _mk_oauth_client()
        params = _mk_auth_params()
        monkeypatch.setattr(oauth_provider, "PENDING_TTL", 0)
        await p.authorize(client, params)
        assert len(p._pending) == 1
        await p.authorize(client, params)   # 第二次调用先清扫过期 pending
        assert len(p._pending) == 1

    asyncio.run(scenario())


def test_pending_limit_refusal(tmp_path, monkeypatch):
    """MAX_PENDING 上限：明确拒绝新请求，不驱逐既有 pending（首个流程不受影响）。"""
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        p = _mk_provider(tmp_path)
        client = _mk_oauth_client()
        params = _mk_auth_params()
        monkeypatch.setattr(oauth_provider, "MAX_PENDING", 1)
        url1 = await p.authorize(client, params)
        with pytest.raises(AuthorizeError):
            await p.authorize(client, params)
        assert len(p._pending) == 1
        # 既有 pending 仍可完成登录
        key1 = url1.split("request=", 1)[1]
        assert p.complete_authorization(key1, PASSWORD) is not None

    asyncio.run(scenario())


def test_expired_code_pruned_and_cannot_exchange(tmp_path):
    """过期 authorization code 不能 exchange，且不残留内存。"""
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        p = _mk_provider(tmp_path)
        client = _mk_oauth_client()
        p._codes["cx"] = AuthorizationCode(
            code="cx", scopes=[], expires_at=time.time() - 1, client_id="c",
            code_challenge="x", redirect_uri=CALLBACK, redirect_uri_provided_explicitly=True)
        assert await p.load_authorization_code(client, "cx") is None
        assert "cx" not in p._codes

    asyncio.run(scenario())


def test_code_limit_refusal(tmp_path, monkeypatch):
    """MAX_CODES 上限：达到上限拒绝发新码（登录页 401），不驱逐既有码。"""
    async def scenario():
        os.environ[PASSWORD_ENV] = PASSWORD
        p = _mk_provider(tmp_path)
        client = _mk_oauth_client()
        params = _mk_auth_params()
        url1 = await p.authorize(client, params)
        key1 = url1.split("request=", 1)[1]
        r1 = p.complete_authorization(key1, PASSWORD)
        assert r1 is not None
        monkeypatch.setattr(oauth_provider, "MAX_CODES", 1)
        url2 = await p.authorize(client, params)
        key2 = url2.split("request=", 1)[1]
        assert p.complete_authorization(key2, PASSWORD) is None   # 上限拒绝 → 401
        assert len(p._codes) == 1
        # 既有码不受影响，可正常 exchange
        assert await p.load_authorization_code(client, r1[1]) is not None

    asyncio.run(scenario())
