from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "gateway"))

from asset_index import AssetIndex
from config import CONFIG
from service_window import is_in_service_window
from sql_guard import SqlGuard


def test_service_window_crosses_midnight() -> None:
    tz = ZoneInfo("Asia/Shanghai")
    assert is_in_service_window(CONFIG, datetime(2026, 6, 26, 12, 0, tzinfo=tz))
    assert is_in_service_window(CONFIG, datetime(2026, 6, 27, 0, 30, tzinfo=tz))
    assert not is_in_service_window(CONFIG, datetime(2026, 6, 26, 2, 0, tzinfo=tz))


def test_sql_guard_adds_default_limit() -> None:
    guard = SqlGuard(CONFIG)
    result = guard.validate(
        "select dt, user_level from ads.ads_cn_user_profile_sla_di where dt='2026-06-01'"
    )
    assert "LIMIT 500" in result.normalized_sql


def test_sql_guard_rejects_mutation() -> None:
    guard = SqlGuard(CONFIG)
    with pytest.raises(ValueError):
        guard.validate("drop table ads.ads_cn_user_profile_sla_di")


def test_asset_search_returns_seed_assets() -> None:
    index = AssetIndex(CONFIG)
    items = index.search("境内 用户画像")
    assert items
