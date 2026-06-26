from pathlib import Path
from typing import Any

import yaml


def load_config(path: str | Path = "config.yaml") -> dict[str, Any]:
    config_path = Path(path)
    if not config_path.is_absolute():
        config_path = Path(__file__).parent / config_path
    with config_path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


CONFIG = load_config()
