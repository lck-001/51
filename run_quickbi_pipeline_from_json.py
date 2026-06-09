from __future__ import annotations

import json
import sys
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
for subdir in ("dashboard_id", "pollkey", "queryByPollkey"):
    path = BASE_DIR / subdir
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from quickbi_dashboard_client import DashboardRequest, QuickBIClient, QuickBIConfig
from quickbi_pollkey_client import PollkeyRequest, QuickBIPollkeyClient, QuickBIPollkeyConfig, extract_csrf_token
from quickbi_query_by_pollkey_client import QueryByPollkeyRequest, QuickBIQueryByPollkeyClient, QuickBIQueryByPollkeyConfig


COOKIE = (
    'cna=9ESgIt4fFHQCAQHLUMIaaKhs; aliyun_lang=zh; aliyun_site=CN; aliyun_country=CN; x_login_pk=727d621bebdd4479a5e8036a8bb5794e; x_login_pk=727d621bebdd4479a5e8036a8bb5794e; qbi_locale=zh-CN; qbi_locale=zh-CN; qbi_version=1; qbi_version=1; login_aliyunid_csrf=_csrf_tk_1858380977697032; login_aliyunid="data @ 51talk"; login_aliyunid_ticket=3SAW2yxnMCnjYw2452ZLYAoA.111EWZwDoggFsfvrV6qoCREnFRzmxuTH2b5XXjQz7McK25w4W1qWV28joExHZaTAAmHmLTF6CevwqBcdTDX7KRbDMm1hfAWbRs19d2Lte7vv7x4sTWkyXGPFHpxHKJVupXiCBQHGXyGnUiyhEUM6K8RELKwh8.2mWNaj2R3tSmsYgruLV8fLnJwG8XAcLVJkVrJCtVwRM3BbzwYppXWVQMRFrQvbtSrF; login_aliyunid_sc=3R5H3e3HY2c8gwLZuY5GmS7K.1115pJgwSWzyZ1zzCQudjPySGezPyosZfbCAajwfExkZdtgU.2mWNaj2qzWyKH95nPZehbyQ6QgmAUcUpr1bxov7gcHQAhReMfDuD1uQKrXRPn3L7Bv; login_aliyunid_pk=31734768; login_current_pk=235454981062774632; csrf_token=f35fe83b-c079-4560-8e89-0d6365a55aed; isg=BKqqAVhAtEKJYDgQM_AWYye8-xBMGy51ZE6LkzR8dPnrZ3YhFqoMhHiF9ZP7jKYN; tfstk=g35oB-t9mTJ7X3o4sDR7nu_qRa2APQOBXMhpvBKU3n-bRaQUFyVhyNvpLuORtij1xbILdQdHLGtXv_QF9e5HNsB-93EWtwS9tlET65Q5PdAUXlEau_YXTePpY-pyub3evlET6SQ5PBOUXwCrhMDDRn8y8blzoI8p0UuyLM-23F8t4BRFYr4DRn-eTBSegrYB0HReTMl7S4-Nt9f4fyFDvHloZsYkEhcpmXc3JUvkba-DlE14OLxNzncU2OSvyHxf_oeclGWP2Es3soANCifHQBVofUXVSI-J_W0BDpfcq9j8JvTcKw56NC0UaZAkqd5fqVcFbZbFBKfY75Oka3WpNw3g2Zfl2a1cJ2k2ZQBDI_Aa10-dHNfH-6ZQiGbF59Jct0jzUxkwM0hBuyCqdv9ylExtr3PRmMyM2nz0oA6BUETMfr4mdAJylUtgorD_mL8Xyxf..'
)
DEFAULT_WORKSPACE_ID = "f15abc53-cb27-4be5-a05b-8a68b3b58736"
INPUT_FILE = Path(r"C:\Users\lichengkang001\Desktop\olap_query_params.json")
RESULT_DIR = BASE_DIR / "result"
CSRF_TOKEN = extract_csrf_token(COOKIE)


def is_cookie_invalid_error(message: str) -> bool:
    lowered = message.lower()
    return (
        "received html instead of json" in lowered
        or "cookie is expired" in lowered
        or "login is required" in lowered
        or "success=false" in lowered
        or "csrf" in lowered
    )


