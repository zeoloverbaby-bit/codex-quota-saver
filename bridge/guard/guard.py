# bridge/guard/guard.py —— bridge-guard HTTP 入口（mcp SDK 2.0）
"""读 guard_config.json → 连上游（静态 Bearer，仅 127.0.0.1）→ 起白名单 MCP server。
配置示例见 guard_config.example.json；真实配置由 bridge/setup.* 生成并 gitignore。

认证（2026-08-17 实测）：ChatGPT 连接器只有 OAuth / 无身份验证 / 混合三种认证，
API key 方案在连接器侧不可行。guard 因此自建 OAuth issuer：DCR 注册表落盘 +
token_secret 持久化 + HS256 JWT（TTL 7 天）；连接器走标准 OAuth 授权码 + PKCE 流程，
在 /auth/login 输一次密码完成授权。白名单在协议层（能力边界）+ OAuth（身份边界）双保险。

auth_mode（PoC：Secure MCP Tunnel）：
- public（默认，config 缺省 auth_mode 即此）：OAuth 2.1 + PKCE + DCR + JWT +
  /authorize /token /register /auth/login，公网 Host 放行（ngrok 转发）。
- tunnel：OpenAI Secure MCP Tunnel 已负责身份/公网边界，guard 不再自建 OAuth
  authorization server（不创建 GuardOAuthProvider / AuthSettings /
  ProviderTokenVerifier / ClientRegistrationOptions，不挂载 OAuth 路由）。
  能力边界（make_guard 白名单 + write_next_step 固定路径 + 文件系统边界）与
  public 完全一致；绝不直连暴露 upstream MCP。本地无 OAuth MCP 必须 fail-closed
  强制 loopback（host 仅允许 127.0.0.1 / ::1，其余配置启动即失败）。
"""
import argparse
import asyncio
import contextlib
import ipaddress
import json
import os
from urllib.parse import urlparse

import uvicorn
from pydantic import AnyHttpUrl

from mcp.client.session import ClientSession
from mcp.client.streamable_http import httpx2, streamable_http_client
from mcp.server.auth.provider import ProviderTokenVerifier
from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions
from mcp.server.transport_security import TransportSecuritySettings

from guard_lib import make_guard
from oauth_provider import GuardOAuthProvider, create_guard_auth_routes, create_login_routes

COMMON_REQUIRED = (
    "workspace", "upstream_url", "upstream_token_env", "allowlist",
)

PUBLIC_REQUIRED = (
    "public_url", "oauth_password_env", "oauth_state_file",
)

AUTH_MODES = ("public", "tunnel")

# tunnel mode 无 OAuth MCP 的合法绑定地址（fail-closed loopback）。
# localhost 不在此列表——host 参数会进入 uvicorn 绑定与 transport_security，
# localhost 可能被系统解析到非 loopback 地址（见 _validate_host_loopback 的拒绝语义）。
TUNNEL_ALLOWED_HOSTS = ("127.0.0.1", "::1")

LOOPBACK_TRANSPORT_SECURITY = TransportSecuritySettings(
    enable_dns_rebinding_protection=True,
    allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*"],
    allowed_origins=["http://127.0.0.1:*", "http://localhost:*", "http://[::1]:*"],
)


def resolve_auth_mode(cfg: dict) -> str:
    """auth_mode missing → public（兼容现有 config 与所有既有用户）。"""
    mode = cfg.get("auth_mode", "public")
    if mode not in AUTH_MODES:
        raise SystemExit(f"guard_config.json 未知 auth_mode: {mode!r}（支持: {AUTH_MODES}）")
    return mode


def required_env_names(cfg: dict, auth_mode: str) -> list:
    """环境变量 preflight 条件式：public 要求 upstream_token + oauth_password；
    tunnel 只要求 upstream_token（不得要求 CQS_OAUTH_PASSWORD）。"""
    env = [cfg["upstream_token_env"]]
    if auth_mode == "public":
        env.append(cfg["oauth_password_env"])
    return env


