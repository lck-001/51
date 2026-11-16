"""Public intake contracts. TrustedCaller is supplied by verified authentication."""
from dataclasses import dataclass
from enum import Enum


class ErrorCode(str, Enum):
    invalid_input = "invalid_input"
    authentication_required = "authentication_required"
    scope_denied = "scope_denied"
    not_found = "not_found"
    delivery_conflict = "delivery_conflict"
    revision_conflict = "revision_conflict"
    storage_unavailable = "storage_unavailable"
    dependency_unavailable = "dependency_unavailable"


class BackendError(Exception):
    def __init__(self, code: ErrorCode):
        self.code = code
        super().__init__(code.value)

    @property
    def http_status(self) -> int:
        return {
            ErrorCode.invalid_input: 422,
            ErrorCode.authentication_required: 401,
            ErrorCode.scope_denied: 403,
            ErrorCode.not_found: 404,
            ErrorCode.delivery_conflict: 409,
            ErrorCode.revision_conflict: 409,
        }.get(self.code, 503)


@dataclass(frozen=True, repr=False)
class TrustedCaller:
    """Not a verifier: only an already verified server-side identity may create it."""
    owner_id: str
    integration_id: str
    scopes: frozenset[str]


@dataclass(frozen=True, repr=False)
class ReceiveMaterial:
    delivery_id: str
    source_key: str
    title: str
    text: str
    source_revision: str | None = None


class ReceiptStatus(str, Enum):
    accepted = "accepted"
    update_pending = "update_pending"


@dataclass(frozen=True)
class DeliveryReceipt:
    receipt_id: str
    material_id: str
    draft_id: str
    status: ReceiptStatus
    replayed: bool = False


@dataclass(frozen=True, repr=False)
class Draft:
    owner_id: str
    material_id: str
    draft_id: str
    revision: int
    title: str
    text: str
    original_text: str
    state: str
    updated_at: str


@dataclass(frozen=True, repr=False)
class MaterialVersion:
    owner_id: str
    material_id: str
    version_id: str
    version_number: int
    draft_id: str
    draft_revision: int
    title: str
    text: str
    confirmed_at: str


@dataclass(frozen=True)
class IntakeLimits:
    max_text_bytes: int = 1_000_000
    max_title_bytes: int = 512
    max_source_bytes: int = 512
    max_delivery_bytes: int = 128
