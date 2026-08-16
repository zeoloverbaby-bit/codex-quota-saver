# bridge/guard/guard.py —— bridge-guard HTTP 入口（mcp SDK 2.0）
"""读 guard_config.json → 连上游（Bearer）→ 起白名单 MCP server（streamable HTTP + token_verifier）。
配置示例见 guard_config.example.json；真实配置由 bridge/setup.* 生成并 gitignore。
认证：token_verifier 由 SDK 在 HTTP 层校验，失败即 401，能力层兜底。
"""
import argparse
import asyncio
import json
import os

import uvicorn

from mcp.client.streamable_http import streamable_http_client, httpx2
from mcp.client.session import ClientSession
from mcp.server.auth.settings import AuthSettings

from guard_lib import make_guard, GuardTokenVerifier


def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


async def serve_once(cfg: dict, host: str, port: int, guard_token: str, upstream_token: str) -> None:
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
            # SDK 2.0：token_verifier 必须与 auth 一起提供，才会装配 AuthenticationMiddleware
            base_url = f"http://{host}:{port}"
            auth = AuthSettings(issuer_url=base_url, resource_server_url=base_url)
            debug = os.environ.get("CQS_GUARD_DEBUG") == "1"
            app = guard.streamable_http_app(
                streamable_http_path="/mcp",
                host=host,
                token_verifier=GuardTokenVerifier(guard_token),
                auth=auth,
                debug=debug,
            )
            # uvicorn.run 是同步入口；在已有事件循环内必须用 async Server.serve()
            server = uvicorn.Server(uvicorn.Config(app, host=host, port=port, log_level="debug" if debug else "warning"))
            await server.serve()


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.environ.get("CQS_GUARD_CONFIG", "guard_config.json"))
    args = ap.parse_args()
    cfg = load_config(args.config)

    guard_token = os.environ[cfg["token_env"]]
    upstream_token = os.environ[cfg["upstream_token_env"]]
    host = cfg.get("host", "127.0.0.1")
    port = int(cfg.get("port", 8766))

    # 上游可能比 guard 晚就绪（启动器并行拉起）——首次连接失败必须重试
    for attempt in range(1, 11):
        try:
            await serve_once(cfg, host, port, guard_token, upstream_token)
            return
        except BaseException as e:
            print(f"[bridge-guard] WARN 启动尝试 {attempt}/10 失败: {e!r}", flush=True)
            await asyncio.sleep(3)
    print("[bridge-guard] FATAL 无法连接上游，退出", flush=True)
    raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(main())
