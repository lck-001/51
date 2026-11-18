"""Restricted local generation service and separate fixture-only worker seam.

No listener, thread, provider call or execution is started on import or create.
Business callers use create/get/cancel, never the internal worker/repository.
"""
from dataclasses import asdict
import hashlib
import io
import json
import math
import re
import wave

from .models import BackendError, ErrorCode, TrustedCaller
from .generation_models import (
    DefinitelyNotSubmitted, FixtureAdapter, FixtureCapabilities, FixtureResult,
    FrozenInput, GeneratedSentence, GenerationError, GenerationErrorCode as E,
    GenerationOptions, ValidationGrant,
)

CREATE = "generation:create"
READ = "generation:read"
CANCEL = "generation:cancel"
MATERIAL_READ = "materials:read"
MAX_AUDIO_BYTES = 2 * 1024 * 1024
MAX_SENTENCES = 128
MAX_TEXT_BYTES = 100_000


def _string(value, limit=128):
    try:
        valid = (isinstance(value, str) and bool(value.strip()) and
                 len(value.encode("utf-8")) <= limit and
                 not any(ord(c) < 32 or ord(c) == 127 for c in value))
    except (UnicodeError, TypeError):
        valid = False
    if not valid:
        raise GenerationError(E.invalid_input)


def _id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{32}", value):
        raise GenerationError(E.invalid_input)


def _revision(value):
    if type(value) is not int or value < 1:
        raise GenerationError(E.invalid_input)


def _allow(caller, scope):
    if not isinstance(caller, TrustedCaller):
        raise GenerationError(E.authentication_required)
    _string(caller.owner_id, 256)
    _string(caller.integration_id, 256)
    if not isinstance(caller.scopes, frozenset) or scope not in caller.scopes:
        raise GenerationError(E.scope_denied)


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
        ensure_ascii=False).encode("utf-8")).hexdigest()


class GenerationService:
    def __init__(self, materials, jobs):
        self.materials = materials
        self.jobs = jobs

    def create(self, caller, material_version_id, request_id, options=GenerationOptions()):
        _allow(caller, CREATE)
        _allow(caller, MATERIAL_READ)
        _id(material_version_id)
        _string(request_id)
        if type(options) is not GenerationOptions:
            raise GenerationError(E.invalid_input)
        _string(options.locale, 24)
        _string(options.policy_version, 128)
        _string(options.voice_config_ref, 128)
        if type(options.require_timings) is not bool:
            raise GenerationError(E.invalid_input)
        try:
            # MaterialRepository only returns confirmed immutable versions. Owner
            # is always from trusted context; unknown/other-owner stay not_found.
            source = self.materials.read_version(caller.owner_id, material_version_id)
        except BackendError as error:
            if error.code == ErrorCode.not_found:
                raise GenerationError(E.not_found) from None
            raise GenerationError(E.storage_unavailable) from None
        try:
            raw = source.text.encode("utf-8")
            if not raw or len(raw) > MAX_TEXT_BYTES:
                raise GenerationError(E.invalid_input)
            if source.owner_id != caller.owner_id or source.version_id != material_version_id:
                raise GenerationError(E.not_found)
            input_hash = hashlib.sha256(raw).hexdigest()
            frozen = FrozenInput(source.owner_id, source.material_id, source.version_id,
                input_hash, source.title, source.text, options)
            request_hash = _digest({"version": source.version_id, "input": input_hash,
                "options": asdict(options)})
        except GenerationError:
            raise
        except Exception:
            raise GenerationError(E.storage_unavailable) from None
        return self.jobs.create(frozen, request_id, options, request_hash)

    def get(self, caller, job_id):
        _allow(caller, READ)
        _id(job_id)
        return self.jobs.get(caller.owner_id, job_id)

    def cancel(self, caller, job_id, expected_revision):
        _allow(caller, CANCEL)
        _id(job_id)
        _revision(expected_revision)
        return self.jobs.cancel(caller.owner_id, job_id, expected_revision)


