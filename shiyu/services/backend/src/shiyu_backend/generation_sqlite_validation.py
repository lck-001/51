"""Bounded, local SQLite generation Adapter. Not PostgreSQL/production authority."""
from contextlib import closing, contextmanager
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import sqlite3
import time
import uuid

from .generation_models import (
    AttemptToken, BudgetSnapshot, FrozenInput, GenerationError,
    GenerationErrorCode as E, GenerationOptions, JobView, ResultManifest,
)


def _id():
    return uuid.uuid4().hex


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


_SCHEMA = """
CREATE TABLE generation_schema(version INTEGER PRIMARY KEY CHECK(version=1));
INSERT INTO generation_schema VALUES(1);
CREATE TABLE generation_jobs(
 job_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, request_id TEXT NOT NULL,
 request_hash TEXT NOT NULL, material_id TEXT NOT NULL, version_id TEXT NOT NULL,
 input_hash TEXT NOT NULL, title TEXT NOT NULL, content_text TEXT NOT NULL,
 options_json TEXT NOT NULL, revision INTEGER NOT NULL, state TEXT NOT NULL,
 phase TEXT NOT NULL, reason TEXT, result_ref TEXT, execution_kind TEXT,
 cancel_requested INTEGER NOT NULL DEFAULT 0, budget_state TEXT NOT NULL,
 grant_id TEXT, admission_hash TEXT, reserved_units INTEGER NOT NULL DEFAULT 0,
 submission_recorded INTEGER NOT NULL DEFAULT 0,
 fence INTEGER NOT NULL DEFAULT 0, UNIQUE(owner_id,request_id));
CREATE TABLE generation_budgets(
 owner_id TEXT NOT NULL, grant_id TEXT NOT NULL, unit TEXT NOT NULL,
 config_ref TEXT NOT NULL, per_job_units INTEGER NOT NULL,
 limit_units INTEGER NOT NULL, reserved_units INTEGER NOT NULL DEFAULT 0,
 spent_units INTEGER NOT NULL DEFAULT 0, unknown_units INTEGER NOT NULL DEFAULT 0,
 max_calls INTEGER NOT NULL, reserved_calls INTEGER NOT NULL DEFAULT 0,
 submitted_calls INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(owner_id,grant_id));
CREATE TABLE generation_attempts(
 attempt_id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES generation_jobs(job_id),
 fence INTEGER NOT NULL, operation_key TEXT NOT NULL UNIQUE,
 expires_at REAL NOT NULL, dispatched INTEGER NOT NULL DEFAULT 0,
 state TEXT NOT NULL, result_ref TEXT NOT NULL UNIQUE);
CREATE TABLE generation_results(
 result_ref TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES generation_jobs(job_id),
 owner_id TEXT NOT NULL, attempt_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
 manifest_json TEXT NOT NULL, sentence_json TEXT NOT NULL, audio_wav BLOB NOT NULL,
 state TEXT NOT NULL);
"""


