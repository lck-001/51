import os
import time
from typing import Any

import requests
from mcp.server.fastmcp import FastMCP


GATEWAY_BASE_URL = os.environ.get("HIVE_GATEWAY_URL", "http://127.0.0.1:8088").rstrip("/")

mcp = FastMCP("company-hive")
_SESSION_CACHE: dict[str, Any] = {"session_id": "", "expires_at": 0}


def _post(path: str, payload: dict[str, Any]) -> dict[str, Any]:
    response = requests.post(f"{GATEWAY_BASE_URL}{path}", json=payload, timeout=360)
    try:
        data = response.json()
    except ValueError as exc:
        raise RuntimeError(f"Gateway returned non-JSON HTTP {response.status_code}: {response.text}") from exc
    if response.status_code >= 400:
        raise RuntimeError(f"Gateway HTTP {response.status_code}: {data}")
    return data


def _get(path: str) -> dict[str, Any]:
    response = requests.get(f"{GATEWAY_BASE_URL}{path}", timeout=30)
    try:
        data = response.json()
    except ValueError as exc:
        raise RuntimeError(f"Gateway returned non-JSON HTTP {response.status_code}: {response.text}") from exc
    if response.status_code >= 400:
        raise RuntimeError(f"Gateway HTTP {response.status_code}: {data}")
    return data


def _load_local_credentials() -> dict[str, str]:
    # 企业客户端统一通过 MCP 配置 env 明文传入 Hive 账号密码，降低员工配置复杂度。
    env_username = os.environ.get("HIVE_USER") or os.environ.get("HIVE_USERNAME")
    env_password = os.environ.get("HIVE_PASSWORD")
    if env_username and env_password:
        return {"username": env_username.strip(), "password": env_password}

    raise RuntimeError("Missing Hive credentials. Set HIVE_USER/HIVE_PASSWORD in MCP env.")


def _local_session_id() -> str:
    now = int(time.time())
    cached_session_id = str(_SESSION_CACHE.get("session_id", ""))
    cached_expires_at = int(_SESSION_CACHE.get("expires_at", 0) or 0)
    if cached_session_id and cached_expires_at - 60 > now:
        return cached_session_id

    credentials = _load_local_credentials()
    login_result = _post("/api/login", credentials)
    session_id = str(login_result["session_id"])
    _SESSION_CACHE["session_id"] = session_id
    _SESSION_CACHE["expires_at"] = int(login_result.get("expires_at", now + 3600))
    return session_id


def _resolve_session_id(session_id: str) -> str:
    return session_id or _local_session_id()


@mcp.tool()
def list_hive_databases() -> dict[str, Any]:
    """List Hive databases available to the configured Hive user."""
    return _post("/api/hive/databases", {"session_id": _resolve_session_id("")})


@mcp.tool()
def list_hive_tables(database: str) -> dict[str, Any]:
    """List Hive tables in a database available to the configured Hive user."""
    return _post("/api/hive/tables", {"session_id": _resolve_session_id(""), "database": database})


@mcp.tool()
def check_hive_sql(sql: str, limit: int = 500, session_id: str = "") -> dict[str, Any]:
    """Check a Hive SELECT statement. Leave session_id empty to use HIVE_USER/HIVE_PASSWORD env."""
    return _post("/api/sql/validate", {"session_id": _resolve_session_id(session_id), "sql": sql, "limit": limit})


@mcp.tool()
def execute_hive_select(sql: str, limit: int = 500, timeout_seconds: int = 300, session_id: str = "") -> dict[str, Any]:
    """Execute a controlled Hive SELECT query. Leave session_id empty to use HIVE_USER/HIVE_PASSWORD env."""
    return _post(
        "/api/sql/execute",
        {
            "session_id": _resolve_session_id(session_id),
            "sql": sql,
            "limit": limit,
            "timeout_seconds": timeout_seconds,
        },
    )


@mcp.tool()
def search_hive_resources(keyword: str, domain: str = "", limit: int = 20) -> dict[str, Any]:
    """Search warehouse table, lineage, SLA, and profile resources."""
    payload: dict[str, Any] = {"keyword": keyword, "limit": limit}
    if domain:
        payload["domain"] = domain
    return _post("/api/assets/search", payload)


@mcp.tool()
def get_hive_table_schema(database: str, table: str) -> dict[str, Any]:
    """Get known metadata for a Hive table from the local asset index."""
    return _post("/api/assets/table", {"database": database, "table": table})


if __name__ == "__main__":
    mcp.run()
