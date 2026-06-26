from dataclasses import dataclass

import sqlglot
from sqlglot import exp


BLOCKED_KEYWORDS = {
    "insert",
    "overwrite",
    "drop",
    "alter",
    "create",
    "truncate",
    "delete",
    "update",
    "load data",
    "msck",
    "add jar",
    "transform",
}


@dataclass
class SqlValidationResult:
    normalized_sql: str
    warnings: list[str]


class SqlGuard:
    def __init__(self, config: dict) -> None:
        self.config = config
        self.limits = config["limits"]
        self.security = config["security"]

    def validate(self, sql: str, requested_limit: int | None = None) -> SqlValidationResult:
        cleaned = sql.strip().rstrip(";").strip()
        if len(cleaned) > int(self.limits["max_sql_length"]):
            raise ValueError("SQL exceeds max length")
        if ";" in cleaned:
            raise ValueError("Multiple SQL statements are not allowed")

        lowered = cleaned.lower()
        for keyword in BLOCKED_KEYWORDS:
            if keyword in lowered:
                raise ValueError(f"Blocked SQL keyword: {keyword}")

        parsed = sqlglot.parse_one(cleaned, read="hive")
        if not self._is_select_or_with_select(parsed):
            raise ValueError("Only SELECT or WITH SELECT is allowed")

        blocked_databases = set(self.security.get("blocked_databases", []))
        for table in parsed.find_all(exp.Table):
            db = table.db
            if db in blocked_databases:
                raise ValueError(f"Database is blocked: {db}")

        warnings: list[str] = []
        if self.security.get("require_partition_filter", True):
            partition_columns = set(self.security.get("partition_columns", []))
            referenced_columns = {col.name for col in parsed.find_all(exp.Column)}
            if partition_columns and not referenced_columns.intersection(partition_columns):
                warnings.append("No configured partition column was detected")

        normalized = self._ensure_limit(cleaned, requested_limit)
        return SqlValidationResult(normalized_sql=normalized, warnings=warnings)

    def _is_select_or_with_select(self, parsed: exp.Expression) -> bool:
        if isinstance(parsed, exp.Select):
            return True
        if isinstance(parsed, exp.With):
            return isinstance(parsed.this, exp.Select)
        return parsed.find(exp.Select) is not None and not any(
            parsed.find(kind)
            for kind in (exp.Insert, exp.Delete, exp.Update, exp.Create, exp.Drop)
        )

    def _ensure_limit(self, sql: str, requested_limit: int | None) -> str:
        default_limit = int(self.limits["default_limit"])
        max_limit = int(self.limits["max_limit"])
        effective_limit = min(requested_limit or default_limit, max_limit)
        parsed = sqlglot.parse_one(sql, read="hive")
        limit = parsed.args.get("limit")
        if limit is None:
            return f"SELECT * FROM ({sql}) mcp_limited_result LIMIT {effective_limit}"
        return sql
