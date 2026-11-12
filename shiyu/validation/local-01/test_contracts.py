"""Independent C01-C07 contract expectations, using synthetic identities only.

These tests exercise a local reference model. They do not establish production
authentication, PostgreSQL transactions, supplier effects, device or speech quality.
"""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
import unittest

from reference_model import (
    ContractError, LocalPlatform, Principal, MAX_RUN_TOOL_CALLS, MAX_PLAN_REVISIONS,
)


class ContractChecks(unittest.TestCase):
    def setUp(self):
        self.model = LocalPlatform(now=1000)
        self.alice = Principal("alice", scopes=frozenset({"*"}), grant_id="alice-app")
        self.bob = Principal("bob", scopes=frozenset({"*"}), grant_id="bob-app")
        self.support = Principal("operator", scopes=frozenset({"*"}),
                                 roles=frozenset({"support"}), grant_id="operator-app")
        self.model.add_material(self.alice, "material-a", "learning-a-v1", ["a1", "a2", "a3"])
        self.model.add_material(self.bob, "material-b", "learning-b-v1", ["b1", "b2"])

    def reject(self, codes, action):
        if isinstance(codes, str):
            codes = {codes}
        with self.assertRaises(ContractError) as raised:
            action()
        self.assertIn(raised.exception.code, codes)
        return raised.exception.code

    def delivery(self, material_id="incoming-a", body="Synthetic story", **overrides):
        payload = dict(material_id=material_id, source_ref="synthetic-source",
                       source_revision="1", body=body)
        payload.update(overrides)
        return payload

    def receiver(self, owner="alice", integration="external-one", **kwargs):
        return Principal(owner, integration_id=integration,
                         scopes=frozenset({"receive:create"}), grant_id=integration, **kwargs)

    def approve(self, plan="plan-a", limit=10):
        return self.model.approve_processing(self.alice, plan, limit, confirmed=True)

    def coach(self, run="run-a", steps=None):
        plan = "planning:" + run
        self.approve(plan, 3)
        self.model.submit_processing(self.alice, "planning-op:" + run, plan, 1)
        self.model.reconcile(self.alice, "planning-op:" + run, "succeeded", actual_cost=1)
        return self.model.coach_plan(self.alice, run, "material-a",
                                     steps if steps is not None else ["read_selected", "save_plan_draft"],
                                     planning_operation_id="planning-op:" + run)

    def new_feedback(self, operation="feedback-op"):
        return self.model.submit_feedback(self.alice, operation, "Synthetic playback problem")

    # C01 identity and capability: body text is not authority.
    def test_payload_owner_does_not_change_authenticated_recipient(self):
        receipt = self.model.receive(self.receiver(), "delivery-owner", self.delivery(owner_id="bob"))
        self.model.get_material(self.alice, receipt["material_id"])
        self.reject("ACCESS_DENIED", lambda: self.model.get_material(self.bob, receipt["material_id"]))

    def test_foreign_and_missing_material_have_same_denial(self):
        foreign = self.reject("ACCESS_DENIED", lambda: self.model.get_material(self.bob, "material-a"))
        missing = self.reject("ACCESS_DENIED", lambda: self.model.get_material(self.bob, "missing"))
        self.assertEqual(foreign, missing)

    def test_selected_material_scope_cannot_expand_to_same_user_library(self):
        self.model.add_material(self.alice, "another-a", "another-v1", ["x1"])
        limited = Principal("alice", scopes=frozenset({"material:read"}),
                            material_scope=frozenset({"material-a"}), grant_id="selection-a")
        self.model.get_material(limited, "material-a")
        self.reject({"SCOPE_DENIED", "ACCESS_DENIED"}, lambda: self.model.get_material(limited, "another-a"))

    def test_expired_grant_cannot_read(self):
        expired = Principal("alice", scopes=frozenset({"*"}), expires_at=999, grant_id="expired")
        self.reject("GRANT_EXPIRED", lambda: self.model.get_material(expired, "material-a"))

    def test_revocation_rejects_new_actions_without_revoking_other_user(self):
        self.model.revoke(self.alice)
        self.reject({"GRANT_REVOKED", "SCOPE_DENIED", "ACCESS_DENIED"},
                    lambda: self.model.get_material(self.alice, "material-a"))
        self.model.get_material(self.bob, "material-b")

    def test_receive_capability_is_not_read_or_coach_authorization(self):
        receiver = self.receiver()
        result = self.model.receive(receiver, "delivery-caps", self.delivery())
        self.reject({"SCOPE_DENIED", "ACCESS_DENIED"}, lambda: self.model.receipt(receiver, result["receipt_id"]))
        self.reject({"SCOPE_DENIED", "ACCESS_DENIED"}, lambda: self.model.get_material(receiver, result["material_id"]))
        self.reject({"SCOPE_DENIED", "ACCESS_DENIED"},
                    lambda: self.model.coach_plan(receiver, "bad-run", result["material_id"], ["read_selected"]))

    # C01 delivery idempotency, including concurrency and changed parameters.
    def test_repeated_delivery_reuses_receipt_and_changed_payload_conflicts(self):
        p = self.receiver()
        one = self.model.receive(p, "same-id", self.delivery())
        two = self.model.receive(p, "same-id", self.delivery())
        self.assertEqual(one["receipt_id"], two["receipt_id"])
        self.assertEqual(one["material_id"], two["material_id"])
        self.assertFalse(one["generated"])
        self.assertFalse(two["generated"])
        self.reject("OPERATION_CONFLICT", lambda: self.model.receive(p, "same-id", self.delivery(body="Changed")))

    def test_concurrent_duplicate_delivery_has_one_receipt(self):
        barrier = Barrier(2)
        def submit(_):
            barrier.wait(timeout=5)
            return self.model.receive(self.receiver(), "concurrent-id", self.delivery())
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(submit, range(2)))
        self.assertEqual(results[0]["receipt_id"], results[1]["receipt_id"])

    def test_delivery_unique_key_includes_integration(self):
        first = self.model.receive(self.receiver(integration="external-one"), "id-1", self.delivery("one"))
        second = self.model.receive(self.receiver(integration="external-two"), "id-1", self.delivery("two"))
        self.assertNotEqual(first["receipt_id"], second["receipt_id"])

    def test_identical_content_does_not_share_other_users_private_material(self):
        a = self.model.receive(self.receiver("alice"), "hash-a", self.delivery("private-a"))
        b = self.model.receive(self.receiver("bob"), "hash-b", self.delivery("private-b"))
        self.assertNotEqual(a["material_id"], b["material_id"])
        self.reject("ACCESS_DENIED", lambda: self.model.get_material(self.bob, a["material_id"]))

    def test_same_source_revision_is_immutable_across_new_delivery_ids(self):
        receiver = self.receiver()
        one = self.model.receive(receiver, "source-first", self.delivery())
        duplicate = self.model.receive(receiver, "source-same-new-id", self.delivery())
        self.assertEqual(one["receipt_id"], duplicate["receipt_id"])
        self.reject("REVISION_CONFLICT", lambda: self.model.receive(
            receiver, "source-changed-new-id", self.delivery(body="Changed without new source revision")))

    # C02 revisions and sentence anchors.
    def test_stale_progress_write_does_not_silently_overwrite(self):
        first = self.model.save_progress(self.alice, "material-a", "learning-a-v1", "a1", expected_revision=0)
        self.assertEqual(first["revision"], 1)
        self.reject("REVISION_CONFLICT", lambda: self.model.save_progress(
            self.alice, "material-a", "learning-a-v1", "a2", expected_revision=0))

    def test_cross_learning_version_is_not_migrated_by_position(self):
        self.model.save_progress(self.alice, "material-a", "learning-a-v1", "a2", expected_revision=0)
        self.reject({"REVISION_CONFLICT", "REFERENCE_UNAVAILABLE"}, lambda: self.model.save_progress(
            self.alice, "material-a", "learning-a-v2", "a2", expected_revision=1))

    # C03 approval, reservation and external outcome uncertainty.
    def test_processing_requires_explicit_approval(self):
        self.reject({"CONSENT_REQUIRED", "BUDGET_NOT_CONFIRMED"},
                    lambda: self.model.submit_processing(self.alice, "op-none", "none", 1))
        self.reject("CONSENT_REQUIRED", lambda: self.model.approve_processing(self.alice, "not-confirmed", 10))
        self.assertEqual(self.model.budget(self.alice)["reserved"], 0)

    def test_external_integration_cannot_approve_itself(self):
        external = Principal("alice", integration_id="external", scopes=frozenset({"*"}), grant_id="ext-all")
        self.reject("ACTOR_NOT_ALLOWED",
                    lambda: self.model.approve_processing(external, "self-approved", 10, confirmed=True))

    def test_changed_plan_has_no_approval(self):
        self.approve("approved-hash")
        self.reject({"CONSENT_REQUIRED", "BUDGET_NOT_CONFIRMED", "PLAN_STALE"},
                    lambda: self.model.submit_processing(self.alice, "hash-op", "different-hash", 1))

    def test_budget_amounts_reject_negative_bool_and_non_integer_values(self):
        for amount in (-1, True, 1.5, "1"):
            with self.subTest(amount=amount, action="approve"):
                self.reject("INVALID_AMOUNT", lambda: self.model.approve_processing(
                    self.alice, "invalid-budget", amount, confirmed=True))
            with self.subTest(amount=amount, action="reserve"):
                self.approve("valid-budget")
                self.reject("INVALID_AMOUNT", lambda: self.model.submit_processing(
                    self.alice, "invalid-cost", "valid-budget", amount))

    def test_concurrent_reservations_do_not_exceed_plan_limit(self):
        self.approve("race-plan", 10)
        barrier = Barrier(2)
        def reserve(index):
            barrier.wait(timeout=5)
            try:
                return self.model.submit_processing(self.alice, "race-" + str(index), "race-plan", 7)
            except ContractError as exc:
                return exc.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(reserve, range(2)))
        self.assertEqual(sum(isinstance(result, dict) for result in results), 1)
        self.assertIn("BUDGET_EXCEEDED", results)
        self.assertEqual(self.model.budget(self.alice)["reserved"], 7)

    def test_unknown_retains_reservation_and_same_operation_does_not_rebuy(self):
        self.approve()
        self.model.submit_processing(self.alice, "unknown-op", "plan-a", 4)
        self.model.mark_unknown(self.alice, "unknown-op")
        before = self.model.budget(self.alice)
        replay = self.model.submit_processing(self.alice, "unknown-op", "plan-a", 4)
        self.assertEqual(replay["state"], "outcome_unknown")
        self.assertEqual(self.model.budget(self.alice), before)
        self.assertEqual(before["reserved"], 4)
        self.assertEqual(before["spent"], 0)

    def test_cancel_request_is_not_terminal_or_refund(self):
        self.approve()
        self.model.submit_processing(self.alice, "cancel-op", "plan-a", 4)
        result = self.model.cancel_processing(self.alice, "cancel-op")
        self.assertEqual(result["state"], "cancel_requested")
        self.assertEqual(self.model.budget(self.alice)["reserved"], 4)

    def test_terminal_callback_is_idempotent_and_parameter_change_conflicts(self):
        self.approve()
        self.model.submit_processing(self.alice, "settled-op", "plan-a", 4)
        self.model.mark_unknown(self.alice, "settled-op")
        self.model.reconcile(self.alice, "settled-op", "succeeded", actual_cost=3)
        first = self.model.budget(self.alice)
        self.model.reconcile(self.alice, "settled-op", "succeeded", actual_cost=3)
        self.assertEqual(self.model.budget(self.alice), first)
        self.assertEqual(first["spent"], 3)
        self.assertEqual(first["reserved"], 0)
        self.reject("OPERATION_CONFLICT", lambda: self.model.reconcile(
            self.alice, "settled-op", "succeeded", actual_cost=1))

    # C06 planning is metered, immutable approval binds the actual plan.
    def test_coach_planning_requires_metered_approved_operation(self):
        self.reject("BUDGET_NOT_CONFIRMED", lambda: self.model.coach_plan(
            self.alice, "unmetered", "material-a", ["read_selected"]))
        self.coach()
        self.assertEqual(self.model.budget(self.alice)["spent"], 1)

    def test_edit_coach_plan_invalidates_old_approval(self):
        self.coach()
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        self.model.edit_coach(self.alice, "run-a", ["read_selected", "create_practice_draft"])
        self.reject({"PLAN_STALE", "CONSENT_REQUIRED"}, lambda: self.model.coach_step(
            self.alice, "run-a", "step-new", "create_practice_draft", "draft-op"))

    def test_forbidden_coach_tool_cannot_be_approved_by_text(self):
        self.coach()
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        for tool in ("publish", "delete", "read_all"):
            with self.subTest(tool=tool):
                self.reject("TOOL_NOT_ALLOWED", lambda: self.model.coach_step(
                    self.alice, "run-a", "injected-step", tool, "injected-operation"))

    def test_stop_blocks_new_coach_steps_without_refunding_unknown(self):
        self.coach()
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        self.approve("dependent", 5)
        self.model.submit_processing(self.alice, "linked-op", "dependent", 2)
        self.model.mark_unknown(self.alice, "linked-op")
        self.model.coach_step(self.alice, "run-a", "step-linked", "save_plan_draft", "linked-op")
        self.model.stop_coach(self.alice, "run-a")
        self.reject({"RUN_STOPPED", "STOP_REQUESTED", "LIMIT_REACHED"}, lambda: self.model.coach_step(
            self.alice, "run-a", "step-after-stop", "read_selected", "after-stop"))
        self.assertEqual(self.model.budget(self.alice)["reserved"], 2)

    def test_coach_step_replay_has_same_draft_and_returned_data_is_not_authority(self):
        self.coach()
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        one = self.model.coach_step(self.alice, "run-a", "draft-step", "save_plan_draft", "stable-draft")
        before = dict(one)
        one["state"] = "forged-state"
        two = self.model.coach_step(self.alice, "run-a", "draft-step", "save_plan_draft", "stable-draft")
        self.assertEqual(two, before)

    def test_coach_new_step_id_cannot_repeat_tool_beyond_approved_slots(self):
        self.coach()
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        self.model.coach_step(self.alice, "run-a", "first-read", "read_selected", "read-op-1")
        # The approved plan contains read_selected once, not an unlimited whitelist.
        self.reject("LIMIT_REACHED", lambda: self.model.coach_step(
            self.alice, "run-a", "invented-read", "read_selected", "read-op-2"))

    def test_coach_same_step_replay_does_not_consume_another_slot(self):
        self.coach()
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        one = self.model.coach_step(self.alice, "run-a", "first-read", "read_selected", "read-once")
        self.assertEqual(self.model.coach_step(
            self.alice, "run-a", "first-read", "read_selected", "read-once"), one)
        stopped = self.model.stop_coach(self.alice, "run-a")
        self.assertEqual(stopped["tool_calls"], 1)
        # Reading an already-completed operation is not starting a new step.
        self.assertEqual(self.model.coach_step(
            self.alice, "run-a", "first-read", "read_selected", "read-once"), one)
        self.assertEqual(self.model.stop_coach(self.alice, "run-a")["tool_calls"], 1)

    def test_coach_deadline_rejects_new_steps(self):
        plan = self.coach()
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        self.model.now = plan["deadline_at"] + 1
        self.reject("LIMIT_REACHED", lambda: self.model.coach_step(
            self.alice, "run-a", "late-step", "read_selected", "late-op"))

    def test_plan_edit_does_not_reset_run_quota_or_extend_deadline(self):
        self.assertEqual(MAX_RUN_TOOL_CALLS, 8)  # Fixed local fixture, not a product limit.
        steps = ["read_selected"] * MAX_RUN_TOOL_CALLS
        plan = self.coach(steps=steps)
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        for index in range(MAX_RUN_TOOL_CALLS):
            self.model.coach_step(self.alice, "run-a", "read-" + str(index),
                                   "read_selected", "read-op-" + str(index))
        self.model.now += 10
        edited = self.model.edit_coach(self.alice, "run-a", steps)
        self.assertEqual(edited["deadline_at"], plan["deadline_at"])
        self.assertEqual(edited["tool_calls"], MAX_RUN_TOOL_CALLS)
        self.model.approve_coach(self.alice, "run-a", confirmed=True)
        self.reject("LIMIT_REACHED", lambda: self.model.coach_step(
            self.alice, "run-a", "new-revision-read", "read_selected", "new-revision-op"))

    def test_last_permitted_plan_revision_can_be_approved_but_next_edit_is_rejected(self):
        self.assertEqual(MAX_PLAN_REVISIONS, 3)  # Synthetic validation policy.
        self.coach()
        for revision in range(2, MAX_PLAN_REVISIONS + 1):
            changed = self.model.edit_coach(self.alice, "run-a", ["read_selected"])
            self.assertEqual(changed["revision"], revision)
            self.model.approve_coach(self.alice, "run-a", confirmed=True)
        self.reject("LIMIT_REACHED", lambda: self.model.edit_coach(
            self.alice, "run-a", ["read_selected"]))

    # C05 options, help, submissions and immutable learning facts.
    def question(self):
        self.model.add_question(self.alice, "progress-question", ["Going well", "Need more time"])
        self.model.start_attempt(self.alice, "attempt-a", "progress-question")

    def test_option_audio_does_not_submit_or_turn_help_into_wrong_answer(self):
        self.question()
        self.model.assist(self.alice, "attempt-a", "option_audio")
        result = self.model.submit_answer(self.alice, "attempt-a", "Going well")
        self.assertTrue(result["accepted"])
        self.assertTrue(result["independent"])

    def test_question_text_help_prevents_independent_listening_claim(self):
        self.question()
        self.model.assist(self.alice, "attempt-a", "question_text")
        result = self.model.submit_answer(self.alice, "attempt-a", "Going well")
        self.assertTrue(result["accepted"])
        self.assertFalse(result["independent"])

    def test_multiple_contextually_reasonable_replies_are_accepted(self):
        self.question()
        self.model.start_attempt(self.alice, "attempt-b", "progress-question")
        self.assertTrue(self.model.submit_answer(self.alice, "attempt-a", "Going well")["accepted"])
        self.assertTrue(self.model.submit_answer(self.alice, "attempt-b", "Need more time")["accepted"])

    def test_answer_replay_and_late_assistance_cannot_rewrite_facts(self):
        self.question()
        one = self.model.submit_answer(self.alice, "attempt-a", "Going well")
        self.assertEqual(self.model.submit_answer(self.alice, "attempt-a", "Going well"), one)
        self.reject("ATTEMPT_FINALIZED", lambda: self.model.assist(self.alice, "attempt-a", "demo"))
        self.reject({"ATTEMPT_FINALIZED", "OPERATION_CONFLICT"}, lambda: self.model.submit_answer(
            self.alice, "attempt-a", "Need more time"))

    # C04 only a validity gate is mocked; no acoustic score is fabricated.
    def test_invalid_recording_never_gets_a_precise_mock_score(self):
        for quality in ("silence", "too_short", "noisy"):
            with self.subTest(quality=quality):
                result = self.model.assess(self.alice, "invalid-" + quality, quality=quality)
                self.assertIsNone(result["score"])
                self.assertTrue(result["mock"])
                self.assertIn(result["state"], {"quality_insufficient", "not_evaluated"})

    def test_unavailable_provider_or_valid_mock_does_not_claim_acoustic_accuracy(self):
        for provider_available in (False, True):
            with self.subTest(provider_available=provider_available):
                result = self.model.assess(self.alice, "provider-" + str(provider_available),
                                            provider_available=provider_available)
                self.assertIsNone(result["score"])
                self.assertTrue(result["mock"])

    # C07 feedback privacy, reliable inbox, and repair evidence.
    def test_feedback_duplicate_is_one_record_and_changed_body_conflicts(self):
        first = self.new_feedback()
        again = self.new_feedback()
        self.assertEqual(first["feedback_id"], again["feedback_id"])
        self.reject("OPERATION_CONFLICT", lambda: self.model.submit_feedback(
            self.alice, "feedback-op", "Changed complaint"))

    def test_feedback_is_private_and_manager_role_is_separate(self):
        feedback_id = self.new_feedback()["feedback_id"]
        self.reject("ACCESS_DENIED", lambda: self.model.feedback(self.bob, feedback_id))
        self.model.feedback(self.support, feedback_id)
        self.reject({"ACCESS_DENIED", "SCOPE_DENIED"}, lambda: self.model.change_feedback(
            self.alice, feedback_id, "processing"))

    def test_append_feedback_keeps_same_id_and_does_not_mark_repaired(self):
        feedback_id = self.new_feedback()["feedback_id"]
        appended = self.model.append_feedback(self.alice, feedback_id, "Additional synthetic detail")
        self.assertEqual(appended["feedback_id"], feedback_id)
        actual = self.model.feedback(self.alice, feedback_id)
        self.assertIn("Additional synthetic detail", actual["info"])
        self.assertNotEqual(actual["status"], "fixed")

    def test_failed_notification_does_not_lose_feedback_and_redelivery_is_idempotent(self):
        feedback_id = self.new_feedback()["feedback_id"]
        self.model.dispatch_feedback(self.support, feedback_id, "operator", fail=True)
        self.assertEqual(self.model.feedback(self.alice, feedback_id)["status"], "received")
        self.assertEqual(self.model.inbox(self.support)["items"], [])
        self.model.dispatch_feedback(self.support, feedback_id, "operator")
        self.model.dispatch_feedback(self.support, feedback_id, "operator")
        self.assertEqual(len(self.model.inbox(self.support)["items"]), 1)

    def test_fetch_cursor_is_not_read_and_read_is_not_problem_resolution(self):
        feedback_id = self.new_feedback()["feedback_id"]
        self.model.dispatch_feedback(self.support, feedback_id, "alice")
        first = self.model.inbox(self.alice)
        self.assertIsNone(first["items"][0]["read_at"])
        self.assertIsNone(self.model.inbox(self.alice)["items"][0]["read_at"])
        self.model.inbox(self.alice, after=first["cursor"])
        notification_id = first["items"][0]["notification_id"]
        self.model.mark_read(self.alice, notification_id)
        self.assertIsNotNone(self.model.inbox(self.alice)["items"][0]["read_at"])
        self.assertEqual(self.model.feedback(self.alice, feedback_id)["status"], "received")

    def test_inbox_notification_cannot_be_read_by_other_user(self):
        feedback_id = self.new_feedback()["feedback_id"]
        self.model.dispatch_feedback(self.support, feedback_id, "alice")
        notification_id = self.model.inbox(self.alice)["items"][0]["notification_id"]
        self.assertEqual(self.model.inbox(self.bob)["items"], [])
        self.reject("ACCESS_DENIED", lambda: self.model.mark_read(self.bob, notification_id))

    def test_fix_requires_release_and_evidence_and_ai_cannot_close(self):
        feedback_id = self.new_feedback()["feedback_id"]
        self.reject("EVIDENCE_REQUIRED", lambda: self.model.change_feedback(
            self.support, feedback_id, "fixed"))
        self.reject("ACTOR_NOT_ALLOWED", lambda: self.model.change_feedback(
            self.support, feedback_id, "handled", actor="ai"))
        result = self.model.change_feedback(self.support, feedback_id, "fixed", release="synthetic-v1", evidence="fixture-evidence")
        self.assertEqual(result["release"], "synthetic-v1")
        self.assertEqual(result["evidence"], "fixture-evidence")

    def test_external_actor_cannot_gain_support_actions_by_claiming_human(self):
        feedback_id = self.new_feedback()["feedback_id"]
        external = Principal("operator", integration_id="external-agent", scopes=frozenset({"*"}),
                             roles=frozenset({"support"}), grant_id="external-support-claim")
        self.reject("ACTOR_NOT_ALLOWED", lambda: self.model.change_feedback(
            external, feedback_id, "handled", actor="human"))
        self.reject("ACTOR_NOT_ALLOWED", lambda: self.model.dispatch_feedback(
            external, feedback_id, "operator"))

    def test_attachments_are_opt_in_and_cross_owner_context_is_rejected(self):
        clean = self.new_feedback("no-attachments")
        self.assertEqual(clean["attachments"], [])
        self.model.add_attachment(self.bob, "bob-image")
        self.reject("ATTACHMENT_DENIED", lambda: self.model.submit_feedback(
            self.alice, "foreign-attachment", "Synthetic issue", attachments=["bob-image"]))
        self.reject({"ACCESS_DENIED", "SCOPE_DENIED"}, lambda: self.model.submit_feedback(
            self.alice, "foreign-context", "Synthetic issue", context={"material_id": "material-b"}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
