#!/usr/bin/env python3
"""
QuickBI 一体化脚本。

只读取当前目录 quickbi_config.json：
1. 使用 quickbi_state.json 登录态打开看板并抓取 olapQueryParam。
2. 使用同一登录态转换出的 cookie 调 QuickBI 接口获取 SQL。
3. 输出组件 SQL 到 quickbi_sql_result.json。
"""

from __future__ import annotations

import json
import re
import sys
import time
import uuid
from dataclasses import dataclass
from json import JSONDecodeError
from pathlib import Path
from typing import Any
from urllib import error, parse, request
from urllib.parse import parse_qs, quote, unquote

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright


BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "quickbi_config.json"
QUICKBI_BASE_URL = "https://bi.aliyun.com"
COOKIE_VALUE_SAFE_CHARS = "!#$%&'()*+-./:<=>?@[]^_`{|}~"


@dataclass(slots=True)
class Config:
    workspace_id: str
    page_id: str
    storage_state: Path
    olap_params_file: Path
    result_file: Path
    poll_attempts: int = 90
    poll_interval_seconds: float = 1.0
    wait_after_load_seconds: float = 20.0
    tab_wait_seconds: float = 5.0


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except JSONDecodeError as exc:
        raise RuntimeError(f"JSON 格式错误: {path}") from exc


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def resolve_local_path(value: str) -> Path:
    path = Path(value)
    if path.is_absolute():
        raise ValueError(f"配置文件路径必须是当前目录下的相对路径: {value}")
    resolved = (BASE_DIR / path).resolve()
    if BASE_DIR not in resolved.parents and resolved != BASE_DIR:
        raise ValueError(f"配置文件路径不能跳出当前目录: {value}")
    return resolved


def load_config() -> Config:
    payload = read_json(CONFIG_FILE)
    if not isinstance(payload, dict):
        raise ValueError("quickbi_config.json 必须是 JSON object")

    workspace_id = str(payload.get("workspace_id") or "").strip()
    page_id = str(payload.get("page_id") or "").strip()
    if not workspace_id or not page_id:
        raise ValueError("quickbi_config.json 必须配置 workspace_id 和 page_id")

    return Config(
        workspace_id=workspace_id,
        page_id=page_id,
        storage_state=resolve_local_path(str(payload.get("storage_state") or "quickbi_state.json")),
        olap_params_file=resolve_local_path(str(payload.get("olap_params_file") or "olap_query_params.json")),
        result_file=resolve_local_path(str(payload.get("result_file") or "quickbi_sql_result.json")),
        poll_attempts=int(payload.get("poll_attempts", 90)),
        poll_interval_seconds=float(payload.get("poll_interval_seconds", 1.0)),
        wait_after_load_seconds=float(payload.get("wait_after_load_seconds", 20)),
        tab_wait_seconds=float(payload.get("tab_wait_seconds", 5)),
    )


# ------------------------- 登录态与请求头 -------------------------


def cookie_domain_matches(domain: str, host: str) -> bool:
    normalized_domain = domain.lstrip(".").lower()
    normalized_host = host.lower()
    return normalized_domain == normalized_host or normalized_host.endswith(f".{normalized_domain}")


def cookie_header_from_storage_state(state_path: Path, host: str = "bi.aliyun.com") -> str:
    payload = read_json(state_path)
    cookies = payload.get("cookies") if isinstance(payload, dict) else None
    if not isinstance(cookies, list):
        raise RuntimeError(f"登录态文件缺少 cookies: {state_path}")

    pairs: list[str] = []
    seen: set[str] = set()
    for cookie in cookies:
        if not isinstance(cookie, dict):
            continue
        name = str(cookie.get("name") or "").strip()
        value = str(cookie.get("value") or "")
        domain = str(cookie.get("domain") or "")
        if not name or not cookie_domain_matches(domain, host) or name in seen:
            continue
        seen.add(name)
        pairs.append(f"{name}={quote(value, safe=COOKIE_VALUE_SAFE_CHARS)}")

    if not pairs:
        raise RuntimeError("登录态中没有 bi.aliyun.com 可用 cookie，请先运行 quickbi_login.py")
    return "; ".join(pairs)