class FixtureGenerationWorker:
    """Trusted internal local-test seam, not a business/public retry interface.

    The only injected implementation is an explicitly labelled fixture callable.
    There is no real-provider type, dynamic import, credential or HTTP endpoint.
    A callable is trusted code: this class is not a sandbox for malicious code.
    Every output is forcibly fixture and never exports a client learning version.
    """
    def __init__(self, jobs, adapter):
        if type(adapter) is not FixtureAdapter or not callable(adapter.generate):
            raise GenerationError(E.invalid_input)
        if type(adapter.capabilities) is not FixtureCapabilities:
            raise GenerationError(E.invalid_input)
        cap = adapter.capabilities
        _string(cap.config_ref, 128)
        _string(cap.locale, 24)
        if (any(type(value) is not bool for value in (cap.translation, cap.pcm_wav,
                cap.timings, cap.pricing_known, cap.rights_confirmed))
            or type(cap.max_input_bytes) is not int or cap.max_input_bytes < 1):
            raise GenerationError(E.invalid_input)
        self.jobs, self.adapter = jobs, adapter

    def admit(self, job_id, expected_revision, grant):
        _id(job_id)
        _revision(expected_revision)
        if type(grant) is not ValidationGrant:
            raise GenerationError(E.invalid_input)
        for value in (grant.grant_id, grant.owner_id, grant.unit, grant.config_ref):
            _string(value, 256)
        if (type(grant.limit_units) is not int or type(grant.reserve_units) is not int
            or not 0 < grant.reserve_units <= grant.limit_units <= 1_000_000_000):
            raise GenerationError(E.invalid_input)
        if type(grant.max_calls) is not int or not 1 <= grant.max_calls <= 100_000:
            raise GenerationError(E.invalid_input)
        source = self.jobs.frozen_input(job_id)
        cap = self.adapter.capabilities
        reason = None
        if (cap.config_ref != grant.config_ref or cap.locale != source.options.locale
            or source.options.locale != "en-US"
            or source.options.policy_version != "us-conversation-v1"
            or not all(value is True for value in (cap.translation, cap.pcm_wav,
                cap.timings, cap.pricing_known, cap.rights_confirmed))
            or type(cap.max_input_bytes) is not int or cap.max_input_bytes < 1
            or len(source.text.encode("utf-8")) > cap.max_input_bytes
            or source.options.voice_config_ref not in {"unconfigured", cap.config_ref}):
            reason = "capability_unavailable"
        return self.jobs.admit(job_id, expected_revision, grant,
            admission_hash=_digest(asdict(cap)), blocked_reason=reason)

    def claim(self, job_id, expected_revision, lease_seconds=30):
        _id(job_id)
        _revision(expected_revision)
        if type(lease_seconds) not in {int, float} or not math.isfinite(lease_seconds) or not 0 < lease_seconds <= 300:
            raise GenerationError(E.invalid_input)
        return self.jobs.claim(job_id, expected_revision, lease_seconds,
            _digest(asdict(self.adapter.capabilities)))

    def _manifest(self, source, result, token):
        if type(result) is not FixtureResult:
            raise ValueError("invalid_fixture_result")
        if (result.owner_id != source.owner_id
            or result.material_version_id != source.material_version_id
            or result.input_sha256 != source.input_sha256):
            raise ValueError("wrong_binding")
        if type(result.audio_wav) is not bytes or not 44 <= len(result.audio_wav) <= MAX_AUDIO_BYTES:
            raise ValueError("invalid_audio")
        if type(result.sentences) is not tuple or not 1 <= len(result.sentences) <= MAX_SENTENCES:
            raise ValueError("invalid_sentences")
        with wave.open(io.BytesIO(result.audio_wav), "rb") as wav:
            if (wav.getcomptype() != "NONE" or wav.getnchannels() != 1
                or wav.getsampwidth() != 2 or wav.getframerate() != 16000
                or wav.getnframes() <= 0):
                raise ValueError("unsupported_audio")
            frames = wav.getnframes()
            if len(wav.readframes(frames)) != frames * 2:
                raise ValueError("truncated_audio")
            duration_ms = (frames * 1000) // 16000
        previous = 0
        text_bytes = 0
        for sentence in result.sentences:
            if type(sentence) is not GeneratedSentence:
                raise ValueError("invalid_sentence")
            for value in (sentence.english, sentence.translation):
                if not isinstance(value, str) or not value.strip():
                    raise ValueError("missing_text")
                text_bytes += len(value.encode("utf-8"))
            if (type(sentence.start_ms) is not int or type(sentence.end_ms) is not int
                or sentence.start_ms < previous or sentence.end_ms <= sentence.start_ms
                or sentence.end_ms > duration_ms):
                raise ValueError("invalid_timing")
            previous = sentence.end_ms
        if text_bytes > MAX_TEXT_BYTES:
            raise ValueError("text_too_large")
        return {"material_version_id": source.material_version_id,
            "owner_id": source.owner_id, "material_id": source.material_id,
            "job_id": token.job_id, "attempt_id": token.attempt_id,
            "schema_version": 1, "plan_version": "generation-bundle-v1",
            "policy_version": source.options.policy_version,
            "config_ref": self.adapter.capabilities.config_ref,
            "voice_config_ref": self.adapter.capabilities.config_ref,
            "timing_origin": "fixture",
            "input_sha256": source.input_sha256,
            "audio_sha256": hashlib.sha256(result.audio_wav).hexdigest(),
            "audio_bytes": len(result.audio_wav), "duration_ms": duration_ms,
            "sentence_count": len(result.sentences), "execution_kind": "fixture",
            "client_learning_ready": False}

    def run(self, token):
        # The durable CAS is separate from claim: repeated or simultaneous run
        # of the same claim can never execute its callable a second time.
        if not self.jobs.start(token, _digest(asdict(self.adapter.capabilities))):
            source = self.jobs.frozen_input(token.job_id)
            return self.jobs.get(source.owner_id, token.job_id)
        source = self.jobs.frozen_input(token.job_id)
        try:
            result = self.adapter.generate(source, token)
        except DefinitelyNotSubmitted:
            return self.jobs.not_submitted(token)
        except Exception:
            return self.jobs.unknown(token)
        try:
            manifest = self._manifest(source, result, token)
        except Exception:
            return self.jobs.finish(token, result, valid=False)
        return self.jobs.finish(token, result, manifest, valid=True)

    def recover_expired(self):
        return self.jobs.recover_expired()
