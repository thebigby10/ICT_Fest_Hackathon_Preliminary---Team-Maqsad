"""End-to-end contract + concurrency tests for the CoWork booking API.

These exercise the black-box contract in ``CLAUDE.md`` / ``README.md``:
API paths, status codes, error ``code`` strings, JSON field names, and the
business rules (datetimes, pricing, double-booking, quota, rate limit, refund
tiers, pagination, multi-tenancy, live stats/reports, auth token lifecycle).

The concurrency tests reproduce the races the bug report says are fixed
(double-booking, quota, reference-code uniqueness, concurrent cancel, refresh
single-use, duplicate registration, notification deadlock). Endpoints are sync
``def`` handlers, so Starlette runs them in a worker threadpool and calls from a
``ThreadPoolExecutor`` genuinely run concurrently.

Run with ``pytest``.
"""
import itertools
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import jwt
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

# Unique suffixes so re-runs against the persistent SQLite file never collide.
_seq = itertools.count()


def _uid() -> str:
    return f"{datetime.now().timestamp()}-{next(_seq)}"


def _future(hours: int) -> str:
    return (
        (datetime.now(timezone.utc) + timedelta(hours=hours))
        .replace(minute=0, second=0, microsecond=0)
        .isoformat()
    )


def _future_dt(hours: int) -> datetime:
    return (datetime.now(timezone.utc) + timedelta(hours=hours)).replace(
        minute=0, second=0, microsecond=0
    )


def _register(org: str, username: str, password: str = "pw12345"):
    return client.post(
        "/auth/register",
        json={"org_name": org, "username": username, "password": password},
    )


def _login(org: str, username: str, password: str = "pw12345"):
    return client.post(
        "/auth/login",
        json={"org_name": org, "username": username, "password": password},
    )


def _headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _admin_ctx():
    """Register a fresh org (caller becomes admin) and return (org, headers)."""
    org = f"org-{_uid()}"
    _register(org, "admin")
    token = _login(org, "admin").json()["access_token"]
    return org, _headers(token)


def _member_ctx(org: str, username: str | None = None):
    username = username or f"m-{_uid()}"
    _register(org, username)
    token = _login(org, username).json()["access_token"]
    return username, _headers(token)


