"""Errors the HTTP layer turns into JSON. No secrets in messages."""

from __future__ import annotations

from typing import Any


class ApiError(Exception):
    def __init__(self, status_code: int, code: str, detail: str, **extra: Any) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.code = code
        self.detail = detail
        self.extra = extra


class ProviderError(Exception):
    def __init__(self, message: str, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


class ProviderNotConfigured(ProviderError):
    def __init__(self, missing: list[str]) -> None:
        self.missing = list(missing)
        super().__init__("Cloudflare is not configured: " + ", ".join(self.missing))