def extract_csrf_token(cookie: str) -> str:
    match = re.search(r"(?:^|;\s*)csrf_token=([^;]+)", cookie)
    if not match:
        raise RuntimeError("cookie 中没有 csrf_token，请重新登录")
    return match.group(1)


def build_headers(config: Config, cookie: str, *, form_post: bool = False) -> dict[str, str]:
    referer = (
        f"{QUICKBI_BASE_URL}/dashboard/pc.htm?"
        f"workspaceId={config.workspace_id}&pageId={config.page_id}"
    )
    return {
        "accept": "*/*",
        "accept-language": "zh-CN,zh;q=0.9,en;q=0.8",
        "bx-v": "2.5.36",
        "cache-control": "max-age=0",
        "content-type": "application/x-www-form-urlencoded; charset=UTF-8" if form_post else "application/json",
        "cookie": cookie,
        "origin": QUICKBI_BASE_URL,
        "qbi-report-trace-id": str(uuid.uuid4()),
        "referer": referer,
        "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
        "x-csrf-token": extract_csrf_token(cookie),
        "x-gw-referer": referer,
        "x-requested-with": "XMLHttpRequest",
    }


def parse_response_json(raw_body: bytes, charset: str | None) -> dict[str, Any]:
    text = raw_body.decode(charset or "utf-8", errors="replace").lstrip("\ufeff\r\n\t ")
    lowered = text.lower()
    if "<html" in lowered or "aliyun-login" in lowered or "<script" in lowered:
        raise RuntimeError("QuickBI 返回登录页，登录态可能已过期，请重新运行 quickbi_login.py")
    payload = json.loads(text)
    if not isinstance(payload, dict):
        raise RuntimeError(f"QuickBI 返回了非对象 JSON: {type(payload).__name__}")
    if not payload.get("success"):
        raise RuntimeError(f"QuickBI success=false, code={payload.get('code')}, message={payload.get('message')}")
    return payload


def http_request_json(url: str, headers: dict[str, str], data: bytes | None = None) -> dict[str, Any]:
    req = request.Request(url=url, headers=headers, data=data, method="POST" if data is not None else "GET")
    try:
        with request.urlopen(req, timeout=60) as resp:
            return parse_response_json(resp.read(), resp.headers.get_content_charset())
    except error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="ignore")[:500]
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
    except error.URLError as exc:
        raise RuntimeError(f"请求失败: {exc.reason}") from exc


# ------------------------- 抓取 olapQueryParam -------------------------


def dashboard_url(config: Config) -> str:
    return (
        f"{QUICKBI_BASE_URL}/dashboard/pc.htm?"
        f"workspaceId={config.workspace_id}&pageId={config.page_id}"
    )


def parse_olap_postdata(post_data: str | None) -> dict[str, Any] | None:
    if not post_data:
        return None
    try:
        parsed = parse_qs(post_data)
        if "olapQueryParam" in parsed:
            return json.loads(unquote(parsed["olapQueryParam"][0]))
        return json.loads(post_data)
    except (TypeError, ValueError, JSONDecodeError):
        return None


def make_olap_entry(oqp: dict[str, Any], trigger: str, config: Config) -> dict[str, Any]:
    return {
        "workspace_id": oqp.get("workspaceId") or config.workspace_id,
        "page_id": oqp.get("pageId") or config.page_id,
        "component_id": oqp.get("componentId", ""),
        "component_type": oqp.get("componentType") or 66,
        "component_name": oqp.get("componentName", ""),
        "report_id": oqp.get("reportId") or config.page_id,
        "trigger": trigger,
        "olap_query_param": oqp,
    }


def is_login_page(page) -> bool:
    url = page.url.lower()
    if "login" in url or "passport" in url or "signin" in url:
        return True
    try:
        text = page.locator("body").inner_text(timeout=3000)
    except Exception:
        return False
    return "登录" in text and ("密码" in text or "验证码" in text or "扫码" in text)


