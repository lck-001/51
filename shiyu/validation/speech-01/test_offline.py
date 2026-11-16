"""Offline contract/model tests. No cloud, paid API, human audio, or UI."""
from __future__ import annotations

import argparse
import base64
import contextlib
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import wave

import speech_probe as probe


def wav_bytes(seconds=1, *, channels=1, rate=16000, width=2):
    output = io.BytesIO()
    with wave.open(output, 'wb') as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(width)
        wav.setframerate(rate)
        wav.writeframes(b'\x01' * (int(rate * seconds) * channels * width))
    return output.getvalue()


def make_fixture(directory: Path, *, seconds=1):
    directory.mkdir(parents=True, exist_ok=True)
    audio = wav_bytes(seconds)
    reference = b'Let me walk you through the plan.\n'
    (directory / 'original.wav').write_bytes(audio)
    (directory / 'reference.txt').write_bytes(reference)
    manifest = {'schema': 'shiyu.speech.synthetic-fixture.v1',
        'kind': 'original_synthetic', 'producer': 'windows-sapi:unit-contract-fixture',
        'original': True, 'transformations': [], 'audioFile': 'original.wav',
        'referenceFile': 'reference.txt', 'audioSha256': probe.digest(audio),
        'referenceSha256': probe.digest(reference)}
    path = directory / 'manifest.local.json'
    path.write_text(json.dumps(manifest), encoding='utf-8')
    return path, manifest


