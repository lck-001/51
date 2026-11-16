"""Validation-only real SQLite Adapter. NOT the production PostgreSQL authority."""
from pathlib import Path
import sqlite3
from .models import BackendError, ErrorCode
from .sql_repository import SQLMaterialRepository


class SQLiteValidationRepository(SQLMaterialRepository):
    def __init__(self, database_path):
        super().__init__()
        self._path = Path(database_path)
        if str(database_path) == ":memory:" or self._path.is_symlink():
            raise BackendError(ErrorCode.invalid_input)
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            connection = self._connect()
            try:
                # Keep the shared column/constraint contract; PG-specific locking
                # is deliberately not emulated or claimed by these tests.
                schema = Path(__file__).resolve().parents[2] / "migrations" / "0001_intake_materials.sql"
                migration = schema.read_text(encoding="utf-8")
                existing = connection.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
                names = {row[0] for row in existing}
                if not names:
                    connection.executescript(migration)
                elif "shiyu_backend_schema" not in names:
                    raise BackendError(ErrorCode.storage_unavailable)
                rows = connection.execute("SELECT version FROM shiyu_backend_schema").fetchall()
                if len(rows) != 1 or rows[0][0] != 1:
                    raise BackendError(ErrorCode.storage_unavailable)
            finally:
                connection.close()
        except BackendError:
            raise
        except Exception:
            raise BackendError(ErrorCode.storage_unavailable) from None

    def _connect(self):
        connection = sqlite3.connect(self._path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        return connection
