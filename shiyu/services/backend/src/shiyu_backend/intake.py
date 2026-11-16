"""Restricted intake service: no generation, publishing or provider tools."""
import hashlib
import json
import re
from .models import BackendError, ErrorCode, IntakeLimits, ReceiveMaterial, TrustedCaller
from .repository import MaterialRepository

RECEIVE = "materials:receive"
READ = "materials:read"
WRITE = "materials:write"
CONFIRM = "materials:confirm"


class IntakeService:
    def __init__(self, repository: MaterialRepository, limits: IntakeLimits | None = None):
        self.repository = repository
        self.limits = limits or IntakeLimits()

    def _allow(self, caller: TrustedCaller, scope: str) -> None:
        if not isinstance(caller, TrustedCaller):
            raise BackendError(ErrorCode.authentication_required)
        self._string(caller.owner_id, 256)
        self._string(caller.integration_id, 256)
        if scope not in caller.scopes:
            raise BackendError(ErrorCode.scope_denied)

    @staticmethod
    def _string(value, maximum: int, *, empty=False, multiline=False) -> None:
        try:
            valid = isinstance(value, str) and (empty or bool(value.strip()))
            valid = valid and len(value.encode("utf-8")) <= maximum
            if not multiline:
                valid = valid and not any(ord(c) < 32 or ord(c) == 127 for c in value)
        except (UnicodeError, TypeError):
            valid = False
        if not valid:
            raise BackendError(ErrorCode.invalid_input)

    @staticmethod
    def _id(value: str) -> None:
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{32}", value):
            raise BackendError(ErrorCode.invalid_input)

    @staticmethod
    def _revision(value: int) -> None:
        if type(value) is not int or value < 1:
            raise BackendError(ErrorCode.invalid_input)

    def receive(self, caller: TrustedCaller, request: ReceiveMaterial):
        self._allow(caller, RECEIVE)
        if not isinstance(request, ReceiveMaterial):
            raise BackendError(ErrorCode.invalid_input)
        self._string(request.delivery_id, self.limits.max_delivery_bytes)
        self._string(request.source_key, self.limits.max_source_bytes)
        self._string(request.title, self.limits.max_title_bytes)
        self._string(request.text, self.limits.max_text_bytes, multiline=True)
        if request.source_revision is not None:
            self._string(request.source_revision, 256)
        body = {"delivery_id": request.delivery_id, "source_key": request.source_key,
                "source_revision": request.source_revision,
                "title": request.title, "text": request.text}
        digest = hashlib.sha256(json.dumps(body, sort_keys=True,
            separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
        return self.repository.receive(caller.owner_id, caller.integration_id, request, digest)

    def read_draft(self, caller, draft_id):
        self._allow(caller, READ); self._id(draft_id)
        return self.repository.read_draft(caller.owner_id, draft_id)

    def list_drafts(self, caller):
        self._allow(caller, READ)
        return self.repository.list_drafts(caller.owner_id)

    def update_draft(self, caller, draft_id, expected_revision, *, title=None, text=None):
        self._allow(caller, WRITE); self._id(draft_id); self._revision(expected_revision)
        if title is None and text is None:
            raise BackendError(ErrorCode.invalid_input)
        if title is not None: self._string(title, self.limits.max_title_bytes)
        if text is not None: self._string(text, self.limits.max_text_bytes, multiline=True)
        return self.repository.update_draft(caller.owner_id, draft_id, expected_revision, title, text)

    def confirm_draft(self, caller, draft_id, expected_revision):
        self._allow(caller, CONFIRM); self._id(draft_id); self._revision(expected_revision)
        return self.repository.confirm_draft(caller.owner_id, draft_id, expected_revision)

    def read_version(self, caller, version_id):
        self._allow(caller, READ); self._id(version_id)
        return self.repository.read_version(caller.owner_id, version_id)

    def list_versions(self, caller, material_id):
        self._allow(caller, READ); self._id(material_id)
        return self.repository.list_versions(caller.owner_id, material_id)
