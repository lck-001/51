"""Actual loopback TCP tests, with synthetic resolver injection explicitly marked.

These prove routing and tested authorization decisions, not production identity
verification, PostgreSQL transactions or an external Agent integration.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener


class LoopbackServer:
    def __init__(self, directory, deny=False):
        self.directory = Path(directory)
        self.info = self.directory / "server-info.json"
        self.info.unlink(missing_ok=True)
        self.log = self.directory / "server.log"
        self.output = self.log.open("ab")
        arguments = [sys.executable, str(Path(__file__).with_name("http_validation_server.py")),
                     "--directory", str(self.directory)]
        if deny:
            arguments.append("--deny-by-default")
        self.process = subprocess.Popen(arguments, stdout=self.output, stderr=self.output,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        self.opener = build_opener(ProxyHandler({}))
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError("synthetic loopback server exited before readiness")
                if self.info.is_file():
                    try:
                        info = json.loads(self.info.read_text(encoding="utf-8"))
                        if info["pid"] != self.process.pid:
                            raise RuntimeError("loopback server identity mismatch")
                        self.base = f'http://127.0.0.1:{info["port"]}'
                        status, _ = self.request("GET", "/v1/drafts", token=None)
                        if status == 401:
                            return
                    except (URLError, ConnectionError, TimeoutError, json.JSONDecodeError):
                        pass
                time.sleep(.05)
            raise RuntimeError("synthetic loopback server readiness timeout")
        except BaseException:
            self.close()
            raise

    def request(self, method, path, body=None, token="synthetic-a-full", extra_headers=None):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        if extra_headers:
            headers.update(extra_headers)
        req = Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=5) as result:
                return result.status, json.loads(result.read().decode("utf-8"))
        except HTTPError as result:
            data = result.read().decode("utf-8")
            try:
                data = json.loads(data)
            except json.JSONDecodeError:
                pass
            return result.code, data

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.output.close()


class HTTPIntakeLoopbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="shiyu-http-qa-")
        try:
            cls.server = LoopbackServer(cls.temporary.name)
        except BaseException:
            cls.temporary.cleanup()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.server.close()
        cls.temporary.cleanup()

    def body(self, suffix="", **changes):
        result = {"delivery_id": self._testMethodName + suffix,
                  "source_key": self._testMethodName,
                  "title": "合成 HTTP 材料", "text": "自造纸船故事。\nSynthetic story.",
                  "source_revision": "r1"}
        result.update(changes)
        return result

    def receive(self, body=None, token="synthetic-a-full"):
        status, receipt = self.server.request("POST", "/v1/material-deliveries", body or self.body(), token)
        self.assertEqual(status, 201)
        return receipt

    def test_default_application_denies_even_forged_owner_headers(self):
        with tempfile.TemporaryDirectory(prefix="shiyu-http-deny-qa-") as directory:
            server = LoopbackServer(directory, deny=True)
            try:
                status, error = server.request("POST", "/v1/material-deliveries", self.body(),
                    extra_headers={"X-Owner-Id": "synthetic-owner-a", "X-Scopes": "materials:receive"})
                self.assertEqual((status, error), (401, {"error": "authentication_required"}))
            finally:
                server.close()

    def test_missing_or_unknown_synthetic_bearer_is_unauthorized(self):
        for token in (None, "not-in-the-synthetic-fixture-map"):
            status, result = self.server.request("POST", "/v1/material-deliveries", self.body(), token)
            self.assertEqual((status, result), (401, {"error": "authentication_required"}))

    def test_valid_delivery_replay_scope_and_cross_owner_routes(self):
        first = self.receive(token="synthetic-a-receive")
        again = self.receive(token="synthetic-a-receive")
        self.assertTrue(again["replayed"])
        self.assertEqual(first["receipt_id"], again["receipt_id"])
        path = '/v1/drafts/' + first["draft_id"]
        self.assertEqual(self.server.request("GET", path, token="synthetic-a-receive")[0], 403)
        self.assertEqual(self.server.request("GET", path, token="synthetic-b-full")[0], 404)
        status, draft = self.server.request("GET", path)
        self.assertEqual(status, 200)
        self.assertEqual((draft["state"], draft["owner_id"]), ("draft", "synthetic-owner-a"))

    def test_body_owner_scopes_generate_share_are_forbidden_extra_fields(self):
        for field, value in (("owner_id", "synthetic-owner-b"), ("scopes", ["materials:confirm"]),
                             ("generate", True), ("share", True)):
            body = self.body(**{field: value})
            status, error = self.server.request("POST", "/v1/material-deliveries", body)
            self.assertEqual((status, error), (422, {"error": "invalid_input"}))
        valid = self.receive()
        self.assertFalse(valid["replayed"], "invalid bodies must not have persisted a hidden draft")

    def test_same_delivery_changed_payload_returns_conflict_and_original_stays(self):
        first = self.receive()
        status, error = self.server.request("POST", "/v1/material-deliveries", self.body(text="Conflicting synthetic text"))
        self.assertEqual((status, error), (409, {"error": "delivery_conflict"}))
        _, draft = self.server.request("GET", '/v1/drafts/' + first["draft_id"])
        self.assertEqual(draft["text"], self.body()["text"])

    def test_pending_update_does_not_overwrite_confirmed_version_over_http(self):
        first = self.receive()
        status, version = self.server.request("POST", '/v1/drafts/' + first["draft_id"] + '/confirm', {"expected_revision": 1})
        self.assertEqual(status, 200)
        pending = self.receive(self.body("-update", source_revision="r2", text="Pending synthetic content"))
        self.assertEqual((pending["status"], pending["material_id"]), ("update_pending", first["material_id"]))
        status, old = self.server.request("GET", '/v1/versions/' + version["version_id"])
        self.assertEqual((status, old["text"]), (200, self.body()["text"]))
        status, error = self.server.request("GET", '/v1/versions/' + version["version_id"], token="synthetic-b-full")
        self.assertEqual((status, error), (404, {"error": "not_found"}))

    def test_patch_expected_revision_and_immutable_version_http_routes(self):
        first = self.receive()
        path = '/v1/drafts/' + first["draft_id"]
        status, old = self.server.request("POST", path + '/confirm', {"expected_revision": 1})
        self.assertEqual(status, 200)
        self.assertEqual(self.server.request("PATCH", path, {"expected_revision": 1, "text": "Edited synthetic content"})[0], 200)
        status, error = self.server.request("PATCH", path, {"expected_revision": 1, "text": "Stale"})
        self.assertEqual((status, error), (409, {"error": "revision_conflict"}))
        self.assertEqual(self.server.request("POST", path + '/confirm', {"expected_revision": True})[0], 422)
        _, version = self.server.request("GET", '/v1/versions/' + old["version_id"])
        self.assertEqual(version["text"], self.body()["text"])

    def test_http_server_process_restart_preserves_receipt_idempotency(self):
        first = self.receive()
        self.server.close()
        type(self).server = LoopbackServer(self.temporary.name)
        second = self.receive()
        self.assertTrue(second["replayed"])
        self.assertEqual((first["receipt_id"], first["draft_id"]), (second["receipt_id"], second["draft_id"]))

    def test_invalid_private_input_is_not_reflected_or_logged(self):
        marker = "SYNTHETIC_HTTP_PRIVATE_BODY_SECRET_73ac"
        status, error = self.server.request("POST", "/v1/material-deliveries", self.body(text={"secret": marker}))
        self.assertEqual((status, error), (422, {"error": "invalid_input"}))
        self.assertNotIn(marker, json.dumps(error))
        self.receive(self.body(text=marker))
        status, error = self.server.request("POST", "/v1/material-deliveries", self.body(text=marker + "changed"))
        self.assertEqual(status, 409)
        self.assertNotIn(marker, json.dumps(error))
        self.assertNotIn(marker, self.server.log.read_text(encoding="utf-8", errors="replace"))
        self.assertNotIn("synthetic-a-full", self.server.log.read_text(encoding="utf-8", errors="replace"))

    def test_text_limit_and_raw_body_limit_do_not_silently_accept_data(self):
        self.assertEqual(self.server.request("POST", "/v1/material-deliveries", self.body(text="x" * 5000))[0], 422)
        status, error = self.server.request("POST", "/v1/material-deliveries", self.body(text="x" * 60000))
        self.assertEqual((status, error), (413, {"error": "request_too_large"}))
        self.assertFalse(self.receive()["replayed"])


if __name__ == "__main__":
    unittest.main()
