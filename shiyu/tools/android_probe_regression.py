"""Finite UI regression on one existing emulator; never installs or captures.

Requires preinstalled probe and synthetic files in Downloads/ShiyuLab_M14.
Only app/SAF UI is operated. No permission grants, media upload, or raw logs.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass

PACKAGE = "com.shiyu.probe.shiyu_media_probe"
IMPORT = "导入本地文件"
HEADING = "媒体能力验证 · 素材保存在本机"
READY = (IMPORT, "开始录音", "开启相机预览（请求相机/麦克风）")


class Failure(Exception):
    """A public, non-sensitive failure code."""


@dataclass
class Tree:
    root: ET.Element
    parents: dict

    @classmethod
    def parse(cls, raw: str) -> "Tree":
        start = raw.find("<?xml")
        if start < 0:
            start = raw.find("<hierarchy")
        end = raw.rfind("</hierarchy>")
        if start < 0 or end < 0:
            raise Failure("ui_dump_missing_xml")
        try:
            root = ET.fromstring(raw[start:end + len("</hierarchy>")])
        except ET.ParseError:
            raise Failure("ui_dump_invalid_xml") from None
        return cls(root, {child: parent for parent in root.iter() for child in parent})

    def nodes(self):
        return list(self.root.iter("node"))

    def exact(self, labels):
        # A filename in a preview description must not beat the exact text label.
        for attr in ("text", "content-desc"):
            for label in labels:
                found = [n for n in self.nodes() if n.get(attr) == label]
                if found:
                    return found
        return []

    def contains(self, value):
        return any(value in n.get(attr, "") for n in self.nodes()
                   for attr in ("text", "content-desc"))

    def package_present(self, package):
        return any(n.get("package") == package for n in self.nodes())

    def picker(self):
        return any(n.get("package", "").endswith(".documentsui") for n in self.nodes())

    @staticmethod
    def bounds(node):
        match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if not match:
            raise Failure("ui_bounds_missing")
        return tuple(map(int, match.groups()))

    def viewport(self):
        boxes = [self.bounds(n) for n in self.nodes() if n.get("bounds")]
        if not boxes:
            raise Failure("ui_empty")
        width, height = max(b[2] for b in boxes), max(b[3] for b in boxes)
        bottom = height
        for n in self.nodes():
            if n.get("package") == "com.android.systemui" and n.get("bounds"):
                x1, y1, x2, y2 = self.bounds(n)
                if y1 > height * .75 and y2 > y1:
                    bottom = min(bottom, y1)
        # Keep a small margin even when the navigation bar is absent from XML.
        return 0, 0, width, min(bottom, height - max(8, int(height * .025)))

    def action(self, node):
        original = node
        while node.get("clickable") != "true":
            node = self.parents.get(node)
            if node is None or node.tag != "node":
                raise Failure("ui_target_not_clickable")
        if node.get("enabled") != "true" or original.get("enabled") == "false":
            raise Failure("ui_target_disabled")
        box, label_box = self.bounds(node), self.bounds(original)
        left, top, right, bottom = self.viewport()
        # Require the whole exact label and actionable cell to be above system UI.
        for b in (box, label_box):
            if not (left <= b[0] < b[2] <= right and top <= b[1] < b[3] <= bottom):
                raise Failure("ui_target_clipped")
        parent = self.parents.get(original)
        while parent is not None and parent.tag == "node":
            if parent.get("scrollable") == "true":
                p = self.bounds(parent)
                if not (p[0] <= label_box[0] and p[1] <= label_box[1]
                        and label_box[2] <= p[2] and label_box[3] <= p[3]):
                    raise Failure("ui_target_clipped")
            parent = self.parents.get(parent)
        if box[3] - box[1] > (bottom - top) * .7:
            raise Failure("ui_target_overbroad")
        return box

    def fully_visible(self, node):
        """Visibility check for static labels too; does not imply clickability."""
        box = self.bounds(node)
        left, top, right, bottom = self.viewport()
        if not (left <= box[0] < box[2] <= right and top <= box[1] < box[3] <= bottom):
            return False
        parent = self.parents.get(node)
        while parent is not None and parent.tag == "node":
            if parent.get("scrollable") == "true":
                p = self.bounds(parent)
                if not (p[0] <= box[0] and p[1] <= box[1]
                        and box[2] <= p[2] and box[3] <= p[3]):
                    return False
            parent = self.parents.get(parent)
        return True

    def rows(self):
        rows = {}
        for node in self.nodes():
            if node.get("clickable") != "true":
                continue
            for attr in ("text", "content-desc"):
                label = node.get(attr, "")
                if "/media_probe/" in label:
                    rows[label] = node
                    break
        return rows


class Probe:
    def __init__(self, adb, port, serial, timeout=15):
        if not 1024 <= port <= 65535 or port == 5037:
            raise Failure("private_nondefault_adb_port_required")
        if not re.fullmatch(r"emulator-\d+", serial):
            raise Failure("explicit_emulator_serial_required")
        self.prefix = [adb, "-P", str(port), "-s", serial]
        self.timeout = timeout
        self.env = os.environ.copy()
        for key in ("ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_PORT", "ANDROID_SERIAL", "ADB_SERVER_PORT"):
            self.env.pop(key, None)

    def adb(self, *args, timeout=20):
        try:
            run = subprocess.run(self.prefix + list(args), env=self.env, capture_output=True,
                                 text=True, encoding="utf-8", errors="replace", timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failure("adb_command_timeout") from None
        except OSError:
            raise Failure("adb_unavailable") from None
        if run.returncode:
            raise Failure("adb_command_failed")
        return run.stdout

    def preflight(self):
        if self.adb("shell", "getprop", "ro.kernel.qemu").strip() != "1":
            raise Failure("target_not_confirmed_emulator")
        if not self.adb("shell", "pm", "path", PACKAGE).strip().startswith("package:"):
            raise Failure("probe_not_installed")

    def tree(self):
        # UIAutomator can return no XML while foreground/idle detection settles.
        # Retry only that tooling condition; malformed XML, ADB errors and real
        # UI assertions remain failures. At most three retries after first try.
        for attempt in range(4):
            try:
                return Tree.parse(self.adb("exec-out", "uiautomator", "dump", "/dev/tty"))
            except Failure as exc:
                if str(exc) != "ui_dump_missing_xml" or attempt == 3:
                    raise
                time.sleep(.3)

    def wait(self, predicate, code):
        deadline = time.monotonic() + self.timeout
        while True:
            tree = self.tree()
            if predicate(tree):
                return tree
            if time.monotonic() >= deadline:
                raise Failure(code)
            time.sleep(.25)

    def scroll(self, tree, up=False):
        candidates = [n for n in tree.nodes() if n.get("scrollable") == "true"
                      and n.get("package") != "com.android.systemui"]
        if not candidates:
            raise Failure("scrollable_content_not_found")
        candidates.sort(key=lambda n: (Tree.bounds(n)[2] - Tree.bounds(n)[0]) *
                        (Tree.bounds(n)[3] - Tree.bounds(n)[1]), reverse=True)
        x1, y1, x2, y2 = tree.bounds(candidates[0])
        safe = tree.viewport()
        y1, y2 = max(y1, safe[1]), min(y2, safe[3])
        if y2 - y1 < 80:
            raise Failure("scrollable_content_too_small")
        x, a, b = (x1 + x2) // 2, int(y1 + (y2-y1)*.78), int(y1 + (y2-y1)*.28)
        self.adb("shell", "input", "swipe", str(x), str(b if up else a),
                 str(x), str(a if up else b), "350")

    def click(self, labels, *, scroll=False):
        for attempt in range(5 if scroll else 1):
            tree = self.tree()
            found = tree.exact(labels)
            if len(found) > 1:
                raise Failure("ui_target_ambiguous")
            if found:
                try:
                    x1, y1, x2, y2 = tree.action(found[0])
                except Failure as exc:
                    if str(exc) != "ui_target_clipped" or not scroll:
                        raise
                else:
                    self.adb("shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2))
                    return
            elif not scroll:
                raise Failure("ui_exact_target_missing")
            if attempt < 4 and scroll:
                self.scroll(tree)
        raise Failure("ui_exact_target_not_visible")

    def top(self):
        for _ in range(5):
            tree = self.tree()
            heading, button = tree.exact((HEADING,)), tree.exact((IMPORT,))
            # IMPORT alone can remain visible while the status above it is
            # scrolled offscreen. Require the static heading as a top anchor.
            # Disabled controls remain visible: readiness is asserted separately.
            if (tree.package_present(PACKAGE) and not tree.picker()
                    and len(heading) == len(button) == 1
                    and tree.fully_visible(heading[0]) and tree.fully_visible(button[0])):
                return tree
            self.scroll(tree, up=True)
        raise Failure("app_controls_not_visible")

    def ready(self):
        def usable(tree):
            if not tree.package_present(PACKAGE) or tree.picker():
                return False
            for label in READY:
                found = tree.exact((label,))
                if len(found) != 1:
                    return False
                try:
                    tree.action(found[0])
                except Failure:
                    return False
            return True
        self.top()
        return self.wait(usable, "app_buttons_not_ready")

    def launch(self):
        result = self.adb("shell", "am", "start", "-W", "-n", PACKAGE + "/.MainActivity")
        if "Error:" in result or "Exception" in result:
            raise Failure("app_launch_failed")
        self.wait(lambda t: t.package_present(PACKAGE) and not t.picker(), "app_not_visible")
        self.ready()

    def picker(self):
        self.ready()
        self.click((IMPORT,))
        return self.wait(lambda t: t.picker(), "saf_not_opened")

    def choose(self, name, folder):
        tree = self.picker()
        if not tree.exact((name,)) and not tree.exact((folder,)):
            self.click(("Show roots", "显示根目录", "Open navigation drawer", "打开导航抽屉"))
            self.wait(lambda t: bool(t.exact(("Downloads", "下载"))), "downloads_root_missing")
            self.click(("Downloads", "下载"))
        tree = self.wait(lambda t: t.picker(), "saf_lost")
        if not tree.exact((name,)):
            self.click((folder,), scroll=True)
        self.click((name,), scroll=True)
        self.wait(lambda t: t.package_present(PACKAGE) and not t.picker(), "saf_did_not_return")

    def all_rows(self):
        self.top()
        rows = set()
        previous = None
        for _ in range(8):
            tree = self.tree()
            rows.update(tree.rows())
            signature = ET.tostring(tree.root, encoding="unicode")
            if signature == previous:
                break
            previous = signature
            try:
                self.scroll(tree)
            except Failure as exc:
                if str(exc) == "scrollable_content_not_found":
                    break
                raise
        else:
            raise Failure("file_list_exceeds_bounded_scan")
        self.top()
        return rows

    def import_case(self, name, folder, empty=False):
        before = self.all_rows()
        self.choose(name, folder)
        self.top()
        expected = "媒体文件不存在或为空；未记作成功。" if empty else "导入完成：" + name
        self.wait(lambda t: t.contains(expected), "import_outcome_missing")
        self.ready()
        after = self.all_rows()
        new = after - before
        if empty:
            if after != before:
                raise Failure("empty_file_changed_list")
            return None
        if not before.issubset(after) or len(new) != 1:
            raise Failure("import_list_delta_not_one")
        return next(iter(new))

    def cancel_case(self):
        before = self.all_rows()
        self.picker()
        for _ in range(4):
            tree = self.tree()
            if not tree.picker():
                break
            self.adb("shell", "input", "keyevent", "KEYCODE_BACK")
        self.wait(lambda t: t.package_present(PACKAGE) and not t.picker(), "saf_did_not_return")
        self.top()
        self.wait(lambda t: t.contains("已取消选文件。") and not t.picker(), "true_cancel_not_confirmed")
        self.ready()
        if self.all_rows() != before:
            raise Failure("cancel_changed_list")

    def decode_error(self, row):
        # Match the exact new copied-file row, never the status or a generic icon.
        self.click((row,), scroll=True)
        self.top()
        self.wait(lambda t: t.contains("播放错误："), "damaged_media_error_not_reported")
        self.ready()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--folder", default="ShiyuLab_M14")
    parser.add_argument("--mp4", default="playback-video-12s.mp4")
    parser.add_argument("--zero", default="zero-byte.wav")
    parser.add_argument("--damaged", default="invalid-media.wav")
    args = parser.parse_args()
    results = []
    step = "preflight"
    try:
        for value in (args.folder, args.mp4, args.zero, args.damaged):
            if not value or any(c in value for c in "/\\\r\n"):
                raise Failure("fixture_basename_required")
        probe = Probe(args.adb, args.port, args.serial)
        probe.preflight()
        results.append({"case": step, "status": "passed"})
        print(json.dumps({"event": "case_complete", **results[-1]}, ensure_ascii=False), flush=True)
        cases = [("launch_and_ready", probe.launch),
                 ("saf_valid_mp4", lambda: probe.import_case(args.mp4, args.folder)),
                 ("saf_true_cancel", probe.cancel_case),
                 ("saf_zero_file", lambda: probe.import_case(args.zero, args.folder, empty=True)),
                 ("saf_damaged_wav", lambda: probe.decode_error(
                     probe.import_case(args.damaged, args.folder))),
                 ("saf_recovery_mp4", lambda: probe.import_case(args.mp4, args.folder))]
        for step, action in cases:
            action()
            results.append({"case": step, "status": "passed"})
            print(json.dumps({"event": "case_complete", **results[-1]}, ensure_ascii=False), flush=True)
    except Failure as exc:
        results.append({"case": step, "status": "failed", "reason": str(exc)})
        print(json.dumps({"scope": "emulator_saf_ui_only", "results": results,
                          "video_playback_verified": False}, ensure_ascii=False), flush=True)
        return 1
    except Exception:
        # Do not print subprocess output, paths, XML, file-row text or traceback.
        results.append({"case": step, "status": "failed", "reason": "unexpected_local_error"})
        print(json.dumps({"scope": "emulator_saf_ui_only", "results": results}, ensure_ascii=False), flush=True)
        return 1
    print(json.dumps({"scope": "emulator_saf_ui_only", "results": results,
                      "video_playback_verified": False, "native_crash_regression_verified": False},
                     ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
