"""Task-owned 127.0.0.1 server with explicitly synthetic auth for HTTP QA only."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import uvicorn
from shiyu_backend.http_api import create_app, validation_token_resolver
from shiyu_backend.intake import CONFIRM, READ, RECEIVE, WRITE
from shiyu_backend.models import IntakeLimits, TrustedCaller
from shiyu_backend.sqlite_validation import SQLiteValidationRepository


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--deny-by-default", action="store_true")
    args = parser.parse_args()
    repository = SQLiteValidationRepository(args.directory / "http-validation.sqlite3")
    resolver = None
    if not args.deny_by_default:
        # These are test fixtures, neither production credentials nor a verifier.
        resolver = validation_token_resolver({
            "synthetic-a-full": TrustedCaller("synthetic-owner-a", "synthetic-http-agent", frozenset({RECEIVE, READ, WRITE, CONFIRM})),
            "synthetic-a-receive": TrustedCaller("synthetic-owner-a", "synthetic-http-agent", frozenset({RECEIVE})),
            "synthetic-b-full": TrustedCaller("synthetic-owner-b", "synthetic-http-agent", frozenset({RECEIVE, READ, WRITE, CONFIRM})),
        })
    app = create_app(repository, caller_resolver=resolver, limits=IntakeLimits(max_text_bytes=4096))
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.bind(("127.0.0.1", 0))
        listener.listen(32)
        port = listener.getsockname()[1]
        (args.directory / "server-info.json").write_text(json.dumps({"port": port, "pid": os.getpid()}), encoding="utf-8")
        server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, access_log=False, log_level="warning"))
        server.run(sockets=[listener])
    finally:
        listener.close()
        repository.close()


if __name__ == "__main__":
    main()
