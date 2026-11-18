"""Independent M19 Interface QA: real temporary SQLite, synthetic fixtures only.

No network/provider, Dart manifest, production identity or user material is used.
Fixture PCM is silence: successful structure is not translation/TTS quality.
"""
from dataclasses import asdict, replace
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from shiyu_backend.generation import GenerationService, FixtureGenerationWorker
from shiyu_backend.generation_models import (
    FixtureAdapter, FixtureCapabilities, FixtureResult, GeneratedSentence,
    GenerationError, GenerationErrorCode, GenerationOptions, ValidationGrant,
)
from shiyu_backend.generation_sqlite_validation import SQLiteGenerationValidationRepository
from shiyu_backend.intake import IntakeService
from shiyu_backend.models import ReceiveMaterial, TrustedCaller
from shiyu_backend.sqlite_validation import SQLiteValidationRepository


OWNER = "independent-generation-owner"
OTHER = "independent-generation-other"
ALL_SCOPES = frozenset({
    "materials:receive", "materials:read", "materials:write", "materials:confirm",
    "generation:create", "generation:read", "generation:cancel",
})
OPTIONS = GenerationOptions(voice_config_ref="fixture-v1")


def identity(owner=OWNER, scopes=ALL_SCOPES):
    return TrustedCaller(owner, "independent-fixture-agent", frozenset(scopes))


