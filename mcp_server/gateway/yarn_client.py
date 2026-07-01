from typing import Any

import requests


class YarnClient:
    def __init__(self, config: dict) -> None:
        self.config = config.get("yarn", {})

    def enabled(self) -> bool:
        return bool(self.config.get("resource_manager_url"))

    def kill_application(self, application_id: str) -> dict[str, Any]:
        # 只供服务器运维脚本调用，不在 Gateway HTTP API 中直接暴露，避免普通用户误杀任务。
        if not self.enabled():
            return {"killed": False, "reason": "yarn resource manager is not configured"}
        base_url = self.config["resource_manager_url"].rstrip("/")
        url = f"{base_url}/ws/v1/cluster/apps/{application_id}/state"
        response = requests.put(url, json={"state": "KILLED"}, timeout=10)
        response.raise_for_status()
        return {"killed": True, "application_id": application_id}
