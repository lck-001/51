from __future__ import annotations

import time
import uuid
from concurrent.futures import ThreadPoolExecutor, TimeoutError
from typing import Any

from fastapi import FastAPI, HTTPException

from asset_index import AssetIndex
from config import CONFIG
from hive_client import HiveClient
from models import AssetSearchRequest, DatabaseRequest, LoginRequest, LogoutRequest, SessionRequest, SqlRequest, TableRequest
from rate_limiter import ConcurrencyLimiter, RateLimiter
from service_window import is_in_service_window
from session_store import SessionStore
from sql_guard import SqlGuard

app = FastAPI(title="MCP Hive Query Gateway")

# 这些对象在进程启动时初始化，生产环境修改 config.yaml 后需要重启服务才会生效。
sessions = SessionStore(ttl_seconds=int(CONFIG["server"]["session_ttl_seconds"]))
rate_limiter = RateLimiter(per_user_per_minute=int(CONFIG["limits"]["per_user_submit_per_minute"]))
concurrency = ConcurrencyLimiter(
    global_limit=int(CONFIG["limits"]["global_concurrency"]),
    per_user_limit=int(CONFIG["limits"]["per_user_concurrency"]),
)
sql_guard = SqlGuard(CONFIG)
assets = AssetIndex(CONFIG)
hive_client = HiveClient(CONFIG)
executor = ThreadPoolExecutor(max_workers=int(CONFIG["limits"]["global_concurrency"]))


@app.get("/api/health")
def health() -> dict[str, Any]:
    """给负载均衡、systemd healthcheck 和 MCP 客户端做健康探测。"""
    return {
        "status": "ok",
        "service_window_open": is_in_service_window(CONFIG),
        "sessions": sessions.count(),
        "active_queries": concurrency.active_global,
        "ts": int(time.time()),
    }


@app.post("/api/login")
def login(req: LoginRequest) -> dict[str, Any]:
    # 登录只生成网关 session；真正 Hive 查询仍会在执行 SQL 时使用该用户身份连接 Hive。
    hive_client.test_connection(req.username, req.password)
    session = sessions.create(req.username, req.password)
    return {
        "session_id": session.session_id,
        "username": session.username,
        "expires_at": int(session.expires_at),
    }


@app.post("/api/logout")
def logout(req: LogoutRequest) -> dict[str, Any]:
    sessions.delete(req.session_id)
    return {"ok": True}


@app.post("/api/assets/search")
def search_assets(req: AssetSearchRequest) -> dict[str, Any]:
    return {"items": assets.search(req.keyword, req.domain, req.limit)}


@app.get("/api/assets/sla-tables")
def get_sla_tables() -> dict[str, Any]:
    return {"items": assets.sla_tables()}


@app.get("/api/assets/profile-assets")
def get_profile_assets() -> dict[str, Any]:
    return {"items": assets.profile_assets()}


@app.post("/api/assets/table")
def get_table(req: TableRequest) -> dict[str, Any]:
    item = assets.get_table(req.database, req.table)
    if not item:
        raise HTTPException(status_code=404, detail="table not found")
    return item


@app.post("/api/hive/databases")
def list_databases(req: SessionRequest) -> dict[str, Any]:
    username, password = _resolve_credentials(req.session_id)
    return {"databases": hive_client.list_databases(username, password)}


@app.post("/api/hive/tables")
def list_tables(req: DatabaseRequest) -> dict[str, Any]:
    username, password = _resolve_credentials(req.session_id)
    try:
        return {"database": req.database, "tables": hive_client.list_tables(username, password, req.database)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/sql/validate")
def validate_sql(req: SqlRequest) -> dict[str, Any]:
    username, _ = _resolve_credentials(req.session_id)
    result = sql_guard.validate(req.sql, req.limit)
    return {
        "valid": True,
        "username": username,
        "normalized_sql": result.normalized_sql,
        "warnings": result.warnings,
    }


@app.post("/api/sql/execute")
def execute_sql(req: SqlRequest) -> dict[str, Any]:
    # 查询执行入口必须先过服务窗口、限流、并发和 SQL 只读校验。
    if not is_in_service_window(CONFIG):
        raise HTTPException(status_code=403, detail="service window is closed")

    username, password = _resolve_credentials(req.session_id)
    if not rate_limiter.allow(username):
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    if not concurrency.acquire(username):
        raise HTTPException(status_code=429, detail="concurrency limit exceeded")

    query_id = "q_" + uuid.uuid4().hex
    started = time.time()
    try:
        validation = sql_guard.validate(req.sql, req.limit)
        max_rows = min(req.limit or int(CONFIG["limits"]["default_limit"]), int(CONFIG["limits"]["max_limit"]))
        timeout = min(
            req.timeout_seconds or int(CONFIG["hive"]["query_timeout_seconds"]),
            int(CONFIG["hive"]["query_timeout_seconds"]),
        )
        future = executor.submit(
            hive_client.execute,
            username=username,
            password=password,
            sql=validation.normalized_sql,
            max_rows=max_rows,
        )
        try:
            result = future.result(timeout=timeout)
        except TimeoutError as exc:
            raise HTTPException(status_code=504, detail="query timeout") from exc
        return {
            "query_id": query_id,
            "sql": validation.normalized_sql,
            "warnings": validation.warnings,
            "elapsed_ms": int((time.time() - started) * 1000),
            **result,
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    finally:
        concurrency.release(username)


def _require_session(session_id: str):
    session = sessions.get(session_id)
    if not session:
        raise HTTPException(status_code=401, detail="invalid or expired session")
    return session


def _resolve_credentials(session_id: str | None) -> tuple[str, str]:
    if session_id:
        session = _require_session(session_id)
        return session.username, session.password
    configured = hive_client.configured_credentials()
    if configured:
        return configured
    raise HTTPException(
        status_code=401,
        detail="missing session_id and no HIVE_USER/HIVE_PASSWORD configured",
    )