def pcm():
    target = io.BytesIO()
    with wave.open(target, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(b"\0\0" * 16000)
    return target.getvalue()


def valid_result(source, _token, *, usage=3):
    return FixtureResult(
        source.owner_id, source.material_version_id, source.input_sha256,
        (GeneratedSentence("A paper boat floats.", "一只纸船漂着。", 0, 1000),),
        pcm(), usage, "fixture-call-units",
    )


class IndependentGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shiyu-generation-independent-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.materials = SQLiteValidationRepository(self.root / "materials.sqlite3")
        self.intake = IntakeService(self.materials)
        self.jobs = SQLiteGenerationValidationRepository(self.root / "jobs.sqlite3")
        self.service = GenerationService(self.materials, self.jobs)
        self.a, self.b = identity(), identity(OTHER)
        self.serial = 0
        self.addCleanup(self.materials.close)
        if hasattr(self.jobs, "close"):
            self.addCleanup(self.jobs.close)

    def material(self, owner=None, text="合成事实：一只纸船漂在水面上。"):
        self.serial += 1
        owner = owner or self.a
        receipt = self.intake.receive(owner, ReceiveMaterial(
            f"fixture-delivery-{self.serial}", f"fixture-source-{self.serial}",
            "Original independent fixture", text,
        ))
        draft = self.intake.read_draft(owner, receipt.draft_id)
        return self.intake.confirm_draft(owner, draft.draft_id, draft.revision)

    def create(self, *, who=None, version=None, request=None, options=OPTIONS):
        version = version or self.material(who)
        return self.service.create(who or self.a, version.version_id,
                                   request or f"request-{self.serial}", options)

    def grant(self, *, limit=20, reserve=5, name="independent-grant", owner=OWNER):
        return ValidationGrant(name, owner, "fixture-call-units", limit, reserve)

    def admit(self, job, worker, grant=None):
        return worker.admit(job.job_id, job.revision, grant or self.grant())

    def worker(self, generate=valid_result, capabilities=FixtureCapabilities()):
        return FixtureGenerationWorker(self.jobs, FixtureAdapter(generate, capabilities))

    def denied(self, code, operation):
        with self.assertRaises(GenerationError) as raised:
            operation()
        self.assertEqual(raised.exception.code, code)

    def test_default_is_blocked_and_receive_scope_cannot_create_or_inspect(self):
        version = self.material()
        job = self.create(version=version)
        self.assertEqual(job.state, "blocked")
        self.assertIsNone(job.result_ref)
        self.assertIsNone(job.execution_kind)
        public = json.dumps(asdict(job))
        for private in (version.text, version.title, str(self.root)):
            self.assertNotIn(private, public)
        receiver = identity(scopes={"materials:receive"})
        self.denied(GenerationErrorCode.scope_denied,
                    lambda: self.create(who=receiver, version=version))
        self.denied(GenerationErrorCode.scope_denied,
                    lambda: self.service.get(receiver, job.job_id))
        self.denied(GenerationErrorCode.not_found,
                    lambda: self.service.get(self.b, job.job_id))
        self.denied(GenerationErrorCode.not_found,
                    lambda: self.create(who=self.b, version=version))

    def test_confirmed_source_and_request_id_are_durable_and_immutable(self):
        version = self.material()
        first = self.create(version=version, request="persistent-key")
        reopened = GenerationService(self.materials,
            SQLiteGenerationValidationRepository(self.root / "jobs.sqlite3"))
        second = reopened.create(self.a, version.version_id, "persistent-key", OPTIONS)
        self.assertEqual(first.job_id, second.job_id)
        self.assertEqual(first.input_sha256, second.input_sha256)
        newer = self.material(text="新合成事实：两只纸船。")
        self.denied(GenerationErrorCode.request_conflict,
                    lambda: reopened.create(self.a, newer.version_id, "persistent-key", OPTIONS))
        self.denied(GenerationErrorCode.request_conflict,
                    lambda: reopened.create(self.a, version.version_id, "persistent-key",
                        replace(OPTIONS, require_timings=False)))
        self.assertEqual(self.service.get(self.a, first.job_id).material_version_id,
                         version.version_id)

    def test_draft_is_not_a_generation_source_and_confirmed_edits_do_not_rebind_job(self):
        receipt = self.intake.receive(self.a, ReceiveMaterial(
            "draft-only", "source-edit", "Synthetic original", "原始合成事实：一只纸船。"))
        self.denied(GenerationErrorCode.not_found,
                    lambda: self.service.create(self.a, receipt.draft_id, "must-confirm", OPTIONS))
        version = self.intake.confirm_draft(self.a, receipt.draft_id, 1)
        job = self.create(version=version, request="original-generation")
        updated = self.intake.update_draft(self.a, receipt.draft_id, 1,
                                          text="新合成事实：三只纸船。")
        new_version = self.intake.confirm_draft(self.a, receipt.draft_id, updated.revision)
        newer = self.create(version=new_version, request="new-version-generation")
        self.assertNotEqual(newer.input_sha256, job.input_sha256)
        observed = []
        def generate(source, token):
            observed.append((source.material_version_id, source.text))
            return valid_result(source, token)
        worker = self.worker(generate)
        queued = self.admit(job, worker)
        token = worker.claim(queued.job_id, queued.revision)
        final = worker.run(token)
        self.assertEqual(final.state, "completed")
        self.assertEqual(observed, [(version.version_id, version.text)])

    def test_capability_or_wrong_owner_grant_cannot_reach_adapter(self):
        calls = []
        for capabilities in (
            FixtureCapabilities(locale="zh-CN"),
            FixtureCapabilities(pricing_known=False),
            FixtureCapabilities(timings=False),
            FixtureCapabilities(rights_confirmed=False),
        ):
            with self.subTest(capabilities=capabilities):
                job = self.create()
                worker = self.worker(lambda source, token: calls.append(token), capabilities)
                try:
                    outcome = self.admit(job, worker)
                except GenerationError:
                    outcome = self.service.get(self.a, job.job_id)
                self.assertEqual(outcome.state, "blocked")
        job = self.create()
        try:
            self.admit(job, self.worker(), self.grant(owner=OTHER))
        except GenerationError:
            pass
        self.assertEqual(self.service.get(self.a, job.job_id).state, "blocked")
        self.assertEqual(calls, [])

    def test_unknown_content_policy_is_not_an_admitted_capability(self):
        job = self.create(options=replace(OPTIONS, policy_version="unreviewed-policy"))
        try:
            admitted = self.admit(job, self.worker())
        except GenerationError:
            admitted = self.service.get(self.a, job.job_id)
        self.assertEqual(admitted.state, "blocked")

    def test_different_or_unavailable_worker_cannot_spend_old_admission(self):
        for capabilities in (
            FixtureCapabilities(config_ref="different-fixture-config"),
            FixtureCapabilities(rights_confirmed=False),
        ):
            with self.subTest(capabilities=capabilities):
                calls = []
                job = self.admit(self.create(), self.worker())
                replacement = self.worker(
                    lambda source, token: calls.append(token) or valid_result(source, token),
                    capabilities,
                )
                try:
                    token = replacement.claim(job.job_id, job.revision)
                    replacement.run(token)
                except GenerationError:
                    pass
                self.assertEqual(calls, [])
                self.assertNotEqual(self.service.get(self.a, job.job_id).state, "completed")

    def test_same_claim_parallel_run_enters_adapter_only_once(self):
        entered, release = threading.Event(), threading.Event()
        calls, errors = [], []
        def generate(source, token):
            calls.append(token.operation_key)
            entered.set()
            if not release.wait(4):
                raise TimeoutError("controlled gate")
            return valid_result(source, token)
        worker = self.worker(generate)
        job = self.admit(self.create(), worker)
        token = worker.claim(job.job_id, job.revision)
        def run():
            try:
                worker.run(token)
            except Exception as error:
                errors.append(error)
        first = threading.Thread(target=run)
        first.start()
        try:
            self.assertTrue(entered.wait(2))
            second = threading.Thread(target=run)
            second.start()
            second.join(2)
            self.assertFalse(second.is_alive())
            self.assertEqual(len(calls), 1)
        finally:
            release.set()
            first.join(4)
        self.assertFalse(first.is_alive())
        self.assertEqual(len(calls), 1)
        completed = self.service.get(self.a, job.job_id)
        self.assertEqual(completed.state, "completed")
        self.assertEqual(completed.execution_kind, "fixture")
        self.assertIsNotNone(completed.result_ref)

    def test_running_cancel_is_not_completion_and_late_result_never_publishes(self):
        entered, release = threading.Event(), threading.Event()
        errors = []
        def generate(source, token):
            entered.set()
            if not release.wait(4):
                raise TimeoutError("controlled cancel gate")
            return valid_result(source, token)
        worker = self.worker(generate)
        job = self.admit(self.create(), worker)
        token = worker.claim(job.job_id, job.revision)
        def run():
            try:
                worker.run(token)
            except Exception as error:
                errors.append(error)
        thread = threading.Thread(target=run)
        thread.start()
        try:
            self.assertTrue(entered.wait(2))
            running = self.service.get(self.a, job.job_id)
            cancelled = self.service.cancel(self.a, job.job_id, running.revision)
            self.assertEqual(cancelled.state, "cancel_requested")
            self.assertIsNone(cancelled.result_ref)
        finally:
            release.set()
            thread.join(4)
        self.assertFalse(thread.is_alive())
        final = self.service.get(self.a, job.job_id)
        self.assertEqual(final.state, "cancelled")
        self.assertIsNone(final.result_ref)

    def test_ordinary_adapter_error_is_unknown_and_cannot_be_replayed(self):
        calls = []
        def generate(source, token):
            calls.append(token.operation_key)
            raise RuntimeError("provider-raw-error PRIVATE_FIXTURE_BODY secret-do-not-reflect")
        worker = self.worker(generate)
        job = self.admit(self.create(), worker)
        token = worker.claim(job.job_id, job.revision)
        try:
            worker.run(token)
        except GenerationError:
            pass
        unknown = self.service.get(self.a, job.job_id)
        self.assertEqual(unknown.state, "uncertain")
        self.assertNotIn("secret-do-not-reflect", repr(unknown))
        try:
            worker.run(token)
        except GenerationError:
            pass
        self.assertEqual(len(calls), 1)
        reopened = GenerationService(self.materials,
            SQLiteGenerationValidationRepository(self.root / "jobs.sqlite3"))
        self.assertEqual(reopened.get(self.a, job.job_id).state, "uncertain")

    def test_atomic_budget_reservation_across_repository_instances(self):
        first, second = self.create(), self.create()
        grant = self.grant(limit=5)
        start = threading.Barrier(2)
        outcomes = []
        def admit(job):
            repository = SQLiteGenerationValidationRepository(self.root / "jobs.sqlite3")
            worker = FixtureGenerationWorker(repository, FixtureAdapter(valid_result))
            start.wait(timeout=3)
            try:
                outcomes.append(worker.admit(job.job_id, job.revision, grant))
            except GenerationError:
                outcomes.append(self.service.get(self.a, job.job_id))
        threads = [threading.Thread(target=admit, args=(job,)) for job in (first, second)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(4)
            self.assertFalse(thread.is_alive())
        self.assertEqual(len(outcomes), 2)
        self.assertEqual(sorted(item.state for item in outcomes), ["blocked", "queued"])
        balance = self.jobs.inspect_budget(OWNER, grant.grant_id)
        self.assertEqual(balance.reserved_units, 5)
        self.assertEqual(balance.spent_units + balance.unknown_held_units, 0)

    def test_cancel_queued_releases_only_unspent_reservation(self):
        worker = self.worker()
        grant = self.grant(limit=5)
        job = self.admit(self.create(), worker, grant)
        cancelled = self.service.cancel(self.a, job.job_id, job.revision)
        self.assertEqual(cancelled.state, "cancelled")
        balance = self.jobs.inspect_budget(OWNER, grant.grant_id)
        self.assertEqual((balance.reserved_units, balance.spent_units,
                          balance.unknown_held_units), (0, 0, 0))
        later = self.admit(self.create(), worker, grant)
        self.assertEqual(later.state, "queued")

    def test_zero_usage_still_consumes_a_persistent_hard_call_slot(self):
        calls = []
        def generate(source, token):
            calls.append(token.operation_key)
            return valid_result(source, token, usage=0)
        worker = self.worker(generate)
        grant = replace(self.grant(limit=5), max_calls=1)
        job = self.admit(self.create(), worker, grant)
        token = worker.claim(job.job_id, job.revision)
        self.assertEqual(worker.run(token).state, "completed")
        reopened = SQLiteGenerationValidationRepository(self.root / "jobs.sqlite3")
        replacement = FixtureGenerationWorker(reopened, FixtureAdapter(generate))
        next_job = self.admit(self.create(), replacement, grant)
        self.assertEqual(next_job.state, "blocked")
        balance = reopened.inspect_budget(OWNER, grant.grant_id)
        self.assertEqual((balance.spent_units, balance.reserved_calls,
                          balance.submitted_calls, balance.max_calls), (0, 0, 1, 1))
        self.assertEqual(len(calls), 1)

    def test_missing_or_wrong_usage_unit_holds_budget_without_refund(self):
        for name, mutate in (
            ("missing", lambda result: replace(result, usage_units=None)),
            ("wrong-unit", lambda result: replace(result, usage_unit="other-currency")),
            ("negative", lambda result: replace(result, usage_units=-1)),
        ):
            with self.subTest(case=name):
                grant = self.grant(name=f"unknown-{name}", limit=5)
                worker = self.worker(lambda source, token: mutate(valid_result(source, token)))
                job = self.admit(self.create(), worker, grant)
                token = worker.claim(job.job_id, job.revision)
                try:
                    worker.run(token)
                except GenerationError:
                    pass
                balance = self.jobs.inspect_budget(OWNER, grant.grant_id)
                self.assertEqual(balance.unknown_held_units, 5)
                self.assertEqual(balance.spent_units, 0)
                next_job = self.create()
                try:
                    next_job = self.admit(next_job, worker, grant)
                except GenerationError:
                    next_job = self.service.get(self.a, next_job.job_id)
                self.assertEqual(next_job.state, "blocked")

    def test_completed_fixture_manifest_is_actual_pcm_but_never_client_ready(self):
        worker = self.worker()
        grant = self.grant()
        job = self.admit(self.create(), worker, grant)
        token = worker.claim(job.job_id, job.revision)
        final = worker.run(token)
        self.assertEqual(final.state, "completed")
        manifest = self.jobs.inspect_result(OWNER, final.result_ref)
        self.assertEqual(manifest.material_version_id, job.material_version_id)
        self.assertEqual(manifest.input_sha256, job.input_sha256)
        self.assertEqual(manifest.audio_sha256, hashlib.sha256(pcm()).hexdigest())
        self.assertEqual(manifest.audio_bytes, len(pcm()))
        self.assertEqual((manifest.duration_ms, manifest.sentence_count), (1000, 1))
        self.assertEqual(manifest.execution_kind, "fixture")
        self.assertIs(manifest.client_learning_ready, False)
        self.assertEqual((manifest.owner_id, manifest.material_id, manifest.job_id,
                          manifest.attempt_id),
                         (OWNER, job.material_id, job.job_id, token.attempt_id))
        self.assertEqual((manifest.schema_version, manifest.policy_version,
                          manifest.plan_version, manifest.config_ref,
                          manifest.voice_config_ref, manifest.timing_origin),
                         (1, "us-conversation-v1", "generation-bundle-v1",
                          "fixture-v1", "fixture-v1", "fixture"))
        self.denied(GenerationErrorCode.not_found,
                    lambda: self.jobs.inspect_result(OTHER, final.result_ref))
        balance = self.jobs.inspect_budget(OWNER, grant.grant_id)
        self.assertEqual((balance.reserved_units, balance.spent_units,
                          balance.unknown_held_units), (0, 3, 0))
        try:
            worker.run(token)
        except GenerationError:
            pass
        self.assertEqual(self.jobs.inspect_budget(OWNER, grant.grant_id), balance)
        self.assertEqual(self.service.get(self.a, job.job_id).result_ref, final.result_ref)

    def test_expired_attempt_late_success_is_not_published_or_resubmitted(self):
        now = [1000.0]
        repository = SQLiteGenerationValidationRepository(self.root / "jobs.sqlite3",
                                                          clock=lambda: now[0])
        calls = []
        def generate(source, token):
            calls.append(token.operation_key)
            now[0] = token.expires_at + 1
            return valid_result(source, token)
        worker = FixtureGenerationWorker(repository, FixtureAdapter(generate))
        grant = self.grant(limit=5)
        job = self.admit(self.create(), worker, grant)
        token = worker.claim(job.job_id, job.revision, lease_seconds=10)
        late = worker.run(token)
        self.assertEqual(late.state, "uncertain")
        self.assertIsNone(late.result_ref)
        self.assertEqual(repository.inspect_budget(OWNER, grant.grant_id).unknown_held_units, 5)
        try:
            worker.run(token)
        except GenerationError:
            pass
        self.assertEqual(len(calls), 1)

    def test_atomic_publish_failure_leaves_no_visible_result_or_retry_submission(self):
        # A trigger injects disk-transaction failure only in this test-owned DB.
        # All task/outbound/recovery assertions still use the public Interfaces.
        now = [1000.0]
        repository = SQLiteGenerationValidationRepository(self.root / "jobs.sqlite3",
                                                          clock=lambda: now[0])
        calls = []
        def generate(source, token):
            calls.append(token.operation_key)
            return valid_result(source, token)
        worker = FixtureGenerationWorker(repository, FixtureAdapter(generate))
        grant = self.grant(limit=5)
        job = self.admit(self.create(), worker, grant)
        token = worker.claim(job.job_id, job.revision, lease_seconds=10)
        connection = sqlite3.connect(self.root / "jobs.sqlite3")
        try:
            connection.execute("""CREATE TRIGGER qa_fail_publication
                BEFORE UPDATE ON generation_jobs WHEN NEW.state='completed'
                BEGIN SELECT RAISE(ABORT, 'controlled publication failure'); END""")
            connection.commit()
        finally:
            connection.close()
        self.denied(GenerationErrorCode.storage_unavailable, lambda: worker.run(token))
        pending = self.service.get(self.a, job.job_id)
        self.assertNotEqual(pending.state, "completed")
        self.assertIsNone(pending.result_ref)
        self.assertEqual(len(calls), 1)
        now[0] = token.expires_at + 1
        self.assertEqual(worker.recover_expired(), 1)
        final = self.service.get(self.a, job.job_id)
        self.assertEqual(final.state, "uncertain")
        self.assertIsNone(final.result_ref)
        try:
            worker.run(token)
        except GenerationError:
            pass
        self.assertEqual(len(calls), 1)
        balance = repository.inspect_budget(OWNER, grant.grant_id)
        self.assertEqual((balance.spent_units, balance.unknown_held_units), (0, 5))

    def test_real_child_crash_after_dispatch_recovers_uncertain_without_resubmission(self):
        worker = self.worker()
        grant = self.grant(limit=5)
        job = self.admit(self.create(), worker, grant)
        marker = self.root / "synthetic-dispatch-marker.txt"
        source = str(Path(__file__).resolve().parents[1] / "src")
        child = r'''
import os, pathlib, sys
sys.path.insert(0, sys.argv[1])
from shiyu_backend.generation import FixtureGenerationWorker
from shiyu_backend.generation_models import FixtureAdapter
from shiyu_backend.generation_sqlite_validation import SQLiteGenerationValidationRepository
def leave_during_execution(source, token):
    pathlib.Path(sys.argv[5]).write_text(token.operation_key, encoding="ascii")
    os._exit(0)
jobs = SQLiteGenerationValidationRepository(sys.argv[2], clock=lambda: 1000.0)
worker = FixtureGenerationWorker(jobs, FixtureAdapter(leave_during_execution))
token = worker.claim(sys.argv[3], int(sys.argv[4]), lease_seconds=1)
worker.run(token)
raise AssertionError("controlled exit did not occur")
'''
        outcome = subprocess.run([sys.executable, "-c", child, source,
            str(self.root / "jobs.sqlite3"), job.job_id, str(job.revision), str(marker)],
            capture_output=True, timeout=10)
        self.assertEqual(outcome.returncode, 0, outcome.stderr.decode("utf-8", "replace"))
        self.assertTrue(marker.exists())
        calls = []
        reopened = SQLiteGenerationValidationRepository(self.root / "jobs.sqlite3",
                                                        clock=lambda: 2000.0)
        recovery = FixtureGenerationWorker(reopened,
            FixtureAdapter(lambda source, token: calls.append(token)))
        self.assertEqual(recovery.recover_expired(), 1)
        self.assertEqual(recovery.recover_expired(), 0)
        view = GenerationService(self.materials, reopened).get(self.a, job.job_id)
        self.assertEqual(view.state, "uncertain")
        self.assertIsNone(view.result_ref)
        self.assertEqual(calls, [])
        balance = reopened.inspect_budget(OWNER, grant.grant_id)
        self.assertEqual(balance.unknown_held_units, 5)

    def test_invalid_result_binding_audio_or_timings_never_completes(self):
        mutations = {
            "wrong_owner": lambda result: replace(result, owner_id=OTHER),
            "wrong_source": lambda result: replace(result, input_sha256="0" * 64),
            "corrupt_audio": lambda result: replace(result, audio_wav=b"not a wav"),
            "empty_english": lambda result: replace(result, sentences=(
                GeneratedSentence("", "中文合成", 0, 1000),)),
            "reverse_time": lambda result: replace(result, sentences=(
                GeneratedSentence("A boat.", "纸船。", 900, 100),)),
            "beyond_audio": lambda result: replace(result, sentences=(
                GeneratedSentence("A boat.", "纸船。", 0, 2000),)),
        }
        for name, mutate in mutations.items():
            with self.subTest(case=name):
                worker = self.worker(lambda source, token: mutate(valid_result(source, token)))
                grant = self.grant(name=f"invalid-{name}")
                job = self.admit(self.create(), worker, grant)
                token = worker.claim(job.job_id, job.revision)
                try:
                    worker.run(token)
                except GenerationError:
                    pass
                final = self.service.get(self.a, job.job_id)
                self.assertNotEqual(final.state, "completed")
                self.assertIsNone(final.result_ref)


if __name__ == "__main__":
    unittest.main()