def _make_room(headers: dict, rate: int = 1000, capacity: int = 4) -> int:
    r = client.post(
        "/rooms",
        json={"name": f"room-{_uid()}", "capacity": capacity, "hourly_rate_cents": rate},
        headers=headers,
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


def _book(headers: dict, room_id: int, start_h: int, end_h: int):
    return client.post(
        "/bookings",
        json={"room_id": room_id, "start_time": _future(start_h), "end_time": _future(end_h)},
        headers=headers,
    )


# --------------------------------------------------------------------------- #
# Original golden path                                                          #
# --------------------------------------------------------------------------- #
def test_core_flow():
    assert client.get("/health").json() == {"status": "ok"}

    org, headers = _admin_ctx()
    room_id = _make_room(headers, rate=1000)

    booking = _book(headers, room_id, 50, 52)
    assert booking.status_code == 201
    assert booking.json()["price_cents"] == 2000

    listing = client.get("/bookings", headers=headers)
    assert listing.status_code == 200
    assert listing.json()["total"] >= 1


# --------------------------------------------------------------------------- #
# Registration & auth                                                          #
# --------------------------------------------------------------------------- #
def test_register_admin_then_member_roles():
    org = f"org-{_uid()}"
    a = _register(org, "alice")
    assert a.status_code == 201
    body = a.json()
    assert body["role"] == "admin"
    assert set(body) == {"user_id", "org_id", "username", "role"}

    b = _register(org, "bob")
    assert b.status_code == 201
    assert b.json()["role"] == "member"
    assert b.json()["org_id"] == body["org_id"]


def test_duplicate_username_conflict():
    org = f"org-{_uid()}"
    assert _register(org, "dup").status_code == 201
    r = _register(org, "dup")
    assert r.status_code == 409
    assert r.json()["code"] == "USERNAME_TAKEN"


def test_same_username_different_org_ok():
    _register(f"org-{_uid()}", "same")
    r = _register(f"org-{_uid()}", "same")
    assert r.status_code == 201


def test_login_bad_credentials_and_unknown_org():
    org = f"org-{_uid()}"
    _register(org, "carol")
    bad = _login(org, "carol", "wrong-password")
    assert bad.status_code == 401 and bad.json()["code"] == "INVALID_CREDENTIALS"
    nouser = _login(org, "ghost")
    assert nouser.status_code == 401 and nouser.json()["code"] == "INVALID_CREDENTIALS"
    noorg = _login(f"missing-{_uid()}", "carol")
    assert noorg.status_code == 401 and noorg.json()["code"] == "INVALID_CREDENTIALS"


def test_access_token_lifetime_is_900_seconds():
    org = f"org-{_uid()}"
    _register(org, "dana")
    token = _login(org, "dana").json()["access_token"]
    claims = jwt.decode(token, options={"verify_signature": False})
    assert claims["type"] == "access"
    assert claims["exp"] - claims["iat"] == 900


def test_login_returns_token_pair_shape():
    org = f"org-{_uid()}"
    _register(org, "erin")
    body = _login(org, "erin").json()
    assert set(body) == {"access_token", "refresh_token", "token_type"}
    assert body["token_type"] == "bearer"


def test_missing_and_malformed_tokens_rejected():
    assert client.get("/rooms").status_code == 401  # no header
    assert client.get("/rooms", headers={"Authorization": "Bearer garbage"}).status_code == 401
    assert client.get("/rooms", headers={"Authorization": "Basic abc"}).status_code == 401


def test_refresh_token_cannot_be_used_as_access_token():
    org = f"org-{_uid()}"
    _register(org, "frank")
    refresh = _login(org, "frank").json()["refresh_token"]
    # Presenting a refresh token where an access token is expected -> 401.
    assert client.get("/rooms", headers=_headers(refresh)).status_code == 401


def test_logout_invalidates_access_token():
    org = f"org-{_uid()}"
    _register(org, "gary")
    token = _login(org, "gary").json()["access_token"]
    h = _headers(token)
    assert client.get("/rooms", headers=h).status_code == 200
    assert client.post("/auth/logout", headers=h).status_code == 200
    assert client.get("/rooms", headers=h).status_code == 401


def test_refresh_rotates_and_is_single_use():
    org = f"org-{_uid()}"
    _register(org, "helen")
    tokens = _login(org, "helen").json()
    r1 = client.post("/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert r1.status_code == 200
    new = r1.json()
    assert new["access_token"] != tokens["access_token"]
    assert new["refresh_token"] != tokens["refresh_token"]
    # Reusing the consumed refresh token -> 401.
    reuse = client.post("/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert reuse.status_code == 401
    # The freshly issued refresh token still works.
    assert client.post("/auth/refresh", json={"refresh_token": new["refresh_token"]}).status_code == 200


# --------------------------------------------------------------------------- #
# Rooms & authorization                                                        #
# --------------------------------------------------------------------------- #
def test_member_cannot_create_room():
    org, admin_h = _admin_ctx()
    _, member_h = _member_ctx(org)
    r = client.post(
        "/rooms",
        json={"name": "nope", "capacity": 2, "hourly_rate_cents": 500},
        headers=member_h,
    )
    assert r.status_code == 403 and r.json()["code"] == "FORBIDDEN"


def test_rooms_are_org_scoped():
    _, admin_a = _admin_ctx()
    _make_room(admin_a)
    _, admin_b = _admin_ctx()
    # Org B sees none of org A's rooms.
    assert client.get("/rooms", headers=admin_b).json() == []


def test_room_object_shape():
    _, headers = _admin_ctx()
    rid = _make_room(headers, rate=750, capacity=6)
    room = next(r for r in client.get("/rooms", headers=headers).json() if r["id"] == rid)
    assert set(room) == {"id", "org_id", "name", "capacity", "hourly_rate_cents"}
    assert room["capacity"] == 6 and room["hourly_rate_cents"] == 750


# --------------------------------------------------------------------------- #
# Booking creation & validation                                               #
# --------------------------------------------------------------------------- #
def test_booking_price_is_rate_times_hours():
    _, headers = _admin_ctx()
    rid = _make_room(headers, rate=1500)
    r = _book(headers, rid, 50, 53)  # 3 hours
    assert r.status_code == 201
    assert r.json()["price_cents"] == 4500
    assert set(r.json()) >= {
        "id", "reference_code", "room_id", "user_id",
        "start_time", "end_time", "status", "price_cents", "created_at",
    }
    assert r.json()["status"] == "confirmed"


def test_response_datetimes_have_utc_designator():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    r = _book(headers, rid, 50, 51)
    assert r.json()["start_time"].endswith("+00:00")
    assert r.json()["end_time"].endswith("+00:00")


def test_booking_window_validation():
    _, headers = _admin_ctx()
    rid = _make_room(headers)

    def code(resp):
        return resp.status_code, resp.json().get("code")

    # start in the past
    past = client.post(
        "/bookings",
        json={"room_id": rid, "start_time": _future(-2), "end_time": _future(2)},
        headers=headers,
    )
    assert code(past) == (400, "INVALID_BOOKING_WINDOW")

    # zero duration (end == start)
    assert code(_book(headers, rid, 50, 50)) == (400, "INVALID_BOOKING_WINDOW")

    # end before start
    assert code(_book(headers, rid, 52, 50)) == (400, "INVALID_BOOKING_WINDOW")

    # duration > 8h
    assert code(_book(headers, rid, 50, 59)) == (400, "INVALID_BOOKING_WINDOW")

    # non-whole-hour duration (90 minutes)
    ninety = client.post(
        "/bookings",
        json={
            "room_id": rid,
            "start_time": _future_dt(50).isoformat(),
            "end_time": (_future_dt(50) + timedelta(minutes=90)).isoformat(),
        },
        headers=headers,
    )
    assert code(ninety) == (400, "INVALID_BOOKING_WINDOW")

    # malformed datetime -> 400, not 500
    malformed = client.post(
        "/bookings",
        json={"room_id": rid, "start_time": "not-a-date", "end_time": _future(52)},
        headers=headers,
    )
    assert code(malformed) == (400, "INVALID_BOOKING_WINDOW")


def test_booking_min_and_max_duration_boundaries():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    assert _book(headers, rid, 50, 51).status_code == 201   # 1h min ok
    rid2 = _make_room(headers)
    assert _book(headers, rid2, 50, 58).status_code == 201  # 8h max ok


def test_booking_timezone_offset_converted_to_utc():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    tz = timezone(timedelta(hours=5))
    start_utc = _future_dt(50)
    end_utc = _future_dt(52)
    r = client.post(
        "/bookings",
        json={
            "room_id": rid,
            "start_time": start_utc.astimezone(tz).isoformat(),  # same instant, +05:00
            "end_time": end_utc.astimezone(tz).isoformat(),
        },
        headers=headers,
    )
    assert r.status_code == 201
    # Stored/returned time must be the UTC instant, not the wall-clock +05:00 value.
    assert r.json()["start_time"] == start_utc.isoformat()
    assert r.json()["end_time"] == end_utc.isoformat()


def test_booking_unknown_room():
    _, headers = _admin_ctx()
    r = _book(headers, 999999, 50, 51)
    assert r.status_code == 404 and r.json()["code"] == "ROOM_NOT_FOUND"


def test_booking_cross_org_room_is_not_found():
    _, admin_a = _admin_ctx()
    rid = _make_room(admin_a)
    _, admin_b = _admin_ctx()
    r = _book(admin_b, rid, 50, 51)
    assert r.status_code == 404 and r.json()["code"] == "ROOM_NOT_FOUND"


# --------------------------------------------------------------------------- #
# Double booking & back-to-back                                               #
# --------------------------------------------------------------------------- #
def test_overlap_conflict_and_back_to_back_allowed():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    assert _book(headers, rid, 50, 52).status_code == 201
    overlap = _book(headers, rid, 51, 53)
    assert overlap.status_code == 409 and overlap.json()["code"] == "ROOM_CONFLICT"
    # back-to-back (starts exactly when the previous ends) is allowed
    assert _book(headers, rid, 52, 54).status_code == 201
    # and the slot just before, ending exactly at the first start, is allowed
    assert _book(headers, rid, 49, 50).status_code == 201


# --------------------------------------------------------------------------- #
# Quota                                                                        #
# --------------------------------------------------------------------------- #
def test_member_quota_limit():
    org, admin_h = _admin_ctx()
    _, member_h = _member_ctx(org)
    rid = _make_room(admin_h)
    # Member: 3 confirmed bookings within (now, now+24h] allowed, 4th rejected.
    assert _book(member_h, rid, 2, 3).status_code == 201
    assert _book(member_h, rid, 4, 5).status_code == 201
    assert _book(member_h, rid, 6, 7).status_code == 201
    fourth = _book(member_h, rid, 8, 9)
    assert fourth.status_code == 409 and fourth.json()["code"] == "QUOTA_EXCEEDED"
    # Bookings beyond the 24h window are not subject to the quota.
    assert _book(member_h, rid, 50, 51).status_code == 201
    # (Admin quota behavior intentionally not asserted — Rule 4's "member"
    # wording is ambiguous; base behavior applies the quota to all users. See
    # bug_report.md #24.)


def test_cancelled_booking_frees_quota():
    org, admin_h = _admin_ctx()
    _, member_h = _member_ctx(org)
    rid = _make_room(admin_h)
    ids = []
    for h in (2, 4, 6):
        r = _book(member_h, rid, h, h + 1)
        assert r.status_code == 201
        ids.append(r.json()["id"])
    assert _book(member_h, rid, 8, 9).status_code == 409  # quota full
    # Cancel one -> a slot frees up.
    assert client.post(f"/bookings/{ids[0]}/cancel", headers=member_h).status_code == 200
    assert _book(member_h, rid, 8, 9).status_code == 201


# --------------------------------------------------------------------------- #
# Booking visibility & detail                                                 #
# --------------------------------------------------------------------------- #
def test_member_cannot_read_other_members_booking():
    org, admin_h = _admin_ctx()
    _, m1 = _member_ctx(org)
    _, m2 = _member_ctx(org)
    rid = _make_room(admin_h)
    bid = _book(m1, rid, 50, 51).json()["id"]
    # Other member -> 404 (as if it doesn't exist).
    r = client.get(f"/bookings/{bid}", headers=m2)
    assert r.status_code == 404 and r.json()["code"] == "BOOKING_NOT_FOUND"
    # Admin of same org can read it.
    assert client.get(f"/bookings/{bid}", headers=admin_h).status_code == 200


def test_booking_detail_returns_start_time_not_created_at():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    created = _book(headers, rid, 50, 52).json()
    detail = client.get(f"/bookings/{created['id']}", headers=headers).json()
    assert detail["start_time"] == created["start_time"]
    assert detail["start_time"] != detail["created_at"]
    assert "refunds" in detail and detail["refunds"] == []


def test_cross_org_booking_read_is_not_found():
    _, admin_a = _admin_ctx()
    rid = _make_room(admin_a)
    bid = _book(admin_a, rid, 50, 51).json()["id"]
    _, admin_b = _admin_ctx()
    r = client.get(f"/bookings/{bid}", headers=admin_b)
    assert r.status_code == 404 and r.json()["code"] == "BOOKING_NOT_FOUND"


# --------------------------------------------------------------------------- #
# Cancellation & refunds                                                       #
# --------------------------------------------------------------------------- #
def test_refund_tiers():
    _, headers = _admin_ctx()
    # 100% : >= 48h notice
    rid = _make_room(headers, rate=1000)
    b = _book(headers, rid, 50, 52).json()  # price 2000
    r = client.post(f"/bookings/{b['id']}/cancel", headers=headers).json()
    assert r["refund_percent"] == 100 and r["refund_amount_cents"] == 2000
    assert r["status"] == "cancelled"

    # 50% : 24h <= notice < 48h
    rid2 = _make_room(headers, rate=1000)
    b2 = _book(headers, rid2, 30, 32).json()  # price 2000, notice 30h
    r2 = client.post(f"/bookings/{b2['id']}/cancel", headers=headers).json()
    assert r2["refund_percent"] == 50 and r2["refund_amount_cents"] == 1000

    # 0% : notice < 24h
    rid3 = _make_room(headers, rate=1000)
    b3 = _book(headers, rid3, 5, 7).json()  # price 2000, notice 5h
    r3 = client.post(f"/bookings/{b3['id']}/cancel", headers=headers).json()
    assert r3["refund_percent"] == 0 and r3["refund_amount_cents"] == 0


def test_refund_rounds_half_cent_up_and_matches_ledger():
    _, headers = _admin_ctx()
    # 50% of 999 = 499.5 -> must round half-up to 500 (not banker's 500/499).
    rid = _make_room(headers, rate=999)
    b = _book(headers, rid, 30, 31).json()  # price 999, notice 30h -> 50%
    r = client.post(f"/bookings/{b['id']}/cancel", headers=headers).json()
    assert r["refund_percent"] == 50
    assert r["refund_amount_cents"] == 500
    # The cancel response amount must equal the stored RefundLog amount.
    detail = client.get(f"/bookings/{b['id']}", headers=headers).json()
    assert len(detail["refunds"]) == 1
    assert detail["refunds"][0]["amount_cents"] == r["refund_amount_cents"]
    assert detail["refunds"][0]["status"] == "processed"


def test_cancel_already_cancelled_conflicts():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    bid = _book(headers, rid, 50, 51).json()["id"]
    assert client.post(f"/bookings/{bid}/cancel", headers=headers).status_code == 200
    again = client.post(f"/bookings/{bid}/cancel", headers=headers)
    assert again.status_code == 409 and again.json()["code"] == "ALREADY_CANCELLED"


def test_member_cannot_cancel_others_booking_admin_can():
    org, admin_h = _admin_ctx()
    _, m1 = _member_ctx(org)
    _, m2 = _member_ctx(org)
    rid = _make_room(admin_h)
    bid = _book(m1, rid, 50, 51).json()["id"]
    # Another member -> 404 (not FORBIDDEN, per booking-visibility rule).
    assert client.post(f"/bookings/{bid}/cancel", headers=m2).status_code == 404
    # Admin can cancel it.
    assert client.post(f"/bookings/{bid}/cancel", headers=admin_h).status_code == 200


# --------------------------------------------------------------------------- #
# Pagination                                                                   #
# --------------------------------------------------------------------------- #
def test_pagination_order_limit_and_no_skips():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    starts = [50, 52, 54, 56, 58]
    for h in starts:
        assert _book(headers, rid, h, h + 1).status_code == 201

    full = client.get("/bookings", headers=headers, params={"limit": 100}).json()
    assert full["total"] == 5
    times = [b["start_time"] for b in full["items"]]
    assert times == sorted(times)  # ascending by start time

    p1 = client.get("/bookings", headers=headers, params={"page": 1, "limit": 2}).json()
    p2 = client.get("/bookings", headers=headers, params={"page": 2, "limit": 2}).json()
    p3 = client.get("/bookings", headers=headers, params={"page": 3, "limit": 2}).json()
    assert p1["limit"] == 2 and len(p1["items"]) == 2
    ids = [b["id"] for b in p1["items"] + p2["items"] + p3["items"]]
    assert len(ids) == 5 and len(set(ids)) == 5  # no repeats, no skips
    assert ids == [b["id"] for b in full["items"]]


# --------------------------------------------------------------------------- #
# Availability & stats                                                          #
# --------------------------------------------------------------------------- #
def test_availability_reflects_create_and_cancel_immediately():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    start = _future_dt(50)
    date = start.date().isoformat()
    created = _book(headers, rid, 50, 52).json()

    avail = client.get(f"/rooms/{rid}/availability", headers=headers, params={"date": date}).json()
    assert avail["room_id"] == rid and avail["date"] == date
    assert avail["busy"] == [{"start_time": created["start_time"], "end_time": created["end_time"]}]

    client.post(f"/bookings/{created['id']}/cancel", headers=headers)
    after = client.get(f"/rooms/{rid}/availability", headers=headers, params={"date": date}).json()
    assert after["busy"] == []  # cache invalidated on cancel


def test_room_stats_track_confirmed_count_and_revenue():
    _, headers = _admin_ctx()
    rid = _make_room(headers, rate=1000)
    zero = client.get(f"/rooms/{rid}/stats", headers=headers).json()
    assert zero == {"room_id": rid, "total_confirmed_bookings": 0, "total_revenue_cents": 0}

    b = _book(headers, rid, 50, 52).json()  # price 2000
    one = client.get(f"/rooms/{rid}/stats", headers=headers).json()
    assert one["total_confirmed_bookings"] == 1 and one["total_revenue_cents"] == 2000

    client.post(f"/bookings/{b['id']}/cancel", headers=headers)
    back = client.get(f"/rooms/{rid}/stats", headers=headers).json()
    assert back["total_confirmed_bookings"] == 0 and back["total_revenue_cents"] == 0


# --------------------------------------------------------------------------- #
# Admin usage report & export                                                  #
# --------------------------------------------------------------------------- #
def test_usage_report_includes_zero_rooms_and_reflects_state():
    _, headers = _admin_ctx()
    rid_a = _make_room(headers, rate=1000)
    rid_b = _make_room(headers, rate=1000)  # stays empty
    start = _future_dt(50)
    _book(headers, rid_a, 50, 52)  # revenue 2000
    day = start.date().isoformat()

    rep = client.get("/admin/usage-report", headers=headers, params={"from": day, "to": day}).json()
    assert rep["from"] == day and rep["to"] == day
    rooms = {r["room_id"]: r for r in rep["rooms"]}
    assert rooms[rid_a]["confirmed_bookings"] == 1 and rooms[rid_a]["revenue_cents"] == 2000
    # Zero-booking room still present.
    assert rooms[rid_b]["confirmed_bookings"] == 0 and rooms[rid_b]["revenue_cents"] == 0
    assert set(rooms[rid_a]) == {"room_id", "room_name", "confirmed_bookings", "revenue_cents"}


def test_usage_report_requires_admin():
    org, admin_h = _admin_ctx()
    _, member_h = _member_ctx(org)
    day = _future_dt(50).date().isoformat()
    r = client.get("/admin/usage-report", headers=member_h, params={"from": day, "to": day})
    assert r.status_code == 403 and r.json()["code"] == "FORBIDDEN"


def test_export_header_is_exact_and_org_scoped():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    _book(headers, rid, 50, 51)
    resp = client.get("/admin/export", headers=headers, params={"include_all": True})
    assert resp.status_code == 200
    header = resp.text.splitlines()[0]
    assert header == "id,reference_code,room_id,user_id,start_time,end_time,status,price_cents"
    assert len(resp.text.strip().splitlines()) >= 2  # header + at least one row


def test_export_cross_org_room_returns_header_only():
    _, admin_a = _admin_ctx()
    rid = _make_room(admin_a)
    _book(admin_a, rid, 50, 51)
    _, admin_b = _admin_ctx()
    # Org B asking for org A's room id must not leak rows.
    resp = client.get(
        "/admin/export", headers=admin_b, params={"room_id": rid, "include_all": True}
    )
    assert resp.status_code == 200
    lines = [ln for ln in resp.text.splitlines() if ln.strip()]
    assert len(lines) == 1  # header only


# --------------------------------------------------------------------------- #
# Concurrency / technical                                                      #
# --------------------------------------------------------------------------- #
def _parallel(fn, n, workers=None):
    workers = workers or n
    with ThreadPoolExecutor(max_workers=workers) as ex:
        return [f.result(timeout=30) for f in [ex.submit(fn, i) for i in range(n)]]


def test_concurrent_double_booking_only_one_wins():
    _, headers = _admin_ctx()  # admin: quota-exempt
    rid = _make_room(headers)
    results = _parallel(lambda _i: _book(headers, rid, 60, 62).status_code, 10)
    assert results.count(201) == 1
    assert results.count(409) == 9


def test_concurrent_quota_allows_exactly_three():
    org, admin_h = _admin_ctx()
    _, member_h = _member_ctx(org)
    rid = _make_room(admin_h)
    # 5 non-overlapping slots within the 24h window -> only quota can reject.
    slots = [(2, 3), (4, 5), (6, 7), (8, 9), (10, 11)]
    results = _parallel(lambda i: _book(member_h, rid, *slots[i]).status_code, 5)
    assert results.count(201) == 3
    assert results.count(409) == 2


def test_concurrent_bookings_have_unique_reference_codes():
    _, headers = _admin_ctx()  # admin: quota-exempt
    rid = _make_room(headers)
    slots = [(50 + 2 * i, 51 + 2 * i) for i in range(10)]  # distinct, non-overlapping

    def book(i):
        r = _book(headers, rid, *slots[i])
        return r.json().get("reference_code")

    codes = _parallel(book, 10)
    assert all(codes) and len(set(codes)) == 10


def test_concurrent_cancel_produces_single_refund():
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    bid = _book(headers, rid, 50, 52).json()["id"]
    results = _parallel(
        lambda _i: client.post(f"/bookings/{bid}/cancel", headers=headers).status_code, 8
    )
    assert results.count(200) == 1
    assert results.count(409) == 7
    detail = client.get(f"/bookings/{bid}", headers=headers).json()
    assert len(detail["refunds"]) == 1  # exactly one RefundLog row


def test_concurrent_refresh_token_reuse_only_one_wins():
    org = f"org-{_uid()}"
    _register(org, "iris")
    refresh = _login(org, "iris").json()["refresh_token"]
    results = _parallel(
        lambda _i: client.post("/auth/refresh", json={"refresh_token": refresh}).status_code, 10
    )
    assert results.count(200) == 1
    assert results.count(401) == 9


def test_concurrent_duplicate_registration_only_one_wins():
    org = f"org-{_uid()}"
    results = _parallel(lambda _i: _register(org, "raceuser").status_code, 10)
    assert results.count(201) == 1
    assert results.count(409) == 9
    assert 500 not in results


def test_rate_limit_blocks_21st_request():
    _, headers = _admin_ctx()  # fresh user -> clean bucket
    rid = _make_room(headers)
    # Requests fail validation (past start) but still count toward the limit,
    # since the rate check runs first. First 20 pass the limiter; the 21st 429s.
    def attempt(_i):
        return client.post(
            "/bookings",
            json={"room_id": rid, "start_time": _future(-1), "end_time": _future(2)},
            headers=headers,
        ).status_code

    codes = [attempt(i) for i in range(21)]
    assert codes[:20] == [400] * 20
    assert codes[20] == 429


def test_concurrent_create_and_cancel_do_not_deadlock():
    # Notification locks are acquired in the same order on both paths; a
    # create and a cancel running at once must both complete, not hang.
    _, headers = _admin_ctx()
    rid = _make_room(headers)
    existing = _book(headers, rid, 50, 52).json()["id"]

    with ThreadPoolExecutor(max_workers=2) as ex:
        f_cancel = ex.submit(lambda: client.post(f"/bookings/{existing}/cancel", headers=headers))
        f_create = ex.submit(lambda: _book(headers, rid, 60, 62))
        assert f_cancel.result(timeout=15).status_code == 200
        assert f_create.result(timeout=15).status_code == 201
