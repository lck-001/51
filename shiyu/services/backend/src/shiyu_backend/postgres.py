"""PostgreSQL Adapter SOURCE; no connection is opened until an operation runs."""
from .models import BackendError, ErrorCode
from .sql_repository import SQLMaterialRepository


class PostgresRepository(SQLMaterialRepository):
    postgres = True

    def __init__(self, dsn):
        super().__init__()
        self._dsn = dsn

    def _connect(self):
        try:
            import psycopg
            from psycopg.rows import dict_row
        except ImportError:
            raise BackendError(ErrorCode.dependency_unavailable) from None
        return psycopg.connect(self._dsn, row_factory=dict_row, connect_timeout=5)
