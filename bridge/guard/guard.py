# bridge/guard/guard.py —— bridge-guard HTTP 入口（mcp SDK 2.0）
"""读 guard_config.json → 连上游（静态 Bearer，仅 127.0.0.1）→ 起白名单 MCP server + 自建 OAuth 2.1 授权服务器。
配置示例见 guard_config.example.json；真实配置由 bridge/setup.* 生成并 gitignore。

认证（2026-08-17 实测）：ChatGPT 连接器只有 OAuth / 无身份验证 / 混合三种认证，
API key 方案在连接器侧不可行。guard 因此自建 OAuth issuer：DCR 注册表落盘 +
token_secret 持久化 + HS256 JWT（TTL 7 天）；连接器走标准 OAuth 授权码 + PKCE 流程，
在 /auth/login 输一次密码完成授权。白名单在协议层（能力边界）+ OAuth（身份边界）双保险。
"""
import argparse
import asyncio
import json
import os

import uvicorn
from pydantic import AnyHttpUrl

from mcp.client.session import ClientSession
from mcp.client.streamable_http import httpx2, streamable_http_client
from mcp.server.auth.provider import ProviderTokenVerifier
from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions

from guard_lib import make_guard
from oauth_provider import GuardOAuthProvider, create_guard_auth_routes, create_login_routes

REQUIRED_KEYS = (
    "workspace", "upstream_url", "upstream_token_env", "public_url",
    "oauth_password_env", "oauth_state_file", "allowlist",
)


def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    missing = [k for k in REQUIRED_KEYS if k not in cfg]
    if missing:
        raise SystemExit(f"guard_config.json 缺少字段: {missing}")
    return cfg


def _resolve(path: str, config_dir: str) -> str:
    """oauth_state_file 相对路径按 guard_config.json 所在目录解析。"""
    return path if os.path.isabs(path) else os.path.join(config_dir, path)


async def serve_once(cfg: dict, host: str, port: int, config_dir: str) -> None:
    upstream_token = os.environ[cfg["upstream_token_env"]]
    # 上游直连：Bearer 走 HTTP 头（不经过进程命令行）
    http_client = httpx2.AsyncClient(headers={"Authorization": f"Bearer {upstream_token}"})
    async with streamable_http_client(cfg["upstream_url"], http_client=http_client) as streams:
        read_stream, write_stream = streams
        # SDK 2.0：ClientSession 必须 async with 进入（启动内部 dispatcher）
        async with ClientSession(read_stream, write_stream) as upstream:
            await upstream.initialize()
            upstream_tools = {t.name for t in (await upstream.list_tools()).tools}
            missing = set(cfg["allowlist"]) - upstream_tools
            if missing:
                print(f"[bridge-guard] WARN 白名单含上游不存在的工具: {sorted(missing)}", flush=True)

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
                debug=debug,
            )
            # uvicorn.run 是同步入口；在已有事件循环内必须用 async Server.serve()
            server = uvicorn.Server(uvicorn.Config(app, host=host, port=port, log_level="debug" if debug else "warning"))
            await server.serve()


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.environ.get("CQS_GUARD_CONFIG", "guard_config.json"))
    args = ap.parse_args()
    config_path = os.path.abspath(args.config)
    cfg = load_config(config_path)
    config_dir = os.path.dirname(config_path)

    host = cfg.get("host", "127.0.0.1")
    port = int(cfg.get("port", 8766))

    # 上游可能比 guard 晚就绪（启动器并行拉起）——首次连接失败必须重试
    for attempt in range(1, 11):
        try:
            await serve_once(cfg, host, port, config_dir)
            return
        except BaseException as e:
            print(f"[bridge-guard] WARN 启动尝试 {attempt}/10 失败: {e!r}", flush=True)
            await asyncio.sleep(3)
    print("[bridge-guard] FATAL 无法连接上游，退出", flush=True)
    raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(main())
