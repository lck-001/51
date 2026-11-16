# Shiyu restricted intake/material slice (M16)

Actual domain service, transactional repository seam and limited HTTP facade.
This packet only receives **text** into private drafts and confirms immutable
material snapshots. It does not translate, create learning content, generate
audio, score speech, publish, call providers, manage production identity or
start a network listener on import.

## Identity and permissions

`TrustedCaller(owner_id, integration_id, scopes)` must come from an already
verified **server-side** authentication Adapter. The dataclass is not a verifier
and cannot be accepted from a request body or arbitrary owner header. The domain
Service requires these independent scopes:

| Scope | Method |
| --- | --- |
| `materials:receive` | `receive(caller, ReceiveMaterial(...))` |
| `materials:read` | `read_draft`, `list_drafts`, `read_version`, `list_versions` |
| `materials:write` | `update_draft(..., expected_revision, title=..., text=...)` |
| `materials:confirm` | `confirm_draft(..., expected_revision)` |

Receive-only access cannot read/confirm/edit existing content. There are no
generation, sharing or source-reading tools in this slice. All repository
queries bind owner from the trusted caller, never from submitted material fields.
An owner may read their space with a read grant; integration identity namespaces
source/delivery IDs, not an additional owner account.

## Persistence and states

- A new `(owner, integration, source_key)` creates one material and a private
  draft (`state=draft`, edit revision 1). Receipt has opaque IDs/status only.
- `(owner, integration, delivery_id)` is persistent and unique. Same payload
  returns the original receipt IDs with `replayed=true`; changed payload returns
  `delivery_conflict` (HTTP409), not a new draft.
- A new delivery for an existing source creates a **different** draft ID in
  `update_pending`, linked to the same material. It never overwrites the original
  or previously confirmed snapshot. Distinct delivery IDs may still create
  identical pending proposals; cross-delivery content deduplication is not claimed.
- Draft edits require `expected_revision`; they increment edit revision and
  preserve `original_text`. Editing a confirmed draft reopens it as `draft`.
- Confirmation requires the current edit revision and appends an immutable
  version. Confirming the same draft revision is idempotent. Old versions remain
  unchanged after later edits or source updates; confirmation is **not** a
  generated/learning-ready result.
- Owner/resource mismatch returns not-found, without revealing another owner's
  content or existence. Public errors carry stable codes, not SQL/DSN/path/input.

Every operation is one repository transaction. The repository is a trusted
persistence seam, not an authentication entry point; use `IntakeService` for
authorization and validation. Domain limits bound UTF-8 input sizes; no macro,
file, webpage, media or structured-document parser is added.

## PostgreSQL authority: implementation source, not yet runtime verified

`src/shiyu_backend/postgres.py` uses optional psycopg3; construction does not
connect. `migrations/0001_intake_materials.sql` is the reviewed migration SOURCE,
to be applied once through migration tooling, not by each API-worker startup.
The local environment has no psycopg runtime/approved PostgreSQL instance for
this packet, so no migration, PG transaction, RLS, capacity or concurrency pass
is claimed. No company database, Docker daemon or production resource was used.

PostgreSQL operations use transaction-scoped stable advisory locks for delivery
and source namespaces plus material/draft row locks for sequential version
numbers. Unique constraints back persistent idempotency and version numbering;
values are parameterized. Lock order is material then draft for confirmation.
The schema check fails closed on missing/unsupported migration version.
Explicit DB roles/RLS, OIDC, deployment, connection pooling, backups, distributed
budget, blobs and actual providers remain separate reviewed implementation work.
Application-level immutable versions are not a claim that a privileged DB admin
is physically unable to change rows.

## Validation-only real SQLite

`SQLiteValidationRepository(path)` uses real temporary file storage, foreign-key
constraints and `BEGIN IMMEDIATE` for local writes. It creates an empty validation
schema using the common SQL migration; a foreign or corrupt existing database is
not dropped/reset into a healthy empty store. Each operation opens/closes its own
connection. `close()` rejects later operations on that instance; a new instance
can reopen the same file. No `:memory:` backend is used for persistence evidence.

SQLite is expressly **not** a replacement for the planned PostgreSQL production
authority. Its global local writer lock, transaction behavior and temporary
synthetic identity tests do not prove PG locks, real authentication, multi-node
isolation, disaster recovery, no data loss or cross-platform client acceptance.
Tests must use their own temporary directories and synthetic content only.

## HTTP facade: available local runtime, no new installation

`create_app(repository, caller_resolver=None)` in `shiyu_backend.http_api` denies
every material route without a supplied trusted identity resolver. Request bodies
forbid extra fields such as `owner_id`/`scopes`; validation errors do not echo
Pydantic's private input. JSON bodies are bounded before parsing. Responses are
authorized content or minimal receipts; there is no request/SQL/content logging.

`validation_token_resolver({synthetic_token: TrustedCaller(...)})` is only an
explicit in-memory synthetic fixture. It is **not production auth**, token
issuance, a saved credential or permission to expose this application publicly.
Do not store real tokens in fixtures, command lines, logs, documentation or Git.
All actual HTTP validation must bind only `127.0.0.1` with access logging disabled,
use an ephemeral test port, and stop the child server after checks. No default
server startup or public listener is provided.

| HTTP route | Operation |
| --- | --- |
| `POST /v1/material-deliveries` | Receive, 201 with receipt/replay indicator |
| `GET /v1/drafts` / `GET /v1/drafts/{draft_id}` | Owner-private reads |
| `PATCH /v1/drafts/{draft_id}` | Expected-revision draft edit |
| `POST /v1/drafts/{draft_id}/confirm` | Expected-revision immutable confirmation |
| `GET /v1/versions/{version_id}` | Private immutable snapshot |
| `GET /v1/materials/{material_id}/versions` | Private version list |

`requirements-http.txt` pins the runtime already available for this packet:
FastAPI0.122.0, Uvicorn0.38.0, Pydantic2.12.5, Starlette0.50.0. This is a runtime
snapshot, not a claim of latest-security-version or fully locked transitive build.
The independent test harness uses the already available httpx0.28.1. No install
or dependency upgrade was performed.

## Run background synthetic checks

Set `PYTHONPATH` to this directory's `src` for module/tests. Use the existing
Python runtime; no global environment change is required. Independent tests live
in `tests/`; their executed results must be recorded separately, distinguishing
domain/SQLite, in-process ASGI, actual localhost HTTP, and unexecuted PostgreSQL.

Current stage: restricted intake/material implementation. Next: connect approved
learning-version/media contracts and real provider validation, not fabricated
translations/scores. No UI, actual Agent account integration or release is claimed.
