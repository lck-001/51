from __future__ import annotations

import argparse
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "gateway"))

from config import CONFIG
from yarn_client import YarnClient


def main() -> int:
    parser = argparse.ArgumentParser(description="查杀指定 YARN application。")
    parser.add_argument("application_id", help="例如 application_1710000000000_12345")
    args = parser.parse_args()

    # 这个脚本只给服务器运维人员使用，不通过 MCP 或普通 HTTP 接口暴露。
    result = YarnClient(CONFIG).kill_application(args.application_id)
    print(result)
    return 0 if result.get("killed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
