"""Supplemental real-IO checks for bounded fixture generation; never a cloud test."""
from dataclasses import replace
from contextlib import closing
import io
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from shiyu_backend.generation import GenerationService, FixtureGenerationWorker
from shiyu_backend.generation_models import (
    DefinitelyNotSubmitted, FixtureAdapter, FixtureResult, GeneratedSentence,
    GenerationError, GenerationErrorCode, ValidationGrant,
)
from shiyu_backend.generation_sqlite_validation import SQLiteGenerationValidationRepository
from shiyu_backend.intake import IntakeService
from shiyu_backend.models import ReceiveMaterial, TrustedCaller
from shiyu_backend.sqlite_validation import SQLiteValidationRepository


class LocalGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shiyu-generation-local-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.now = [100.0]
        self.materials = SQLiteValidationRepository(self.path / "material.sqlite")
        self.jobs = SQLiteGenerationValidationRepository(self.path / "jobs.sqlite", clock=lambda: self.now[0])
        self.addCleanup(self.materials.close)
        self.addCleanup(self.jobs.close)
        self.caller = TrustedCaller("local-fixture-owner", "local-fixture-integration", frozenset({
            "materials:receive", "materials:read", "materials:confirm",
            "generation:create", "generation:read", "generation:cancel"}))
        intake = IntakeService(self.materials)
        receipt = intake.receive(self.caller, ReceiveMaterial("delivery", "source", "Synthetic only", "A paper boat."))
        self.version = intake.confirm_draft(self.caller, receipt.draft_id, 1)
        self.service = GenerationService(self.materials, self.jobs)
        self.grant = ValidationGrant("fixture-grant", self.caller.owner_id, "fixture-units", 40, 4)
        self.calls = 0

    def output(self, source, token):
        self.calls += 1
        audio = io.BytesIO()
        with wave.open(audio, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(bytes(32000))
        return FixtureResult(source.owner_id, source.material_version_id, source.input_sha256,
            (GeneratedSentence("A paper boat.", "原创结构夹具，不是翻译服务。", 0, 1000),),
            audio.getvalue(), 2, self.grant.unit)

    def queued(self, worker, request="request", grant=None):
        job = self.service.create(self.caller, self.version.version_id, request)
        return worker.admit(job.job_id, job.revision, grant or self.grant)

    def test_zero_cost_does_not_bypass_persistent_call_cap(self):
        grant = replace(self.grant, max_calls=1)
        worker = FixtureGenerationWorker(self.jobs, FixtureAdapter(
            lambda s, t: replace(self.output(s, t), usage_units=0)))
        first = self.queued(worker, grant=grant)
        done = worker.run(worker.claim(first.job_id, first.revision))
        self.assertEqual(done.state, "completed")
        self.jobs.close()
        self.jobs = SQLiteGenerationValidationRepository(self.path / "jobs.sqlite", clock=lambda: self.now[0])
        self.addCleanup(self.jobs.close)
        self.service = GenerationService(self.materials, self.jobs)
        worker = FixtureGenerationWorker(self.jobs, FixtureAdapter(self.output))
        second = self.queued(worker, "another-request", grant)
        self.assertEqual((second.state, second.reason), ("blocked", "budget_exhausted"))
        b = self.jobs.inspect_budget(self.caller.owner_id, grant.grant_id)
        self.assertEqual((b.spent_units, b.submitted_calls, b.reserved_calls, self.calls), (0, 1, 0, 1))

    def test_usage_missing_negative_wrong_unit_or_above_reservation_is_unknown(self):
        for index, changes in enumerate((
            {"usage_units": None}, {"usage_units": -1}, {"usage_unit": "wrong-unit"}, {"usage_units": 5},
        )):
            worker = FixtureGenerationWorker(self.jobs, FixtureAdapter(
                lambda s, t, changes=changes: replace(self.output(s, t), **changes)))
            q = self.queued(worker, str(index))
            result = worker.run(worker.claim(q.job_id, q.revision))
            self.assertEqual((result.state, result.budget_state, result.result_ref), ("uncertain", "unknown", None))
        b = self.jobs.inspect_budget(self.caller.owner_id, self.grant.grant_id)
        self.assertEqual((b.spent_units, b.reserved_units, b.unknown_held_units, b.submitted_calls), (0, 0, 16, 4))

    def test_positive_no_submission_evidence_releases_units_not_dispatch_cap(self):
        def not_sent(source, token):
            raise DefinitelyNotSubmitted("This private adapter detail must not be surfaced")
        worker = FixtureGenerationWorker(self.jobs, FixtureAdapter(not_sent))
        q = self.queued(worker)
        done = worker.run(worker.claim(q.job_id, q.revision))
        self.assertEqual((done.state, done.reason, done.budget_state), ("failed", "not_submitted", "released"))
        b = self.jobs.inspect_budget(self.caller.owner_id, self.grant.grant_id)
        self.assertEqual((b.reserved_units, b.spent_units, b.unknown_held_units, b.submitted_calls), (0, 0, 0, 1))

    def test_expired_success_does_not_publish_or_release_unknown_budget(self):
        def late(source, token):
            result = self.output(source, token)
            self.now[0] += 60
            return result
        worker = FixtureGenerationWorker(self.jobs, FixtureAdapter(late))
        q = self.queued(worker)
        token = worker.claim(q.job_id, q.revision, lease_seconds=5)
        result = worker.run(token)
        self.assertEqual((result.state, result.budget_state, result.result_ref), ("uncertain", "unknown", None))
        with self.assertRaises(GenerationError):
            worker.run(token)
        self.assertEqual(self.calls, 1)
        b = self.jobs.inspect_budget(self.caller.owner_id, self.grant.grant_id)
        self.assertEqual((b.spent_units, b.unknown_held_units), (0, 4))
        # Real file read proves a private staged candidate is not a published
        # manifest. It is retained for diagnosis, not erased into a healthy job.
        with closing(sqlite3.connect(self.path / "jobs.sqlite")) as c:
            self.assertEqual(c.execute("SELECT state FROM generation_results").fetchall(), [("staged",)])

    def test_foreign_database_is_not_reset(self):
        foreign = self.path / "foreign.sqlite"
        with closing(sqlite3.connect(foreign)) as c:
            c.execute("CREATE TABLE retained(value TEXT)")
            c.execute("INSERT INTO retained VALUES('synthetic retained value')")
            c.commit()
        with self.assertRaises(GenerationError) as caught:
            SQLiteGenerationValidationRepository(foreign)
        self.assertEqual(caught.exception.code, GenerationErrorCode.storage_unavailable)
        with closing(sqlite3.connect(foreign)) as c:
            self.assertEqual(c.execute("SELECT value FROM retained").fetchone()[0], "synthetic retained value")


if __name__ == "__main__":
    unittest.main()
