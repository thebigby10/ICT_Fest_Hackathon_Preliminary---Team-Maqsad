"""Administrative reporting and export endpoints."""
from datetime import datetime, time, timedelta

from fastapi import APIRouter, Depends, Query
from fastapi.responses import Response
from sqlalchemy.orm import Session

from .. import cache
from ..auth import require_admin
from ..database import get_db
from ..errors import AppError
from ..models import Booking, Room, User
from ..services.export import generate_export
from ..timeutils import parse_input_datetime

router = APIRouter(prefix="/admin", tags=["admin"])


def _parse_report_bound(value: str, *, end: bool) -> datetime:
    """Parse a usage-report range bound. Accepts a bare date (`YYYY-MM-DD`,
    whole-day inclusive) or a full ISO 8601 datetime. Returns the boundary for
    the half-open filter `start_time < range_end`, so `end` bounds are pushed
    just past the inclusive instant/day."""
    try:
        d = datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        dt = parse_input_datetime(value)  # ISO 8601, offset→UTC; raises ValueError
        return dt + timedelta(microseconds=1) if end else dt
    return datetime.combine(d + timedelta(days=1) if end else d, time.min)


@router.get("/usage-report")
def usage_report(
    frm: str = Query(..., alias="from"),
    to: str = Query(...),
    db: Session = Depends(get_db),
    admin: User = Depends(require_admin),
):
    cached = cache.get_report(admin.org_id, frm, to)
    if cached is not None:
        return cached
    epoch = cache.get_report_epoch(admin.org_id)

    try:
        range_start = _parse_report_bound(frm, end=False)
        range_end = _parse_report_bound(to, end=True)
    except ValueError:
        raise AppError(400, "INVALID_BOOKING_WINDOW", "Invalid date range")

    rooms = db.query(Room).filter(Room.org_id == admin.org_id).order_by(Room.id.asc()).all()
    room_rows = []
    for room in rooms:
        bookings = (
            db.query(Booking)
            .filter(
                Booking.room_id == room.id,
                Booking.status == "confirmed",
                Booking.start_time >= range_start,
                Booking.start_time < range_end,
            )
            .all()
        )
        room_rows.append(
            {
                "room_id": room.id,
                "room_name": room.name,
                "confirmed_bookings": len(bookings),
                "revenue_cents": sum(b.price_cents for b in bookings),
            }
        )

    result = {"from": frm, "to": to, "rooms": room_rows}
    cache.set_report(admin.org_id, frm, to, result, epoch)
    return result


@router.get("/export")
def export(
    room_id: int | None = Query(None),
    include_all: bool = Query(False),
    db: Session = Depends(get_db),
    admin: User = Depends(require_admin),
):
    csv_body = generate_export(db, admin.org_id, admin.id, room_id, include_all)
    return Response(content=csv_body, media_type="text/csv")
