from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any


class AssetIndex:
    def __init__(self, config: dict) -> None:
        assets = config["assets"]
        self.max_hits = int(config["limits"]["max_asset_hits"])
        self.scan_extensions = set(assets.get("scan_extensions", [".sql", ".sh", ".md", ".txt", ".json"]))
        self.max_file_bytes = int(assets.get("max_file_bytes", 1048576))
        self.max_snippet_chars = int(assets.get("max_snippet_chars", 4000))
        self.max_scan_files = int(assets.get("max_scan_files", 20000))
        self.excluded_dirs = set(
            assets.get(
                "excluded_dirs",
                [".git", ".idea", "__pycache__", ".venv", "venv", "node_modules", "target", "dist", "build"],
            )
        )
        self.directory_cache_ttl_seconds = int(assets.get("directory_cache_ttl_seconds", 300))
        self._directory_cache: list[dict[str, Any]] | None = None
        self._directory_cache_expires_at = 0.0
        self.ddl_dirs = [self._resolve(path) for path in assets.get("ddl_dirs", [])]
        self.dml_dirs = [self._resolve(path) for path in assets.get("dml_dirs", [])]
        self.profile_dirs = [self._resolve(path) for path in assets.get("profile_dirs", [])]
        self.sla_table_file = self._resolve(assets["sla_table_file"])
        self.profile_asset_file = self._resolve(assets["profile_asset_file"])
        self.table_file = self._resolve(assets["table_file"])
        self.etl_file = self._resolve(assets["etl_file"])

    def search(self, keyword: str, domain: str | None = None, limit: int | None = None) -> list[dict[str, Any]]:
        max_hits = min(limit or self.max_hits, self.max_hits)
        terms = [term.lower() for term in keyword.split() if term.strip()]
        items = self._load_all_assets()
        scored: list[tuple[int, dict[str, Any]]] = []
        for item in items:
            if domain and item.get("domain") and item.get("domain") != domain:
                continue
            text = json.dumps(item, ensure_ascii=False).lower()
            score = sum(1 for term in terms if term in text)
            if score > 0:
                scored.append((score, item))
        scored.sort(key=lambda row: row[0], reverse=True)
        return [item for _, item in scored[:max_hits]]

    def get_table(self, database: str, table: str) -> dict[str, Any] | None:
        target = f"{database}.{table}".lower()
        for item in self._read_jsonl(self.table_file):
            full_name = f"{item.get('database')}.{item.get('table')}".lower()
            if full_name == target:
                return item
        for item in self._scan_directory_assets():
            if item["asset_type"] != "ddl_file":
                continue
            path_text = item["path"].lower()
            file_stem = Path(path_text).stem
            if file_stem == table.lower() and database.lower() in path_text:
                return item
        return None

    def sla_tables(self) -> list[dict[str, Any]]:
        data = self._read_json(self.sla_table_file, default=[])
        return data if isinstance(data, list) else data.get("tables", [])

    def profile_assets(self) -> list[dict[str, Any]]:
        data = self._read_json(self.profile_asset_file, default=[])
        return data if isinstance(data, list) else data.get("assets", [])

    def _load_all_assets(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        items.extend(self.sla_tables())
        items.extend(self.profile_assets())
        items.extend(self._read_jsonl(self.table_file))
        items.extend(self._read_jsonl(self.etl_file))
        items.extend(self._scan_directory_assets())
        return items

    def _scan_directory_assets(self) -> list[dict[str, Any]]:
        # 目录扫描会读取大量 DDL/DML 文件，使用短 TTL 缓存减少每次资产搜索的磁盘开销。
        now = time.time()
        if self._directory_cache is not None and self._directory_cache_expires_at > now:
            return self._directory_cache
        items: list[dict[str, Any]] = []
        items.extend(self._scan_dirs(self.ddl_dirs, "ddl_file"))
        items.extend(self._scan_dirs(self.dml_dirs, "dml_file"))
        items.extend(self._scan_dirs(self.profile_dirs, "profile_file"))
        self._directory_cache = items
        self._directory_cache_expires_at = now + self.directory_cache_ttl_seconds
        return items

    def _scan_dirs(self, dirs: list[Path], asset_type: str) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        scanned = 0
        for base_dir in dirs:
            if not base_dir.exists() or not base_dir.is_dir():
                continue
            for root, dirnames, filenames in os.walk(base_dir):
                dirnames[:] = [dirname for dirname in dirnames if dirname not in self.excluded_dirs]
                root_path = Path(root)
                for filename in filenames:
                    if scanned >= self.max_scan_files:
                        return items
                    path = root_path / filename
                    if path.suffix.lower() not in self.scan_extensions:
                        continue
                    scanned += 1
                    try:
                        if path.stat().st_size > self.max_file_bytes:
                            continue
                        text = path.read_text(encoding="utf-8", errors="ignore")
                    except OSError:
                        continue
                    items.append(
                        {
                            "asset_type": asset_type,
                            "path": str(path),
                            "name": path.name,
                            "relative_path": str(path.relative_to(base_dir)),
                            "snippet": text[: self.max_snippet_chars],
                        }
                    )
        return items

    def _read_json(self, path: Path, default: Any) -> Any:
        if not path.exists():
            return default
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)

    def _read_jsonl(self, path: Path) -> list[dict[str, Any]]:
        if not path.exists():
            return []
        rows: list[dict[str, Any]] = []
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
        return rows

    def _resolve(self, value: str) -> Path:
        path = Path(value)
        if path.is_absolute():
            return path
        return (Path(__file__).parent / path).resolve()
