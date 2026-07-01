from __future__ import annotations

import re
from typing import Any


IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class HiveClient:
    def __init__(self, config: dict) -> None:
        self.config = config["hive"]

    def test_connection(self, username: str, password: str) -> None:
        # Keep login cheap in the skeleton. Enable real validation by calling execute
        # with SELECT 1 once Hive dependencies and credentials are available.
        if not username or not password:
            raise ValueError("username and password are required")

    def configured_credentials(self) -> tuple[str, str] | None:
        username = self.config.get("username")
        password = self.config.get("password")
        if username and password:
            return str(username), str(password)
        return None

    def execute(self, username: str, password: str, sql: str, max_rows: int) -> dict[str, Any]:
        try:
            from pyhive import hive
        except ImportError as exc:
            raise RuntimeError("pyhive is not installed") from exc

        conn = hive.Connection(
            host=self.config["host"],
            port=int(self.config["port"]),
            username=username,
            password=password,
            database=self.config.get("database", "default"),
            auth=self.config.get("auth", "LDAP"),
        )
        try:
            cursor = conn.cursor()
            queue = self.config.get("queue")
            if queue:
                # 同时设置 MR 和 Tez 队列，兼容不同 Hive 执行引擎。
                cursor.execute(f"SET mapreduce.job.queuename={queue}")
                cursor.execute(f"SET tez.queue.name={queue}")
            cursor.execute(sql)
            columns = [desc[0] for desc in cursor.description or []]
            rows = cursor.fetchmany(max_rows)
            return {
                "columns": columns,
                "rows": [list(row) for row in rows],
                "row_count": len(rows),
                "truncated": len(rows) >= max_rows,
            }
        finally:
            conn.close()

    def list_databases(self, username: str, password: str) -> list[str]:
        result = self.execute(username=username, password=password, sql="SHOW DATABASES", max_rows=10000)
        databases: list[str] = []
        for row in result["rows"]:
            if row and row[0] is not None:
                databases.append(str(row[0]))
        return databases

    def list_tables(self, username: str, password: str, database: str) -> list[str]:
        if not IDENTIFIER_RE.fullmatch(database):
            raise ValueError("Invalid database name")
        result = self.execute(username=username, password=password, sql=f"SHOW TABLES IN `{database}`", max_rows=10000)
        tables: list[str] = []
        for row in result["rows"]:
            if row and row[0] is not None:
                tables.append(str(row[0]))
        return tables