def _validate_host_loopback(cfg: dict) -> str:
    """tunnel mode 硬约束：本地无 OAuth MCP 只能绑定 loopback，fail-fast（不 warning）。

    只接受数值地址 127.0.0.1 / ::1，按 IP 语义校验 is_loopback（不查 DNS——数值
    地址无解析歧义，也避开 hosts 文件篡改面）；名字 localhost 直接拒绝（可能解析到
    非 loopback）。0.0.0.0 / LAN IP / 公网 IP / 其他一切 → 启动失败。"""
    host = str(cfg.get("host", "127.0.0.1"))
    if host == "localhost":
        raise SystemExit(
            "[bridge-guard] FATAL auth_mode=tunnel 不接受 host='localhost'"
            "（可能解析到非 loopback 地址）；请显式使用 127.0.0.1"
        )
    if host not in TUNNEL_ALLOWED_HOSTS:
        raise SystemExit(
            f"[bridge-guard] FATAL auth_mode=tunnel 只允许 loopback 绑定"
            f"（127.0.0.1 / ::1），拒绝 host={host!r}——无 OAuth 的 MCP 不得绑定"
            f" 0.0.0.0 / LAN / 公网地址，否则等于把无认证的能力面暴露到网络"
        )
    try:
        addr = ipaddress.ip_address(host)
    except ValueError as exc:
        raise SystemExit(f"[bridge-guard] FATAL auth_mode=tunnel host {host!r} 不是合法 IP 地址: {exc}") from exc
    if not addr.is_loopback:
        raise SystemExit(f"[bridge-guard] FATAL auth_mode=tunnel host {host!r} 不是 loopback 地址——拒绝启动")
    return host


def build_transport_security(public_url: str) -> TransportSecuritySettings:
    """public 模式 /mcp 端点的 DNS-rebinding 防护：放行公网域名（ngrok 转发后 Host 是公网域名），
    同时保留本机回环（本地诊断/直连）。
    2026-08-17 现场教训：SDK 在 host 为 localhost 时会自动只放行回环 Host——不显式传入，
    经 ngrok 的请求（Host=公网域名）全部 421「Invalid Host header」：ChatGPT 连接器
    /token 已成功但 /mcp 全被拒，工具列表为空。"""
    public_host = urlparse(public_url).hostname or "127.0.0.1"
    return TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[public_host, f"{public_host}:*", "127.0.0.1:*", "localhost:*", "[::1]:*"],
    )


def load_config(path: str) -> dict:
    """条件式校验：COMMON 必需；public 额外要求 PUBLIC；tunnel 只要求 COMMON。"""
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    mode = resolve_auth_mode(cfg)
    if mode == "tunnel":
        _validate_host_loopback(cfg)
    required = list(COMMON_REQUIRED)
    if mode == "public":
        required += list(PUBLIC_REQUIRED)
    missing = [k for k in required if k not in cfg]
    if missing:
        raise SystemExit(f"guard_config.json（auth_mode={mode}）缺少字段: {missing}")
    return cfg


def _resolve(path: str, config_dir: str) -> str:
    """oauth_state_file 相对路径按 guard_config.json 所在目录解析。"""
    return path if os.path.isabs(path) else os.path.join(config_dir, path)


@contextlib.asynccontextmanager
async def connect_upstream(cfg: dict):
    """连接上游 coding-tools-mcp，yield (upstream_session, upstream_tools)。

    上游直连：Bearer 走 HTTP 头（不经过进程命令行）。upstream 自身只绑定 127.0.0.1
    （不开 OAuth、不对外）；认证全在 guard 层。启动失败重试 10 次 ×3s（上游可能比
    guard 晚就绪——启动器并行拉起）；成功后在 context 内保持连接存活。"""
    upstream_token = os.environ[cfg["upstream_token_env"]]
    http_client = httpx2.AsyncClient(headers={"Authorization": f"Bearer {upstream_token}"})
    streams = None
    upstream = None
    try:
        for attempt in range(1, 11):
            try:
                streams = streamable_http_client(cfg["upstream_url"], http_client=http_client)
                read_stream, write_stream = await streams.__aenter__()
                # SDK 2.0：ClientSession 必须 async with 进入（启动内部 dispatcher）
                upstream = ClientSession(read_stream, write_stream)
                await upstream.__aenter__()
                await upstream.initialize()
                upstream_tools = {t.name for t in (await upstream.list_tools()).tools}
                missing = set(cfg["allowlist"]) - upstream_tools
                if missing:
                    print(f"[bridge-guard] WARN 白名单含上游不存在的工具: {sorted(missing)}", flush=True)
                yield upstream, upstream_tools
                return
            except BaseException as e:
                if upstream is not None:
                    with contextlib.suppress(BaseException):
                        await upstream.__aexit__(None, None, None)
                    upstream = None
                if streams is not None:
                    with contextlib.suppress(BaseException):
                        await streams.__aexit__(None, None, None)
                    streams = None
                print(f"[bridge-guard] WARN 上游连接尝试 {attempt}/10 失败: {e!r}", flush=True)
                await asyncio.sleep(3)
        print("[bridge-guard] FATAL 无法连接上游，退出", flush=True)
        raise SystemExit(1)
    finally:
        if upstream is not None:
            with contextlib.suppress(BaseException):
                await upstream.__aexit__(None, None, None)
        if streams is not None:
            with contextlib.suppress(BaseException):
                await streams.__aexit__(None, None, None)
        with contextlib.suppress(BaseException):
            await http_client.aclose()


