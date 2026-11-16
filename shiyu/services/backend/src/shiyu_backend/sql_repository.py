"""SQL persistence implementation shared by explicit PostgreSQL/validation adapters."""
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import uuid
from .models import (BackendError, DeliveryReceipt, Draft, ErrorCode,
                     MaterialVersion, ReceiptStatus)
from .repository import MaterialRepository


def _now():
    return datetime.now(timezone.utc).isoformat()


def _id():
    return uuid.uuid4().hex


class _Session:
    def __init__(self, connection, postgres):
        self.connection = connection
        self.postgres = postgres

    def execute(self, sql, params=()):
        if self.postgres:
            sql = sql.replace("?", "%s")
        return self.connection.execute(sql, params)

    def one(self, sql, params=(), *, lock=False):
        if lock and self.postgres:
            sql += " FOR UPDATE"
        row = self.execute(sql, params).fetchone()
        return dict(row) if row is not None else None

    def all(self, sql, params=()):
        return tuple(dict(row) for row in self.execute(sql, params).fetchall())

    def lock_operation(self, namespace, *parts):
        if self.postgres:
            # Stable transaction-scoped lock, not Python's randomized hash().
            raw = (namespace + "\0" + "\0".join(parts)).encode("utf-8")
            key = int.from_bytes(hashlib.sha256(raw).digest()[:8], "big", signed=True)
            self.execute("SELECT pg_advisory_xact_lock(?)", (key,))


