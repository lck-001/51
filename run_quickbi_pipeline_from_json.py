from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from json import JSONDecodeError
from pathlib import Path
from typing import Any
from urllib.parse import quote


BASE_DIR = Path(__file__).resolve().parent
# 脚本放到 51 仓库后，模块目录还在上一级工程目录里，所以这里做一层回退查找。
PROJECT_DIR = BASE_DIR
if not (PROJECT_DIR / "dashboard_id").exists():
    PROJECT_DIR = BASE_DIR.parent

for subdir in ("dashboard_id", "pollkey", "queryByPollkey"):
    path = PROJECT_DIR / subdir
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from quickbi_dashboard_client import DashboardRequest, QuickBIClient, QuickBIConfig
from quickbi_pollkey_client import PollkeyRequest, QuickBIPollkeyClient, QuickBIPollkeyConfig, extract_csrf_token
from quickbi_query_by_pollkey_client import QueryByPollkeyRequest, QuickBIQueryByPollkeyClient, QuickBIQueryByPollkeyConfig


DEFAULT_CONFIG_FILE = BASE_DIR / "quickbi_pipeline_config.local.json"
DEFAULT_OUTPUT_MODE = "sql"
DEFAULT_POLL_ATTEMPTS = 90
DEFAULT_POLL_INTERVAL_SECONDS = 1.0
OUTPUT_MODES = {"full", "sql", "summary"}
COOKIE_VALUE_SAFE_CHARS = "!#$%&'()*+-./:<=>?@[]^_`{|}~"


@dataclass(slots=True)
class RuntimeConfig:
    cookie: str
    csrf_token: str
    input_file: Path
    result_dir: Path
    default_workspace_id: str
    output_mode: str = DEFAULT_OUTPUT_MODE
    continue_on_error: bool = True
    poll_attempts: int = DEFAULT_POLL_ATTEMPTS
    poll_interval_seconds: float = DEFAULT_POLL_INTERVAL_SECONDS
    verbose: bool = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run QuickBI SQL extraction pipeline from exported JSON params.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_FILE, help="local JSON config file")
    parser.add_argument("--input-file", type=Path, help="override input JSON file from config")
    parser.add_argument("--result-dir", type=Path, help="override result directory from config")
    parser.add_argument(
        "--storage-state",
        type=Path,
        help="Playwright storage state JSON; when provided, refresh cookie in config before running",
    )
    parser.add_argument(
        "--save-config",
        action="store_true",
        help="persist --storage-state cookie and CLI path/mode overrides into the config file before running",
    )
    parser.add_argument("--output-mode", choices=sorted(OUTPUT_MODES), help="output shape, default: sql")
    parser.add_argument("--verbose", action="store_true", help="print detailed progress")
    parser.add_argument("--stop-on-error", action="store_true", help="stop when one component/page fails")
    return parser.parse_args()


def read_json_file(path: Path) -> object:
    text = path.read_text(encoding="utf-8-sig")
    try:
        return json.loads(text)
    except JSONDecodeError:
        repaired_text = escape_cookie_value_quotes(text)
        if repaired_text != text:
            return json.loads(repaired_text)
        raise


def is_escaped(value: str, index: int) -> bool:
    backslash_count = 0
    cursor = index - 1
    while cursor >= 0 and value[cursor] == "\\":
        backslash_count += 1
        cursor -= 1
    return backslash_count % 2 == 1


def escape_unescaped_quotes(value: str) -> str:
    chars: list[str] = []
    for index, char in enumerate(value):
        if char == '"' and not is_escaped(value, index):
            chars.append('\\"')
        else:
            chars.append(char)
    return "".join(chars)


