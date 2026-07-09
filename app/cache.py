"""In-memory response caches for read-heavy reporting endpoints.

Usage reports and per-room availability are relatively expensive to compute and
are read far more often than the underlying data changes, so results are cached
and invalidated when the data they depend on is modified.
"""
import threading

_report_cache: dict[tuple, dict] = {}
_report_epoch: dict[int, int] = {}
_availability_cache: dict[tuple, dict] = {}
_availability_epoch: dict[tuple, int] = {}
_lock = threading.Lock()


def get_report(org_id: int, frm: str, to: str):
    return _report_cache.get((org_id, frm, to))


def get_report_epoch(org_id: int) -> int:
    with _lock:
        return _report_epoch.get(org_id, 0)


def set_report(org_id: int, frm: str, to: str, value: dict, epoch: int) -> None:
    # ponytail: only commit the write if no invalidation happened since the
    # caller started computing `value` — otherwise a slow reader can clobber
    # a fresher cache with stale data after a concurrent write invalidated it.
    with _lock:
        if epoch == _report_epoch.get(org_id, 0):
            _report_cache[(org_id, frm, to)] = value


def invalidate_report(org_id: int) -> None:
    with _lock:
        _report_epoch[org_id] = _report_epoch.get(org_id, 0) + 1
        for key in [k for k in _report_cache if k[0] == org_id]:
            _report_cache.pop(key, None)


def get_availability(room_id: int, date: str):
    return _availability_cache.get((room_id, date))


def get_availability_epoch(room_id: int, date: str) -> int:
    with _lock:
        return _availability_epoch.get((room_id, date), 0)


def set_availability(room_id: int, date: str, value: dict, epoch: int) -> None:
    with _lock:
        if epoch == _availability_epoch.get((room_id, date), 0):
            _availability_cache[(room_id, date)] = value


def invalidate_availability(room_id: int, date: str) -> None:
    with _lock:
        _availability_epoch[(room_id, date)] = _availability_epoch.get((room_id, date), 0) + 1
        _availability_cache.pop((room_id, date), None)
