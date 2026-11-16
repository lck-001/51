-- PostgreSQL migration SOURCE. Apply once through reviewed migration tooling,
-- never on every API-worker startup. No database is contacted by this file.
BEGIN;
CREATE TABLE shiyu_backend_schema (version INTEGER PRIMARY KEY CHECK (version = 1));
INSERT INTO shiyu_backend_schema (version) VALUES (1);
CREATE TABLE shiyu_materials (
    material_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    integration_id TEXT NOT NULL,
    source_key TEXT NOT NULL,
    latest_version_no INTEGER NOT NULL DEFAULT 0 CHECK (latest_version_no >= 0),
    created_at TEXT NOT NULL,
    UNIQUE (owner_id, integration_id, source_key),
    UNIQUE (owner_id, material_id)
);
CREATE TABLE shiyu_drafts (
    draft_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    material_id TEXT NOT NULL,
    source_revision TEXT,
    title TEXT NOT NULL,
    content_text TEXT NOT NULL,
    original_text TEXT NOT NULL,
    edit_revision INTEGER NOT NULL CHECK (edit_revision >= 1),
    state TEXT NOT NULL CHECK (state IN ('draft','update_pending','confirmed')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (owner_id,draft_id),
    FOREIGN KEY (owner_id,material_id) REFERENCES shiyu_materials(owner_id,material_id)
);
CREATE TABLE shiyu_receipts (
    receipt_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    integration_id TEXT NOT NULL,
    delivery_id TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    material_id TEXT NOT NULL,
    draft_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('accepted','update_pending')),
    created_at TEXT NOT NULL,
    UNIQUE (owner_id,integration_id,delivery_id),
    FOREIGN KEY (owner_id,material_id) REFERENCES shiyu_materials(owner_id,material_id),
    FOREIGN KEY (owner_id,draft_id) REFERENCES shiyu_drafts(owner_id,draft_id)
);
CREATE TABLE shiyu_versions (
    version_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    material_id TEXT NOT NULL,
    version_number INTEGER NOT NULL CHECK (version_number >= 1),
    draft_id TEXT NOT NULL,
    draft_revision INTEGER NOT NULL CHECK (draft_revision >= 1),
    title TEXT NOT NULL,
    content_text TEXT NOT NULL,
    confirmed_at TEXT NOT NULL,
    UNIQUE (owner_id,material_id,version_number),
    UNIQUE (owner_id,draft_id,draft_revision),
    FOREIGN KEY (owner_id,material_id) REFERENCES shiyu_materials(owner_id,material_id),
    FOREIGN KEY (owner_id,draft_id) REFERENCES shiyu_drafts(owner_id,draft_id)
);
CREATE INDEX shiyu_drafts_owner_created ON shiyu_drafts(owner_id,created_at);
COMMIT;
