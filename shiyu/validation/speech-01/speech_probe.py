"""M16 short scripted acoustic assessment gate; stdlib only, OFFLINE by default.

--allow-cloud is a technical switch, never a substitute for user approval.
No SDK installation, resource creation, microphone, playback or UI automation.
"""
from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_CEILING
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import ssl
from typing import Any
import urllib.error
import urllib.request
import wave

BASE = Path(__file__).resolve().parent
MAX_CALLS = 2
MAX_AUDIO_MS = 30000
MAX_SINGLE_MS = 15000
MAX_RESPONSE_BYTES = 1024 * 1024
DEFAULT_MANIFEST = BASE / 'fixtures' / 'manifest.local.json'
LEDGER_FILE = BASE / 'results' / 'cloud-budget.local.sqlite'
SCORE_NAMES = ('AccuracyScore', 'FluencyScore', 'CompletenessScore', 'PronScore', 'ProsodyScore')
# Public Azure only. Sovereign/private endpoints require a separate reviewed
# destination contract; do not silently send their keys/audio to public cloud.
PUBLIC_REGIONS = frozenset('southafricanorth eastasia southeastasia australiaeast centralindia '
    'japaneast japanwest koreacentral canadacentral canadaeast northeurope westeurope '
    'francecentral germanywestcentral italynorth norwayeast swedencentral switzerlandnorth '
    'switzerlandwest uksouth ukwest uaenorth brazilsouth qatarcentral centralus eastus eastus2 '
    'northcentralus southcentralus westcentralus westus westus2 westus3'.split())


class GateError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def require(condition: bool, code: str) -> None:
    if not condition:
        raise GateError(code)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    try:
        result = json.loads(path.read_text(encoding='utf-8-sig'))
    except (OSError, UnicodeError, ValueError):
        raise GateError('json_file_unreadable') from None
    require(isinstance(result, dict), 'json_object_required')
    return result


def finite_decimal(value: Any, code: str) -> Decimal:
    require(not isinstance(value, bool) and value is not None, code)
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        raise GateError(code) from None
    require(result.is_finite() and result >= 0, code)
    return result


def positive_int(value: Any, code: str, upper: int) -> int:
    require(type(value) is int and 0 < value <= upper, code)
    return value


@dataclass(frozen=True, repr=False)
class Fixture:
    audio: bytes = field(repr=False)
    reference: str = field(repr=False)
    audio_sha256: str
    reference_sha256: str
    frames: int
    duration_ms: int
    manifest_path: Path = field(repr=False)


def inspect_wave(data: bytes) -> tuple[int, int]:
    require(len(data) <= 16000 * 2 * 15 + 4096, 'wave_file_too_large')
    try:
        with wave.open(io.BytesIO(data), 'rb') as audio:
            require(audio.getcomptype() == 'NONE', 'pcm_required')
            require(audio.getnchannels() == 1, 'mono_required')
            require(audio.getsampwidth() == 2, 'pcm16_required')
            require(audio.getframerate() == 16000, 'sample_rate_16000_required')
            frames = audio.getnframes()
            actual = audio.readframes(frames)
            require(len(actual) == frames * 2, 'wave_data_truncated')
            require(frames > 0, 'empty_wave')
            duration_ms = math.ceil(frames * 1000 / 16000)
            require(duration_ms <= MAX_SINGLE_MS, 'single_audio_over_15_seconds')
            return frames, duration_ms
    except (wave.Error, EOFError, OSError):
        raise GateError('invalid_wave') from None


def _child(directory: Path, name: Any) -> Path:
    require(isinstance(name, str) and Path(name).name == name and name not in ('', '.', '..'),
            'fixture_path_must_be_local_basename')
    path = (directory / name).resolve()
    require(path.parent == directory.resolve(), 'fixture_path_escape')
    return path


def load_fixture(manifest_path: Path) -> Fixture:
    manifest = read_json(manifest_path)
    require(manifest.get('schema') == 'shiyu.speech.synthetic-fixture.v1', 'fixture_schema')
    require(manifest.get('kind') == 'original_synthetic' and manifest.get('original') is True,
            'original_synthetic_only')
    require(manifest.get('transformations') == [], 'derived_or_transformed_audio_not_allowed')
    require(isinstance(manifest.get('producer'), str) and
            manifest['producer'].startswith('windows-sapi:'), 'synthetic_provenance_required')
    try:
        audio = _child(manifest_path.parent, manifest.get('audioFile')).read_bytes()
        reference_data = _child(manifest_path.parent, manifest.get('referenceFile')).read_bytes()
    except OSError:
        raise GateError('fixture_file_unreadable') from None
    require(digest(audio) == manifest.get('audioSha256'), 'audio_hash_mismatch')
    require(digest(reference_data) == manifest.get('referenceSha256'), 'reference_hash_mismatch')
    try:
        reference = reference_data.decode('utf-8-sig').strip()
    except UnicodeError:
        raise GateError('reference_utf8_required') from None
    require(0 < len(reference) <= 500 and not any(ord(c) < 32 for c in reference),
            'short_scripted_reference_required')
    frames, duration_ms = inspect_wave(audio)
    return Fixture(audio, reference, digest(audio), digest(reference_data),
                   frames, duration_ms, manifest_path.resolve())


