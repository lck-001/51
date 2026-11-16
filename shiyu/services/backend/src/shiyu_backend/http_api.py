"""HTTP facade. Deny by default; verifier injection is not real authentication."""
from dataclasses import asdict
import hmac
import inspect
from typing import Callable, Mapping

from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, StrictInt, StrictStr

from .intake import IntakeService
from .models import (BackendError, ErrorCode, IntakeLimits, ReceiveMaterial,
                     TrustedCaller)
from .repository import MaterialRepository


class _Body(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ReceiveBody(_Body):
    delivery_id: StrictStr
    source_key: StrictStr
    title: StrictStr
    text: StrictStr
    source_revision: StrictStr | None = None


class EditBody(_Body):
    expected_revision: StrictInt = Field(ge=1)
    title: StrictStr | None = None
    text: StrictStr | None = None


class ConfirmBody(_Body):
    expected_revision: StrictInt = Field(ge=1)


class _LimitedBody:
    """Bound raw JSON before FastAPI parsing; never log/echo submitted content."""
    def __init__(self, app, maximum):
        self.app, self.maximum = app, maximum

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        messages, size = [], 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            if message["type"] != "http.request":
                continue
            size += len(message.get("body", b""))
            if size > self.maximum:
                response = JSONResponse({"error": "request_too_large"}, status_code=413)
                return await response(scope, receive, send)
            messages.append(message)
            if not message.get("more_body", False):
                break
        index = 0

        async def replay():
            nonlocal index
            if index < len(messages):
                message = messages[index]
                index += 1
                return message
            return {"type": "http.disconnect"}

        return await self.app(scope, replay, send)


def create_app(repository: MaterialRepository, *,
               caller_resolver: Callable | None = None,
               limits: IntakeLimits | None = None) -> FastAPI:
    """No network listener, migration or credentials are created by this factory.

    The resolver must verify identity server-side; no owner header/body fallback.
    With no resolver, all material endpoints return authentication_required.
    """
    service = IntakeService(repository, limits)
    app = FastAPI(title="Shiyu restricted intake", docs_url=None,
                  redoc_url=None, openapi_url=None, debug=False)
    app.add_middleware(_LimitedBody,
        maximum=service.limits.max_text_bytes * 6 + 32_768)

    async def caller(request: Request):
        if caller_resolver is None:
            raise BackendError(ErrorCode.authentication_required)
        try:
            identity = caller_resolver(request)
            if inspect.isawaitable(identity):
                identity = await identity
        except BackendError:
            raise
        except Exception:
            raise BackendError(ErrorCode.authentication_required) from None
        if not isinstance(identity, TrustedCaller):
            raise BackendError(ErrorCode.authentication_required)
        return identity

    @app.exception_handler(BackendError)
    async def domain_error(_request, error):
        return JSONResponse({"error": error.code.value}, status_code=error.http_status)

    @app.exception_handler(RequestValidationError)
    async def invalid_body(_request, _error):
        # Pydantic's detailed errors can contain the raw submitted private input.
        return JSONResponse({"error": "invalid_input"}, status_code=422)

    @app.post("/v1/material-deliveries", status_code=201)
    def receive_material(body: ReceiveBody, actor=Depends(caller)):
        receipt = service.receive(actor, ReceiveMaterial(**body.model_dump()))
        return asdict(receipt)

    @app.get("/v1/drafts")
    def drafts(actor=Depends(caller)):
        return {"items": [asdict(item) for item in service.list_drafts(actor)]}

    @app.get("/v1/drafts/{draft_id}")
    def draft(draft_id: str, actor=Depends(caller)):
        return asdict(service.read_draft(actor, draft_id))

    @app.patch("/v1/drafts/{draft_id}")
    def edit(draft_id: str, body: EditBody, actor=Depends(caller)):
        return asdict(service.update_draft(actor, draft_id,
            body.expected_revision, title=body.title, text=body.text))

    @app.post("/v1/drafts/{draft_id}/confirm")
    def confirm(draft_id: str, body: ConfirmBody, actor=Depends(caller)):
        return asdict(service.confirm_draft(actor, draft_id, body.expected_revision))

    @app.get("/v1/versions/{version_id}")
    def version(version_id: str, actor=Depends(caller)):
        return asdict(service.read_version(actor, version_id))

    @app.get("/v1/materials/{material_id}/versions")
    def versions(material_id: str, actor=Depends(caller)):
        return {"items": [asdict(item) for item in service.list_versions(actor, material_id)]}

    return app


def validation_token_resolver(tokens: Mapping[str, TrustedCaller]) -> Callable:
    """Synthetic loopback validation only. Not OIDC, token issuance or production auth.

    Tokens are injected in memory by the test harness; none are stored or logged.
    """
    approved = tuple(tokens.items())
    if not approved or any(not isinstance(key, str) or not key or
                           not isinstance(value, TrustedCaller)
                           for key, value in approved):
        raise BackendError(ErrorCode.invalid_input)

    def resolve(request: Request):
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer "):
            raise BackendError(ErrorCode.authentication_required)
        supplied = header[7:]
        for token, identity in approved:
            if hmac.compare_digest(supplied.encode("utf-8"), token.encode("utf-8")):
                return identity
        raise BackendError(ErrorCode.authentication_required)

    return resolve