def read_json_file(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_task(item: dict) -> dict:
    page_id = item.get("page_id") or item.get("report_id")
    workspace_id = item.get("workspace_id") or DEFAULT_WORKSPACE_ID
    component_type = item.get("component_type")
    if component_type in ("", None):
        component_type = 66
    else:
        component_type = int(component_type)
    task = {
        "component_id": item["component_id"],
        "component_type": component_type,
        "first_request": bool(item.get("first_request", False)),
        "olap_query_param": item["olap_query_param"],
        "report_id": item.get("report_id") or page_id,
        "page_id": page_id,
        "workspace_id": workspace_id,
        "component_name": item.get("component_name"),
        "trigger": item.get("trigger"),
    }
    if not task["page_id"]:
        raise ValueError(f"missing page_id/report_id for component {task['component_id']}")
    return task


def load_tasks_by_page(path: Path) -> dict[str, list[dict]]:
    payload = read_json_file(path)
    if not isinstance(payload, list):
        raise ValueError("olap_query_params.json must contain a JSON array")

    grouped: dict[str, list[dict]] = {}
    for raw_item in payload:
        if not isinstance(raw_item, dict):
            continue
        task = normalize_task(raw_item)
        grouped.setdefault(task["page_id"], []).append(task)
    return grouped


def fetch_dashboard(page_id: str, workspace_id: str) -> dict:
    client = QuickBIClient(
        QuickBIConfig(
            cookie=COOKIE,
            workspace_id=workspace_id,
        )
    )
    return client.fetch_dashboard(DashboardRequest(dashboard_id=page_id))


def require_valid_cookie(page_id: str, workspace_id: str) -> None:
    try:
        fetch_dashboard(page_id=page_id, workspace_id=workspace_id)
    except Exception as exc:
        message = str(exc)
        if is_cookie_invalid_error(message):
            raise RuntimeError(
                "COOKIE is invalid or expired. Update COOKIE in run_quickbi_pipeline_from_json.py and retry."
            ) from exc
        raise


def fetch_pollkeys(report_id: str, workspace_id: str, tasks: list[dict]) -> list[dict]:
    client = QuickBIPollkeyClient(
        QuickBIPollkeyConfig(
            cookie=COOKIE,
            csrf_token=CSRF_TOKEN,
            workspace_id=workspace_id,
            page_id=report_id,
        )
    )
    requests = [
        PollkeyRequest(
            component_id=item["component_id"],
            report_id=report_id,
            component_type=item["component_type"],
            olap_query_param=item["olap_query_param"],
        )
        for item in tasks
    ]
    return client.query_many(requests)


def fetch_final_results(report_id: str, workspace_id: str, tasks: list[dict], pollkey_payloads: list[dict]) -> list[dict]:
    client = QuickBIQueryByPollkeyClient(
        QuickBIQueryByPollkeyConfig(
            cookie=COOKIE,
            csrf_token=CSRF_TOKEN,
            workspace_id=workspace_id,
            page_id=report_id,
        )
    )
    payloads: list[dict] = []
    for task, pollkey_payload in zip(tasks, pollkey_payloads, strict=True):
        poll_key = (pollkey_payload.get("data") or {}).get("pollKey")
        if not poll_key:
            raise RuntimeError(f"pollKey missing for component {task['component_id']}")
        request_item = QueryByPollkeyRequest(
            component_id=task["component_id"],
            poll_key=poll_key,
            first_request=bool(task.get("first_request", False)),
        )
        payloads.append(client.wait_until_ready(request_item))
    return payloads


def build_output(page_id: str, workspace_id: str, tasks: list[dict], dashboard_payload: dict, pollkey_payloads: list[dict], final_payloads: list[dict]) -> dict:
    return {
        "page_id": page_id,
        "workspace_id": workspace_id,
        "task_count": len(tasks),
        "tasks": tasks,
        "dashboard": dashboard_payload,
        "pollkey": pollkey_payloads,
        "queryByPollkey": final_payloads,
    }


def resolve_runtime_workspace_id(page_id: str, tasks: list[dict]) -> tuple[str, dict]:
    preferred_workspace_id = next((item["workspace_id"] for item in tasks if item.get("workspace_id")), DEFAULT_WORKSPACE_ID)
    dashboard_payload = fetch_dashboard(page_id=page_id, workspace_id=preferred_workspace_id)
    dashboard_data = dashboard_payload.get("data") or {}
    workspace_id = dashboard_data.get("workspaceId") or dashboard_data.get("wsId") or preferred_workspace_id
    return workspace_id, dashboard_payload


def write_result(page_id: str, payload: dict) -> Path:
    RESULT_DIR.mkdir(parents=True, exist_ok=True)
    output_path = RESULT_DIR / f"{page_id}.json"
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return output_path


def run_for_page(page_id: str, tasks: list[dict]) -> Path:
    require_valid_cookie(page_id=page_id, workspace_id=tasks[0]["workspace_id"])
    workspace_id, dashboard_payload = resolve_runtime_workspace_id(page_id=page_id, tasks=tasks)
    pollkey_payloads = fetch_pollkeys(report_id=page_id, workspace_id=workspace_id, tasks=tasks)
    final_payloads = fetch_final_results(
        report_id=page_id,
        workspace_id=workspace_id,
        tasks=tasks,
        pollkey_payloads=pollkey_payloads,
    )
    output = build_output(
        page_id=page_id,
        workspace_id=workspace_id,
        tasks=tasks,
        dashboard_payload=dashboard_payload,
        pollkey_payloads=pollkey_payloads,
        final_payloads=final_payloads,
    )
    return write_result(page_id=page_id, payload=output)


def main() -> int:
    tasks_by_page = load_tasks_by_page(INPUT_FILE)
    if not tasks_by_page:
        raise RuntimeError(f"no tasks found in {INPUT_FILE}")

    written_files: list[Path] = []
    for page_id, tasks in tasks_by_page.items():
        written_files.append(run_for_page(page_id=page_id, tasks=tasks))

    print(json.dumps({"written_files": [str(path) for path in written_files]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1) from exc
