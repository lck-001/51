"""Independent domain/repository tests using synthetic identities and real SQLite.

No company DB, PostgreSQL instance, network server, credential verifier or model
provider is used. A new Python process verifies persisted idempotency separately.
"""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from dataclasses import asdict, dataclass, replace
import io
import logging
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from shiyu_backend.intake import CONFIRM, READ, RECEIVE, WRITE, IntakeService
from shiyu_backend.models import (
    BackendError, ErrorCode, IntakeLimits, ReceiptStatus, ReceiveMaterial,
    TrustedCaller,
)
from shiyu_backend.sqlite_validation import SQLiteValidationRepository

ALL = frozenset({RECEIVE, READ, WRITE, CONFIRM})
OWNER_A = "synthetic-owner-a"
OWNER_B = "synthetic-owner-b"
INTEGRATION = "synthetic-agent-a"
TEXT = "这是合成中文故事：一只蓝色纸船。🚀\nA blue paper boat.\r\nNo private material."


def caller(owner=OWNER_A, integration=INTEGRATION, scopes=ALL):
    # Deliberately synthetic trusted context, not a JWT/OAuth verification result.
    return TrustedCaller(owner, integration, frozenset(scopes))


def request(**changes):
    return replace(ReceiveMaterial(
        delivery_id="synthetic-delivery-1", source_key="synthetic-source-1",
        title="合成材料 / Synthetic material", text=TEXT, source_revision="r1",
    ), **changes)


@dataclass(frozen=True, repr=False)
class BodyWithUntrustedClaims(ReceiveMaterial):
    owner_id: str = OWNER_B
    integration_id: str = "untrusted-body-integration"
    generate: bool = True
    share: bool = True


class IntakeSQLiteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="shiyu-intake-qa-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "validation.sqlite3"
        self.repositories = []
        self.addCleanup(self.close_all)
        self.service, self.repo = self.open_service()
        self.a, self.b = caller(), caller(OWNER_B)

    def open_service(self):
        repository = SQLiteValidationRepository(self.path)
        self.repositories.append(repository)
        return IntakeService(repository), repository

    def close_repo(self, repository):
        self.repositories.remove(repository)
        repository.close()

    def close_all(self):
        for repository in self.repositories[:]:
            self.close_repo(repository)

    def denied(self, code, operation, status=None):
        with self.assertRaises(BackendError) as caught:
            operation()
        self.assertEqual(caught.exception.code, code)
        if status is not None:
            self.assertEqual(caught.exception.http_status, status)
        return caught.exception

    def receive(self, who=None, body=None):
        return self.service.receive(who or self.a, body or request())

    def test_receipt_means_private_unconfirmed_draft_not_generated_learning(self):
        receipt = self.receive()
        draft = self.service.read_draft(self.a, receipt.draft_id)
        self.assertEqual(receipt.status, ReceiptStatus.accepted)
        self.assertFalse(receipt.replayed)
        self.assertEqual(draft.owner_id, OWNER_A)
        self.assertEqual((draft.text, draft.original_text, draft.revision), (TEXT, TEXT, 1))
        self.assertEqual(draft.state, "draft")
        self.assertEqual(self.service.list_versions(self.a, receipt.material_id), ())

    def test_replay_returns_same_persistent_receipt_without_duplicate_draft(self):
        first = self.receive()
        again = self.receive()
        self.assertTrue(again.replayed)
        self.assertEqual((first.receipt_id, first.material_id, first.draft_id),
                         (again.receipt_id, again.material_id, again.draft_id))
        self.assertEqual(len(self.service.list_drafts(self.a)), 1)

    def test_reopened_repository_deduplicates_from_disk(self):
        first = self.receive()
        self.close_repo(self.repo)
        self.service, self.repo = self.open_service()
        again = self.receive()
        self.assertTrue(again.replayed)
        self.assertEqual(again.receipt_id, first.receipt_id)
        self.assertEqual(self.service.read_draft(self.a, again.draft_id).original_text, TEXT)

    def test_new_python_process_replays_same_committed_receipt(self):
        first = self.receive()
        self.close_repo(self.repo)
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--child-replay",
             str(self.path), first.receipt_id, first.material_id, first.draft_id],
            capture_output=True, text=True, encoding="utf-8", timeout=10,
        )
        self.assertEqual(result.returncode, 0, "independent process reopen failed")
        self.assertEqual(result.stdout.strip(), "CHILD_REPLAY_OK")
        self.service, self.repo = self.open_service()
        self.assertEqual(len(self.service.list_drafts(self.a)), 1)

    def test_same_delivery_id_different_content_conflicts_without_overwrite(self):
        first = self.receive()
        self.denied(ErrorCode.delivery_conflict,
                    lambda: self.receive(body=request(text="different synthetic text")), 409)
        self.assertEqual(self.service.read_draft(self.a, first.draft_id).text, TEXT)
        self.assertEqual(len(self.service.list_drafts(self.a)), 1)

    def test_same_delivery_id_changed_provenance_or_title_is_conflict(self):
        self.receive()
        for changes in ({"title": "Changed title"}, {"source_key": "different-source"},
                        {"source_revision": "r2"}):
            with self.subTest(field=next(iter(changes))):
                self.denied(ErrorCode.delivery_conflict,
                            lambda: self.receive(body=request(**changes)), 409)

    def test_same_source_update_is_pending_and_does_not_replace_original_draft(self):
        first = self.receive()
        newer = self.receive(body=request(delivery_id="synthetic-delivery-2", text="New synthetic source", source_revision="r2"))
        self.assertEqual(newer.status, ReceiptStatus.update_pending)
        self.assertEqual(newer.material_id, first.material_id)
        self.assertNotEqual(newer.draft_id, first.draft_id)
        self.assertEqual(self.service.read_draft(self.a, first.draft_id).text, TEXT)
        self.assertEqual(self.service.read_draft(self.a, newer.draft_id).state, "update_pending")
        self.assertEqual(self.service.list_versions(self.a, first.material_id), ())

    def test_confirmed_source_and_pending_update_relationship_survive_reopen(self):
        first = self.receive()
        version = self.service.confirm_draft(self.a, first.draft_id, 1)
        update = self.receive(body=request(delivery_id="synthetic-delivery-2", text="Pending synthetic change", source_revision="r2"))
        self.close_repo(self.repo)
        self.service, self.repo = self.open_service()
        self.assertEqual(self.service.read_version(self.a, version.version_id).text, TEXT)
        self.assertEqual(self.service.read_draft(self.a, first.draft_id).state, "confirmed")
        self.assertEqual(self.service.read_draft(self.a, update.draft_id).state, "update_pending")
        replay = self.receive(body=request(delivery_id="synthetic-delivery-2", text="Pending synthetic change", source_revision="r2"))
        self.assertTrue(replay.replayed)
        self.assertEqual(replay.draft_id, update.draft_id)

    def test_two_owners_with_same_delivery_and_source_never_share_receipts(self):
        a, b = self.receive(), self.receive(self.b)
        self.assertNotEqual(a.receipt_id, b.receipt_id)
        self.assertNotEqual(a.material_id, b.material_id)
        self.assertEqual(self.service.list_drafts(self.a)[0].draft_id, a.draft_id)
        self.assertEqual(self.service.list_drafts(self.b)[0].draft_id, b.draft_id)

    def test_cross_owner_reads_edits_confirmation_and_version_listing_are_not_found(self):
        receipt = self.receive()
        version = self.service.confirm_draft(self.a, receipt.draft_id, 1)
        operations = (
            lambda: self.service.read_draft(self.b, receipt.draft_id),
            lambda: self.service.update_draft(self.b, receipt.draft_id, 1, text="forbidden"),
            lambda: self.service.confirm_draft(self.b, receipt.draft_id, 1),
            lambda: self.service.read_version(self.b, version.version_id),
            lambda: self.service.list_versions(self.b, receipt.material_id),
        )
        for operation in operations:
            self.denied(ErrorCode.not_found, operation, 404)
        self.assertEqual(self.service.read_draft(self.a, receipt.draft_id).text, TEXT)

    def test_integrations_have_independent_delivery_source_namespace_but_owner_can_read(self):
        first = self.receive()
        other_integration = caller(integration="synthetic-agent-b")
        second = self.receive(other_integration)
        self.assertEqual(second.status, ReceiptStatus.accepted)
        self.assertNotEqual(first.material_id, second.material_id)
        self.assertNotEqual(first.receipt_id, second.receipt_id)
        self.assertEqual(self.service.read_draft(other_integration, first.draft_id).owner_id, OWNER_A)

    def test_receive_scope_does_not_imply_read_write_or_confirm(self):
        restricted = caller(scopes={RECEIVE})
        receipt = self.receive(restricted)
        operations = (
            lambda: self.service.read_draft(restricted, receipt.draft_id),
            lambda: self.service.list_drafts(restricted),
            lambda: self.service.update_draft(restricted, receipt.draft_id, 1, text="forbidden"),
            lambda: self.service.confirm_draft(restricted, receipt.draft_id, 1),
            lambda: self.service.list_versions(restricted, receipt.material_id),
        )
        for operation in operations:
            self.denied(ErrorCode.scope_denied, operation, 403)
        self.assertEqual(self.service.read_draft(self.a, receipt.draft_id).revision, 1)

    def test_read_generate_or_share_scope_cannot_receive_material(self):
        for scopes in ({READ}, {"learning:generate"}, {"materials:share"}, set()):
            with self.subTest(scopes=tuple(sorted(scopes))):
                self.denied(ErrorCode.scope_denied, lambda: self.receive(caller(scopes=scopes)), 403)
        self.assertEqual(self.service.list_drafts(self.a), ())

    def test_revoked_receive_scope_cannot_bypass_permission_via_existing_delivery_id(self):
        self.receive()
        self.denied(ErrorCode.scope_denied, lambda: self.receive(caller(scopes=set())), 403)
        self.assertEqual(len(self.service.list_drafts(self.a)), 1)

    def test_body_cannot_construct_trusted_caller_or_override_owner(self):
        self.denied(ErrorCode.authentication_required,
                    lambda: self.service.receive({"owner_id": OWNER_A, "scopes": [RECEIVE]}, request()), 401)
        self.denied(ErrorCode.invalid_input,
                    lambda: self.service.receive(self.a, {"owner_id": OWNER_B, "text": TEXT}), 422)
        self.assertEqual(self.service.list_drafts(self.a), ())

    def test_typed_body_extra_owner_integration_and_actions_cannot_expand_authority(self):
        body = BodyWithUntrustedClaims(**asdict(request()))
        receipt = self.receive(body=body)
        draft = self.service.read_draft(self.a, receipt.draft_id)
        self.assertEqual(draft.owner_id, OWNER_A)
        self.assertEqual(draft.state, "draft")
        self.assertEqual(self.service.list_drafts(self.b), ())
        self.assertEqual(self.service.list_versions(self.a, receipt.material_id), ())
        self.assertTrue(self.receive().replayed)

    def test_stale_update_revision_conflict_preserves_committed_draft(self):
        receipt = self.receive()
        updated = self.service.update_draft(self.a, receipt.draft_id, 1, text="Synthetic corrected text")
        self.assertEqual(updated.revision, 2)
        self.denied(ErrorCode.revision_conflict,
                    lambda: self.service.update_draft(self.a, receipt.draft_id, 1, text="stale"), 409)
        self.assertEqual(self.service.read_draft(self.a, receipt.draft_id).text, "Synthetic corrected text")

    def test_stale_confirmation_does_not_create_any_version(self):
        receipt = self.receive()
        self.service.update_draft(self.a, receipt.draft_id, 1, title="Synthetic edit")
        self.denied(ErrorCode.revision_conflict,
                    lambda: self.service.confirm_draft(self.a, receipt.draft_id, 1), 409)
        self.assertEqual(self.service.list_versions(self.a, receipt.material_id), ())

    def test_same_revision_confirmation_is_idempotent_and_does_not_edit_draft(self):
        receipt = self.receive()
        first = self.service.confirm_draft(self.a, receipt.draft_id, 1)
        second = self.service.confirm_draft(self.a, receipt.draft_id, 1)
        self.assertEqual(first.version_id, second.version_id)
        self.assertEqual(len(self.service.list_versions(self.a, receipt.material_id)), 1)
        self.assertEqual(self.service.read_draft(self.a, receipt.draft_id).revision, 1)

    def test_old_version_and_original_submission_are_immutable_after_edit(self):
        receipt = self.receive()
        first = self.service.confirm_draft(self.a, receipt.draft_id, 1)
        changed = self.service.update_draft(self.a, receipt.draft_id, 1, text="Synthetic correction v2")
        self.assertEqual(changed.state, "draft")
        second = self.service.confirm_draft(self.a, receipt.draft_id, 2)
        self.close_repo(self.repo)
        self.service, self.repo = self.open_service()
        self.assertEqual(self.service.read_version(self.a, first.version_id).text, TEXT)
        self.assertEqual(self.service.read_draft(self.a, receipt.draft_id).original_text, TEXT)
        self.assertGreater(second.version_number, first.version_number)
        self.assertEqual(second.draft_revision, 2)

    def test_unconfirmed_private_draft_is_not_material_or_learning_ready(self):
        receipt = self.receive()
        self.service.update_draft(self.a, receipt.draft_id, 1, text="Another private synthetic draft")
        draft = self.service.read_draft(self.a, receipt.draft_id)
        self.assertEqual(draft.state, "draft")
        self.assertEqual(self.service.list_versions(self.a, receipt.material_id), ())
        # This module exposes no learning/provider operation; do not invent a
        # successful generated edition from a confirmed material or receipt.
        self.assertNotIn(draft.state, {"ready", "generated", "learning_ready"})

    def test_unicode_limit_uses_bytes_and_rejects_before_persistence(self):
        limited = IntakeService(self.repo, IntakeLimits(max_text_bytes=8))
        self.denied(ErrorCode.invalid_input,
                    lambda: limited.receive(self.a, request(text="四个汉字")), 422)
        self.assertEqual(self.service.list_drafts(self.a), ())
        receipt = limited.receive(self.a, request(text="你好"))
        self.assertEqual(self.service.read_draft(self.a, receipt.draft_id).text, "你好")

    def test_sql_like_text_and_quotes_are_literal_data(self):
        text = "Synthetic '); DROP TABLE deliveries; --\n中文 still present."
        receipt = self.receive(body=request(text=text))
        self.assertEqual(self.service.read_draft(self.a, receipt.draft_id).text, text)
        self.assertTrue(self.receive(body=request(text=text)).replayed)

    def test_malformed_ids_and_noninteger_expected_revision_are_rejected(self):
        receipt = self.receive()
        self.denied(ErrorCode.invalid_input, lambda: self.service.read_draft(self.a, "../../synthetic"), 422)
        for revision in (0, -1, True, "1"):
            self.denied(ErrorCode.invalid_input,
                        lambda: self.service.confirm_draft(self.a, receipt.draft_id, revision), 422)

    def test_logs_representations_and_errors_do_not_disclose_text_or_secret(self):
        marker = "SYNTHETIC_PRIVATE_BODY_AND_SECRET_9fbe1"
        body = request(text=marker)
        logs, printed = io.StringIO(), io.StringIO()
        handler = logging.StreamHandler(logs)
        root_logger = logging.getLogger()
        level = root_logger.level
        root_logger.addHandler(handler)
        root_logger.setLevel(logging.DEBUG)
        try:
            with redirect_stdout(printed), redirect_stderr(printed):
                first = self.receive(body=body)
                self.receive(body=body)
                error = self.denied(ErrorCode.delivery_conflict,
                                    lambda: self.receive(body=request(text=marker + "changed")))
                self.service.read_draft(self.a, first.draft_id)
        finally:
            root_logger.removeHandler(handler)
            root_logger.setLevel(level)
            handler.close()
        for output in (logs.getvalue(), printed.getvalue(), repr(body), repr(self.a), str(error)):
            self.assertNotIn(marker, output)

    def test_corrupt_sqlite_file_fails_instead_of_reinitializing_empty_database(self):
        self.close_repo(self.repo)
        self.path.write_bytes(b"synthetic-not-a-sqlite-database" * 8)
        self.denied(ErrorCode.storage_unavailable,
                    lambda: SQLiteValidationRepository(self.path), 503)

    def test_closed_repository_returns_storage_error_not_empty_list(self):
        self.receive()
        self.close_repo(self.repo)
        self.denied(ErrorCode.storage_unavailable, lambda: self.service.list_drafts(self.a), 503)
        self.denied(ErrorCode.storage_unavailable, lambda: self.receive(), 503)


def child_replay(arguments):
    repository = None
    try:
        repository = SQLiteValidationRepository(Path(arguments[0]))
        service = IntakeService(repository)
        receipt = service.receive(caller(), request())
        if not receipt.replayed:
            raise RuntimeError("persisted delivery was not replayed")
        if (receipt.receipt_id, receipt.material_id, receipt.draft_id) != tuple(arguments[1:4]):
            raise RuntimeError("persisted identity differs")
        if service.read_draft(caller(), receipt.draft_id).original_text != TEXT:
            raise RuntimeError("persisted content differs")
        if len(service.list_drafts(caller())) != 1:
            raise RuntimeError("persistent replay duplicated draft")
        print("CHILD_REPLAY_OK")
        return 0
    except Exception:
        # Synthetic child failure is explicit; no raw SQL, paths or payload.
        print("CHILD_REPLAY_FAILED")
        return 1
    finally:
        if repository is not None:
            repository.close()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--child-replay":
        raise SystemExit(child_replay(sys.argv[2:]))
    unittest.main()