class SQLiteGenerationValidationRepository:
    """Trusted internal persistence seam; service performs caller authorization.

    Uses a separate validation database, never writes the material repository's
    migration/version or a Dart manifest. File-level BEGIN IMMEDIATE serializes
    local budget and state changes; this is not a distributed worker/PG proof.
    """
    def __init__(self, database_path, *, clock=time.time):
        self._path = Path(database_path)
        self._closed = False
        self._clock = clock
        if str(database_path) == ":memory:" or self._path.is_symlink():
            raise GenerationError(E.invalid_input)
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            with closing(self._connect()) as c:
                names = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if not names:
                    c.executescript("BEGIN IMMEDIATE;" + _SCHEMA + "COMMIT;")
                elif names != {"generation_schema", "generation_jobs", "generation_budgets",
                               "generation_attempts", "generation_results"}:
                    raise GenerationError(E.storage_unavailable)
                rows = c.execute("SELECT version FROM generation_schema").fetchall()
                if len(rows) != 1 or rows[0][0] != 1:
                    raise GenerationError(E.storage_unavailable)
        except GenerationError:
            raise
        except Exception:
            raise GenerationError(E.storage_unavailable) from None

    def close(self):
        self._closed = True

    def _connect(self):
        c = sqlite3.connect(self._path, timeout=5, isolation_level=None)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA foreign_keys=ON")
        return c

    @contextmanager
    def _tx(self, *, write=False):
        c = None
        try:
            if self._closed:
                raise GenerationError(E.storage_unavailable)
            c = self._connect()
            c.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            schema = c.execute("SELECT version FROM generation_schema").fetchall()
            if len(schema) != 1 or schema[0][0] != 1:
                raise GenerationError(E.storage_unavailable)
            yield c
            c.commit()
        except GenerationError:
            if c is not None:
                c.rollback()
            raise
        except Exception:
            if c is not None:
                c.rollback()
            raise GenerationError(E.storage_unavailable) from None
        finally:
            if c is not None:
                c.close()

    @staticmethod
    def _row(c, job_id, owner_id=None):
        sql = "SELECT * FROM generation_jobs WHERE job_id=?"
        params = (job_id,)
        if owner_id is not None:
            sql += " AND owner_id=?"
            params += (owner_id,)
        row = c.execute(sql, params).fetchone()
        if row is None:
            raise GenerationError(E.not_found)
        return row

    @staticmethod
    def _view(row):
        return JobView(row["job_id"], row["material_id"], row["version_id"],
            row["input_hash"], row["revision"], row["state"], row["phase"],
            row["reason"], row["result_ref"], row["execution_kind"],
            bool(row["cancel_requested"]), row["budget_state"])

    def create(self, source, request_id, options, request_hash):
        with self._tx(write=True) as c:
            old = c.execute("SELECT * FROM generation_jobs WHERE owner_id=? AND request_id=?",
                (source.owner_id, request_id)).fetchone()
            if old is not None:
                if old["request_hash"] != request_hash:
                    raise GenerationError(E.request_conflict)
                return self._view(old)
            job_id = _id()
            c.execute("""INSERT INTO generation_jobs
             (job_id,owner_id,request_id,request_hash,material_id,version_id,input_hash,
              title,content_text,options_json,revision,state,phase,reason,budget_state)
             VALUES(?,?,?,?,?,?,?,?,?,?,1,'blocked','admission','resources_unavailable','unreserved')""",
             (job_id, source.owner_id, request_id, request_hash, source.material_id,
              source.material_version_id, source.input_sha256, source.title, source.text,
              _json(asdict(options))))
            return self._view(self._row(c, job_id))

    def get(self, owner_id, job_id):
        with self._tx() as c:
            return self._view(self._row(c, job_id, owner_id))

    @staticmethod
    def _release(c, row):
        if row["budget_state"] != "reserved":
            return
        c.execute("""UPDATE generation_budgets SET reserved_units=reserved_units-?,
          reserved_calls=reserved_calls-?
          WHERE owner_id=? AND grant_id=?""",
          (row["reserved_units"], 0 if row["submission_recorded"] else 1,
           row["owner_id"], row["grant_id"]))

    def cancel(self, owner_id, job_id, revision):
        with self._tx(write=True) as c:
            row = self._row(c, job_id, owner_id)
            if row["revision"] != revision:
                raise GenerationError(E.revision_conflict)
            if row["state"] in {"cancelled", "completed", "failed"} or row["cancel_requested"]:
                return self._view(row)
            state = "cancel_requested"
            budget = row["budget_state"]
            if row["state"] in {"blocked", "queued"}:
                self._release(c, row)
                state, budget = "cancelled", "released"
            elif row["state"] == "uncertain":
                state = "uncertain"
            c.execute("""UPDATE generation_jobs SET state=?, cancel_requested=1,
             budget_state=?,revision=revision+1 WHERE job_id=?""", (state, budget, job_id))
            return self._view(self._row(c, job_id))

    def admit(self, job_id, revision, grant, *, admission_hash, blocked_reason=None):
        with self._tx(write=True) as c:
            row = self._row(c, job_id)
            if row["revision"] != revision:
                raise GenerationError(E.revision_conflict)
            if row["state"] != "blocked":
                raise GenerationError(E.worker_conflict)
            if row["owner_id"] != grant.owner_id:
                raise GenerationError(E.not_found)
            if blocked_reason is not None:
                c.execute("UPDATE generation_jobs SET reason=?,revision=revision+1 WHERE job_id=?",
                    (blocked_reason, job_id))
                return self._view(self._row(c, job_id))
            budget = c.execute("SELECT * FROM generation_budgets WHERE owner_id=? AND grant_id=?",
                (row["owner_id"], grant.grant_id)).fetchone()
            if budget is None:
                c.execute("""INSERT INTO generation_budgets
                 (owner_id,grant_id,unit,config_ref,per_job_units,limit_units,max_calls) VALUES(?,?,?,?,?,?,?)""",
                 (row["owner_id"], grant.grant_id, grant.unit, grant.config_ref,
                  grant.reserve_units, grant.limit_units, grant.max_calls))
                used = 0
                calls = 0
            else:
                if (budget["unit"], budget["config_ref"], budget["per_job_units"], budget["limit_units"], budget["max_calls"]) != (
                    grant.unit, grant.config_ref, grant.reserve_units, grant.limit_units, grant.max_calls):
                    raise GenerationError(E.invalid_input)
                used = budget["reserved_units"] + budget["spent_units"] + budget["unknown_units"]
                calls = budget["reserved_calls"] + budget["submitted_calls"]
            if used + grant.reserve_units > grant.limit_units or calls >= grant.max_calls:
                c.execute("UPDATE generation_jobs SET reason='budget_exhausted',revision=revision+1 WHERE job_id=?",
                    (job_id,))
            else:
                c.execute("UPDATE generation_budgets SET reserved_units=reserved_units+?,reserved_calls=reserved_calls+1 WHERE owner_id=? AND grant_id=?",
                    (grant.reserve_units, row["owner_id"], grant.grant_id))
                c.execute("""UPDATE generation_jobs SET state='queued',reason=NULL,revision=revision+1,
                 grant_id=?,admission_hash=?,reserved_units=?,budget_state='reserved',execution_kind='fixture' WHERE job_id=?""",
                 (grant.grant_id, admission_hash, grant.reserve_units, job_id))
            return self._view(self._row(c, job_id))

    def frozen_input(self, job_id):
        with self._tx() as c:
            row = self._row(c, job_id)
            return FrozenInput(row["owner_id"], row["material_id"], row["version_id"],
                row["input_hash"], row["title"], row["content_text"],
                GenerationOptions(**json.loads(row["options_json"])))

    def claim(self, job_id, revision, lease_seconds, admission_hash):
        with self._tx(write=True) as c:
            row = self._row(c, job_id)
            if row["revision"] != revision:
                raise GenerationError(E.revision_conflict)
            if row["state"] != "queued":
                raise GenerationError(E.worker_conflict)
            if row["admission_hash"] != admission_hash:
                raise GenerationError(E.worker_conflict)
            token = AttemptToken(job_id, _id(), row["fence"] + 1, _id(), self._clock()+lease_seconds)
            c.execute("""INSERT INTO generation_attempts
             (attempt_id,job_id,fence,operation_key,expires_at,state,result_ref)
             VALUES(?,?,?,?,?,'claimed',?)""", (token.attempt_id, job_id, token.fence,
             token.operation_key, token.expires_at, _id()))
            c.execute("""UPDATE generation_jobs SET state='running',phase='generate_bundle',
             revision=revision+1,fence=? WHERE job_id=?""", (token.fence, job_id))
            return token

    @staticmethod
    def _attempt(c, token):
        if not isinstance(token, AttemptToken):
            raise GenerationError(E.invalid_input)
        a = c.execute("SELECT * FROM generation_attempts WHERE attempt_id=? AND job_id=?",
            (token.attempt_id, token.job_id)).fetchone()
        row = SQLiteGenerationValidationRepository._row(c, token.job_id)
        if (a is None or a["fence"] != token.fence or row["fence"] != token.fence
            or a["operation_key"] != token.operation_key or a["expires_at"] != token.expires_at):
            raise GenerationError(E.worker_conflict)
        return row, a

    @staticmethod
    def _uncertain(c, row, attempt_id, reason):
        if row["budget_state"] == "reserved":
            c.execute("""UPDATE generation_budgets SET reserved_units=reserved_units-?,
             unknown_units=unknown_units+? WHERE owner_id=? AND grant_id=?""",
             (row["reserved_units"], row["reserved_units"], row["owner_id"], row["grant_id"]))
        c.execute("UPDATE generation_jobs SET state='uncertain',reason=?,budget_state='unknown',revision=revision+1 WHERE job_id=?",
            (reason, row["job_id"]))
        c.execute("UPDATE generation_attempts SET state='uncertain' WHERE attempt_id=?", (attempt_id,))

    def start(self, token, admission_hash):
        """CAS the first outbound submission; one claim cannot execute twice."""
        with self._tx(write=True) as c:
            row, a = self._attempt(c, token)
            if row["admission_hash"] != admission_hash:
                raise GenerationError(E.worker_conflict)
            if a["state"] != "claimed" or a["dispatched"] or row["state"] not in {"running", "cancel_requested"}:
                raise GenerationError(E.worker_conflict)
            if token.expires_at <= self._clock():
                self._uncertain(c, row, a["attempt_id"], "execution_unknown")
                return False
            if row["cancel_requested"]:
                self._release(c, row)
                c.execute("UPDATE generation_jobs SET state='cancelled',budget_state='released',revision=revision+1 WHERE job_id=?",
                    (token.job_id,))
                c.execute("UPDATE generation_attempts SET state='not_submitted' WHERE attempt_id=?", (token.attempt_id,))
                return False
            c.execute("UPDATE generation_attempts SET dispatched=1,state='dispatched' WHERE attempt_id=? AND dispatched=0",
                (token.attempt_id,))
            c.execute("UPDATE generation_jobs SET submission_recorded=1 WHERE job_id=?", (token.job_id,))
            c.execute("""UPDATE generation_budgets SET reserved_calls=reserved_calls-1,
             submitted_calls=submitted_calls+1 WHERE owner_id=? AND grant_id=?""",
             (row["owner_id"], row["grant_id"]))
            return True

    def unknown(self, token):
        with self._tx(write=True) as c:
            row, a = self._attempt(c, token)
            if a["state"] != "dispatched" or row["state"] not in {"running", "cancel_requested"}:
                raise GenerationError(E.worker_conflict)
            self._uncertain(c, row, token.attempt_id, "execution_unknown")
            return self._view(self._row(c, token.job_id))

    def not_submitted(self, token):
        with self._tx(write=True) as c:
            row, a = self._attempt(c, token)
            if a["state"] != "dispatched" or row["state"] not in {"running", "cancel_requested"}:
                raise GenerationError(E.worker_conflict)
            self._release(c, row)
            c.execute("""UPDATE generation_jobs SET state=?,reason='not_submitted',
             budget_state='released',revision=revision+1 WHERE job_id=?""",
             ("cancelled" if row["cancel_requested"] else "failed", token.job_id))
            c.execute("UPDATE generation_attempts SET state='not_submitted' WHERE attempt_id=?", (token.attempt_id,))
            return self._view(self._row(c, token.job_id))

    def finish(self, token, result, manifest=None, *, valid=False):
        """Write private candidate bytes first, then CAS manifest+known settlement.

        A crash between these transactions leaves a staged, invisible candidate.
        Recovery never treats its existence as evidence of a completed operation.
        """
        if valid:
            payload_hash = hashlib.sha256(result.audio_wav + _json([
                asdict(s) for s in result.sentences]).encode("utf-8")).hexdigest()
            with self._tx(write=True) as c:
                row, a = self._attempt(c, token)
                if a["state"] != "dispatched":
                    raise GenerationError(E.worker_conflict)
                old = c.execute("SELECT payload_hash FROM generation_results WHERE result_ref=?", (a["result_ref"],)).fetchone()
                if old is not None and old[0] != payload_hash:
                    raise GenerationError(E.worker_conflict)
                if old is None:
                    final_manifest = dict(manifest, result_ref=a["result_ref"])
                    c.execute("INSERT INTO generation_results VALUES(?,?,?,?,?,?,?,?,'staged')",
                        (a["result_ref"], token.job_id, row["owner_id"], token.attempt_id,
                         payload_hash, _json(final_manifest), _json([asdict(s) for s in result.sentences]), result.audio_wav))
        with self._tx(write=True) as c:
            row, a = self._attempt(c, token)
            if a["state"] != "dispatched" or row["state"] not in {"running", "cancel_requested"}:
                raise GenerationError(E.worker_conflict)
            if token.expires_at <= self._clock():
                self._uncertain(c, row, token.attempt_id, "execution_unknown")
                return self._view(self._row(c, token.job_id))
            b = c.execute("SELECT * FROM generation_budgets WHERE owner_id=? AND grant_id=?",
                (row["owner_id"], row["grant_id"])).fetchone()
            usage = getattr(result, "usage_units", None)
            unit = getattr(result, "usage_unit", None)
            if type(usage) is not int or usage < 0 or usage > row["reserved_units"] or unit != b["unit"]:
                self._uncertain(c, row, token.attempt_id, "usage_unknown")
                return self._view(self._row(c, token.job_id))
            c.execute("""UPDATE generation_budgets SET reserved_units=reserved_units-?,spent_units=spent_units+?
             WHERE owner_id=? AND grant_id=?""", (row["reserved_units"], usage, row["owner_id"], row["grant_id"]))
            cancelled = bool(row["cancel_requested"])
            state = "cancelled" if cancelled else "completed" if valid else "failed"
            reason = None if valid or cancelled else "invalid_result"
            result_ref = a["result_ref"] if valid and not cancelled else None
            c.execute("""UPDATE generation_jobs SET state=?,phase='package',reason=?,result_ref=?,
             budget_state='settled',revision=revision+1 WHERE job_id=?""", (state, reason, result_ref, token.job_id))
            c.execute("UPDATE generation_attempts SET state='settled' WHERE attempt_id=?", (token.attempt_id,))
            if valid:
                c.execute("UPDATE generation_results SET state=? WHERE result_ref=?",
                    ("discarded" if cancelled else "published", a["result_ref"]))
            return self._view(self._row(c, token.job_id))

    def recover_expired(self):
        count = 0
        with self._tx(write=True) as c:
            rows = c.execute("""SELECT a.attempt_id,a.job_id FROM generation_attempts a
             JOIN generation_jobs j ON j.job_id=a.job_id AND j.fence=a.fence
             WHERE a.state IN ('claimed','dispatched') AND a.expires_at<=?
             AND j.state IN ('running','cancel_requested')""", (self._clock(),)).fetchall()
            for a in rows:
                self._uncertain(c, self._row(c, a["job_id"]), a["attempt_id"], "execution_unknown")
                count += 1
        return count

    def inspect_budget(self, owner_id, grant_id):
        with self._tx() as c:
            b = c.execute("SELECT * FROM generation_budgets WHERE owner_id=? AND grant_id=?",
                (owner_id, grant_id)).fetchone()
            if b is None:
                raise GenerationError(E.not_found)
            return BudgetSnapshot(b["unit"], b["limit_units"], b["reserved_units"], b["spent_units"], b["unknown_units"],
                b["max_calls"], b["reserved_calls"], b["submitted_calls"])

    def inspect_result(self, owner_id, result_ref):
        with self._tx() as c:
            r = c.execute("SELECT manifest_json FROM generation_results WHERE owner_id=? AND result_ref=? AND state='published'",
                (owner_id, result_ref)).fetchone()
            if r is None:
                raise GenerationError(E.not_found)
            return ResultManifest(**json.loads(r[0]))