def escape_cookie_value_quotes(text: str) -> str:
    lines = text.splitlines(keepends=True)
    changed = False
    for index, line in enumerate(lines):
        if '"cookie"' not in line:
            continue
        colon_index = line.find(":")
        value_start = line.find('"', colon_index + 1)
        value_end = line.rfind('"')
        if colon_index < 0 or value_start < 0 or value_end <= value_start:
            continue
        value = line[value_start + 1 : value_end]
        escaped_value = escape_unescaped_quotes(value)
        if escaped_value != value:
            lines[index] = line[: value_start + 1] + escaped_value + line[value_end:]
            changed = True
    return "".join(lines) if changed else text


def resolve_path(value: str | Path, base_dir: Path) -> Path:
    path = Path(value).expanduser()
    if path.is_absolute():
        return path
    return base_dir / path


def cookie_domain_matches(domain: str, host: str) -> bool:
    normalized_domain = domain.lstrip(".").lower()
    normalized_host = host.lower()
    return normalized_domain == normalized_host or normalized_host.endswith(f".{normalized_domain}")


def cookie_header_from_storage_state(state_path: Path, host: str = "bi.aliyun.com") -> str:
    payload = read_json_file(state_path)
    if not isinstance(payload, dict):
        raise ValueError("storage state file must contain a JSON object")

    cookies = payload.get("cookies")
    if not isinstance(cookies, list):
        raise ValueError("storage state file missing cookies array")

    pairs: list[str] = []
    seen: set[str] = set()
    for cookie in cookies:
        if not isinstance(cookie, dict):
            continue
        name = str(cookie.get("name") or "").strip()
        value = str(cookie.get("value") or "")
        domain = str(cookie.get("domain") or "")
        if not name or not cookie_domain_matches(domain, host):
            continue
        if name in seen:
            continue
        seen.add(name)
        pairs.append(f"{name}={quote(value, safe=COOKIE_VALUE_SAFE_CHARS)}")

    if not pairs:
        raise ValueError(f"no cookies for {host} found in {state_path}")
    return "; ".join(pairs)


def load_config_payload(config_path: Path) -> dict[str, Any]:
    payload = read_json_file(config_path)
    if not isinstance(payload, dict):
        raise ValueError("config file must contain a JSON object")
    return payload


def write_config_payload(config_path: Path, payload: dict[str, Any]) -> None:
    config_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def refresh_config_cookie_from_storage_state(config_path: Path, storage_state_path: Path) -> None:
    payload = load_config_payload(config_path)
    payload["cookie"] = cookie_header_from_storage_state(storage_state_path)
    payload["csrf_token"] = extract_csrf_token(payload["cookie"])
    write_config_payload(config_path, payload)


def update_config_from_args(config_path: Path, args: argparse.Namespace) -> None:
    payload = load_config_payload(config_path)
    if args.storage_state:
        storage_state_path = resolve_path(args.storage_state, BASE_DIR)
        payload["cookie"] = cookie_header_from_storage_state(storage_state_path)
        payload["csrf_token"] = extract_csrf_token(payload["cookie"])
    if args.input_file:
        payload["input_file"] = str(resolve_path(args.input_file, BASE_DIR))
    if args.result_dir:
        payload["result_dir"] = str(resolve_path(args.result_dir, BASE_DIR))
    if args.output_mode:
        payload["output_mode"] = args.output_mode
    write_config_payload(config_path, payload)


