"""M19 local generation contracts. No real provider or authorization is created."""
from dataclasses import dataclass
from enum import Enum
from typing import Callable


class GenerationErrorCode(str, Enum):
    invalid_input = "invalid_input"
    authentication_required = "authentication_required"
    scope_denied = "scope_denied"
    not_found = "not_found"
    request_conflict = "request_conflict"
    revision_conflict = "revision_conflict"
    worker_conflict = "worker_conflict"
    storage_unavailable = "storage_unavailable"


class GenerationError(Exception):
    def __init__(self, code: GenerationErrorCode):
        self.code = code
        super().__init__(code.value)


@dataclass(frozen=True)
class GenerationOptions:
    locale: str = "en-US"
    policy_version: str = "us-conversation-v1"
    voice_config_ref: str = "unconfigured"
    require_timings: bool = True


@dataclass(frozen=True)
class JobView:
    job_id: str
    material_id: str
    material_version_id: str
    input_sha256: str
    revision: int
    state: str
    phase: str
    reason: str | None
    result_ref: str | None
    execution_kind: str | None
    cancel_requested: bool
    budget_state: str


@dataclass(frozen=True, repr=False)
class FrozenInput:
    owner_id: str
    material_id: str
    material_version_id: str
    input_sha256: str
    title: str
    text: str
    options: GenerationOptions


@dataclass(frozen=True, repr=False)
class ValidationGrant:
    """Internal fixture budget, NOT proof of a user's cloud/data approval."""
    grant_id: str
    owner_id: str
    unit: str
    limit_units: int
    reserve_units: int
    config_ref: str = "fixture-v1"
    max_calls: int = 16


@dataclass(frozen=True)
class FixtureCapabilities:
    config_ref: str = "fixture-v1"
    locale: str = "en-US"
    translation: bool = True
    pcm_wav: bool = True
    timings: bool = True
    pricing_known: bool = True
    rights_confirmed: bool = True
    max_input_bytes: int = 100_000


@dataclass(frozen=True, repr=False)
class GeneratedSentence:
    english: str
    translation: str
    start_ms: int
    end_ms: int


@dataclass(frozen=True, repr=False)
class FixtureResult:
    owner_id: str
    material_version_id: str
    input_sha256: str
    sentences: tuple[GeneratedSentence, ...]
    audio_wav: bytes
    usage_units: int | None
    usage_unit: str | None


@dataclass(frozen=True, repr=False)
class AttemptToken:
    job_id: str
    attempt_id: str
    fence: int
    operation_key: str
    expires_at: float


@dataclass(frozen=True, repr=False)
class FixtureAdapter:
    """Explicit trusted test callable; no provider registry/HTTP/credentials.

    Injected Python code is trusted process code, not a security sandbox. The
    worker permanently labels all outputs fixture, regardless of callable claims.
    There is deliberately no production ProviderAdapter in this validation slice.
    """
    generate: Callable[[FrozenInput, AttemptToken], FixtureResult]
    capabilities: FixtureCapabilities = FixtureCapabilities()


class DefinitelyNotSubmitted(Exception):
    """Only an adapter's positive evidence of no outbound execution may use this.

    A normal error/timeout is never this evidence. Its message is not exposed.
    """


@dataclass(frozen=True)
class BudgetSnapshot:
    unit: str
    limit_units: int
    reserved_units: int
    spent_units: int
    unknown_held_units: int
    max_calls: int = 0
    reserved_calls: int = 0
    submitted_calls: int = 0


@dataclass(frozen=True)
class ResultManifest:
    result_ref: str
    material_version_id: str
    input_sha256: str
    audio_sha256: str
    audio_bytes: int
    duration_ms: int
    sentence_count: int
    owner_id: str
    material_id: str
    job_id: str
    attempt_id: str
    policy_version: str
    config_ref: str
    voice_config_ref: str
    schema_version: int = 1
    plan_version: str = "generation-bundle-v1"
    timing_origin: str = "fixture"
    execution_kind: str = "fixture"
    client_learning_ready: bool = False
