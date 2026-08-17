# bridge/guard/oauth_provider.py —— bridge-guard 自建 OAuth 2.1 授权服务器 Provider（mcp SDK 2.0）
"""ChatGPT 连接器只支持 OAuth / 无身份验证 / 混合三种认证（2026-08-17 实测），
API key 方案在连接器侧不可行——guard 改为自建 OAuth issuer（授权码 + PKCE）。

架构：SDK 2.0 的 create_auth_routes 提供 /authorize /token /register + well-known 元数据
（HTTP 协议层、PKCE 校验、DCR 校验全由 SDK 管）；本模块只实现
OAuthAuthorizationServerProvider 协议——存储与签发：

- 客户端注册表落盘 oauth_state.json → 重启免疫（旧桥坑 10/11：内存注册表 + 随机密钥，
  服务器一重启连接器全断。此处从设计上根治）
- token_secret 持久化 → 重启后已签发 token 依然有效
- access token = HS256 JWT，TTL 7 天，不签发 refresh token（与旧桥口径一致）
- /auth/login 密码页：单用户输入 CQS_OAUTH_PASSWORD 完成授权（密码经 env 注入，不落盘）
"""
import hmac
import html
import json
import os
import secrets
import time

import jwt
from pydantic import AnyHttpUrl

from mcp.server.auth.handlers.metadata import MetadataHandler
from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizeError,
    OAuthAuthorizationServerProvider,
    RegistrationError,
    TokenError,
    construct_redirect_uri,
)
from mcp.server.auth.routes import build_metadata, cors_middleware, create_auth_routes
from mcp.server.auth.settings import ClientRegistrationOptions, RevocationOptions
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from starlette.responses import HTMLResponse, RedirectResponse
from starlette.routing import Route

ACCESS_TOKEN_TTL = 7 * 24 * 3600  # 与旧桥 CODING_TOOLS_MCP_OAUTH_TOKEN_TTL=604800 一致
CODE_TTL = 300  # 授权码 5 分钟
PENDING_TTL = 600  # 待授权请求 10 分钟
MAX_PASSWORD_ATTEMPTS = 5  # 每个待授权请求最多试错次数
# 公网入口 bounded state：ngrok 域名公开可达，匿名 DCR/authorize 不能无限膨胀资源。
# 拒绝语义 = 拒绝新请求、绝不驱逐仍合法的既有 state（单用户桥正常用量远低于上限）。
MAX_CLIENTS = 100  # 落盘客户端注册表上限（单用户桥只需个位数；重启免疫不受影响）
MAX_PENDING = 50  # 内存待授权请求上限
MAX_CODES = 50  # 内存授权码上限

LOGIN_HTML = """<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><title>bridge-guard 授权</title></head>
<body>
<h2>bridge-guard 授权登录</h2>
<p>输入部署时生成的 OAuth 密码，为 ChatGPT 连接器完成授权。</p>
<form method="post" action="/auth/login">
  <input type="hidden" name="request" value="{key}">
  <label>密码 <input type="password" name="password" autofocus></label>
  <button type="submit">授权</button>
</form>
</body></html>"""

LOGIN_FAILED_HTML = """<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><title>授权失败</title></head>
<body>
<h2>授权失败</h2>
<p>密码错误（或请求已过期 / 试错次数用尽）。请回到 ChatGPT 连接器重新发起授权。</p>
</body></html>"""


