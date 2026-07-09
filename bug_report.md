# Bug Report — CoWork API

Each bug is checked against the Business Rules in `CLAUDE.md`. All fixes preserve the
API contract (paths, status codes, error codes, JSON field names) exactly.

---

## 1. Access token lifetime computed 60x too large — **Easy**

**File:** `app/auth.py:50`

**Bug:** `create_access_token` built the expiry as
`timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES * 60)`. With
`ACCESS_TOKEN_EXPIRE_MINUTES = 15`, this produced a 900-*minute* (54,000 second)
lifetime instead of 900 seconds, violating Rule 8 ("Access tokens expire in
exactly 900 seconds").

**Fix:** Removed the stray `* 60`: `timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)`.

---

## 2. Logout never actually revokes the access token — **Medium**

**File:** `app/auth.py:86, 97`

**Bug:** `revoke_access_token` stored the token's `jti` claim in `_revoked_tokens`,
but `get_token_payload` checked membership using `payload.get("sub")` (the user
id) instead of `payload.get("jti")`. Since a user id never matches a UUID jti,
the revoked-token check could never trigger — logout was a no-op and a
"revoked" access token kept working, violating Rule 8 ("Logout immediately
invalidates the presented access token").

**Fix:** Check `payload.get("jti") in _revoked_tokens`.

---

## 3. Refresh tokens are not single-use — **Hard**

**Files:** `app/auth.py`, `app/routers/auth.py` (`refresh` endpoint)

**Bug:** There was no tracking of used refresh tokens at all. `POST
/auth/refresh` decoded the presented refresh token and issued new tokens, but
never invalidated the one just used, so the same refresh token could be
replayed indefinitely. Violates Rule 8 ("Refresh tokens are single-use: … reuse
→ 401").

**Fix:** Added a `_revoked_refresh_tokens` set with `revoke_refresh_token()` /
`is_refresh_token_revoked()` helpers in `app/auth.py`, mirroring the access-token
mechanism. The `/auth/refresh` handler now rejects an already-used token's
`jti` with `401 UNAUTHORIZED` and marks the presented token's `jti` as revoked
before returning the new token pair.

---

## 4. Duplicate username on register silently "succeeds" — **Easy**

**File:** `app/routers/auth.py:32-43`

**Bug:** When a username already existed within the org, `register` returned
the *existing* user's info with `201 Created` instead of rejecting the
request. This let anyone "register" as an existing user without a password
check, and violated Rule 15 ("A duplicate username within the org →
`409 USERNAME_TAKEN`").

**Fix:** Raise `AppError(409, "USERNAME_TAKEN", …)` when a user with that
username already exists in the org.

---

## 5. `GET /bookings/{id}` leaks other members' bookings — **Medium**

**File:** `app/routers/bookings.py` (`get_booking`)

**Bug:** The handler scoped the query by `Room.org_id == user.org_id` only —
it never checked booking ownership for non-admins, unlike `cancel_booking`,
which does. Any member could read any other member's booking (including
another member's refund history) as long as it was in the same org, and only
had to guess a booking id. Violates Rule 10 ("Members may read and cancel only
their own bookings … → `404 BOOKING_NOT_FOUND`").

**Fix:** Added the same ownership check used in `cancel_booking`:
`if user.role != "admin" and booking.user_id != user.id: raise 404`.

---

## 6. `GET /bookings/{id}` returns the wrong `start_time` — **Easy**

**File:** `app/routers/bookings.py:166` (pre-fix)

**Bug:** After building the correct response via `serialize_booking`, the
handler overwrote it with `response["start_time"] = iso_utc(booking.created_at)`,
so the response showed the booking's *creation* timestamp instead of its
actual start time.

**Fix:** Deleted the overwrite; `serialize_booking` already sets the correct
`start_time`.

---

## 7. Booking start-time check has a 5-minute grace window — **Easy**

**File:** `app/routers/bookings.py:86` (pre-fix)

**Bug:** `if start <= now - timedelta(seconds=300)` allowed `start_time` up to
5 minutes in the past to be accepted. Rule 2 requires `start_time` be
"strictly in the future at request time — no grace window."

**Fix:** `if start <= now:`.

---

## 8. Minimum booking duration never enforced — **Easy**

**File:** `app/routers/bookings.py:89-94` (pre-fix)

**Bug:** `MIN_DURATION_HOURS = 1` was defined but never used. Only the maximum
(`duration_hours > MAX_DURATION_HOURS`) was checked, so a booking with
`end_time == start_time` (0-hour duration) passed validation, violating Rule 2
("Duration must be a whole number of hours, minimum 1 … `end_time` must be
strictly after `start_time`").

**Fix:** Combined bounds check:
`if duration_hours < MIN_DURATION_HOURS or duration_hours > MAX_DURATION_HOURS: raise INVALID_BOOKING_WINDOW`.

---

## 9. Back-to-back bookings incorrectly rejected as conflicts — **Medium**

**File:** `app/routers/bookings.py:50` (`_has_conflict`)

**Bug:** The overlap test used `b.start_time <= end and start <= b.end_time`
(non-strict `<=`). Rule 3 defines overlap as `existing.start < new.end AND
new.start < existing.end` (strict `<`), and explicitly states "back-to-back
bookings are allowed." With `<=`, a new booking starting exactly when another
ends (e.g. 10:00–11:00 followed by 11:00–12:00) was flagged as a
`409 ROOM_CONFLICT`.

**Fix:** Changed both comparisons to strict `<`.

---

## 10. Double-booking race condition under concurrent requests — **Hard**

**File:** `app/routers/bookings.py` (`_has_conflict` / `create_booking`)

**Bug:** The conflict check (`_has_conflict`, with a deliberate 0.12s
simulated-latency pause between reading existing bookings and returning) and
the subsequent insert were not atomic. Two concurrent requests for the same
slot could both pass the conflict check before either committed, both
inserting overlapping confirmed bookings. Violates Rule 3 ("Must hold under
concurrent requests").

**Fix:** Wrapped the conflict check, quota check, and insert+commit in a
module-level `threading.Lock()` (`_booking_lock`), serializing the whole
critical section. Verified with 10 concurrent identical-slot requests:
exactly one `201`, nine `409 ROOM_CONFLICT`.

*(ponytail: one process-wide lock, not per-room — simplest fix that's
correct; split into per-room locks if throughput ever becomes a bottleneck.)*

---

## 11. Quota race condition under concurrent requests — **Hard**

**File:** `app/routers/bookings.py` (`_check_quota`)

**Bug:** Same shape as #10: the quota count query (with a deliberate 0.1s
pause) and the booking insert were not atomic, so multiple concurrent
requests could each see a count below the limit and all insert, exceeding the
3-booking quota. Violates Rule 4 ("Must hold under concurrent requests").

**Fix:** Covered by the same `_booking_lock` added for #10 (the quota check
happens inside the same critical section as the conflict check and insert).
Verified with 5 concurrent requests within the 24h window: exactly 3 succeed,
2 return `409 QUOTA_EXCEEDED`.

---

## 12. Refund tier logic: wrong boundary and missing 0% tier — **Medium**

**File:** `app/routers/bookings.py:201-206` (pre-fix)

**Bug:**
```python
if notice_hours > 48:
    refund_percent = 100
elif notice >= timedelta(hours=24):
    refund_percent = 50
else:
    refund_percent = 50   # <-- should be 0
```
Two problems: (a) the 100% boundary used `> 48` instead of `>= 48`, so a
cancellation at exactly 48 hours' notice got only 50%; (b) the `else` branch
— meant for notice `< 24h` — also returned 50%, so the entire 0%-refund tier
from Rule 6 was unreachable. No cancellation could ever get less than a 50%
refund.

**Fix:**
```python
if notice >= timedelta(hours=48):
    refund_percent = 100
elif notice >= timedelta(hours=24):
    refund_percent = 50
else:
    refund_percent = 0
```

---

## 13. Refund amount rounding inconsistent between response and RefundLog — **Medium**

**Files:** `app/routers/bookings.py:208` (pre-fix), `app/services/refunds.py:14-17` (pre-fix)

**Bug:** The cancel response computed
`refund_amount_cents = round(booking.price_cents * (refund_percent / 100.0))`
(Python's banker's rounding, round-half-to-even), while `log_refund` computed
its own amount independently via
`int((price_cents/100.0) * (percent/100.0) * 100)` (plain truncation). These
two float-based calculations could disagree on the same input (e.g.
`price_cents=999, percent=50` → response `500`, log `499`), violating Rule 6
("the amount returned by the cancel response must equal the amount stored in
the RefundLog"). Neither implementation actually rounded half-cents up as
required.

**Fix:** Compute the amount once in `cancel_booking` using integer arithmetic
that rounds half-up exactly: `(price_cents * refund_percent + 50) // 100`.
Pass that single value into `log_refund`, which now just persists the given
`amount_cents` instead of recomputing it — guaranteeing the response and the
ledger entry always agree.

---

## 14. Concurrent cancel of the same booking could create duplicate refunds — **Hard**

**File:** `app/routers/bookings.py` (`cancel_booking`)

**Bug:** Two problems compounded here:
1. The status check, refund logging (with a deliberate 0.12s pause), and
   status update were not atomic, so two concurrent cancel requests for the
   same booking could both read `status == "confirmed"` and both proceed.
2. After wrapping the critical section in `_booking_lock` (fix for the above),
   a second, subtler bug remained: each request loads its own `Booking` ORM
   object from its own per-request `Session` (`get_db`). The lock serializes
   *execution order*, but a thread that queued behind the lock was still
   checking `booking.status` on the object it loaded *before* acquiring the
   lock — which does not reflect another session's already-committed change.
   Both threads could still see `status == "confirmed"` inside the lock and
   both log a refund, violating Rule 6 ("A cancelled booking has exactly one
   RefundLog entry").

**Fix:** Wrapped the status-check → refund-log → status-update sequence in
`_booking_lock`, **and** added `db.refresh(booking)` immediately after
acquiring the lock so each thread re-reads the authoritative current status
from the database before deciding whether to proceed. Verified with 8
concurrent cancel requests on the same booking: exactly one `200`, seven
`409 ALREADY_CANCELLED`, exactly one `RefundLog` row.

---

## 15. Cancelling a booking leaves the availability cache stale — **Easy**

**File:** `app/routers/bookings.py` (`cancel_booking`)

**Bug:** `create_booking` calls `cache.invalidate_availability(...)` after
inserting a booking, but `cancel_booking` never called it after cancelling
one. `GET /rooms/{id}/availability` could keep reporting a cancelled booking's
slot as busy until the cache happened to be invalidated for an unrelated
reason. Violates Rule 13 ("reflecting the current state immediately").

**Fix:** Added `cache.invalidate_availability(booking.room_id,
booking.start_time.date().isoformat())` alongside the existing
`cache.invalidate_report(...)` call in `cancel_booking`.

---

## 16. Pagination: wrong offset, hardcoded limit, wrong sort order — **Medium**

**File:** `app/routers/bookings.py:137-139` (pre-fix)

**Bug:** Three separate bugs in `list_bookings`:
- `.order_by(Booking.start_time.desc(), …)` sorted **descending**, but Rule 11
  requires ascending order by start time.
- `.offset(page * limit)` should have been `(page - 1) * limit` — page 1 was
  skipping the first `limit` items entirely (items 1..limit were never
  returned by any page).
- `.limit(10)` was hardcoded, ignoring the caller's `limit` query parameter,
  so requesting `limit=50` still returned at most 10 items.

**Fix:**
```python
base.order_by(Booking.start_time.asc(), Booking.id.asc())
    .offset((page - 1) * limit)
    .limit(limit)
```

---

## 17. Reference-code counter race allows duplicate codes — **Hard**

**File:** `app/services/reference.py`

**Bug:** `next_reference_code` read `_counter["value"]`, paused 0.12s
(simulated formatting work), then wrote back `current + 1` — a classic
read-pause-write race with no locking. Two concurrent booking creations could
both read the same counter value before either wrote back, issuing the same
reference code twice. Violates Rule 7 ("Every booking's reference code is
unique, including under concurrent creation").

**Fix:** Wrapped the read/pause/write sequence in a module-level
`threading.Lock()`. Verified with 10 concurrent booking creations: 10 unique
reference codes.

---

## 18. Rate limiter bucket race allows exceeding 20 requests/60s — **Hard**

**File:** `app/services/ratelimit.py`

**Bug:** `record_and_check` read the user's bucket, trimmed it, paused 0.1s,
then appended and checked the length — all unguarded. Concurrent requests
from the same user could each read the bucket before any of them wrote it
back, letting more than 20 requests per rolling 60s window pass. Violates
Rule 5 ("Must hold under concurrent requests").

**Fix:** Wrapped the whole read-trim-append-check sequence in a module-level
`threading.Lock()`.

---

## 19. Room stats lost-update race under concurrent create/cancel — **Hard**

**File:** `app/services/stats.py`

**Bug:** `record_create`/`record_cancel` read the current `{count, revenue}`
dict, paused 0.1s, then wrote back a new dict computed from the value read
before the pause — a lost-update race. Concurrent creates/cancels for the
same room could clobber each other's updates, leaving `total_confirmed_bookings`
/ `total_revenue_cents` inconsistent with the actual bookings. Violates Rule
14 ("always consistent with the bookings themselves, including after bursts
of concurrent activity").

**Fix:** Wrapped both functions' read-pause-write sequence in a module-level
`threading.Lock()`.

---

## 20. Notification lock-ordering deadlock — **Hard**

**File:** `app/services/notifications.py`

**Bug:** `notify_created` acquired `_email_lock` and then, nested inside it,
`_audit_lock`. `notify_cancelled` acquired `_audit_lock` and then, nested
inside it, `_email_lock` — the reverse order. If a booking creation and a
booking cancellation ran concurrently on different threads, thread A could
hold `_email_lock` waiting on `_audit_lock` while thread B held `_audit_lock`
waiting on `_email_lock`: a classic lock-ordering deadlock that would hang
both requests forever. Violates Rule 16 ("no combination of concurrent valid
requests may hang the service").

**Fix:** Removed the nesting — each function now acquires and releases
`_email_lock` and `_audit_lock` sequentially (one `with` block at a time)
instead of nesting one inside the other, eliminating the possibility of
circular wait entirely while still serializing each resource individually.

---

## 21. Admin export leaks another org's bookings via `room_id` — **Hard**

**File:** `app/services/export.py`

**Bug:** `generate_export`, when called with `include_all=true` **and** a
`room_id`, routed through `fetch_bookings_raw(db, room_id)`, which filtered
only by `Booking.room_id` — it never checked that the room belonged to the
caller's org (unlike `_fetch_scoped`, used on every other path, which joins
`Room` and filters by `Room.org_id`). An admin could pass another
organization's room id and export that org's bookings via CSV. Violates Rule
9 ("A user … may only ever read or act on data belonging to their own
organization, on every code path. Cross-org resource IDs behave as
non-existent").

**Fix:** Removed the unsafe `fetch_bookings_raw` helper entirely and routed
the `include_all` path through the existing org-scoped `_fetch_scoped(db,
org_id, None, room_id)`, matching the non-`include_all` path. A foreign
`room_id` now yields zero rows (header only), consistent with "cross-org
resource IDs behave as non-existent."

---

## 22. Datetime UTC offsets dropped instead of converted — **Medium**

**File:** `app/timeutils.py`

**Bug:** `parse_input_datetime` did `dt.replace(tzinfo=None)` for offset-aware
inputs, which strips the timezone **without converting the wall-clock time**.
An input like `2026-01-01T12:00:00+02:00` was stored as naive `12:00` instead
of the correct `10:00` UTC. Violates Rule 1 ("Input datetimes carrying a UTC
offset are converted to UTC before storage or comparison"). This also skews
overlap/quota/availability comparisons for any client that sends an offset.

**Fix:** Convert to UTC before dropping the tzinfo:
`dt = dt.astimezone(timezone.utc).replace(tzinfo=None)`.

---

## 23. Usage-report cache not invalidated on booking creation — **Easy**

**File:** `app/routers/bookings.py` (`create_booking`)

**Bug:** `create_booking` invalidated only the availability cache
(`cache.invalidate_availability`), not the usage-report cache. A previously
cached `GET /admin/usage-report` covering the new booking's date range kept
returning stale numbers after a booking was created. Violates Rule 12 ("The
report reflects the current state immediately"). This is the create-side
counterpart of bug #15 (cancel-side availability cache).

**Fix:** Added `cache.invalidate_report(user.org_id)` after a successful
create, mirroring the invalidation already done on the cancel path.

---

## Score summary

| # | Bug | Difficulty | Points |
|---|-----|------------|--------|
| 1 | Access token lifetime x60 | Easy | 3 |
| 2 | Logout checks `sub` not `jti` | Medium | 5 |
| 3 | Refresh tokens not single-use | Hard | 10 |
| 4 | Duplicate username returns 200 | Easy | 3 |
| 5 | `GET /bookings/{id}` leaks other members' bookings | Medium | 5 |
| 6 | `GET /bookings/{id}` wrong `start_time` | Easy | 3 |
| 7 | Booking start-time grace window | Easy | 3 |
| 8 | Minimum duration unenforced | Easy | 3 |
| 9 | Back-to-back bookings rejected | Medium | 5 |
| 10 | Double-booking race | Hard | 10 |
| 11 | Quota race | Hard | 10 |
| 12 | Refund tier logic wrong | Medium | 5 |
| 13 | Refund rounding inconsistent | Medium | 5 |
| 14 | Concurrent cancel double-refund | Hard | 10 |
| 15 | Cancel doesn't invalidate availability cache | Easy | 3 |
| 16 | Pagination broken (offset/limit/order) | Medium | 5 |
| 17 | Reference code race | Hard | 10 |
| 18 | Rate limiter race | Hard | 10 |
| 19 | Stats lost-update race | Hard | 10 |
| 20 | Notification lock-ordering deadlock | Hard | 10 |
| 21 | Admin export cross-org leak | Hard | 10 |
| 22 | Datetime UTC offset dropped, not converted | Medium | 5 |
| 23 | Create doesn't invalidate usage-report cache | Easy | 3 |

**Total: 146 points** (6 Easy × 3 = 18, 7 Medium × 5 = 35, 10 Hard × 10 = 100)

---

## Verification

- `pytest tests/` — passes (existing smoke test).
- Manual end-to-end script exercising: duplicate-username 409, access-token
  900s lifetime, back-to-back bookings, overlap conflict, zero-duration
  rejection, 100%/50%/0% refund tiers, cross-member booking-read 404, logout
  invalidation, refresh single-use, pagination ordering/limit — all pass.
- Concurrency stress tests (`ThreadPoolExecutor`, 5–10 concurrent workers):
  double-booking → exactly one `201`; quota → exactly 3 of 5 succeed;
  concurrent cancel of one booking → exactly one `200` and exactly one
  `RefundLog` row; 10 concurrent creates → 10 unique reference codes — all
  pass.
- Cross-org export leak test: exporting a foreign org's `room_id` with
  `include_all=true` now returns an empty CSV body (header only).