def validate_region(region: str) -> str:
    require(bool(re.fullmatch(r'[a-z][a-z0-9]{1,30}', region)), 'invalid_resource_region')
    require(region in PUBLIC_REGIONS, 'public_cloud_region_not_reviewed')
    return region


@dataclass(frozen=True, repr=False)
class PreparedRequest:
    url: str
    headers: dict[str, str] = field(repr=False)
    audio: bytes = field(repr=False)


def prepare_request(fixture: Fixture, *, region: str, key: str,
                    prosody: bool = False) -> PreparedRequest:
    validate_region(region)
    require(bool(key) and not any(ord(c) < 32 for c in key), 'credential_missing_or_invalid')
    # REST docs use strings for the True/False assessment options.
    params = {
        'ReferenceText': fixture.reference,
        'GradingSystem': 'HundredMark',
        'Granularity': 'Phoneme',
        'Dimension': 'Comprehensive',
        'EnableMiscue': 'True',
        'EnableProsodyAssessment': 'True' if prosody else 'False',
    }
    encoded = base64.b64encode(json.dumps(params, ensure_ascii=False,
        separators=(',', ':')).encode('utf-8')).decode('ascii')
    return PreparedRequest(
        f'https://{region}.stt.speech.microsoft.com/speech/recognition/conversation/'
        'cognitiveservices/v1?language=en-US&format=detailed',
        {'Ocp-Apim-Subscription-Key': key,
         'Pronunciation-Assessment': encoded,
         'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=16000',
         'Accept': 'application/json'}, fixture.audio)


def _score(value: Any) -> float | None:
    if value is None:
        return None
    require(type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 100,
            'provider_score_outside_contract')
    return float(value)


def _assessment(node: dict[str, Any]) -> tuple[dict[str, Any], str]:
    nested = node.get('PronunciationAssessment')
    return (nested, 'sdk_nested') if isinstance(nested, dict) else (node, 'rest_flat')


def normalize_result(payload: Any) -> dict[str, Any]:
    require(isinstance(payload, dict), 'provider_json_object_required')
    status = payload.get('RecognitionStatus')
    known = {'Success', 'NoMatch', 'InitialSilenceTimeout', 'BabbleTimeout', 'Error'}
    status = status if isinstance(status, str) and status in known else 'Unknown'
    result: dict[str, Any] = {
        'contract': 'shiyu.speech.acoustic-assessment.v1',
        'recognitionStatus': status,
        'assessmentState': 'no_valid_speech',
        'scores': {name: None for name in SCORE_NAMES},
        'wordDetails': [],
        'scoreMeaning': 'provider_acoustic_model_score_not_correct_percent',
        'asrConfidenceUsedAsPronunciation': False,
        'humanPronunciationEffectVerified': False,
        'providerModelVersion': None,
    }
    if status != 'Success':
        return result
    nbest = payload.get('NBest')
    require(isinstance(nbest, list) and nbest and isinstance(nbest[0], dict),
            'detailed_result_missing')
    first = nbest[0]
    assessment, layout = _assessment(first)
    scores = {name: _score(assessment.get(name)) for name in SCORE_NAMES}
    if scores['AccuracyScore'] is None:
        result['assessmentState'] = 'professional_assessment_missing'
        return result  # Text success/confidence is never promoted to a score.
    result['scores'] = scores
    result['providerLayout'] = layout
    result['assessmentState'] = ('professional_assessment' if
        all(scores[name] is not None for name in SCORE_NAMES[:4]) else
        'professional_assessment_partial')
    words = first.get('Words', [])
    require(isinstance(words, list) and len(words) <= 200, 'word_details_outside_contract')
    allowed_errors = {'None', 'Omission', 'Insertion', 'Mispronunciation',
                      'UnexpectedBreak', 'MissingBreak', 'Monotone'}
    for index, word in enumerate(words):
        require(isinstance(word, dict), 'invalid_word_detail')
        values, _ = _assessment(word)
        phonemes = word.get('Phonemes')
        require(phonemes is None or isinstance(phonemes, list) and len(phonemes) <= 100,
                'phoneme_details_outside_contract')
        details = []
        for phone_index, phone in enumerate(phonemes or []):
            require(isinstance(phone, dict), 'invalid_phoneme_detail')
            phone_scores, _ = _assessment(phone)
            # No ASR text, reference words, headers or raw provider body in receipts.
            details.append({'phonemeIndex': phone_index,
                            'accuracyScore': _score(phone_scores.get('AccuracyScore'))})
        error = values.get('ErrorType')
        result['wordDetails'].append({'wordIndex': index,
            'accuracyScore': _score(values.get('AccuracyScore')),
            'errorType': error if isinstance(error, str) and error in allowed_errors else None,
            'phonemeDetailsPresent': phonemes is not None,
            'phonemes': details})
    result['wordDetailsPresent'] = bool(words)
    result['phonemeAcousticDetailsPresent'] = any(
        phone['accuracyScore'] is not None for word in result['wordDetails']
        for phone in word['phonemes'])
    result['missingExpectedDimensions'] = [name for name in SCORE_NAMES[:4]
                                           if scores[name] is None]
    if not result['phonemeAcousticDetailsPresent']:
        result['missingExpectedDimensions'].append('phoneme_acoustic_details')
        result['assessmentState'] = 'professional_assessment_partial'
    return result