def load_runtime_config(args: argparse.Namespace) -> RuntimeConfig:
    config_path = args.config
    if not config_path.is_absolute():
        config_path = BASE_DIR / config_path
    if not config_path.exists():
        raise RuntimeError(
            f"config file not found: {config_path}. Copy quickbi_pipeline_config.example.json "
            "to quickbi_pipeline_config.local.json and fill in your QuickBI cookie."
        )

    if args.save_config:
        update_config_from_args(config_path, args)
    elif args.storage_state:
        storage_state_path = resolve_path(args.storage_state, BASE_DIR)
        refresh_config_cookie_from_storage_state(config_path, storage_state_path)

    payload = load_config_payload(config_path)

    cookie = str(payload.get("cookie") or "").strip()
    if not cookie:
        raise ValueError("config field 'cookie' is required")

    default_workspace_id = str(payload.get("default_workspace_id") or "").strip()
    if not default_workspace_id:
        raise ValueError("config field 'default_workspace_id' is required")

    input_file_value = args.input_file or payload.get("input_file")
    if not input_file_value:
        raise ValueError("config field 'input_file' is required")

    result_dir_value = args.result_dir or payload.get("result_dir") or "result"
    output_mode = args.output_mode or str(payload.get("output_mode") or DEFAULT_OUTPUT_MODE)
    if output_mode not in OUTPUT_MODES:
        raise ValueError(f"output_mode must be one of: {', '.join(sorted(OUTPUT_MODES))}")

    csrf_token = str(payload.get("csrf_token") or "").strip() or extract_csrf_token(cookie)
    config = RuntimeConfig(
        cookie=cookie,
        csrf_token=csrf_token,
        input_file=resolve_path(input_file_value, BASE_DIR),
        result_dir=resolve_path(result_dir_value, BASE_DIR),
        default_workspace_id=default_workspace_id,
        output_mode=output_mode,
        continue_on_error=bool(payload.get("continue_on_error", True)),
        poll_attempts=int(payload.get("poll_attempts", DEFAULT_POLL_ATTEMPTS)),
        poll_interval_seconds=float(payload.get("poll_interval_seconds", DEFAULT_POLL_INTERVAL_SECONDS)),
        verbose=bool(payload.get("verbose", False)),
    )
    if args.verbose:
        config.verbose = True
    if args.stop_on_error:
        config.continue_on_error = False
    return config


def log(config: RuntimeConfig, message: str, *, verbose_only: bool = False) -> None:
    if verbose_only and not config.verbose:
        return
    print(message)


def is_cookie_invalid_error(message: str) -> bool:
    lowered = message.lower()
    return (
        "received html instead of json" in lowered
        or "cookie is expired" in lowered
        or "login is required" in lowered
        or "success=false" in lowered
        or "csrf" in lowered
    )


def normalize_task(item: dict[str, Any], default_workspace_id: str) -> dict[str, Any]:
    # page_id 为空时直接退回 report_id，避免抓包结果字段不完整导致任务无法分组。
    page_id = item.get("page_id") or item.get("report_id")
    workspace_id = item.get("workspace_id") or default_workspace_id
    component_type = item.get("component_type")
    # 抓包结果里 component_type 经常是空字符串，这里按当前看板默认补成 66。
    if component_type in ("", None):
        component_type = 66
    else:
        component_type = int(component_type)
    task = {
        "component_id": item["component_id"],
        "component_type": component_type,
        "first_request": bool(item.get("first_request", False)),
        "olap_query_param": normalize_olap_query_param(item["olap_query_param"]),
        "report_id": item.get("report_id") or page_id,
        "page_id": page_id,
        "workspace_id": workspace_id,
        "component_name": item.get("component_name"),
        "trigger": item.get("trigger"),
    }
    if not task["page_id"]:
        raise ValueError(f"missing page_id/report_id for component {task['component_id']}")
    return task


