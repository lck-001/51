from __future__ import annotations

from datetime import datetime, time
from zoneinfo import ZoneInfo


def _parse_hhmm(value: str) -> time:
    hour, minute = value.split(":", 1)
    return time(int(hour), int(minute))


def is_in_service_window(config: dict, now: datetime | None = None) -> bool:
    timezone = ZoneInfo(config["server"].get("timezone", "Asia/Shanghai"))
    current = now.astimezone(timezone) if now else datetime.now(timezone)
    current_time = current.time()
    start = _parse_hhmm(config["server"]["service_window"]["start"])
    end = _parse_hhmm(config["server"]["service_window"]["end"])
    if start <= end:
        return start <= current_time < end
    return current_time >= start or current_time < end