@dataclass(frozen=True)
class ApprovedCost:
    approval_hash: str
    currency: str
    max_cost: Decimal
    per_call_cost: Decimal
    reserved_calls: int
    reserved_audio_ms: int


def validate_approval(doc: dict[str, Any], fixture: Fixture, *, region: str,
                      calls: int, prosody: bool, now: datetime | None = None) -> ApprovedCost:
    require(doc.get('schema') == 'shiyu.speech.approval.v1' and doc.get('approved') is True,
            'specific_user_approval_required')
    require(isinstance(doc.get('approvalReference'), str) and bool(doc['approvalReference'].strip()),
            'approval_reference_missing')
    try:
        expires = datetime.fromisoformat(doc['expiresAt'].replace('Z', '+00:00'))
        require(expires.tzinfo is not None and expires > (now or datetime.now(timezone.utc)),
                'approval_expired')
    except (KeyError, AttributeError, TypeError, ValueError):
        raise GateError('approval_expiry_required') from None
    require(doc.get('region') == region and validate_region(region) == region,
            'approved_region_mismatch')
    require(isinstance(doc.get('resourceId'), str) and
            '/providers/Microsoft.CognitiveServices/accounts/' in doc['resourceId'],
            'authorized_speech_resource_required')
    require(doc.get('resourceTier') in ('F0', 'S0'), 'resource_tier_unconfirmed')
    data = doc.get('data', {})
    require(data.get('originalSyntheticOnly') is True and
            data.get('allowAudioAndReferenceToAzure') is True,
            'audio_reference_external_processing_not_approved')
    require(data.get('audioSha256') == fixture.audio_sha256 and
            data.get('referenceSha256') == fixture.reference_sha256,
            'approved_payload_hash_mismatch')
    limit_calls = positive_int(doc.get('maxCalls'), 'approval_call_cap', MAX_CALLS)
    limit_seconds = finite_decimal(doc.get('maxAudioSeconds'), 'approval_audio_cap')
    require(limit_seconds <= 30 and calls <= limit_calls and
            calls * fixture.duration_ms <= limit_seconds * 1000,
            'approved_call_or_duration_limit_exceeded')
    require(not prosody or doc.get('prosodyApproved') is True, 'prosody_addon_not_approved')
    pricing = doc.get('pricing', {})
    require(pricing.get('confirmed') is True and
            isinstance(pricing.get('evidenceReference'), str) and bool(pricing['evidenceReference']) and
            isinstance(pricing.get('evidenceDate'), str) and bool(pricing['evidenceDate']),
            'actual_region_price_evidence_required')
    currency = pricing.get('currency')
    require(isinstance(currency, str) and bool(re.fullmatch(r'[A-Z]{3}', currency)),
            'approved_currency_required')
    cap = finite_decimal(pricing.get('maxCost'), 'approved_cost_cap_required')
    base = finite_decimal(pricing.get('basePerHour'), 'base_hour_price_required')
    extra = finite_decimal(pricing.get('prosodyPerHour'), 'prosody_hour_price_required') if prosody else Decimal(0)
    increment = finite_decimal(pricing.get('billingIncrementSeconds'), 'billing_increment_required')
    require(increment >= 1, 'billing_increment_at_least_one_second')
    minimum = finite_decimal(pricing.get('minimumBillableSecondsPerRequest'), 'billing_minimum_required')
    per_request = finite_decimal(pricing.get('perRequestFee'), 'per_request_fee_required')
    tax = finite_decimal(pricing.get('taxRate'), 'tax_rule_required')
    require(tax <= 1, 'tax_rule_invalid')
    if doc['resourceTier'] == 'F0':
        require(pricing.get('freeAllowanceVerified') is True and
                finite_decimal(pricing.get('remainingFreeSeconds'), 'free_allowance_unverified') >=
                Decimal(calls * fixture.duration_ms) / 1000, 'free_allowance_unverified')
    seconds = Decimal(fixture.duration_ms) / 1000
    billable = max(minimum, (seconds / increment).to_integral_value(rounding=ROUND_CEILING) * increment)
    per_call = (billable / 3600 * (base + extra) + per_request) * (1 + tax)
    require(per_call * calls <= cap, 'approved_cost_cap_exceeded')
    fingerprint = digest(json.dumps(doc, sort_keys=True, separators=(',', ':')).encode())
    return ApprovedCost(fingerprint, currency, cap, per_call, calls,
                        calls * fixture.duration_ms)


