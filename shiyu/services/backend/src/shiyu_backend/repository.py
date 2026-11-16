"""Transactional persistence seam. Repositories do not authenticate callers."""
from abc import ABC, abstractmethod
from .models import DeliveryReceipt, Draft, MaterialVersion, ReceiveMaterial


class MaterialRepository(ABC):
    @abstractmethod
    def receive(self, owner_id: str, integration_id: str,
                request: ReceiveMaterial, payload_hash: str) -> DeliveryReceipt: ...

    @abstractmethod
    def read_draft(self, owner_id: str, draft_id: str) -> Draft: ...

    @abstractmethod
    def list_drafts(self, owner_id: str) -> tuple[Draft, ...]: ...

    @abstractmethod
    def update_draft(self, owner_id: str, draft_id: str, expected_revision: int,
                     title: str | None, text: str | None) -> Draft: ...

    @abstractmethod
    def confirm_draft(self, owner_id: str, draft_id: str,
                      expected_revision: int) -> MaterialVersion: ...

    @abstractmethod
    def read_version(self, owner_id: str, version_id: str) -> MaterialVersion: ...

    @abstractmethod
    def list_versions(self, owner_id: str, material_id: str) -> tuple[MaterialVersion, ...]: ...