def switch_to_preview(page) -> str:
    mode = page.evaluate(
        """
        () => {
          const all = Array.from(document.querySelectorAll('button,div,a,span'));
          const buttons = Array.from(document.querySelectorAll('button'));
          if (all.some(el => el.textContent.trim().includes('继续编辑'))) return 'preview';
          if (buttons.some(b => ['预 览', '预览'].includes(b.textContent.trim()))) return 'edit';
          return 'unknown';
        }
        """
    )
    if mode != "edit":
        return mode

    page.evaluate(
        """
        () => {
          const b = Array.from(document.querySelectorAll('button'))
            .find(btn => ['预 览', '预览'].includes(btn.textContent.trim()));
          if (b) b.click();
        }
        """
    )
    page.wait_for_timeout(8000)
    return page.evaluate(
        """
        () => Array.from(document.querySelectorAll('button,div,a,span'))
          .some(el => el.textContent.trim().includes('继续编辑')) ? 'preview' : 'unknown'
        """
    )


def get_tabs(page) -> list[dict[str, Any]]:
    raw = page.evaluate(
        """
        () => JSON.stringify(Array.from(document.querySelectorAll('.story-builder-tab'))
          .map((t, i) => ({idx: i, text: (t.textContent || '').trim().substring(0, 60)})))
        """
    )
    return json.loads(raw) if raw else []


def wait_and_scroll(page, seconds: float) -> None:
    page.wait_for_timeout(int(seconds * 1000))
    for y in range(0, 3001, 500):
        page.evaluate("(value) => window.scrollTo(0, value)", y)
        page.wait_for_timeout(300)


