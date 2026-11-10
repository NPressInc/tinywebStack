"""Keep setup codes and tunnel tokens out of log lines."""

from __future__ import annotations

import logging
import re

_JSON_SECRET = re.compile(
    r'("(?:setup_code|claim_token|token|TunnelSecret|api_token)"\s*:\s*")([^"]*)(")',
    re.IGNORECASE,
)
_BEARER = re.compile(r"(Bearer\s+)\S+", re.IGNORECASE)
_TUNNEL_ENV = re.compile(r"(TUNNEL_TOKEN=)\S+")


def redact_text(text: str) -> str:
    text = _JSON_SECRET.sub(r"\1REDACTED\3", text)
    text = _BEARER.sub(r"\1REDACTED", text)
    text = _TUNNEL_ENV.sub(r"\1REDACTED", text)
    return text


class SecretLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            rendered = record.getMessage()
        except Exception:
            return True
        cleaned = redact_text(rendered)
        if cleaned != rendered:
            record.msg = cleaned.replace("%", "%%")
            record.args = ()
        return True


def install_log_redaction() -> None:
    filt = SecretLogFilter()
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access", "tinyweb_controlplane"):
        logging.getLogger(name).addFilter(filt)
