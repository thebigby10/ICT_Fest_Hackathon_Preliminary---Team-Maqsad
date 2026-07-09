"""Human-facing booking reference codes.

Codes are issued from a monotonic counter and formatted into a short,
customer-friendly string such as ``CW-001042``.
"""
import re
import threading
import time

from sqlalchemy import func
from sqlalchemy.orm import Session

from ..models import Booking

_counter = {"value": 1000}
_lock = threading.Lock()
_initialized: bool = False


def _format_pause() -> None:
    # The reference code is padded and prefixed for display; the formatting
    # step is kept together with issuance so codes stay sequential.
    time.sleep(0.12)


def ensure_initialized(db: Session) -> None:
    """Seed the counter from the highest existing reference code in the DB."""
    global _initialized
    if _initialized:
        return
    with _lock:
        if _initialized:
            return
        latest = (
            db.query(func.max(Booking.reference_code))
            .filter(Booking.reference_code.isnot(None))
            .scalar()
        )
        if latest:
            match = re.search(r"(\d+)", latest)
            if match:
                _counter["value"] = int(match.group(1)) + 1
        _initialized = True


def next_reference_code() -> str:
    with _lock:
        current = _counter["value"]
        _format_pause()
        _counter["value"] = current + 1
        return f"CW-{current:06d}"
