#!/usr/bin/env python3
"""
Open a visible browser, let the user sign in to QuickBI, and save Playwright
storage state for later headless capture runs.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright


DEFAULT_LOGIN_URL = "https://bi.aliyun.com/"
DEFAULT_STATE_FILE = "quickbi_state.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Save QuickBI browser login state")
    parser.add_argument(
        "--storage-state",
        default=DEFAULT_STATE_FILE,
        help=f"Path to save storage state, default: {DEFAULT_STATE_FILE}",
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_LOGIN_URL,
        help=f"URL to open for login, default: {DEFAULT_LOGIN_URL}",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Maximum seconds to wait for manual login, default: 300",
    )
    return parser.parse_args()


def looks_logged_in(page) -> bool:
    url = page.url.lower()
    if "login" in url or "passport" in url or "signin" in url:
        return False

    marker_script = """
    () => {
      const text = document.body ? document.body.innerText : "";
      const hasLoginText = /登录|验证码|密码|账户|扫码登录/.test(text);
      const hasQuickBi = /Quick\\s*BI|工作台|仪表板|数据门户|看板/.test(text);
      return hasQuickBi && !hasLoginText;
    }
    """
    try:
        return bool(page.evaluate(marker_script))
    except Exception:
        return False


def main() -> int:
    args = parse_args()
    state_path = Path(args.storage_state).resolve()
    state_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Opening browser for QuickBI login: {args.url}", flush=True)
    print(f"Storage state will be saved to: {state_path}", flush=True)
    print("Complete login in the opened browser. This script will wait.", flush=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        context = browser.new_context()
        page = context.new_page()
        page.goto(args.url, wait_until="domcontentloaded", timeout=60_000)

        deadline_ms = args.timeout * 1000
        try:
            page.wait_for_function(
                """
                () => {
                  const url = location.href.toLowerCase();
                  if (url.includes("login") || url.includes("passport") || url.includes("signin")) {
                    return false;
                  }
                  const text = document.body ? document.body.innerText : "";
                  const hasLoginText = /登录|验证码|密码|账户|扫码登录/.test(text);
                  const hasQuickBi = /Quick\\s*BI|工作台|仪表板|数据门户|看板/.test(text);
                  return hasQuickBi && !hasLoginText;
                }
                """,
                timeout=deadline_ms,
            )
        except PlaywrightTimeoutError:
            print("Timed out waiting for a logged-in QuickBI page.", file=sys.stderr)
            print("If login succeeded but detection failed, rerun with a QuickBI dashboard URL via --url.", file=sys.stderr)
            browser.close()
            return 2

        if not looks_logged_in(page):
            print("Could not confirm QuickBI login state.", file=sys.stderr)
            browser.close()
            return 2

        context.storage_state(path=str(state_path))
        browser.close()

    print(f"Saved QuickBI login state: {state_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