class SQLMaterialRepository(MaterialRepository):
    postgres = False

    def __init__(self):
        self._closed = False

    def close(self):
        self._closed = True

    def _connect(self):
        raise NotImplementedError

    @contextmanager
    def _transaction(self, *, write=False):
        if self._closed:
            raise BackendError(ErrorCode.storage_unavailable)
        connection = None
        try:
            connection = self._connect()
            if not self.postgres:
                connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            session = _Session(connection, self.postgres)
            version = session.one("SELECT version FROM shiyu_backend_schema")
            if version is None or version["version"] != 1:
                raise BackendError(ErrorCode.storage_unavailable)
            yield session
            connection.commit()
        except BackendError:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
            raise
        except Exception:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
            raise BackendError(ErrorCode.storage_unavailable) from None
        finally:
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    pass

    @staticmethod
    def _draft(row):
        if row is None:
            raise BackendError(ErrorCode.not_found)
        return Draft(owner_id=row["owner_id"], material_id=row["material_id"],
            draft_id=row["draft_id"], revision=row["edit_revision"],
            title=row["title"], text=row["content_text"],
            original_text=row["original_text"], state=row["state"],
            updated_at=row["updated_at"])

    @staticmethod
    def _version(row):
        if row is None:
            raise BackendError(ErrorCode.not_found)
        return MaterialVersion(owner_id=row["owner_id"], material_id=row["material_id"],
            version_id=row["version_id"], version_number=row["version_number"],
            draft_id=row["draft_id"], draft_revision=row["draft_revision"],
            title=row["title"], text=row["content_text"], confirmed_at=row["confirmed_at"])

    @staticmethod
    def _receipt(row, *, replayed=False):
        return DeliveryReceipt(receipt_id=row["receipt_id"],
            material_id=row["material_id"], draft_id=row["draft_id"],
            status=ReceiptStatus(row["status"]), replayed=replayed)

    def receive(self, owner_id, integration_id, request, payload_hash):
        with self._transaction(write=True) as tx:
            tx.lock_operation("delivery", owner_id, integration_id, request.delivery_id)
            previous = tx.one("SELECT * FROM shiyu_receipts WHERE owner_id=? "
                "AND integration_id=? AND delivery_id=?",
                (owner_id, integration_id, request.delivery_id))
            if previous is not None:
                if previous["payload_hash"] != payload_hash:
                    raise BackendError(ErrorCode.delivery_conflict)
                return self._receipt(previous, replayed=True)
            tx.lock_operation("source", owner_id, integration_id, request.source_key)
            material = tx.one("SELECT * FROM shiyu_materials WHERE owner_id=? "
                "AND integration_id=? AND source_key=?",
                (owner_id, integration_id, request.source_key), lock=True)
            status = "update_pending" if material is not None else "accepted"
            material_id = material["material_id"] if material is not None else _id()
            now = _now()
            if material is None:
                tx.execute("INSERT INTO shiyu_materials "
                    "(material_id,owner_id,integration_id,source_key,latest_version_no,created_at) "
                    "VALUES (?,?,?,?,0,?)",
                    (material_id, owner_id, integration_id, request.source_key, now))
            draft_id, receipt_id = _id(), _id()
            tx.execute("INSERT INTO shiyu_drafts (draft_id,owner_id,material_id,source_revision,"
                "title,content_text,original_text,edit_revision,state,created_at,updated_at) "
                "VALUES (?,?,?,?,?,?,?,1,?,?,?)",
                (draft_id, owner_id, material_id, request.source_revision,
                 request.title, request.text, request.text,
                 "update_pending" if material is not None else "draft", now, now))
            row = {"receipt_id": receipt_id, "owner_id": owner_id,
                "integration_id": integration_id, "delivery_id": request.delivery_id,
                "payload_hash": payload_hash, "material_id": material_id,
                "draft_id": draft_id, "status": status, "created_at": now}
            tx.execute("INSERT INTO shiyu_receipts (receipt_id,owner_id,integration_id,delivery_id,"
                "payload_hash,material_id,draft_id,status,created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                tuple(row.values()))
            return self._receipt(row)

    def read_draft(self, owner_id, draft_id):
        with self._transaction() as tx:
            return self._draft(tx.one("SELECT * FROM shiyu_drafts WHERE owner_id=? AND draft_id=?",
                                     (owner_id, draft_id)))

    def list_drafts(self, owner_id):
        with self._transaction() as tx:
            return tuple(self._draft(row) for row in tx.all(
                "SELECT * FROM shiyu_drafts WHERE owner_id=? ORDER BY created_at,draft_id", (owner_id,)))

    def update_draft(self, owner_id, draft_id, expected_revision, title, text):
        with self._transaction(write=True) as tx:
            row = tx.one("SELECT * FROM shiyu_drafts WHERE owner_id=? AND draft_id=?",
                         (owner_id, draft_id), lock=True)
            if row is None:
                raise BackendError(ErrorCode.not_found)
            if row["edit_revision"] != expected_revision:
                raise BackendError(ErrorCode.revision_conflict)
            state = "draft" if row["state"] == "confirmed" else row["state"]
            tx.execute("UPDATE shiyu_drafts SET title=?,content_text=?,edit_revision=?,state=?,"
                "updated_at=? WHERE owner_id=? AND draft_id=? AND edit_revision=?",
                (row["title"] if title is None else title,
                 row["content_text"] if text is None else text,
                 expected_revision + 1, state, _now(), owner_id, draft_id, expected_revision))
            return self._draft(tx.one("SELECT * FROM shiyu_drafts WHERE owner_id=? AND draft_id=?",
                                     (owner_id, draft_id)))

    def confirm_draft(self, owner_id, draft_id, expected_revision):
        with self._transaction(write=True) as tx:
            initial = tx.one("SELECT material_id FROM shiyu_drafts WHERE owner_id=? AND draft_id=?",
                             (owner_id, draft_id))
            if initial is None:
                raise BackendError(ErrorCode.not_found)
            # Material then draft is a consistent lock order for version numbering.
            material = tx.one("SELECT * FROM shiyu_materials WHERE owner_id=? AND material_id=?",
                              (owner_id, initial["material_id"]), lock=True)
            draft = tx.one("SELECT * FROM shiyu_drafts WHERE owner_id=? AND draft_id=?",
                           (owner_id, draft_id), lock=True)
            if material is None or draft is None:
                raise BackendError(ErrorCode.not_found)
            if draft["edit_revision"] != expected_revision:
                raise BackendError(ErrorCode.revision_conflict)
            previous = tx.one("SELECT * FROM shiyu_versions WHERE owner_id=? AND draft_id=? "
                              "AND draft_revision=?", (owner_id, draft_id, expected_revision))
            if previous is not None:
                return self._version(previous)
            now, version_id = _now(), _id()
            number = material["latest_version_no"] + 1
            tx.execute("INSERT INTO shiyu_versions (version_id,owner_id,material_id,version_number,"
                "draft_id,draft_revision,title,content_text,confirmed_at) VALUES (?,?,?,?,?,?,?,?,?)",
                (version_id, owner_id, material["material_id"], number, draft_id,
                 expected_revision, draft["title"], draft["content_text"], now))
            tx.execute("UPDATE shiyu_materials SET latest_version_no=? WHERE owner_id=? AND material_id=?",
                       (number, owner_id, material["material_id"]))
            tx.execute("UPDATE shiyu_drafts SET state='confirmed',updated_at=? WHERE owner_id=? AND draft_id=?",
                       (now, owner_id, draft_id))
            return self._version(tx.one("SELECT * FROM shiyu_versions WHERE owner_id=? AND version_id=?",
                                       (owner_id, version_id)))

    def read_version(self, owner_id, version_id):
        with self._transaction() as tx:
            return self._version(tx.one("SELECT * FROM shiyu_versions WHERE owner_id=? AND version_id=?",
                                       (owner_id, version_id)))

    def list_versions(self, owner_id, material_id):
        with self._transaction() as tx:
            if tx.one("SELECT material_id FROM shiyu_materials WHERE owner_id=? AND material_id=?",
                      (owner_id, material_id)) is None:
                raise BackendError(ErrorCode.not_found)
            return tuple(self._version(row) for row in tx.all(
                "SELECT * FROM shiyu_versions WHERE owner_id=? AND material_id=? ORDER BY version_number",
                (owner_id, material_id)))