class GuardOAuthProvider:
    """OAuthAuthorizationServerProvider 的落盘实现（单用户自托管）。"""

    def __init__(self, state_path, issuer, resource_url, password_env, ttl=ACCESS_TOKEN_TTL):
        self._state_path = state_path
        self._issuer = issuer
        self._resource_url = resource_url
        self._password_env = password_env
        self._ttl = ttl
        self._clients = {}  # client_id -> OAuthClientInformationFull
        self._pending = {}  # request_key -> [client_id, AuthorizationParams, created, attempts]
        self._codes = {}  # code -> AuthorizationCode
        self._secret = None
        self._load_state()
        if not self._secret:
            # 首次启动：生成持久化密钥（之后重启复用——重启免疫的关键）
            self._secret = secrets.token_hex(32)
            self._save_state()

    # ---- 状态落盘 ----
    def _load_state(self):
        if os.path.exists(self._state_path):
            with open(self._state_path, encoding="utf-8") as f:
                data = json.load(f)
            self._secret = data.get("token_secret")
            for cid, cjson in (data.get("clients") or {}).items():
                self._clients[cid] = OAuthClientInformationFull.model_validate(cjson)

    def _save_state(self):
        state_dir = os.path.dirname(self._state_path) or "."
        os.makedirs(state_dir, exist_ok=True)
        try:
            # POSIX：state 目录 owner-only（0700）——含 token_secret + 客户端注册表。
            # Windows 目录 ACL 由 bridge/setup.* 收紧（os.chmod 对 ACL 无效，此处只兜底 POSIX）
            os.chmod(state_dir, 0o700)
        except OSError:  # pragma: no cover
            pass
        data = {
            "token_secret": self._secret,
            "clients": {cid: json.loads(c.model_dump_json()) for cid, c in self._clients.items()},
        }
        tmp = self._state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, self._state_path)  # 原子替换，避免半写状态
        try:
            os.chmod(self._state_path, 0o600)
        except OSError:  # pragma: no cover
            pass  # Windows 不适用；目录权限由 bridge/setup.* 收紧

    # ---- 惰性清理（无后台线程；在 register/authorize/complete/exchange 入口调用）----
    def _prune_pending(self):
        now = time.time()
        # >= ：恰好到 TTL 边界的条目同样视为过期（Windows 时钟粒度粗，> 会漏判同 tick 条目）
        expired = [k for k, e in self._pending.items() if now - e[2] >= PENDING_TTL]
        for k in expired:
            self._pending.pop(k, None)

    def _prune_codes(self):
        now = time.time()
        expired = [k for k, c in self._codes.items() if c.expires_at < now]
        for k in expired:
            self._codes.pop(k, None)

    # ---- 客户端注册（DCR，落盘 → 重启免疫） ----
    async def get_client(self, client_id):
        return self._clients.get(client_id)

    async def register_client(self, client_info):
        # 上限：拒绝新注册（SDK 映射 HTTP 400），绝不驱逐既有合法 client
        if len(self._clients) >= MAX_CLIENTS:
            raise RegistrationError(
                error="invalid_client_metadata",
                error_description="client registration limit reached",
            )
        self._clients[client_info.client_id] = client_info
        self._save_state()

    # ---- 授权码流程 ----
    async def authorize(self, client, params):
        self._prune_pending()
        if len(self._pending) >= MAX_PENDING:
            raise AuthorizeError(
                error="temporarily_unavailable",
                error_description="too many pending authorization requests",
            )
        key = secrets.token_urlsafe(24)
        self._pending[key] = [client.client_id, params, time.time(), 0]
        return f"{self._issuer}/auth/login?request={key}"

    def complete_authorization(self, request_key, password):
        """登录页回调：密码正确 → 签发授权码，返回 (redirect_uri, code, state)；否则 None。"""
        entry = self._pending.get(request_key)
        if entry is None:
            return None
        client_id, params, created, attempts = entry
        if time.time() - created > PENDING_TTL:
            self._pending.pop(request_key, None)
            return None
        expected = os.environ.get(self._password_env, "")
        if not expected or not hmac.compare_digest(expected, password):
            entry[3] += 1
            if entry[3] >= MAX_PASSWORD_ATTEMPTS:
                self._pending.pop(request_key, None)
            return None
        self._pending.pop(request_key, None)
        self._prune_codes()
        if len(self._codes) >= MAX_CODES:
            return None  # 上限拒绝发新码（登录页 401）；既有码不驱逐
        code = secrets.token_urlsafe(32)
        self._codes[code] = AuthorizationCode(
            code=code,
            scopes=params.scopes or [],
            expires_at=time.time() + CODE_TTL,
            client_id=client_id,
            code_challenge=params.code_challenge,
            redirect_uri=params.redirect_uri,
            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
            resource=params.resource,
        )
        return params.redirect_uri, code, params.state

    async def load_authorization_code(self, client, authorization_code):
        self._prune_codes()
        # 一次性使用：取出即销毁
        c = self._codes.pop(authorization_code, None)
        if c is None or c.client_id != client.client_id:
            return None
        return c

    async def exchange_authorization_code(self, client, authorization_code):
        now = int(time.time())
        scopes = " ".join(authorization_code.scopes)
        claims = {
            "sub": client.client_id,
            "iss": self._issuer,
            "aud": self._resource_url,
            "iat": now,
            "exp": now + self._ttl,
        }
        if scopes:
            claims["scope"] = scopes
        token = jwt.encode(claims, self._secret, algorithm="HS256")
        return OAuthToken(
            access_token=token,
            token_type="Bearer",
            expires_in=self._ttl,
            scope=scopes or None,
        )

    # ---- refresh token：不签发（与旧桥一致） ----
    async def load_refresh_token(self, client, refresh_token):
        return None

    async def exchange_refresh_token(self, client, refresh_token, scopes):
        raise TokenError(error="invalid_grant", error_description="bridge-guard 不签发 refresh token")

    # ---- access token 验证（MCP 请求 Bearer 校验，SDK 的 BearerAuthBackend 调用） ----
    async def load_access_token(self, token):
        try:
            claims = jwt.decode(
                token, self._secret, algorithms=["HS256"],
                audience=self._resource_url, issuer=self._issuer,
            )
        except jwt.PyJWTError:
            return None
        scope = claims.get("scope") or ""
        return AccessToken(
            token=token,
            client_id=claims.get("sub") or "",
            scopes=scope.split() if scope else [],
            expires_at=claims.get("exp"),
            resource=claims.get("aud"),
            claims=claims,
        )

    async def revoke_token(self, token):
        # 无状态自签 JWT：撤销靠 TTL 到期；实现留空
        pass


