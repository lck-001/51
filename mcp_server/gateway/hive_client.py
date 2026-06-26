from typing import Any


class HiveClient:
    def __init__(self, config: dict) -> None:
        self.config = config["hive"]

    def test_connection(self, username: str, password: str) -> None:
        # Keep login cheap in the skeleton. Enable real validation by calling execute
        # with SELECT 1 once Hive dependencies and credentials are available.
        if not username or not password:
            raise ValueError("username and password are required")

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
