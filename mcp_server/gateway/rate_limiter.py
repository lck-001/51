import time
from collections import defaultdict, deque
from threading import Lock


class RateLimiter:
    def __init__(self, per_user_per_minute: int) -> None:
        self.per_user_per_minute = per_user_per_minute
        self._events: dict[str, deque[float]] = defaultdict(deque)
        self._lock = Lock()

    def allow(self, username: str) -> bool:
        with self._lock:
            # 滑动窗口限流：按用户统计最近 60 秒提交次数。
            now = time.time()
            window_start = now - 60
            events = self._events[username]
            while events and events[0] < window_start:
                events.popleft()
            if len(events) >= self.per_user_per_minute:
                return False
            events.append(now)
            return True


class ConcurrencyLimiter:
    def __init__(self, global_limit: int, per_user_limit: int) -> None:
        self.global_limit = global_limit
        self.per_user_limit = per_user_limit
        self.active_global = 0
        self.active_by_user: dict[str, int] = defaultdict(int)
        self._lock = Lock()

    def acquire(self, username: str) -> bool:
        with self._lock:
            # 双层并发保护：全局保护 Hive 集群，单用户保护公平性。
            if self.active_global >= self.global_limit:
                return False
            if self.active_by_user[username] >= self.per_user_limit:
                return False
            self.active_global += 1
            self.active_by_user[username] += 1
            return True

    def release(self, username: str) -> None:
        with self._lock:
            self.active_global = max(0, self.active_global - 1)
            self.active_by_user[username] = max(0, self.active_by_user[username] - 1)