def create_login_routes(provider):
    """密码授权页。authorize 把待授权请求暂存（高熵随机 key），
    登录页完成密码校验后 302 回 redirect_uri（带 code + state）。"""

    async def login_get(request):
        key = request.query_params.get("request", "")
        return HTMLResponse(LOGIN_HTML.format(key=html.escape(key)))

    async def login_post(request):
        form = await request.form()
        key = str(form.get("request", ""))
        password = str(form.get("password", ""))
        result = provider.complete_authorization(key, password)
        if result is None:
            return HTMLResponse(LOGIN_FAILED_HTML, status_code=401, headers={"Cache-Control": "no-store"})
        redirect_uri, code, state = result
        url = construct_redirect_uri(str(redirect_uri), code=code, state=state)
        return RedirectResponse(url, status_code=302, headers={"Cache-Control": "no-store"})

    return [
        Route("/auth/login", endpoint=login_get, methods=["GET"]),
        Route("/auth/login", endpoint=login_post, methods=["POST"]),
    ]


def create_guard_auth_routes(provider, issuer_url, client_registration_options=None):
    """SDK create_auth_routes + 元数据补 'none'。

    ChatGPT 连接器的 MCP 客户端以 public client 注册（token_endpoint_auth_method=none，
    旧桥实测如此）；SDK 默认元数据只广告 client_secret_post/basic，不补 'none' 可能让
    连接器拒绝完成注册。SDK 的 ClientAuthenticator / RegistrationHandler 本身接受 'none'。
    """
    issuer_url = AnyHttpUrl(str(issuer_url))
    options = client_registration_options or ClientRegistrationOptions()
    routes = create_auth_routes(provider, issuer_url, client_registration_options=options)
    # build_metadata 直接访问 revocation_options.enabled，必须传实例（SDK 无 None 兜底）
    metadata = build_metadata(issuer_url, None, options, RevocationOptions())
    metadata = metadata.model_copy(update={
        "token_endpoint_auth_methods_supported": ["none", "client_secret_post", "client_secret_basic"],
    })
    # routes[0] 恒为 well-known 元数据路由（SDK create_auth_routes 固定顺序）
    routes[0] = Route(
        "/.well-known/oauth-authorization-server",
        endpoint=cors_middleware(MetadataHandler(metadata).handle, ["GET", "OPTIONS"]),
        methods=["GET", "OPTIONS"],
    )
    return routes
