import time
import uuid
from dataclasses import dataclass
from threading import Lock


@dataclass
class Session:
    session_id: str
    username: str
    password: str
    created_at: float
    expires_at: float


class SessionStore:
    def __init__(self, ttl_seconds: int) -> None:
        self.ttl_seconds = ttl_seconds
        self._sessions: dict[str, Session] = {}
        self._lock = Lock()

    def create(self, username: str, password: str) -> Session:
        with self._lock:
            now = time.time()
            session = Session(
                session_id=uuid.uuid4().hex,
                username=username,
                password=password,
                created_at=now,
                expires_at=now + self.ttl_seconds,
            )
            self._sessions[session.session_id] = session
            return session

    def get(self, session_id: str) -> Session | None:
        with self._lock:
            self._cleanup_unlocked()
            return self._sessions.get(session_id)

    def delete(self, session_id: str) -> None:
        with self._lock:
            self._sessions.pop(session_id, None)

    def cleanup(self) -> None:
        with self._lock:
            self._cleanup_unlocked()

    def count(self) -> int:
        with self._lock:
            self._cleanup_unlocked()
            return len(self._sessions)

    def _cleanup_unlocked(self) -> None:
        now = time.time()
        expired = [sid for sid, session in self._sessions.items() if session.expires_at <= now]
        for sid in expired:
            self._sessions.pop(sid, None)
