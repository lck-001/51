from __future__ import annotations

from pathlib import Path
from typing import Any
import os

import yaml


def load_config(path: str | Path = "config.yaml") -> dict[str, Any]:
    """读取网关配置，并允许用环境变量覆盖部署差异。"""
    config_path = Path(path)
    if not config_path.is_absolute():
        config_path = Path(__file__).parent / config_path
    with config_path.open("r", encoding="utf-8") as f:
        config = yaml.safe_load(f)
    apply_env_overrides(config)
    return config


def apply_env_overrides(config: dict[str, Any]) -> None:
    # 生产环境推荐把 Hive 地址、队列和账号放到环境变量，避免把敏感信息写进仓库。
    hive = config.setdefault("hive", {})
    env_map = {
        "HIVE_HOST": "host",
        "HIVE_PORT": "port",
        "HIVE_AUTH": "auth",
        "HIVE_DATABASE": "database",
        "HIVE_QUEUE": "queue",
        "HIVE_USER": "username",
        "HIVE_USERNAME": "username",
        "HIVE_PASSWORD": "password",
    }
    for env_name, config_key in env_map.items():
        value = os.environ.get(env_name)
        if value:
            hive[config_key] = int(value) if config_key == "port" else value


CONFIG = load_config(os.environ.get("HIVE_GATEWAY_CONFIG", "config.yaml"))