class BudgetLedger:
    """Local persistent M16 cap, not a production/vendor billing ledger.

    Reservations are never refunded on timeout or failure. No reset CLI exists.
    A crash after reserve/submission cannot silently reissue the same batch.
    """
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=5, isolation_level=None)
        self.db.execute('CREATE TABLE IF NOT EXISTS budget '
            '(id INTEGER PRIMARY KEY CHECK(id=1), calls INTEGER NOT NULL, '
            'audio_ms INTEGER NOT NULL, currency TEXT, cost TEXT NOT NULL, frozen INTEGER NOT NULL)')
        self.db.execute("INSERT OR IGNORE INTO budget VALUES(1,0,0,NULL,'0',0)")
        self.db.execute('CREATE TABLE IF NOT EXISTS reservations '
            '(batch TEXT PRIMARY KEY, status TEXT NOT NULL)')

    def close(self) -> None:
        self.db.close()

    def reserve(self, approval: ApprovedCost, batch: str) -> None:
        self.db.execute('BEGIN IMMEDIATE')
        try:
            calls, audio_ms, currency, cost, frozen = self.db.execute(
                'SELECT calls,audio_ms,currency,cost,frozen FROM budget WHERE id=1').fetchone()
            require(not frozen, 'ledger_unknown_or_failed_requires_reconciliation')
            require(self.db.execute('SELECT 1 FROM reservations WHERE batch=?', (batch,)).fetchone() is None,
                    'batch_already_reserved_no_resubmit')
            require(calls + approval.reserved_calls <= MAX_CALLS and
                    audio_ms + approval.reserved_audio_ms <= MAX_AUDIO_MS, 'persistent_m16_cap_exceeded')
            require(currency in (None, approval.currency), 'ledger_currency_changed')
            total = Decimal(cost) + approval.per_call_cost * approval.reserved_calls
            require(total <= approval.max_cost, 'persistent_cost_cap_exceeded')
            self.db.execute('UPDATE budget SET calls=?,audio_ms=?,currency=?,cost=? WHERE id=1',
                (calls + approval.reserved_calls, audio_ms + approval.reserved_audio_ms,
                 approval.currency, str(total)))
            self.db.execute("INSERT INTO reservations VALUES(?,'reserved')", (batch,))
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise

    def finish(self, batch: str, *, success: bool) -> None:
        self.db.execute('BEGIN IMMEDIATE')
        try:
            self.db.execute('UPDATE reservations SET status=? WHERE batch=?',
                ('complete' if success else 'unknown_or_failed', batch))
            if not success:
                self.db.execute('UPDATE budget SET frozen=1 WHERE id=1')
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward a Speech key or audio to a redirect host.


def send_once(request: PreparedRequest) -> dict[str, Any]:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()), _NoRedirect())
    req = urllib.request.Request(request.url, data=request.audio,
                                 headers=request.headers, method='POST')
    try:
        with opener.open(req, timeout=30) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
            require(len(body) <= MAX_RESPONSE_BYTES, 'provider_response_too_large')
            require(response.status == 200, 'provider_http_not_200')
    except urllib.error.HTTPError as error:
        # Do not print response bodies, Location, URL, headers, or credentials.
        raise GateError(f'provider_http_{int(error.code)}_no_retry') from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise GateError('cloud_result_unknown_no_retry') from None
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeError):
        raise GateError('provider_json_invalid_no_retry') from None
    return normalize_result(payload)