def approval(fixture):
    # Deliberately synthetic price numbers for arithmetic tests, NOT Azure quote.
    return {'schema': 'shiyu.speech.approval.v1', 'approved': True,
        'approvalReference': 'unit-test-not-human-approval',
        'expiresAt': (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat(),
        'region': 'eastasia',
        'resourceId': '/subscriptions/unit/providers/Microsoft.CognitiveServices/accounts/unit',
        'resourceTier': 'S0', 'data': {'originalSyntheticOnly': True,
            'audioSha256': fixture.audio_sha256,
            'referenceSha256': fixture.reference_sha256,
            'allowAudioAndReferenceToAzure': True},
        'maxCalls': 2, 'maxAudioSeconds': 30, 'prosodyApproved': False,
        'pricing': {'confirmed': True, 'evidenceReference': 'unit-price-model-only',
            'evidenceDate': '2026-11-16', 'currency': 'USD', 'maxCost': '1',
            'basePerHour': '3.6', 'prosodyPerHour': None,
            'billingIncrementSeconds': '1', 'minimumBillableSecondsPerRequest': '1',
            'perRequestFee': '0', 'taxRate': '0', 'freeAllowanceVerified': False,
            'remainingFreeSeconds': None}}


class OfflineContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manifest_path, self.manifest = make_fixture(self.root)
        self.fixture = probe.load_fixture(self.manifest_path)

    def tearDown(self):
        self.temp.cleanup()

    def rejects(self, code, action):
        with self.assertRaises(probe.GateError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_pcm_format_duration_and_original_hash(self):
        self.assertEqual(self.fixture.duration_ms, 1000)
        self.assertEqual(self.fixture.frames, 16000)
        self.assertEqual(self.fixture.audio_sha256, self.manifest['audioSha256'])

    def test_stereo_rejected(self):
        self.rejects('mono_required', lambda: probe.inspect_wave(wav_bytes(channels=2)))

    def test_wrong_sample_rate_rejected(self):
        self.rejects('sample_rate_16000_required', lambda: probe.inspect_wave(wav_bytes(rate=8000)))

    def test_wrong_width_rejected(self):
        self.rejects('pcm16_required', lambda: probe.inspect_wave(wav_bytes(width=1)))

    def test_single_duration_limit(self):
        # 15.001 seconds is over the local 15-second per-request contract.
        self.rejects('single_audio_over_15_seconds',
                     lambda: probe.inspect_wave(wav_bytes(seconds=15.001)))

    def test_truncated_wave_rejected(self):
        self.rejects('wave_data_truncated', lambda: probe.inspect_wave(wav_bytes()[:-100]))

    def test_audio_hash_mismatch_rejected(self):
        (self.root / 'original.wav').write_bytes(wav_bytes(seconds=2))
        self.rejects('audio_hash_mismatch', lambda: probe.load_fixture(self.manifest_path))

    def test_reference_hash_mismatch_rejected(self):
        (self.root / 'reference.txt').write_text('Different.', encoding='utf-8')
        self.rejects('reference_hash_mismatch', lambda: probe.load_fixture(self.manifest_path))

    def test_path_traversal_rejected(self):
        self.manifest['audioFile'] = '../private.wav'
        self.manifest_path.write_text(json.dumps(self.manifest), encoding='utf-8')
        self.rejects('fixture_path_must_be_local_basename', lambda: probe.load_fixture(self.manifest_path))

    def test_transformed_audio_rejected(self):
        self.manifest['transformations'] = ['resample']
        self.manifest_path.write_text(json.dumps(self.manifest), encoding='utf-8')
        self.rejects('derived_or_transformed_audio_not_allowed',
                     lambda: probe.load_fixture(self.manifest_path))

    def test_request_uses_real_rest_assessment_contract(self):
        req = probe.prepare_request(self.fixture, region='eastasia', key='offline-test-key')
        params = json.loads(base64.b64decode(req.headers['Pronunciation-Assessment']))
        self.assertEqual(params['ReferenceText'], 'Let me walk you through the plan.')
        self.assertEqual(params['Dimension'], 'Comprehensive')
        self.assertEqual(params['Granularity'], 'Phoneme')
        self.assertEqual(params['EnableProsodyAssessment'], 'False')
        self.assertIn('eastasia.stt.speech.microsoft.com', req.url)
        self.assertEqual(req.audio, self.fixture.audio)
        self.assertNotIn('offline-test-key', repr(req))

    def test_region_cannot_inject_other_host(self):
        self.rejects('invalid_resource_region', lambda: probe.prepare_request(
            self.fixture, region='eastasia.evil.invalid', key='offline-only'))

    def test_sovereign_region_never_silently_uses_public_cloud_endpoint(self):
        self.rejects('public_cloud_region_not_reviewed', lambda: probe.prepare_request(
            self.fixture, region='chinaeast2', key='offline-only'))

    def test_header_injection_rejected(self):
        self.rejects('credential_missing_or_invalid', lambda: probe.prepare_request(
            self.fixture, region='eastasia', key='secret\r\nInjected: value'))

    def test_plain_asr_never_becomes_pronunciation_score(self):
        result = probe.normalize_result({'RecognitionStatus': 'Success',
            'NBest': [{'Confidence': 1.0, 'Lexical': 'same text'}]})
        self.assertEqual(result['assessmentState'], 'professional_assessment_missing')
        self.assertTrue(all(value is None for value in result['scores'].values()))
        self.assertFalse(result['asrConfidenceUsedAsPronunciation'])

    def test_current_rest_flat_professional_metrics(self):
        result = probe.normalize_result({'RecognitionStatus': 'Success', 'NBest': [{
            'AccuracyScore': 92, 'FluencyScore': 85, 'CompletenessScore': 100,
            'PronScore': 89, 'Display': 'must not be logged', 'Words': [
                {'Word': 'private-output-not-serialized', 'AccuracyScore': 70,
                 'ErrorType': 'Mispronunciation', 'Phonemes': [
                    {'Phoneme': 't', 'AccuracyScore': 70}]}]}]})
        self.assertEqual(result['providerLayout'], 'rest_flat')
        self.assertEqual(result['assessmentState'], 'professional_assessment')
        self.assertIsNone(result['scores']['ProsodyScore'])
        self.assertNotIn('private-output', json.dumps(result))
        self.assertFalse(result['humanPronunciationEffectVerified'])

    def test_sdk_nested_layout_is_explicit(self):
        result = probe.normalize_result({'RecognitionStatus': 'Success', 'NBest': [{
            'PronunciationAssessment': {'AccuracyScore': 90, 'PronScore': 88},
            'Words': [{'PronunciationAssessment': {'AccuracyScore': 80}}]}]})
        self.assertEqual(result['providerLayout'], 'sdk_nested')
        self.assertEqual(result['assessmentState'], 'professional_assessment_partial')
        self.assertIsNone(result['providerModelVersion'])

    def test_missing_requested_phoneme_detail_stays_partial(self):
        result = probe.normalize_result({'RecognitionStatus': 'Success', 'NBest': [{
            'AccuracyScore': 90, 'FluencyScore': 90, 'CompletenessScore': 100,
            'PronScore': 90, 'Words': [{'AccuracyScore': 90, 'ErrorType': 'None'}]}]})
        self.assertEqual(result['assessmentState'], 'professional_assessment_partial')
        self.assertFalse(result['phonemeAcousticDetailsPresent'])
        self.assertIn('phoneme_acoustic_details', result['missingExpectedDimensions'])

    def test_no_match_has_no_valid_scores(self):
        result = probe.normalize_result({'RecognitionStatus': 'NoMatch',
                                        'ErrorDetails': 'must not be logged'})
        self.assertEqual(result['assessmentState'], 'no_valid_speech')
        self.assertNotIn('must not', json.dumps(result))

    def test_invalid_score_is_not_clamped_or_fabricated(self):
        self.rejects('provider_score_outside_contract', lambda: probe.normalize_result(
            {'RecognitionStatus': 'Success', 'NBest': [{'AccuracyScore': float('nan')}]}))

    def test_missing_human_approval_stops_cloud(self):
        doc = approval(self.fixture)
        doc['approved'] = False
        self.rejects('specific_user_approval_required', lambda: probe.validate_approval(
            doc, self.fixture, region='eastasia', calls=1, prosody=False))

    def test_payload_approval_hash_must_match(self):
        doc = approval(self.fixture)
        doc['data']['audioSha256'] = '0' * 64
        self.rejects('approved_payload_hash_mismatch', lambda: probe.validate_approval(
            doc, self.fixture, region='eastasia', calls=1, prosody=False))

    def test_unknown_current_region_price_blocks_even_small_request(self):
        doc = approval(self.fixture)
        doc['pricing']['confirmed'] = False
        self.rejects('actual_region_price_evidence_required', lambda: probe.validate_approval(
            doc, self.fixture, region='eastasia', calls=1, prosody=False))

    def test_f0_does_not_automatically_mean_this_run_is_free(self):
        doc = approval(self.fixture)
        doc['resourceTier'] = 'F0'
        self.rejects('free_allowance_unverified', lambda: probe.validate_approval(
            doc, self.fixture, region='eastasia', calls=1, prosody=False))

    def test_prosody_requires_separate_addon_approval(self):
        self.rejects('prosody_addon_not_approved', lambda: probe.validate_approval(
            approval(self.fixture), self.fixture, region='eastasia', calls=1, prosody=True))

    def test_expired_approval_rejected(self):
        doc = approval(self.fixture)
        doc['expiresAt'] = '2020-01-01T00:00:00+00:00'
        self.rejects('approval_expired', lambda: probe.validate_approval(
            doc, self.fixture, region='eastasia', calls=1, prosody=False))

    def test_cost_arithmetic_uses_declared_rounding_not_assumed_free(self):
        cost = probe.validate_approval(approval(self.fixture), self.fixture,
                                      region='eastasia', calls=2, prosody=False)
        self.assertEqual(cost.per_call_cost, Decimal('0.001'))
        self.assertEqual(cost.reserved_audio_ms, 2000)

    def test_persistent_budget_caps_two_across_process_equivalent_instances(self):
        cost = probe.validate_approval(approval(self.fixture), self.fixture,
                                      region='eastasia', calls=1, prosody=False)
        ledger_file = self.root / 'budget.local.sqlite'
        ledger = probe.BudgetLedger(ledger_file)
        ledger.reserve(cost, 'first')
        ledger.close()
        reopened = probe.BudgetLedger(ledger_file)
        try:
            reopened.reserve(cost, 'second')
            self.rejects('persistent_m16_cap_exceeded', lambda: reopened.reserve(cost, 'third'))
        finally:
            reopened.close()

    def test_unknown_result_freezes_without_refund_or_retry(self):
        cost = probe.validate_approval(approval(self.fixture), self.fixture,
                                      region='eastasia', calls=1, prosody=False)
        ledger = probe.BudgetLedger(self.root / 'unknown.local.sqlite')
        try:
            ledger.reserve(cost, 'one')
            ledger.finish('one', success=False)
            self.rejects('ledger_unknown_or_failed_requires_reconciliation',
                         lambda: ledger.reserve(cost, 'another'))
            self.assertEqual(ledger.db.execute('SELECT calls FROM budget').fetchone()[0], 1)
        finally:
            ledger.close()

    def test_duplicate_reserved_batch_is_not_resubmitted(self):
        cost = probe.validate_approval(approval(self.fixture), self.fixture,
                                      region='eastasia', calls=1, prosody=False)
        ledger = probe.BudgetLedger(self.root / 'duplicate.local.sqlite')
        try:
            ledger.reserve(cost, 'same')
            self.rejects('batch_already_reserved_no_resubmit', lambda: ledger.reserve(cost, 'same'))
        finally:
            ledger.close()

    def test_ledger_audio_duration_cap_cannot_be_reset_by_new_approval(self):
        ledger = probe.BudgetLedger(self.root / 'duration.local.sqlite')
        try:
            first = probe.ApprovedCost('unit', 'USD', Decimal(1), Decimal('.01'), 1, 16000)
            ledger.reserve(first, 'one')
            second = probe.ApprovedCost('unit2', 'USD', Decimal(1), Decimal('.01'), 1, 15000)
            self.rejects('persistent_m16_cap_exceeded', lambda: ledger.reserve(second, 'two'))
        finally:
            ledger.close()

    def test_offline_cli_never_opens_network_reads_key_or_prints_payload(self):
        args = argparse.Namespace(manifest=str(self.manifest_path), calls=1,
            prosody=False, allow_cloud=False, approval=None)
        with patch.dict(os.environ, {'AZURE_SPEECH_KEY': 'DO_NOT_PRINT_ME',
                                    'AZURE_SPEECH_REGION': 'eastasia'}), \
             patch('urllib.request.build_opener', side_effect=AssertionError('network forbidden')):
            result = probe.run(args)
        encoded = json.dumps(result)
        self.assertNotIn('DO_NOT_PRINT_ME', encoded)
        self.assertNotIn('walk you', encoded)
        self.assertEqual(result['cloudCallsSubmitted'], 0)
        self.assertFalse(result['costVerified'])

    def test_explicit_cloud_switch_without_approval_still_cannot_send(self):
        output = io.StringIO()
        with patch('urllib.request.build_opener', side_effect=AssertionError('network forbidden')), \
             contextlib.redirect_stdout(output):
            code = probe.main(['--manifest', str(self.manifest_path), '--allow-cloud'])
        self.assertEqual(code, 2)
        self.assertIn('approval_file_required_for_cloud', output.getvalue())

    def test_redirect_handler_never_forwards_key(self):
        handler = probe._NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, 'Found', {},
                                                  'https://other.invalid/'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