async def serve_public(cfg: dict, host: str, port: int, config_dir: str) -> None:
    """public 模式 = 现状（ngrok + 自建 OAuth）：GuardOAuthProvider + PKCE + DCR + JWT
    + OAuth routes + 公网 Host transport security。不得借本轮重构 OAuth。"""
    async with connect_upstream(cfg) as (upstream, _upstream_tools):
        guard = make_guard(upstream, allowlist=set(cfg["allowlist"]), workspace=cfg["workspace"])

        public_url = str(cfg["public_url"]).rstrip("/")
        issuer = AnyHttpUrl(public_url)
        resource = AnyHttpUrl(public_url + "/mcp")
        provider = GuardOAuthProvider(
            state_path=_resolve(cfg["oauth_state_file"], config_dir),
            issuer=public_url,
            resource_url=public_url + "/mcp",
            password_env=cfg["oauth_password_env"],
        )
        # SDK 2.0：token_verifier 与 auth 一起提供才装配认证（MCP 端点强制 Bearer，
        # OAuth 端点匿名可达）；custom_starlette_routes 注入授权服务器路由 + 密码页
        auth = AuthSettings(issuer_url=issuer, resource_server_url=resource)
        debug = os.environ.get("CQS_GUARD_DEBUG") == "1"
        app = guard.streamable_http_app(
            streamable_http_path="/mcp",
            host=host,
            token_verifier=ProviderTokenVerifier(provider),
            auth=auth,
            custom_starlette_routes=(
                create_guard_auth_routes(provider, issuer, ClientRegistrationOptions(enabled=True))
                + create_login_routes(provider)
            ),
            transport_security=build_transport_security(public_url),
            debug=debug,
        )
        # uvicorn.run 是同步入口；在已有事件循环内必须用 async Server.serve()
        server = uvicorn.Server(uvicorn.Config(app, host=host, port=port, log_level="debug" if debug else "warning"))
        await server.serve()


async def serve_tunnel(cfg: dict, host: str, port: int, config_dir: str) -> None:
    """tunnel 模式（Secure MCP Tunnel PoC-B）：
    - 不创建 GuardOAuthProvider / AuthSettings / ProviderTokenVerifier / ClientRegistrationOptions
    - 不挂载 /authorize /token /register /auth/login
    - 完整保留 make_guard：白名单 + write_next_step + 文件系统边界
    - 本地无 OAuth MCP 必须 loopback（load_config 已 fail-fast 校验 host）

    host 参数（127.0.0.1 / ::1）仅影响 transport_security 的校验语义；
    transport_security 使用与 SDK loopback 默认一致的回环最小配置。"""
    async with connect_upstream(cfg) as (upstream, _upstream_tools):
        guard = make_guard(upstream, allowlist=set(cfg["allowlist"]), workspace=cfg["workspace"])

        debug = os.environ.get("CQS_GUARD_DEBUG") == "1"
        app = guard.streamable_http_app(
            streamable_http_path="/mcp",
            host=host,
            transport_security=LOOPBACK_TRANSPORT_SECURITY,
            debug=debug,
        )
        server = uvicorn.Server(uvicorn.Config(app, host=host, port=port, log_level="debug" if debug else "warning"))
        await server.serve()


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.environ.get("CQS_GUARD_CONFIG", "guard_config.json"))
    args = ap.parse_args()
    config_path = os.path.abspath(args.config)
    cfg = load_config(config_path)
    config_dir = os.path.dirname(config_path)
    auth_mode = resolve_auth_mode(cfg)

    host = str(cfg.get("host", "127.0.0.1"))
    port = int(cfg.get("port", 8766))
    if auth_mode == "tunnel":
        # load_config 已校验 loopback；再取经过校验的 canonical host
        host = _validate_host_loopback(cfg)

    # 环境变量缺失立即失败并给明确原因（2026-08-17 现场：启动器 env 加载被非 ASCII 注释破坏，
    # 这里曾 KeyError → 重试 10×3s 后静默退出，窗口消失无从排查）
    missing_env = [k for k in required_env_names(cfg, auth_mode) if k not in os.environ]
    if missing_env:
        print(
            f"[bridge-guard] FATAL 缺少环境变量: {missing_env} —— "
            "请确认启动器已正确加载 .secrets.local.env",
            flush=True,
        )
        raise SystemExit(1)

    if auth_mode == "public":
        await serve_public(cfg, host, port, config_dir)
    else:
        await serve_tunnel(cfg, host, port, config_dir)


if __name__ == "__main__":
    asyncio.run(main())
