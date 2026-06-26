from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=512)


class LogoutRequest(BaseModel):
    session_id: str


class SqlRequest(BaseModel):
    session_id: str
    sql: str
    limit: int | None = None
    timeout_seconds: int | None = None


class AssetSearchRequest(BaseModel):
    keyword: str = Field(min_length=1, max_length=512)
    domain: str | None = None
    limit: int | None = None


class TableRequest(BaseModel):
    database: str
    table: str
