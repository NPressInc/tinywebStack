"""Run the control plane. Bind localhost unless the operator says otherwise."""

from __future__ import annotations

import logging

import uvicorn

from tinyweb_controlplane.app import create_app
from tinyweb_controlplane.config import Settings
from tinyweb_controlplane.redact import install_log_redaction


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    install_log_redaction()
    settings = Settings.from_env()
    log = logging.getLogger("tinyweb_controlplane")
    if settings.provider_name == "fake":
        log.warning("TWS_CONTROL_PLANE_PROVIDER=fake; tunnel issuance will not publish DNS")
    app = create_app(settings)
    uvicorn.run(app, host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