def run(args: argparse.Namespace) -> dict[str, Any]:
    calls = positive_int(args.calls, 'calls_must_be_1_or_2', MAX_CALLS)
    fixture = load_fixture(Path(args.manifest))
    require(calls * fixture.duration_ms <= MAX_AUDIO_MS, 'total_audio_over_30_seconds')
    # Offline never loads a key and never creates a network opener or ledger.
    region = os.environ.get('AZURE_SPEECH_REGION', '').strip() or 'eastasia'
    validate_region(region)
    result: dict[str, Any] = {
        'schema': 'shiyu.speech.preflight.v1',
        'mode': 'offline', 'cloudCallsSubmitted': 0,
        'fixtureAudioSha256': fixture.audio_sha256,
        'fixtureReferenceSha256': fixture.reference_sha256,
        'audioMsPerCall': fixture.duration_ms, 'plannedCalls': calls,
        'plannedAudioMs': calls * fixture.duration_ms,
        'format': 'PCM16LE/16000Hz/mono/WAV', 'locale': 'en-US',
        'assessment': 'scripted_professional_acoustic', 'prosodyRequested': args.prosody,
        'candidateRegion': region,
        'humanPronunciationEffectVerified': False,
        'costVerified': False,
        'approvalNeededBeforeCloud': True,
    }
    # Exercise the real request constructor without revealing headers or bytes.
    prepare_request(fixture, region=region, key='OFFLINE_PLACEHOLDER', prosody=args.prosody)
    if not args.allow_cloud:
        return result
    require(args.approval is not None, 'approval_file_required_for_cloud')
    require(fixture.manifest_path.parent == (BASE / 'fixtures').resolve(),
            'cloud_fixture_outside_validation_scope')
    require(bool(os.environ.get('AZURE_SPEECH_REGION', '').strip()), 'explicit_resource_region_required')
    approval = validate_approval(read_json(Path(args.approval)), fixture,
                                region=region, calls=calls, prosody=args.prosody)
    key = os.environ.get('AZURE_SPEECH_KEY', '').strip()
    request = prepare_request(fixture, region=region, key=key, prosody=args.prosody)
    batch = digest((approval.approval_hash + fixture.audio_sha256 +
                    fixture.reference_sha256 + str(args.prosody) + str(calls)).encode())
    ledger = BudgetLedger(LEDGER_FILE)
    try:
        ledger.reserve(approval, batch)
        result.update(mode='cloud', costVerified=True, approvalNeededBeforeCloud=False,
                      currency=approval.currency, reservedEstimatedCost=str(approval.per_call_cost * calls),
                      results=[])
        try:
            for _ in range(calls):
                result['cloudCallsSubmitted'] += 1
                assessment = send_once(request)
                result['results'].append(assessment)
                require(assessment['assessmentState'] == 'professional_assessment',
                        'professional_result_missing_or_partial_no_retry')
            ledger.finish(batch, success=True)
        except BaseException:
            ledger.finish(batch, success=False)
            raise
    finally:
        ledger.close()
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', default=str(DEFAULT_MANIFEST))
    parser.add_argument('--calls', type=int, default=1)
    parser.add_argument('--prosody', action='store_true')
    parser.add_argument('--allow-cloud', action='store_true')
    parser.add_argument('--approval')
    parser.add_argument('--output', help='Optional sanitized .local.json receipt')
    args = parser.parse_args(argv)
    try:
        result = run(args)
        code = 0
    except GateError as error:
        result = {'schema': 'shiyu.speech.preflight.v1', 'passed': False,
                  'error': error.code, 'automaticRetry': False,
                  'cloudCallCountMustBeReconciledFromLocalLedger': bool(args.allow_cloud)}
        code = 2
    except Exception:
        result = {'schema': 'shiyu.speech.preflight.v1', 'passed': False,
                  'error': 'local_or_provider_operation_unconfirmed', 'automaticRetry': False}
        code = 2
    encoded = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False)
    if args.output:
        try:
            target = Path(args.output)
            require(target.name.endswith('.local.json'), 'receipt_local_json_required')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(encoded, encoding='utf-8')
        except (OSError, GateError):
            print(json.dumps({'passed': False, 'error': 'receipt_write_failed_no_retry'}))
            return 2
    print(encoded)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