def normalize_olap_query_param(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    raise ValueError(f"olap_query_param must be string or object, got {type(value).__name__}")


def validate_raw_task(item: Any, index: int) -> list[str]:
    errors: list[str] = []
    if not isinstance(item, dict):
        return [f"item {index} must be an object"]
    for field_name in ("component_id", "olap_query_param"):
        if not item.get(field_name):
            errors.append(f"item {index} missing {field_name}")
    if not (item.get("page_id") or item.get("report_id")):
        errors.append(f"item {index} missing page_id/report_id")
    return errors


def load_tasks_by_page(path: Path, default_workspace_id: str) -> dict[str, list[dict[str, Any]]]:
    payload = read_json_file(path)
    if not isinstance(payload, list):
        raise ValueError("olap_query_params.json must contain a JSON array")

    validation_errors: list[str] = []
    grouped: dict[str, list[dict[str, Any]]] = {}
    for index, raw_item in enumerate(payload, start=1):
        item_errors = validate_raw_task(raw_item, index)
        if item_errors:
            validation_errors.extend(item_errors)
            continue
        task = normalize_task(raw_item, default_workspace_id)
        grouped.setdefault(task["page_id"], []).append(task)

    if validation_errors:
        detail = "\n".join(validation_errors[:20])
        if len(validation_errors) > 20:
            detail += f"\n... and {len(validation_errors) - 20} more"
        raise ValueError(f"input validation failed:\n{detail}")
    return grouped


def fetch_dashboard(page_id: str, workspace_id: str, config: RuntimeConfig) -> dict[str, Any]:
    client = QuickBIClient(
        QuickBIConfig(
            cookie=config.cookie,
            workspace_id=workspace_id,
        )
    )
    return client.fetch_dashboard(DashboardRequest(dashboard_id=page_id))


def require_valid_cookie(page_id: str, workspace_id: str, config: RuntimeConfig) -> None:
    try:
        fetch_dashboard(page_id=page_id, workspace_id=workspace_id, config=config)
    except Exception as exc:
        message = str(exc)
        # 先用 dashboard 接口做登录态探活，避免后面跑到一半才发现 COOKIE 失效。
        if is_cookie_invalid_error(message):
            raise RuntimeError(
                "COOKIE is invalid or expired. Update cookie in quickbi_pipeline_config.local.json and retry."
            ) from exc
        raise


def get_sql_records_from_payload(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data") or {}
    performance_info = data.get("performanceInfo") or {}
    sql_records = performance_info.get("sqlRecords") or []
    if not isinstance(sql_records, list):
        return []
    return [record for record in sql_records if isinstance(record, dict)]


def has_sql_records(payload: dict[str, Any]) -> bool:
    return bool(get_sql_records_from_payload(payload))


def build_pollkey_client(report_id: str, workspace_id: str, config: RuntimeConfig) -> QuickBIPollkeyClient:
    return QuickBIPollkeyClient(
        QuickBIPollkeyConfig(
            cookie=config.cookie,
            csrf_token=config.csrf_token,
            workspace_id=workspace_id,
            page_id=report_id,
        )
    )


def build_query_client(report_id: str, workspace_id: str, config: RuntimeConfig) -> QuickBIQueryByPollkeyClient:
    return QuickBIQueryByPollkeyClient(
        QuickBIQueryByPollkeyConfig(
            cookie=config.cookie,
            csrf_token=config.csrf_token,
            workspace_id=workspace_id,
            page_id=report_id,
        )
    )


def fetch_component_result(
    task: dict[str, Any],
    report_id: str,
    pollkey_client: QuickBIPollkeyClient,
    query_client: QuickBIQueryByPollkeyClient,
    config: RuntimeConfig,
) -> dict[str, Any]:
    pollkey_payload = pollkey_client.query_pollkey(
        PollkeyRequest(
            component_id=task["component_id"],
            report_id=report_id,
            component_type=task["component_type"],
            olap_query_param=task["olap_query_param"],
        )
    )

    if has_sql_records(pollkey_payload):
        final_payload = pollkey_payload
        poll_key = (pollkey_payload.get("data") or {}).get("pollKey")
    else:
        poll_key = (pollkey_payload.get("data") or {}).get("pollKey")
        if not poll_key:
            raise RuntimeError(f"pollKey missing for component {task['component_id']}")

        log(config, f"component {task['component_id']} pollKey={poll_key}", verbose_only=True)
        final_payload = wait_until_sql_records(
            query_client=query_client,
            request_item=QueryByPollkeyRequest(
                component_id=task["component_id"],
                poll_key=poll_key,
                first_request=bool(task.get("first_request", False)),
            ),
            config=config,
        )

    return {
        "success": True,
        "task": task,
        "pollKey": poll_key,
        "pollkey_payload": pollkey_payload,
        "final_payload": final_payload,
    }


def wait_until_sql_records(
    query_client: QuickBIQueryByPollkeyClient,
    request_item: QueryByPollkeyRequest,
    config: RuntimeConfig,
) -> dict[str, Any]:
    last_payload: dict[str, Any] | None = None
    for attempt in range(1, config.poll_attempts + 1):
        last_payload = query_client.query_by_pollkey(request_item)
        if has_sql_records(last_payload):
            return last_payload
        if attempt < config.poll_attempts:
            time.sleep(config.poll_interval_seconds)

    if last_payload is None:
        raise RuntimeError("queryByPollKey returned no payload")
    raise RuntimeError(
        "queryByPollKey did not return SQL records after "
        f"{config.poll_attempts} attempts for component {request_item.component_id}"
    )


def extract_sql_records(component_result: dict[str, Any]) -> list[dict[str, Any]]:
    final_payload = component_result.get("final_payload") or {}
    return get_sql_records_from_payload(final_payload)


def build_component_sql_output(component_result: dict[str, Any]) -> dict[str, Any]:
    task = component_result.get("task") or {}
    sql_records = extract_sql_records(component_result)
    final_payload = component_result.get("final_payload") or {}
    data = final_payload.get("data") or {}
    return {
        "component_id": task.get("component_id"),
        "component_name": task.get("component_name"),
        "component_type": task.get("component_type"),
        "success": True,
        "pollKey": component_result.get("pollKey"),
        "runtime": data.get("runtime"),
        "sql_count": len(sql_records),
        "sqlRecords": sql_records,
    }


def build_component_summary(component_result: dict[str, Any]) -> dict[str, Any]:
    if not component_result.get("success"):
        return {
            "component_id": component_result.get("component_id"),
            "component_name": component_result.get("component_name"),
            "success": False,
            "error": component_result.get("error"),
        }

    sql_output = build_component_sql_output(component_result)
    final_payload = component_result.get("final_payload") or {}
    data = final_payload.get("data") or {}
    value = data.get("value") or {}
    return {
        "component_id": sql_output["component_id"],
        "component_name": sql_output["component_name"],
        "success": True,
        "pollKey": sql_output["pollKey"],
        "runtime": sql_output["runtime"],
        "sql_count": sql_output["sql_count"],
        "row_count": len(value.get("rows") or []),
        "column_count": len(value.get("columns") or []),
    }


def build_output(
    page_id: str,
    workspace_id: str,
    tasks: list[dict[str, Any]],
    dashboard_payload: dict[str, Any],
    component_results: list[dict[str, Any]],
    output_mode: str,
) -> dict[str, Any]:
    failed_count = sum(1 for item in component_results if not item.get("success"))
    base = {
        "page_id": page_id,
        "workspace_id": workspace_id,
        "task_count": len(tasks),
        "success_count": len(component_results) - failed_count,
        "failed_count": failed_count,
        "output_mode": output_mode,
    }

    if output_mode == "full":
        return {
            **base,
            "tasks": tasks,
            "dashboard": dashboard_payload,
            "components": component_results,
        }

    if output_mode == "summary":
        return {
            **base,
            "components": [build_component_summary(item) for item in component_results],
        }

    sql_components: list[dict[str, Any]] = []
    for item in component_results:
        if item.get("success"):
            sql_components.append(build_component_sql_output(item))
        else:
            sql_components.append(
                {
                    "component_id": item.get("component_id"),
                    "component_name": item.get("component_name"),
                    "success": False,
                    "error": item.get("error"),
                    "sql_count": 0,
                    "sqlRecords": [],
                }
            )
    return {**base, "components": sql_components}


def resolve_runtime_workspace_id(page_id: str, tasks: list[dict[str, Any]], config: RuntimeConfig) -> tuple[str, dict[str, Any]]:
    # 优先使用抓包里带出的 workspace_id，再用 dashboard 返回值做最终纠正。
    preferred_workspace_id = next((item["workspace_id"] for item in tasks if item.get("workspace_id")), config.default_workspace_id)
    dashboard_payload = fetch_dashboard(page_id=page_id, workspace_id=preferred_workspace_id, config=config)
    dashboard_data = dashboard_payload.get("data") or {}
    workspace_id = dashboard_data.get("workspaceId") or dashboard_data.get("wsId") or preferred_workspace_id
    return workspace_id, dashboard_payload


def write_result(page_id: str, payload: dict[str, Any], config: RuntimeConfig) -> Path:
    config.result_dir.mkdir(parents=True, exist_ok=True)
    # 每个 page_id 单独输出一个结果文件，便于回看和重跑。
    output_path = config.result_dir / f"{page_id}.{config.output_mode}.json"
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return output_path


def run_for_page(page_id: str, tasks: list[dict[str, Any]], config: RuntimeConfig) -> Path:
    # 单页执行主链路：校验 COOKIE -> 取 workspace_id -> 拿 pollkey -> 拉最终结果 -> 落盘。
    log(config, f"page {page_id}: start, tasks={len(tasks)}")
    require_valid_cookie(page_id=page_id, workspace_id=tasks[0]["workspace_id"], config=config)
    workspace_id, dashboard_payload = resolve_runtime_workspace_id(page_id=page_id, tasks=tasks, config=config)
    pollkey_client = build_pollkey_client(report_id=page_id, workspace_id=workspace_id, config=config)
    query_client = build_query_client(report_id=page_id, workspace_id=workspace_id, config=config)

    component_results: list[dict[str, Any]] = []
    for index, task in enumerate(tasks, start=1):
        component_id = task["component_id"]
        component_name = task.get("component_name")
        log(config, f"page {page_id}: component {index}/{len(tasks)} {component_id}", verbose_only=True)
        try:
            component_results.append(
                fetch_component_result(
                    task=task,
                    report_id=page_id,
                    pollkey_client=pollkey_client,
                    query_client=query_client,
                    config=config,
                )
            )
        except Exception as exc:
            error_message = str(exc)
            if is_cookie_invalid_error(error_message):
                raise RuntimeError(
                    "COOKIE is invalid or expired. Update cookie in quickbi_pipeline_config.local.json and retry."
                ) from exc
            if not config.continue_on_error:
                raise
            log(config, f"page {page_id}: component {component_id} failed: {error_message}")
            component_results.append(
                {
                    "success": False,
                    "component_id": component_id,
                    "component_name": component_name,
                    "error": error_message,
                }
            )

    output = build_output(
        page_id=page_id,
        workspace_id=workspace_id,
        tasks=tasks,
        dashboard_payload=dashboard_payload,
        component_results=component_results,
        output_mode=config.output_mode,
    )
    output_path = write_result(page_id=page_id, payload=output, config=config)
    log(config, f"page {page_id}: wrote {output_path}")
    return output_path


def main() -> int:
    args = parse_args()
    config = load_runtime_config(args)
    tasks_by_page = load_tasks_by_page(config.input_file, config.default_workspace_id)
    if not tasks_by_page:
        raise RuntimeError(f"no tasks found in {config.input_file}")

    total_tasks = sum(len(tasks) for tasks in tasks_by_page.values())
    log(config, f"loaded {total_tasks} tasks from {config.input_file}, pages={len(tasks_by_page)}")

    # 支持一个输入文件里包含多个 page_id，逐页执行。
    written_files: list[Path] = []
    for page_id, tasks in tasks_by_page.items():
        try:
            written_files.append(run_for_page(page_id=page_id, tasks=tasks, config=config))
        except Exception as exc:
            if not config.continue_on_error:
                raise
            log(config, f"page {page_id}: failed: {exc}")

    print(json.dumps({"written_files": [str(path) for path in written_files]}, ensure_ascii=False, indent=2))
    return 0 if written_files else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1) from exc
