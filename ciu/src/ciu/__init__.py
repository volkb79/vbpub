"""CIU package."""

from __future__ import annotations

import os
from datetime import datetime, timezone


def _build_date_version() -> str:
	override = os.getenv("CIU_BUILD_VERSION")
	if override:
		return override
	return datetime.now(timezone.utc).strftime("%Y%m%d")


__version__ = _build_date_version()