def capture_olap_params(config: Config) -> list[dict[str, Any]]:
    if not config.storage_state.exists():
        raise RuntimeError("缺少 quickbi_state.json，请先运行 quickbi_login.py 完成登录")

    results: list[dict[str, Any]] = []
    seen_component_ids: set[str] = set()
    current_trigger = "initial_load"
    cdp_session = None

    def record_from_postdata(post_data: str | None) -> None:
        oqp = parse_olap_postdata(post_data)
        if not oqp:
            return
        component_id = str(oqp.get("componentId") or "")
        if not component_id or component_id in seen_component_ids:
            return
        seen_component_ids.add(component_id)
        entry = make_olap_entry(oqp, current_trigger, config)
        results.append(entry)
        print(f"  抓到组件: {component_id[:20]} | {entry['component_name']}", flush=True)

    def on_cdp_request(event: dict[str, Any]) -> None:
        req = event.get("request", {})
        url = req.get("url", "")
        if "/api/v2/olap/query" not in url or "queryByPollKey" in url or "queryForMultiEnum" in url:
            return
        post_data = req.get("postData")
        if not post_data and req.get("hasPostData") and cdp_session is not None:
            post_data = cdp_session.send("Network.getRequestPostData", {"requestId": event.get("requestId")}).get("postData")
        record_from_postdata(post_data)

    print("步骤 1/2：打开看板并抓取 olapQueryParam", flush=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(storage_state=str(config.storage_state))
        page = context.new_page()
        cdp_session = context.new_cdp_session(page)
        cdp_session.send("Network.enable")
        cdp_session.on("Network.requestWillBeSent", on_cdp_request)

        try:
            page.goto(dashboard_url(config), wait_until="domcontentloaded", timeout=90000)
        except PlaywrightTimeoutError:
            print("  看板加载超时，继续检查已加载内容", flush=True)

        page.wait_for_timeout(5000)
        if is_login_page(page):
            browser.close()
            raise RuntimeError("登录态已过期，请重新运行 quickbi_login.py")

        wait_and_scroll(page, config.wait_after_load_seconds)
        mode = switch_to_preview(page)
        print(f"  页面模式: {mode}", flush=True)

        tabs = get_tabs(page)
        print(f"  识别 Tab 数: {len(tabs)}", flush=True)
        for tab in tabs:
            current_trigger = f"tab:{tab.get('text', '')[:30]}"
            print(f"  点击 Tab: {tab.get('text')}", flush=True)
            page.evaluate(
                "(idx) => { const tab = document.querySelectorAll('.story-builder-tab')[idx]; if (tab) tab.click(); }",
                tab.get("idx"),
            )
            wait_and_scroll(page, config.tab_wait_seconds)

        browser.close()

    if not results:
        raise RuntimeError("没有抓到 olapQueryParam，请确认看板有权限且页面可正常加载")
    write_json(config.olap_params_file, results)
    print(f"  已保存抓参结果: {config.olap_params_file}", flush=True)
    return results


# ------------------------- 使用 olapQueryParam 获取 SQL -------------------------


def olap_query(item: dict[str, Any], config: Config, cookie: str) -> dict[str, Any]:
    oqp = json.dumps(item["olap_query_param"], ensure_ascii=False, separators=(",", ":"))
    body = parse.urlencode(
        {
            "olapQueryParam": oqp,
            "componentId": item["component_id"],
            "reportId": item.get("report_id") or config.page_id,
            "componentType": str(item.get("component_type") or 66),
        }
    ).encode("utf-8")
    return http_request_json(
        f"{QUICKBI_BASE_URL}/api/v2/olap/query",
        build_headers(config, cookie, form_post=True),
        data=body,
    )


def query_by_pollkey(component_id: str, poll_key: str, config: Config, cookie: str) -> dict[str, Any]:
    query = parse.urlencode(
        {
            "componentId": component_id,
            "pollKey": poll_key,
            "firstRequest": "false",
        }
    )
    return http_request_json(
        f"{QUICKBI_BASE_URL}/api/v2/olap/queryByPollKey?{query}",
        build_headers(config, cookie),
    )


def sql_records(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data") or {}
    performance_info = data.get("performanceInfo") or {}
    records = performance_info.get("sqlRecords") or []
    return records if isinstance(records, list) else []


def fetch_component_sql(item: dict[str, Any], config: Config, cookie: str) -> dict[str, Any]:
    component_id = item["component_id"]
    first_payload = olap_query(item, config, cookie)
    records = sql_records(first_payload)
    poll_key = (first_payload.get("data") or {}).get("pollKey")

    if not records:
        if not poll_key:
            raise RuntimeError(f"组件缺少 pollKey: {component_id}")
        for _ in range(config.poll_attempts):
            payload = query_by_pollkey(component_id, poll_key, config, cookie)
            records = sql_records(payload)
            if records:
                first_payload = payload
                break
            time.sleep(config.poll_interval_seconds)

    if not records:
        raise RuntimeError(f"轮询结束仍未拿到 SQL: {component_id}")

    data = first_payload.get("data") or {}
    return {
        "component_id": component_id,
        "component_name": item.get("component_name"),
        "success": True,
        "pollKey": poll_key,
        "runtime": data.get("runtime"),
        "sql_count": len(records),
        "sqlRecords": records,
    }


def fetch_all_sql(config: Config, items: list[dict[str, Any]]) -> dict[str, Any]:
    print("步骤 2/2：调用 QuickBI 接口获取 SQL", flush=True)
    cookie = cookie_header_from_storage_state(config.storage_state)
    components: list[dict[str, Any]] = []

    for index, item in enumerate(items, start=1):
        component_id = item["component_id"]
        print(f"  处理组件 {index}/{len(items)}: {component_id} | {item.get('component_name')}", flush=True)
        try:
            components.append(fetch_component_sql(item, config, cookie))
        except Exception as exc:
            components.append(
                {
                    "component_id": component_id,
                    "component_name": item.get("component_name"),
                    "success": False,
                    "error": str(exc),
                    "sql_count": 0,
                    "sqlRecords": [],
                }
            )

    failed_count = sum(1 for item in components if not item.get("success"))
    return {
        "workspace_id": config.workspace_id,
        "page_id": config.page_id,
        "component_count": len(components),
        "success_count": len(components) - failed_count,
        "failed_count": failed_count,
        "sql_count": sum(int(item.get("sql_count") or 0) for item in components),
        "components": components,
    }


def main() -> int:
    try:
        config = load_config()
        olap_items = capture_olap_params(config)
        result = fetch_all_sql(config, olap_items)
        write_json(config.result_file, result)
        print(f"完成：成功 {result['success_count']}/{result['component_count']}，SQL {result['sql_count']} 条", flush=True)
        print(f"输出文件: {config.result_file}", flush=True)
        return 0 if result["failed_count"] == 0 else 1
    except Exception as exc:
        print(f"执行失败: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
