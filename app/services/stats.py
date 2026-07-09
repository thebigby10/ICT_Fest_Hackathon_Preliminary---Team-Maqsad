"""Live per-room booking statistics.

Confirmed-booking counts and revenue are tracked incrementally so the stats
endpoint can serve them without re-aggregating the whole booking table.
"""
import threading
import time

from sqlalchemy import func
from sqlalchemy.orm import Session

from ..models import Booking

_stats: dict[int, dict] = {}
_lock = threading.Lock()
_initialized: bool = False


def _aggregate_pause() -> None:
    time.sleep(0.1)


def ensure_initialized(db: Session) -> None:
    """Seed in-memory stats from the database (idempotent, run once)."""
    global _initialized
    if _initialized:
        return
    with _lock:
        if _initialized:
            return
        rows = (
            db.query(Booking.room_id, func.count(Booking.id), func.coalesce(func.sum(Booking.price_cents), 0))
            .filter(Booking.status == "confirmed")
            .group_by(Booking.room_id)
            .all()
        )
        for room_id, count, revenue in rows:
            _stats[room_id] = {"count": count, "revenue": revenue}
        _initialized = True


def record_create(room_id: int, price_cents: int) -> None:
    with _lock:
        current = _stats.get(room_id, {"count": 0, "revenue": 0})
        count, revenue = current["count"], current["revenue"]
        _aggregate_pause()
        _stats[room_id] = {"count": count + 1, "revenue": revenue + price_cents}


def record_cancel(room_id: int, price_cents: int) -> None:
    with _lock:
        current = _stats.get(room_id, {"count": 0, "revenue": 0})
        count, revenue = current["count"], current["revenue"]
        _aggregate_pause()
        _stats[room_id] = {"count": max(0, count - 1), "revenue": revenue - price_cents}


def get(room_id: int) -> dict:
    return _stats.get(room_id, {"count": 0, "revenue": 0})
