#!/usr/bin/env bash
# =============================================================================
# CoWork API — curl test suite (all functional test cases from CoWork_Test_Cases.md)
# -----------------------------------------------------------------------------
# Usage (Git Bash / WSL / Linux / macOS):
#     docker compose up --build -d      # start the API on :8000 with a FRESH db
#     ./cowork_tests.sh                 # run all tests top-to-bottom
#     ./cowork_tests.sh 2>&1 | tee out.txt
#
# Requires: bash, curl, python (any of `python`/`python3`/`py`) for JSON parsing.
#
# For each test it prints:  [TC-ID]  <what it does>
#                           EXPECT : <expected status + body/notes>
#                           ACTUAL : <http status>  <response body>
# Diff EXPECT vs ACTUAL by eye.  Time-sensitive tests use LIVE `now` so they
# work regardless of the wall clock.  State is isolated with per-section rooms
# so numeric expectations stay exact even if you re-run.
#
# NOTE ON DATETIME FORMAT: this implementation emits `+00:00` (via isoformat()),
# not `Z`.  The contract permits either, so EXPECT lines below use `+00:00`.
# =============================================================================

set -u
BASE="${BASE:-http://localhost:8000}"

# ---- pick a python ----------------------------------------------------------
PY=""
for c in python python3 py; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
[ -z "$PY" ] && { echo "ERROR: need python for JSON parsing"; exit 1; }

# ---- helpers ----------------------------------------------------------------
# jget '<expr>'  reads stdin JSON, prints python expression on the loaded obj `d`
jget() { "$PY" -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

# call METHOD PATH [json-body] [auth-token]  -> sets global CODE and BODY
call() {
  local method="$1" path="$2" body="${3:-}" tok="${4:-}"
  local args=(-s -X "$method" -w $'\n%{http_code}' "$BASE$path")
  [ -n "$tok" ]  && args+=(-H "Authorization: Bearer $tok")
  if [ -n "$body" ]; then args+=(-H "Content-Type: application/json" -d "$body"); fi
  local out; out="$(curl "${args[@]}")"
  CODE="$(printf '%s' "$out" | tail -n1)"
  BODY="$(printf '%s' "$out" | sed '$d')"
}

# same but for raw (CSV) endpoints — keeps body verbatim
callraw() { call "$@"; }

hdr()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
tc()   { printf '\n\033[1;33m[%s]\033[0m %s\n' "$1" "$2"; }
exp()  { printf '  EXPECT : %s\n' "$*"; }
act()  { printf '  ACTUAL : %s  %s\n' "$CODE" "$BODY"; }

# ---- live time anchors (UTC) ------------------------------------------------
# Portable: compute with python (works on GNU date, BSD/macOS date, anywhere).
# Accepts specs like: "now", "+2 hours", "-1 hours", "+5 days",
#                     "+3 hours +30 minutes", "+90 seconds".
_shift() { "$PY" -c "
import datetime,re,sys
now=datetime.datetime.now(datetime.timezone.utc)
spec=sys.argv[1].strip()
for sign,num,unit in re.findall(r'([+-])\s*(\d+)\s*(day|hour|minute|second)s?', spec):
    n=int(num)*(1 if sign=='+' else -1)
    now+=datetime.timedelta(**{unit+'s':n})
print(now.strftime(sys.argv[2]))
" "$1" "$2"; }
iso() { _shift "$1" '%Y-%m-%dT%H:%M:%SZ'; }                 # e.g. iso "+3 hours"
day() { _shift "$1" '%Y-%m-%d'; }                           # e.g. day "+5 days"
# naive (no designator) UTC wall-clock digits, used for offset-input tests
iso_naive() { _shift "$1" '%Y-%m-%dT%H:%M:%S'; }

T_2H=$(iso "+2 hours");  T_3H=$(iso "+3 hours")
T_24H=$(iso "+24 hours"); T_25H=$(iso "+25 hours")
T_30H=$(iso "+30 hours"); T_31H=$(iso "+31 hours")
T_PAST=$(iso "-1 hours")
T_72H=$(iso "+72 hours"); T_73H=$(iso "+73 hours")
T_48H=$(iso "+48 hours"); T_49H=$(iso "+49 hours")
T_36H=$(iso "+36 hours"); T_37H=$(iso "+37 hours")
T_12H=$(iso "+12 hours"); T_13H=$(iso "+13 hours")
DAY_AVAIL=$(day "+5 days")          # dedicated calendar day for availability tests
DAY_AVAIL2=$(day "+6 days")

echo "BASE=$BASE   now(UTC)=$(iso now)"

# #############################################################################
hdr "SETUP: register users, login, capture tokens, create rooms"
# #############################################################################
# Rule 15: unknown org -> admin; known org -> member.

# --- TC-REG-01 alice/acme admin
tc "TC-REG-01" "New org 'acme' -> alice becomes admin"
exp '201  {"user_id":1,"org_id":1,"username":"alice","role":"admin"}  (no password echoed)'
call POST /auth/register '{"org_name":"acme","username":"alice","password":"pass123"}'
act

# --- TC-REG-02 bob/acme member
tc "TC-REG-02" "Known org 'acme' -> bob becomes member (same org_id)"
exp '201  role=="member", org_id==1'
call POST /auth/register '{"org_name":"acme","username":"bob","password":"pass123"}'
act

# carol/acme member (fixture, no TC id)
tc "SETUP" "carol joins acme as member"
exp '201  role=="member"'
call POST /auth/register '{"org_name":"acme","username":"carol","password":"pass123"}'
act

# --- TC-REG-03 dave/globex admin
tc "TC-REG-03" "Unknown org 'globex' -> dave becomes admin (new org_id != 1)"
exp '201  role=="admin", org_id==2'
call POST /auth/register '{"org_name":"globex","username":"dave","password":"pass123"}'
act

# --- TC-REG-04 same username different org allowed
tc "TC-REG-04" "username 'alice' in globex (already exists) -> member, no conflict"
exp '201  role=="member", org_id==2'
call POST /auth/register '{"org_name":"globex","username":"alice","password":"x"}'
act

# --- TC-REG-05 duplicate username same org
tc "TC-REG-05" "Duplicate 'alice' in acme -> 409 USERNAME_TAKEN"
exp '409  {"detail":"...","code":"USERNAME_TAKEN"}'
call POST /auth/register '{"org_name":"acme","username":"alice","password":"whatever"}'
act

# --- TC-REG-06 case sensitivity (implementation-defined)
tc "TC-REG-06" "Register 'Acme' (capital) — org-name case sensitivity"
exp 'implementation-defined: 201 new admin (case-sensitive) OR 409 (normalized). DOCUMENT actual.'
call POST /auth/register '{"org_name":"Acme","username":"z","password":"x"}'
act

# --- TC-REG-07 missing field
tc "TC-REG-07" "Missing password -> 422"
exp '422 (FastAPI validation shape)'
call POST /auth/register '{"org_name":"acme","username":"nopass"}'
act

# --- TC-REG-08 empty username/password
tc "TC-REG-08" "Empty username & password"
exp '422 if min-length enforced, else 201. DOCUMENT actual.'
call POST /auth/register '{"org_name":"acme","username":"","password":""}'
act

# --- TC-REG-09 wrong types
tc "TC-REG-09" "Wrong types -> 422"
exp '422'
call POST /auth/register '{"org_name":123,"username":["a"],"password":true}'
act

# --- TC-REG-10 malformed JSON
tc "TC-REG-10" "Malformed/truncated JSON body -> 422"
exp '422'
call POST /auth/register '{"org_name":"acme",'
act

# --- TC-REG-11 long / unicode username
tc "TC-REG-11" "Unicode username round-trips unchanged (or 422 if capped)"
exp '201 with username=="张三" returned unchanged, OR 422 if length-capped'
call POST /auth/register '{"org_name":"acme","username":"张三","password":"x"}'
act

# ---- LOGIN + capture tokens -------------------------------------------------
login() {  # login ORG USER PASS -> echoes "access refresh" (space separated)
  local o="$1" u="$2" p="$3"
  call POST /auth/login "{\"org_name\":\"$o\",\"username\":\"$u\",\"password\":\"$p\"}"
  printf '%s' "$BODY" | jget "d.get('access_token','') + ' ' + d.get('refresh_token','')"
}
read -r ALICE ALICE_RT <<< "$(login acme alice pass123)"
read -r BOB   BOB_RT   <<< "$(login acme bob   pass123)"
read -r CAROL CAROL_RT <<< "$(login acme carol pass123)"
read -r DAVE  DAVE_RT  <<< "$(login globex dave pass123)"
echo "Tokens captured: ALICE/BOB/CAROL/DAVE (+ refresh tokens)"

# ---- create baseline rooms --------------------------------------------------
tc "TC-ROOM-01" "Admin alice creates room R1 (cap 4, rate 10000)"
exp '201  {"id":1,"org_id":1,"name":"R1","capacity":4,"hourly_rate_cents":10000}'
call POST /rooms '{"name":"R1","capacity":4,"hourly_rate_cents":10000}' "$ALICE"
act
R1=$(printf '%s' "$BODY" | jget "d['id']")

tc "SETUP" "alice creates room R2 (cap 2, rate 12345) for rounding tests"
exp '201  hourly_rate_cents==12345'
call POST /rooms '{"name":"R2","capacity":2,"hourly_rate_cents":12345}' "$ALICE"
act
R2=$(printf '%s' "$BODY" | jget "d['id']")

tc "SETUP" "dave creates room G1 in globex (for cross-tenant tests)"
exp '201  org_id==2'
call POST /rooms '{"name":"G1","capacity":3,"hourly_rate_cents":9000}' "$DAVE"
act
G1=$(printf '%s' "$BODY" | jget "d['id']")
echo "R1=$R1  R2=$R2  G1=$G1"

# #############################################################################
hdr "A. HEALTH"
# #############################################################################
tc "TC-HLTH-01" "GET /health (no auth)"
exp '200  {"status":"ok"}'
call GET /health
act

tc "TC-HLTH-02" "GET /health ignores bogus auth header"
exp '200  {"status":"ok"}'
call GET /health "" "garbage"
act

# #############################################################################
hdr "C. LOGIN"
# #############################################################################
tc "TC-LOG-01" "Valid login"
exp '200  {access_token:<jwt>, refresh_token:<jwt>, token_type:"bearer"}'
call POST /auth/login '{"org_name":"acme","username":"alice","password":"pass123"}'
act

tc "TC-LOG-02" "Wrong password -> 401 INVALID_CREDENTIALS"
exp '401  code=="INVALID_CREDENTIALS"'
call POST /auth/login '{"org_name":"acme","username":"alice","password":"WRONG"}'
act

tc "TC-LOG-03" "Unknown username -> 401 (not 404, no existence leak)"
exp '401  INVALID_CREDENTIALS'
call POST /auth/login '{"org_name":"acme","username":"ghost","password":"x"}'
act

tc "TC-LOG-04" "Right user, wrong org's password -> 401 (org is part of cred check)"
exp '401  INVALID_CREDENTIALS  (acme-alice pass is pass123; globex-alice pass is x)'
call POST /auth/login '{"org_name":"acme","username":"alice","password":"x"}'
act

tc "TC-LOG-05" "Unknown org -> 401 (not creation, not 404)"
exp '401  INVALID_CREDENTIALS'
call POST /auth/login '{"org_name":"nope","username":"alice","password":"pass123"}'
act

tc "TC-LOG-06" "JWT access-token claims (decode, no verify)"
exp 'sub==user-id-as-STRING, org set, role set, jti present, type=="access", exp-iat==900'
printf '%s' "$ALICE" | "$PY" -c "
import sys,json,base64
t=sys.stdin.read().strip().split('.')[1]; t+='='*(-len(t)%4)
c=json.loads(base64.urlsafe_b64decode(t))
print('  DECODED:', {k:c.get(k) for k in ('sub','org','role','jti','type')}, 'exp-iat=', c['exp']-c['iat'])
print('  CHECK  :', 'sub is str' , isinstance(c['sub'],str), '| exp-iat==900', c['exp']-c['iat']==900)
"

tc "TC-LOG-07" "JWT refresh-token lifetime: type=='refresh', exp-iat==604800"
exp 'type=="refresh", exp-iat==604800 (7 days)'
printf '%s' "$BOB_RT" | "$PY" -c "
import sys,json,base64
t=sys.stdin.read().strip().split('.')[1]; t+='='*(-len(t)%4)
c=json.loads(base64.urlsafe_b64decode(t))
print('  DECODED: type=', c.get('type'), 'exp-iat=', c['exp']-c['iat'])
"

tc "TC-LOG-08" "jti unique across two logins"
exp 'two access tokens have different jti'
A1=$(login acme carol pass123 | cut -d' ' -f1)
A2=$(login acme carol pass123 | cut -d' ' -f1)
"$PY" -c "
import base64,json
def jti(t):
  p=t.split('.')[1]; p+='='*(-len(p)%4)
  return json.loads(base64.urlsafe_b64decode(p))['jti']
a,b='$A1','$A2'
print('  jti1=',jti(a)[:8],'jti2=',jti(b)[:8],'| distinct:', jti(a)!=jti(b))
"

tc "TC-LOG-09" "Missing password -> 422"
exp '422'
call POST /auth/login '{"org_name":"acme","username":"alice"}'
act

# #############################################################################
hdr "D. REFRESH (Rule 8: rotates, single-use)"
# #############################################################################
# use a dedicated refresh chain so we don't disturb BOB_RT etc.
read -r RUSER_A RUSER_RT <<< "$(login acme bob pass123)"

tc "TC-REF-01" "Valid refresh rotates -> new access AND new refresh"
exp '200  new access+refresh, both differ from inputs'
call POST /auth/refresh "{\"refresh_token\":\"$RUSER_RT\"}"
act
NEW_RT=$(printf '%s' "$BODY" | jget "d.get('refresh_token','')")

tc "TC-REF-02" "Reuse OLD refresh token -> 401 (single-use)"
exp '401  (blacklisted/rotated)'
call POST /auth/refresh "{\"refresh_token\":\"$RUSER_RT\"}"
act

tc "TC-REF-03" "New (rotated) refresh token works -> 200"
exp '200  rotation chain intact'
call POST /auth/refresh "{\"refresh_token\":\"$NEW_RT\"}"
act

tc "TC-REF-04" "Access token given to refresh -> 401 (must reject type:access)"
exp '401'
call POST /auth/refresh "{\"refresh_token\":\"$BOB\"}"
act

tc "TC-REF-05" "Garbage token -> 401"
exp '401'
call POST /auth/refresh '{"refresh_token":"abc.def.ghi"}'
act

tc "TC-REF-06" "Missing field -> 422"
exp '422'
call POST /auth/refresh '{}'
act

tc "TC-REF-07" "Refresh needs NO Authorization header -> 200 (body-based auth)"
exp '200  (already demonstrated: no Bearer header sent above)'
read -r _ TMP_RT <<< "$(login acme carol pass123)"
call POST /auth/refresh "{\"refresh_token\":\"$TMP_RT\"}"
act

# #############################################################################
hdr "E. LOGOUT & token invalidation (Rule 8)"
# #############################################################################
read -r LOGOUT_AT LOGOUT_RT <<< "$(login acme carol pass123)"

tc "TC-OUT-01" "Logout succeeds"
exp '2xx (200/204)'
call POST /auth/logout "" "$LOGOUT_AT"
act

tc "TC-OUT-02" "Reuse logged-out access token on GET /rooms -> 401"
exp '401 (blacklisted)'
call GET /rooms "" "$LOGOUT_AT"
act

tc "TC-OUT-03" "Refresh token still valid after logout -> 200"
exp '200 (logout kills only the access token)'
call POST /auth/refresh "{\"refresh_token\":\"$LOGOUT_RT\"}"
act

tc "TC-OUT-04" "Logout with no token -> 401"
exp '401'
call POST /auth/logout
act

tc "TC-AUTH-01" "Malformed Authorization header ('Bearer' only) -> 401"
exp '401'
curl -s -o /dev/null -w '  ACTUAL : %{http_code}\n' -H "Authorization: Bearer" "$BASE/rooms"
exp '401 (token without Bearer scheme)'
curl -s -o /dev/null -w '  ACTUAL : %{http_code}\n' -H "Authorization: $BOB" "$BASE/rooms"

tc "TC-AUTH-02" "Tampered signature -> 401"
exp '401'
TAMPER="${BOB%?}X"      # flip last char of signature
call GET /rooms "" "$TAMPER"
act

tc "TC-AUTH-03" "Expired access token -> 401 (mint one with exp in the past)"
exp '401'
FAKE=$("$PY" -c "
import jwt,time
print(jwt.encode({'sub':'2','org':1,'role':'member','jti':'x','type':'access','iat':int(time.time())-1000,'exp':int(time.time())-100},'cowork-dev-secret-change-me',algorithm='HS256'))
" 2>/dev/null)
if [ -n "$FAKE" ]; then call GET /rooms "" "$FAKE"; act; else echo "  (skipped: PyJWT not importable in this shell)"; fi

tc "TC-AUTH-04" "Refresh token used as Bearer on GET /rooms -> 401"
exp '401 (endpoint requires type:access)'
call GET /rooms "" "$BOB_RT"
act

# #############################################################################
hdr "F. ROOMS — list & create"
# #############################################################################
# TC-ROOM-01 already run in setup.
tc "TC-ROOM-02" "Member bob creates room -> 403 FORBIDDEN"
exp '403  code=="FORBIDDEN"'
call POST /rooms '{"name":"X","capacity":2,"hourly_rate_cents":5000}' "$BOB"
act

tc "TC-ROOM-03" "GET /rooms as bob (acme) -> only acme rooms, G1 absent"
exp '200  contains R1,R2 ; does NOT contain G1'
call GET /rooms "" "$BOB"
act

tc "TC-ROOM-04" "GET /rooms as dave (globex) -> only globex rooms (G1), never R1/R2"
exp '200  contains G1 only'
call GET /rooms "" "$DAVE"
act

tc "TC-ROOM-05" "Create room unauthenticated -> 401"
exp '401'
call POST /rooms '{"name":"Y","capacity":1,"hourly_rate_cents":1}'
act

tc "TC-ROOM-06" "Missing fields -> 422"
exp '422'
call POST /rooms '{"name":"NoRate"}' "$ALICE"
act

tc "TC-ROOM-07" "Negative capacity/rate"
exp '422 if schema constrains >=0, else 201 stored as-is. DOCUMENT (affects pricing).'
call POST /rooms '{"name":"Weird","capacity":-1,"hourly_rate_cents":-100}' "$ALICE"
act

tc "TC-ROOM-08" "Wrong types -> 422"
exp '422'
call POST /rooms '{"name":5,"capacity":"four","hourly_rate_cents":"10000"}' "$ALICE"
act

# #############################################################################
hdr "G. AVAILABILITY (Rule 13) — isolated on room AV"
# #############################################################################
call POST /rooms '{"name":"AV","capacity":4,"hourly_rate_cents":10000}' "$ALICE"
AV=$(printf '%s' "$BODY" | jget "d['id']")
echo "  (dedicated availability room AV=$AV, calendar day=$DAY_AVAIL)"

tc "TC-AVAIL-01" "Empty day"
exp "200  {\"room_id\":$AV,\"date\":\"$DAY_AVAIL\",\"busy\":[]}"
call GET "/rooms/$AV/availability?date=$DAY_AVAIL" "" "$BOB"
act

tc "TC-AVAIL-02" "Two confirmed bookings same day -> busy sorted ascending by start"
exp 'busy = [09:00-10:00, 14:00-15:00] on the day (ascending). times are +00:00.'
# book 14:00 first, then 09:00, to prove sorting
call POST /bookings "{\"room_id\":$AV,\"start_time\":\"${DAY_AVAIL}T14:00:00Z\",\"end_time\":\"${DAY_AVAIL}T15:00:00Z\"}" "$BOB"
BK_AV_PM=$(printf '%s' "$BODY" | jget "d.get('id','?')")
call POST /bookings "{\"room_id\":$AV,\"start_time\":\"${DAY_AVAIL}T09:00:00Z\",\"end_time\":\"${DAY_AVAIL}T10:00:00Z\"}" "$BOB"
BK_AV_AM=$(printf '%s' "$BODY" | jget "d.get('id','?')")
call GET "/rooms/$AV/availability?date=$DAY_AVAIL" "" "$BOB"
act

tc "TC-AVAIL-03" "Cancel one booking -> disappears from busy immediately"
exp 'busy = [14:00-15:00] only (09:00 slot gone)'
call POST "/bookings/$BK_AV_AM/cancel" "" "$BOB"
call GET "/rooms/$AV/availability?date=$DAY_AVAIL" "" "$BOB"
act

tc "TC-AVAIL-04" "'Starting on date' boundary: booking 23:00->next 00:00 shows on start day only"
exp "appears for date=$DAY_AVAIL, NOT for date=$DAY_AVAIL2"
call POST /bookings "{\"room_id\":$AV,\"start_time\":\"${DAY_AVAIL}T23:00:00Z\",\"end_time\":\"${DAY_AVAIL2}T00:00:00Z\"}" "$BOB"
call GET "/rooms/$AV/availability?date=$DAY_AVAIL" "" "$BOB";  echo "   [$DAY_AVAIL ] $CODE $BODY"
call GET "/rooms/$AV/availability?date=$DAY_AVAIL2" "" "$BOB"; echo "   [$DAY_AVAIL2] $CODE $BODY"

tc "TC-AVAIL-05" "Offset input maps to correct UTC date"
exp "start 02:00+06:00 on $DAY_AVAIL2 == 20:00Z on $DAY_AVAIL -> appears under $DAY_AVAIL"
call POST /bookings "{\"room_id\":$AV,\"start_time\":\"${DAY_AVAIL2}T02:00:00+06:00\",\"end_time\":\"${DAY_AVAIL2}T03:00:00+06:00\"}" "$BOB"
echo "   create: $CODE $BODY"
call GET "/rooms/$AV/availability?date=$DAY_AVAIL" "" "$BOB"; echo "   [$DAY_AVAIL busy should include 20:00-21:00] $BODY"

tc "TC-AVAIL-06" "Nonexistent room -> 404 ROOM_NOT_FOUND"
exp '404  ROOM_NOT_FOUND'
call GET "/rooms/99999/availability?date=$DAY_AVAIL" "" "$BOB"
act

tc "TC-AVAIL-07" "Cross-org room G1 as bob -> 404 ROOM_NOT_FOUND"
exp '404  ROOM_NOT_FOUND (cross-org == nonexistent)'
call GET "/rooms/$G1/availability?date=$DAY_AVAIL" "" "$BOB"
act

tc "TC-AVAIL-08" "Missing / invalid date -> 422 (or 400)"
exp '422 (or 400 — verify)'
call GET "/rooms/$AV/availability" "" "$BOB";              echo "   [missing]  $CODE $BODY"
call GET "/rooms/$AV/availability?date=not-a-date" "" "$BOB"; echo "   [garbage]  $CODE $BODY"

# #############################################################################
hdr "H. ROOM STATS (Rule 14) — isolated on room ST"
# #############################################################################
call POST /rooms '{"name":"ST","capacity":4,"hourly_rate_cents":10000}' "$ALICE"
ST=$(printf '%s' "$BODY" | jget "d['id']")

tc "TC-STAT-01" "Fresh room stats"
exp "200  {\"room_id\":$ST,\"total_confirmed_bookings\":0,\"total_revenue_cents\":0}"
call GET "/rooms/$ST/stats" "" "$BOB"
act

tc "TC-STAT-02" "After 2 confirmed bookings (2h each @10000 = 20000 each)"
exp "{\"total_confirmed_bookings\":2,\"total_revenue_cents\":40000}"
call POST /bookings "{\"room_id\":$ST,\"start_time\":\"${DAY_AVAIL}T08:00:00Z\",\"end_time\":\"${DAY_AVAIL}T10:00:00Z\"}" "$BOB"
S1=$(printf '%s' "$BODY" | jget "d.get('id','?')")
call POST /bookings "{\"room_id\":$ST,\"start_time\":\"${DAY_AVAIL}T12:00:00Z\",\"end_time\":\"${DAY_AVAIL}T14:00:00Z\"}" "$BOB"
S2=$(printf '%s' "$BODY" | jget "d.get('id','?')")
call GET "/rooms/$ST/stats" "" "$BOB"
act

tc "TC-STAT-03" "Cancel one -> stats drop immediately"
exp "{\"total_confirmed_bookings\":1,\"total_revenue_cents\":20000}"
call POST "/bookings/$S1/cancel" "" "$BOB"
call GET "/rooms/$ST/stats" "" "$BOB"
act

tc "TC-STAT-04" "Nonexistent / cross-org room -> 404"
exp '404 ROOM_NOT_FOUND (both)'
call GET "/rooms/99999/stats" "" "$BOB"; echo "   [99999] $CODE $BODY"
call GET "/rooms/$G1/stats" "" "$BOB";   echo "   [G1  ]  $CODE $BODY"

# #############################################################################
hdr "I. CREATE BOOKING (Rules 2-5,7) — isolated on room BK"
# #############################################################################
call POST /rooms '{"name":"BK","capacity":4,"hourly_rate_cents":10000}' "$ALICE"
BK=$(printf '%s' "$BODY" | jget "d['id']")

tc "TC-BOOK-01" "Happy path 1h booking (+2h..+3h) -> price 10000, confirmed"
exp '201  status=="confirmed", price_cents==10000, reference_code present, datetimes +00:00'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_2H\",\"end_time\":\"$T_3H\"}" "$BOB"
act
BOOK1=$(printf '%s' "$BODY" | jget "d.get('id','?')")

tc "TC-BOOK-02" "Max duration 8h OK -> price 80000"
exp '201  price_cents==80000'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$(iso '+48 hours')\",\"end_time\":\"$(iso '+56 hours')\"}" "$CAROL"
act

tc "TC-BOOK-03" "Duration 9h -> 400 INVALID_BOOKING_WINDOW"
exp '400  INVALID_BOOKING_WINDOW'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$(iso '+48 hours')\",\"end_time\":\"$(iso '+57 hours')\"}" "$DAVE"
act

tc "TC-BOOK-04" "Fractional 90 min -> 400"
exp '400  INVALID_BOOKING_WINDOW'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_2H\",\"end_time\":\"$(iso '+3 hours +30 minutes')\"}" "$CAROL"
act

tc "TC-BOOK-05" "30-minute duration -> 400"
exp '400  INVALID_BOOKING_WINDOW'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_2H\",\"end_time\":\"$(iso '+2 hours +30 minutes')\"}" "$CAROL"
act

tc "TC-BOOK-06" "end == start -> 400"
exp '400  INVALID_BOOKING_WINDOW'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_2H\",\"end_time\":\"$T_2H\"}" "$CAROL"
act

tc "TC-BOOK-07" "end < start -> 400"
exp '400  INVALID_BOOKING_WINDOW'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_3H\",\"end_time\":\"$T_2H\"}" "$CAROL"
act

tc "TC-BOOK-08" "start in the past -> 400"
exp '400  INVALID_BOOKING_WINDOW'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_PAST\",\"end_time\":\"$(iso 'now')\"}" "$CAROL"
act

tc "TC-BOOK-09" "start == now (no grace) -> 400"
exp '400  INVALID_BOOKING_WINDOW (must be strictly future)'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$(iso 'now')\",\"end_time\":\"$(iso '+1 hours')\"}" "$CAROL"
act

tc "TC-BOOK-10" "start a few minutes ahead, 1h duration -> OK"
exp '201  success'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$(iso '+5 minutes')\",\"end_time\":\"$(iso '+1 hours +5 minutes')\"}" "$CAROL"
act

tc "TC-BOOK-11" "Overlap (existing 14-16 style) -> 409 ROOM_CONFLICT"
exp '409  ROOM_CONFLICT'
# BOOK1 already occupies +2h..+3h ; make overlapping +2h..+3h again as CAROL
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_2H\",\"end_time\":\"$T_3H\"}" "$CAROL"
act

tc "TC-BOOK-12" "Back-to-back (new.start==existing.end) -> OK"
exp '201  success (touching boundary is not overlap)'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_3H\",\"end_time\":\"$(iso '+4 hours')\"}" "$CAROL"
act

tc "TC-BOOK-13" "Reverse back-to-back -> OK"
exp '201  success'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$(iso '+1 hours')\",\"end_time\":\"$T_2H\"}" "$CAROL"
act

# containment tests on a clean room to avoid interference
call POST /rooms '{"name":"BKC","capacity":4,"hourly_rate_cents":10000}' "$ALICE"
BKC=$(printf '%s' "$BODY" | jget "d['id']")
call POST /bookings "{\"room_id\":$BKC,\"start_time\":\"$(iso '+2 hours')\",\"end_time\":\"$(iso '+5 hours')\"}" "$BOB"  # existing 2..5

tc "TC-BOOK-14" "Full containment (existing 2-5, new 3-4) -> 409"
exp '409  ROOM_CONFLICT'
call POST /bookings "{\"room_id\":$BKC,\"start_time\":\"$(iso '+3 hours')\",\"end_time\":\"$(iso '+4 hours')\"}" "$CAROL"
act

tc "TC-BOOK-15" "New envelops existing (new 1-6 over existing 2-5) -> 409"
exp '409  ROOM_CONFLICT'
call POST /bookings "{\"room_id\":$BKC,\"start_time\":\"$(iso '+1 hours')\",\"end_time\":\"$(iso '+6 hours')\"}" "$CAROL"
act

tc "TC-BOOK-16" "Overlap only counts CONFIRMED: cancel then rebook same slot -> OK"
exp '201  success (cancelled slot is free)'
# make a fresh room, book, cancel, rebook
call POST /rooms '{"name":"BKF","capacity":4,"hourly_rate_cents":10000}' "$ALICE"
BKF=$(printf '%s' "$BODY" | jget "d['id']")
call POST /bookings "{\"room_id\":$BKF,\"start_time\":\"$T_2H\",\"end_time\":\"$T_3H\"}" "$BOB"
FID=$(printf '%s' "$BODY" | jget "d.get('id','?')")
call POST "/bookings/$FID/cancel" "" "$BOB"
call POST /bookings "{\"room_id\":$BKF,\"start_time\":\"$T_2H\",\"end_time\":\"$T_3H\"}" "$CAROL"
act

tc "TC-BOOK-17" "Same slot DIFFERENT room -> OK (conflict is per-room)"
exp '201  success'
call POST /bookings "{\"room_id\":$R2,\"start_time\":\"$T_2H\",\"end_time\":\"$T_3H\"}" "$CAROL"
act

# ---- Quota (Rule 4): member <=3 confirmed with start in (now, now+24h] ------
hdr "  Quota tests — dedicated member 'quotaguy' & fresh rooms"
call POST /auth/register '{"org_name":"acme","username":"quotaguy","password":"p"}' >/dev/null
read -r QG _ <<< "$(login acme quotaguy p)"
# three fresh rooms so slot-overlap never interferes with quota
for n in Q1 Q2 Q3 Q4; do call POST /rooms "{\"name\":\"$n\",\"capacity\":2,\"hourly_rate_cents\":10000}" "$ALICE";
  eval "$n=$(printf '%s' "$BODY" | jget "d['id']")"; done
# 3 confirmed bookings all inside (now, now+24h]
call POST /bookings "{\"room_id\":$Q1,\"start_time\":\"$(iso '+2 hours')\",\"end_time\":\"$(iso '+3 hours')\"}" "$QG" >/dev/null
call POST /bookings "{\"room_id\":$Q2,\"start_time\":\"$(iso '+4 hours')\",\"end_time\":\"$(iso '+5 hours')\"}" "$QG" >/dev/null
call POST /bookings "{\"room_id\":$Q3,\"start_time\":\"$(iso '+6 hours')\",\"end_time\":\"$(iso '+7 hours')\"}" "$QG" >/dev/null

tc "TC-BOOK-18" "4th booking inside 24h window -> 409 QUOTA_EXCEEDED"
exp '409  QUOTA_EXCEEDED'
call POST /bookings "{\"room_id\":$Q4,\"start_time\":\"$(iso '+8 hours')\",\"end_time\":\"$(iso '+9 hours')\"}" "$QG"
act

tc "TC-BOOK-19" "4th booking OUTSIDE window (start +30h) -> OK"
exp '201  success (start beyond now+24h does not count)'
call POST /bookings "{\"room_id\":$Q4,\"start_time\":\"$T_30H\",\"end_time\":\"$T_31H\"}" "$QG"
act

tc "TC-BOOK-20" "Upper bound inclusive: start exactly +24h with 3 in window -> 409"
exp '409  QUOTA_EXCEEDED  (window is (now, now+24h] inclusive)'
call POST /bookings "{\"room_id\":$Q4,\"start_time\":\"$T_24H\",\"end_time\":\"$T_25H\"}" "$QG"
act

tc "TC-BOOK-21" "Cancelling frees quota"
exp '201  success after cancelling one in-window booking'
# cancel the Q1 booking (need its id) — refetch bob? we lost id; cancel via list
QID=$(call GET "/rooms/$Q1/stats" "" "$QG"; :) # not id; instead list quotaguy bookings
call GET "/bookings?limit=100" "" "$QG"
Q1BID=$(printf '%s' "$BODY" | jget "next(b['id'] for b in d['items'] if b['room_id']==$Q1)")
call POST "/bookings/$Q1BID/cancel" "" "$QG" >/dev/null
call POST /bookings "{\"room_id\":$Q1,\"start_time\":\"$(iso '+10 hours')\",\"end_time\":\"$(iso '+11 hours')\"}" "$QG"
act

tc "TC-BOOK-22" "Quota per-member across all rooms (already spanned Q1..Q3)"
exp 'covered: the 3 that triggered quota spanned different rooms'
echo "  (informational — see TC-BOOK-18)"

tc "TC-BOOK-23" "Other member unaffected by quota"
exp '201  carol can still book while quotaguy is at quota'
call POST /bookings "{\"room_id\":$Q4,\"start_time\":\"$(iso '+2 hours')\",\"end_time\":\"$(iso '+3 hours')\"}" "$CAROL"
act

# ---- Rate limit (Rule 5): 20 POST/60s per user -----------------------------
hdr "  Rate-limit tests — dedicated member 'rlguy'"
call POST /auth/register '{"org_name":"acme","username":"rlguy","password":"p"}' >/dev/null
read -r RL _ <<< "$(login acme rlguy p)"
call POST /rooms '{"name":"RLR","capacity":2,"hourly_rate_cents":10000}' "$ALICE"
RLR=$(printf '%s' "$BODY" | jget "d['id']")

tc "TC-BOOK-24 / TC-BOOK-25" "Fire 20 POSTs, 21st -> 429 RATE_LIMITED (all requests count)"
exp 'requests 1..20: 2xx/4xx (mix ok) ; request 21: 429 RATE_LIMITED'
for i in $(seq 1 20); do
  call POST /bookings "{\"room_id\":$RLR,\"start_time\":\"$(iso "+$((i+1)) hours")\",\"end_time\":\"$(iso "+$((i+2)) hours")\"}" "$RL" >/dev/null
  printf '%s ' "$CODE"
done; echo "  <- first 20 statuses"
call POST /bookings "{\"room_id\":$RLR,\"start_time\":\"$(iso '+30 hours')\",\"end_time\":\"$(iso '+31 hours')\"}" "$RL"
echo "  21st -> ACTUAL: $CODE $BODY   (EXPECT 429 RATE_LIMITED)"

tc "TC-BOOK-26" "Rate limit is per-user: carol still succeeds while rlguy limited"
exp '2xx (or 409 if slot taken) — NOT 429'
call POST /bookings "{\"room_id\":$RLR,\"start_time\":\"$(iso '+40 hours')\",\"end_time\":\"$(iso '+41 hours')\"}" "$CAROL"
act

tc "TC-BOOK-27" "Rate-limit window rolls off after 60s"
exp 'after waiting 60s, a new POST succeeds (2xx). (script does not sleep — run manually)'
echo "  MANUAL: sleep 61 && re-run one POST as rlguy -> expect 2xx"

tc "TC-BOOK-28" "Reference-code uniqueness across N bookings"
exp 'all reference_code distinct'
call GET "/bookings?limit=100" "" "$BOB"
printf '%s' "$BODY" | jget "'  distinct refs: ' + str(len({b['reference_code'] for b in d['items']})==len(d['items']))"

tc "TC-BOOK-29" "Offset input normalized to UTC in response"
exp 'start 20:00+06:00 -> response start_time == ...T14:00:00+00:00'
call POST /bookings "{\"room_id\":$R2,\"start_time\":\"${DAY_AVAIL}T20:00:00+06:00\",\"end_time\":\"${DAY_AVAIL}T21:00:00+06:00\"}" "$CAROL"
act

tc "TC-BOOK-30" "Naive datetime treated as UTC (not server-local)"
exp 'response start_time == ...T14:00:00+00:00 (NOT shifted)'
call POST /bookings "{\"room_id\":$R2,\"start_time\":\"${DAY_AVAIL2}T14:00:00\",\"end_time\":\"${DAY_AVAIL2}T15:00:00\"}" "$CAROL"
act

tc "TC-BOOK-31" "Offset input that makes start past -> 400"
exp '400  INVALID_BOOKING_WINDOW  (compared in UTC)'
# now+2h expressed in +06:00 but shifted to be in the past: use an absolute past instant with offset
call POST /bookings "{\"room_id\":$R2,\"start_time\":\"$(iso_naive '-3 hours')+06:00\",\"end_time\":\"$(iso_naive '-2 hours')+06:00\"}" "$CAROL"
act

tc "TC-BOOK-32" "Nonexistent room -> 404 ROOM_NOT_FOUND"
exp '404  ROOM_NOT_FOUND'
call POST /bookings "{\"room_id\":99999,\"start_time\":\"$T_2H\",\"end_time\":\"$T_3H\"}" "$BOB"
act

tc "TC-BOOK-33" "Cross-org room G1 as bob -> 404 ROOM_NOT_FOUND"
exp '404  ROOM_NOT_FOUND'
call POST /bookings "{\"room_id\":$G1,\"start_time\":\"$T_2H\",\"end_time\":\"$T_3H\"}" "$BOB"
act

tc "TC-BOOK-34" "Missing fields -> 422"
exp '422'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_2H\"}" "$BOB"
act

tc "TC-BOOK-35" "Non-ISO datetime -> 422 (or 400)"
exp '422 (schema parse) — or 400, DOCUMENT'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"10/07/2026 2pm\",\"end_time\":\"10/07/2026 3pm\"}" "$BOB"
act

tc "TC-BOOK-36" "Unauthenticated -> 401"
exp '401'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_2H\",\"end_time\":\"$T_3H\"}"
act

tc "TC-BOOK-37" "Validation ordering — one documented code (400 window / 409 conflict)"
exp 'exactly one error; a valid documented code'
call POST /bookings "{\"room_id\":$BK,\"start_time\":\"$T_PAST\",\"end_time\":\"$(iso '+8 hours')\"}" "$BOB"
act

# #############################################################################
hdr "J. LIST BOOKINGS (Rule 11) — dedicated member 'listguy'"
# #############################################################################
call POST /auth/register '{"org_name":"acme","username":"listguy","password":"p"}' >/dev/null
read -r LG _ <<< "$(login acme listguy p)"
call POST /rooms '{"name":"LR","capacity":4,"hourly_rate_cents":10000}' "$ALICE"
LR=$(printf '%s' "$BODY" | jget "d['id']")
# create 25 bookings for listguy on distinct non-overlapping future hours (but quota+ratelimit!)
# NOTE: quota caps in-window to 3 and rate-limit caps 20/60s. To make 25 we must space starts
# beyond +24h (outside quota) and pace under 20/60s. We create them slowly in 2 bursts.
echo "  Creating bookings for listguy (spaced beyond +24h to dodge quota)..."
mkbk() { call POST /bookings "{\"room_id\":$LR,\"start_time\":\"$(iso "+$1 hours")\",\"end_time\":\"$(iso "+$(($1+1)) hours")\"}" "$LG" >/dev/null; }
i=25; made=0
while [ $made -lt 15 ]; do mkbk $i; i=$((i+2)); made=$((made+1)); done
echo "  (created ~15 bookings; rate-limit may cap the batch — check total below)"

tc "TC-LIST-01" "Defaults: page=1 limit=10"
exp '200  {items:[..<=10..], page:1, limit:10, total:<int>}'
call GET "/bookings" "" "$LG"
printf '  ACTUAL : %s  page=%s limit=%s total=%s items=%s\n' "$CODE" \
  "$(printf '%s' "$BODY" | jget "d['page']")" "$(printf '%s' "$BODY" | jget "d['limit']")" \
  "$(printf '%s' "$BODY" | jget "d['total']")" "$(printf '%s' "$BODY" | jget "len(d['items'])")"

tc "TC-LIST-02" "Ordering: ascending start_time, ties by ascending id"
exp 'items sorted by start_time asc (ties -> id asc)'
call GET "/bookings?limit=100" "" "$LG"
printf '%s' "$BODY" | jget "'  monotonic start_time asc: ' + str(all((d['items'][i]['start_time'],d['items'][i]['id'])<=(d['items'][i+1]['start_time'],d['items'][i+1]['id']) for i in range(len(d['items'])-1)))"

tc "TC-LIST-03" "Pagination no gaps/dupes across pages"
exp 'concatenated ids across pages == unique set, total constant on every page'
ids=""
for p in 1 2 3; do call GET "/bookings?page=$p&limit=10" "" "$LG"; ids="$ids $(printf '%s' "$BODY" | jget "' '.join(str(b['id']) for b in d['items'])")"; done
echo "  ids collected:$ids"
echo "$ids" | "$PY" -c "import sys; x=sys.stdin.read().split(); print('  no dupes:', len(x)==len(set(x)))"

tc "TC-LIST-04" "Page beyond last -> empty items, correct total"
exp '{items:[], page:99, limit:10, total:<same>}'
call GET "/bookings?page=99&limit=10" "" "$LG"
act

tc "TC-LIST-05" "limit=100 accepted"
exp '200  returns up to 100'
call GET "/bookings?limit=100" "" "$LG"
printf '  ACTUAL : %s limit=%s items=%s\n' "$CODE" "$(printf '%s' "$BODY" | jget "d['limit']")" "$(printf '%s' "$BODY" | jget "len(d['items'])")"

tc "TC-LIST-06" "limit=101 -> clamped to 100 OR 422"
exp 'either 422, or 200 with <=100 items. DOCUMENT.'
call GET "/bookings?limit=101" "" "$LG"
printf '  ACTUAL : %s  %s\n' "$CODE" "$(printf '%s' "$BODY" | head -c 200)"

tc "TC-LIST-07" "page=0 / negative / limit=0 -> 422 or defined behavior"
exp '422 if constrained, else defined (no crash, no negative offset). DOCUMENT.'
call GET "/bookings?page=0" "" "$LG";     echo "   [page=0]  $CODE"
call GET "/bookings?page=-1" "" "$LG";    echo "   [page=-1] $CODE"
call GET "/bookings?limit=0" "" "$LG";    echo "   [limit=0] $CODE"

tc "TC-LIST-08" "Visibility: only caller's own bookings"
exp "listguy's list never contains bob's/carol's booking ids"
call GET "/bookings?limit=100" "" "$LG"
printf '%s' "$BODY" | jget "'  all user_ids belong to caller: ' + str(len({b['user_id'] for b in d['items']})<=1)"

tc "TC-LIST-09" "Admin list returns admin's OWN bookings (Rule 11)"
exp "alice's /bookings shows only alice's bookings (flag if impl differs)"
call GET "/bookings?limit=100" "" "$ALICE"
printf '  ACTUAL : total=%s\n' "$(printf '%s' "$BODY" | jget "d['total']")"

tc "TC-LIST-10" "Cancelled bookings still listed with status cancelled"
exp "a cancelled booking still appears; total includes it"
call GET "/bookings?limit=100" "" "$BOB"
printf '%s' "$BODY" | jget "'  has a cancelled row: ' + str(any(b['status']=='cancelled' for b in d['items']))"

tc "TC-LIST-11" "Unauthenticated -> 401"
exp '401'
call GET "/bookings"
act

# #############################################################################
hdr "K. GET BOOKING BY ID (Rules 9,10)"
# #############################################################################
# make a known bob booking on a fresh room
call POST /rooms '{"name":"GR","capacity":4,"hourly_rate_cents":10000}' "$ALICE"
GR=$(printf '%s' "$BODY" | jget "d['id']")
call POST /bookings "{\"room_id\":$GR,\"start_time\":\"$(iso '+90 hours')\",\"end_time\":\"$(iso '+91 hours')\"}" "$BOB"
GBID=$(printf '%s' "$BODY" | jget "d.get('id','?')")
# carol booking for cross-user test
call POST /bookings "{\"room_id\":$GR,\"start_time\":\"$(iso '+92 hours')\",\"end_time\":\"$(iso '+93 hours')\"}" "$CAROL"
CBID=$(printf '%s' "$BODY" | jget "d.get('id','?')")

tc "TC-GET-01" "Owner reads own booking -> full Booking + refunds:[]"
exp '200  includes refunds:[] (never cancelled)'
call GET "/bookings/$GBID" "" "$BOB"
act

tc "TC-GET-03" "Member reads ANOTHER member's booking -> 404 BOOKING_NOT_FOUND"
exp '404  BOOKING_NOT_FOUND (not 403)'
call GET "/bookings/$CBID" "" "$BOB"
act

tc "TC-GET-04" "Admin reads any booking in own org -> 200"
exp '200'
call GET "/bookings/$GBID" "" "$ALICE"
act

tc "TC-GET-05" "Nonexistent id -> 404 BOOKING_NOT_FOUND"
exp '404  BOOKING_NOT_FOUND'
call GET "/bookings/999999" "" "$BOB"
act

tc "TC-GET-06" "Cross-org booking id as acme admin -> 404"
exp '404  BOOKING_NOT_FOUND'
# make a globex booking
call POST /bookings "{\"room_id\":$G1,\"start_time\":\"$(iso '+2 hours')\",\"end_time\":\"$(iso '+3 hours')\"}" "$DAVE"
GXBID=$(printf '%s' "$BODY" | jget "d.get('id','?')")
call GET "/bookings/$GXBID" "" "$ALICE"
act

tc "TC-GET-07" "Unauthenticated -> 401"
exp '401'
call GET "/bookings/$GBID"
act

tc "TC-GET-02" "Cancelled booking shows exactly one refund entry"
exp 'refunds:[{amount_cents:10000,status:"processed",processed_at:...}]  (100% tier, +90h notice)'
call POST "/bookings/$GBID/cancel" "" "$BOB" >/dev/null
call GET "/bookings/$GBID" "" "$BOB"
act

# #############################################################################
hdr "L. CANCEL BOOKING (Rule 6) — dedicated member & rooms per tier"
# #############################################################################
call POST /auth/register '{"org_name":"acme","username":"canguy","password":"p"}' >/dev/null
read -r CG _ <<< "$(login acme canguy p)"
mkroom() { call POST /rooms "{\"name\":\"$1\",\"capacity\":2,\"hourly_rate_cents\":$2}" "$ALICE"; printf '%s' "$BODY" | jget "d['id']"; }
# helper: create a booking outside quota window (start >24h) and echo its id
mkbook() { call POST /bookings "{\"room_id\":$1,\"start_time\":\"$2\",\"end_time\":\"$3\"}" "$4"; printf '%s' "$BODY" | jget "d.get('id','?')"; }

CR100=$(mkroom C100 10000); CR50=$(mkroom C50 10000); CR0=$(mkroom C0 10000)
CRR=$(mkroom CRR 12345);    CRR2=$(mkroom CRR2 4567)

tc "TC-CAN-01" "100% refund (notice +72h), price 20000 (2h)"
exp '200  {status:"cancelled",refund_percent:100,refund_amount_cents:20000}'
B=$(mkbook $CR100 "$T_72H" "$(iso '+74 hours')" "$CG")   # 2h @10000 = 20000
call POST "/bookings/$B/cancel" "" "$CG"
act

tc "TC-CAN-02" "Exactly 48h notice -> 100%"
exp 'refund_percent:100'
B=$(mkbook $CR100 "$T_48H" "$T_49H" "$CG")               # 1h @10000 = 10000
call POST "/bookings/$B/cancel" "" "$CG"
act

tc "TC-CAN-03" "50% refund (notice +36h), price 20000 -> 10000"
exp '{refund_percent:50,refund_amount_cents:10000}'
B=$(mkbook $CR50 "$T_36H" "$(iso '+38 hours')" "$CG")     # 2h = 20000
call POST "/bookings/$B/cancel" "" "$CG"
act

tc "TC-CAN-04" "Exactly 24h notice -> 50%"
exp 'refund_percent:50 (24h boundary belongs to 50% tier)'
B=$(mkbook $CR50 "$T_24H" "$T_25H" "$CG")                 # 1h = 10000 -> 5000
call POST "/bookings/$B/cancel" "" "$CG"
act

tc "TC-CAN-05" "0% refund (notice +12h), price 20000 -> 0 (RefundLog still exists, amount 0)"
exp '{refund_percent:0,refund_amount_cents:0}'
B=$(mkbook $CR0 "$T_12H" "$T_13H" "$CG")                  # 1h = 10000
call POST "/bookings/$B/cancel" "" "$CG"
act

tc "TC-CAN-06" "Half-cent rounds UP: R rate 12345, 1h, 50% -> 6172.5 -> 6173"
exp '{refund_percent:50,refund_amount_cents:6173}'
B=$(mkbook $CRR "$T_36H" "$T_37H" "$CG")                  # 1h @12345 = 12345
call POST "/bookings/$B/cancel" "" "$CG"
act

tc "TC-CAN-07" "Another half-cent: rate 4567, 1h, 50% -> 2283.5 -> 2284"
exp '{refund_percent:50,refund_amount_cents:2284}'
B=$(mkbook $CRR2 "$T_36H" "$T_37H" "$CG")                 # 1h @4567 = 4567
call POST "/bookings/$B/cancel" "" "$CG"
act

tc "TC-CAN-08" "Cancel already-cancelled -> 409 ALREADY_CANCELLED (still one RefundLog)"
exp '409  ALREADY_CANCELLED'
B=$(mkbook $CR100 "$(iso '+50 hours')" "$(iso '+51 hours')" "$CG")
call POST "/bookings/$B/cancel" "" "$CG" >/dev/null      # first: 200
call POST "/bookings/$B/cancel" "" "$CG"                 # second: 409
act

tc "TC-CAN-09" "Admin cancels member's booking (same org) -> 200"
exp '200  refund computed normally'
B=$(mkbook $CR100 "$(iso '+60 hours')" "$(iso '+61 hours')" "$CG")
call POST "/bookings/$B/cancel" "" "$ALICE"
act

tc "TC-CAN-10" "Member cancels ANOTHER member's booking -> 404"
exp '404  BOOKING_NOT_FOUND (visibility rule, not 403)'
B=$(mkbook $CR100 "$(iso '+62 hours')" "$(iso '+63 hours')" "$CG")
call POST "/bookings/$B/cancel" "" "$BOB"
act

tc "TC-CAN-11" "Admin of DIFFERENT org cancels acme booking -> 404"
exp '404  BOOKING_NOT_FOUND (cross-org)'
B=$(mkbook $CR100 "$(iso '+64 hours')" "$(iso '+65 hours')" "$CG")
call POST "/bookings/$B/cancel" "" "$DAVE"
act

tc "TC-CAN-12" "Nonexistent booking -> 404"
exp '404  BOOKING_NOT_FOUND'
call POST "/bookings/999999/cancel" "" "$CG"
act

tc "TC-CAN-15" "Unauthenticated cancel -> 401"
exp '401'
call POST "/bookings/1/cancel"
act

tc "TC-CAN-13/14" "Cancel frees slot & quota; response amount == RefundLog amount"
exp 'covered by TC-BOOK-16 / TC-BOOK-21 and TC-CAN-01..07 (compare cancel amount vs GET refunds[0].amount_cents)'
echo "  (invariant check: cancel response refund_amount_cents == GET /bookings/{id}.refunds[0].amount_cents)"

# #############################################################################
hdr "M. USAGE REPORT (Rule 12, admin)"
# #############################################################################
FROM=$(day "+4 days"); TO=$(day "+8 days")
tc "TC-USE-01" "Member -> 403 FORBIDDEN"
exp '403  FORBIDDEN'
call GET "/admin/usage-report?from=$FROM&to=$TO" "" "$BOB"
act

tc "TC-USE-02" "Includes rooms with zero bookings"
exp 'rooms[] contains every acme room; zero-booking rooms show confirmed_bookings:0, revenue_cents:0'
call GET "/admin/usage-report?from=$FROM&to=$TO" "" "$ALICE"
act

tc "TC-USE-03" "Range boundaries inclusive (start on from and on to both counted)"
exp 'bookings starting exactly at from and at to are included'
echo "  (verify by comparing counts against known bookings on $FROM and $TO)"

tc "TC-USE-04" "Booking starting just outside range excluded"
exp 'start at to+1s or from-1s not counted'
echo "  (informational)"

tc "TC-USE-05" "Only CONFIRMED counted (cancel removes from report immediately)"
exp 'cancelled booking not in counts/revenue'
echo "  (informational — cross-check with TC-STAT-03 style cancel)"

tc "TC-USE-06" "Org scoping: globex rooms never appear for alice"
exp 'rooms[] room_ids all belong to acme'
call GET "/admin/usage-report?from=$FROM&to=$TO" "" "$ALICE"
printf '%s' "$BODY" | jget "'  globex room present? ' + str(any(r['room_id']==$G1 for r in d['rooms']))"

tc "TC-USE-07" "Offset from/to normalized to UTC"
exp 'from=...T06:00:00+06:00 (==00:00Z) compared in UTC'
call GET "/admin/usage-report?from=${FROM}T06:00:00+06:00&to=${TO}T00:00:00Z" "" "$ALICE"
printf '  ACTUAL : %s  (%s)\n' "$CODE" "$(printf '%s' "$BODY" | head -c 120)"

tc "TC-USE-08" "from > to (empty range) -> all rooms 0, no error/negatives"
exp 'every room confirmed_bookings:0'
call GET "/admin/usage-report?from=$TO&to=$FROM" "" "$ALICE"
act

tc "TC-USE-09" "Missing from/to -> 422 (verify)"
exp '422 (or defined) — DOCUMENT'
call GET "/admin/usage-report" "" "$ALICE"
act

tc "TC-USE-10" "Unauthenticated -> 401"
exp '401'
call GET "/admin/usage-report?from=$FROM&to=$TO"
act

# #############################################################################
hdr "N. EXPORT CSV (admin)"
# #############################################################################
tc "TC-EXP-01" "Header exact match"
exp 'first line EXACTLY: id,reference_code,room_id,user_id,start_time,end_time,status,price_cents'
call GET "/admin/export?room_id=$R1&include_all=true" "" "$ALICE"
echo "  Content-Type:"; curl -s -D - -o /dev/null "$BASE/admin/export?room_id=$R1&include_all=true" -H "Authorization: Bearer $ALICE" | grep -i '^content-type'
echo "  first line: $(printf '%s' "$BODY" | head -n1)"

tc "TC-EXP-02" "Rows for specified room; UTC datetimes; valid status"
exp 'all rows have room_id==R1; datetimes end +00:00'
call GET "/admin/export?room_id=$R1&include_all=true" "" "$ALICE"
echo "$BODY" | head -n5

tc "TC-EXP-03" "include_all toggles output"
exp 'true vs false MUST differ. NOTE: this impl toggles OWN-vs-ALL-users (not cancelled). Flag vs spec intent.'
call GET "/admin/export?room_id=$BK&include_all=true"  "" "$ALICE"; echo "  [true ] rows=$(printf '%s' "$BODY" | grep -c ',')"
call GET "/admin/export?room_id=$BK&include_all=false" "" "$ALICE"; echo "  [false] rows=$(printf '%s' "$BODY" | grep -c ',')"

tc "TC-EXP-04" "Member -> 403 FORBIDDEN"
exp '403  FORBIDDEN'
call GET "/admin/export?room_id=$R1&include_all=true" "" "$BOB"
act

tc "TC-EXP-05" "Cross-org / nonexistent room_id -> 404 ROOM_NOT_FOUND"
exp '404  ROOM_NOT_FOUND'
call GET "/admin/export?room_id=$G1&include_all=true" "" "$ALICE"; echo "   [G1   ] $CODE $BODY"
call GET "/admin/export?room_id=99999&include_all=true" "" "$ALICE"; echo "   [99999] $CODE $BODY"

tc "TC-EXP-06" "Empty result set -> header row only"
exp 'exactly one line (header), no data rows'
EMPTY=$(mkroom EMPTY 10000)
call GET "/admin/export?room_id=$EMPTY&include_all=true" "" "$ALICE"
printf '  ACTUAL : lines=%s\n%s\n' "$(printf '%s' "$BODY" | grep -c '.')" "$BODY"

tc "TC-EXP-07" "Unauthenticated -> 401"
exp '401'
call GET "/admin/export?room_id=$R1&include_all=true"
act

# #############################################################################
hdr "O. MULTI-TENANCY (Rule 9) — mostly covered above"
# #############################################################################
tc "TC-TEN-01" "Cross-org room stats/availability as acme -> 404"
exp '404 ROOM_NOT_FOUND (both)'
call GET "/rooms/$G1/stats" "" "$BOB";                       echo "   [stats] $CODE $BODY"
call GET "/rooms/$G1/availability?date=$DAY_AVAIL" "" "$BOB"; echo "   [avail] $CODE $BODY"

tc "TC-TEN-02" "Cross-org booking read/cancel as acme admin -> 404"
exp '404 BOOKING_NOT_FOUND (both)  — see TC-GET-06 / TC-CAN-11'
echo "  (covered)"

tc "TC-TEN-03" "Cross-org booking creation -> 404 (see TC-BOOK-33)"
exp '404 ROOM_NOT_FOUND'
echo "  (covered)"

tc "TC-TEN-04" "Lists never leak other orgs"
exp 'GET /rooms, /bookings, usage-report, export contain no globex data for acme'
echo "  (covered by TC-ROOM-03/04, TC-USE-06)"

tc "TC-TEN-05" "Token org claim is authoritative"
exp 'acme token cannot touch globex ids even if they exist'
echo "  (covered by cross-org 404s above)"

# #############################################################################
hdr "P. CONCURRENCY (Rules 3-7,14,16) — parallel snippets"
# #############################################################################
echo "These need parallel requests. Runnable snippets (assert aggregate invariant):"
cat <<'SNIP'

  # TC-CONC-01  No double-booking: 50 concurrent identical-slot POSTs -> exactly ONE 201, rest 409
  ROOM=<id>; TOK=<member-token>; S=<future-iso>; E=<+1h-iso>
  for i in $(seq 1 50); do
    curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE/bookings" \
      -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      -d "{\"room_id\":$ROOM,\"start_time\":\"$S\",\"end_time\":\"$E\"}" &
  done | sort | uniq -c
  # EXPECT: exactly one 201, all others 409

  # TC-CONC-02  Quota under race: member w/ 2 in-window fires many -> confirmed in window <= 3
  # EXPECT: total 201 <= 1 (so window total <=3); excess -> 409 QUOTA_EXCEEDED. Never 4 confirmed.

  # TC-CONC-03  Rate limit under race: 40 concurrent POSTs -> non-429 count <= 20
  # (same loop with 40 iterations & distinct slots) ; EXPECT: (#non-429) <= 20

  # TC-CONC-04  Reference codes unique under race: create many across rooms -> all reference_code distinct

  # TC-CONC-05  Stats consistent after burst: concurrent creates+cancels then GET /rooms/{id}/stats
  # EXPECT: total_confirmed_bookings & total_revenue_cents == ground-truth recount

  # TC-CONC-06  Single RefundLog under concurrent cancel: N concurrent cancels of SAME booking
  #             -> exactly one 200, rest 409 ALREADY_CANCELLED, exactly one RefundLog entry

  # TC-CONC-07  Liveness: sustained concurrent traffic, every request returns (set --max-time; any hang = fail)
SNIP

# #############################################################################
hdr "Q. DATETIME (Rule 1) — cross-cutting"
# #############################################################################
echo "  TC-DT-01 offset->UTC        : see TC-BOOK-29"
echo "  TC-DT-02 naive==UTC         : see TC-BOOK-30"
echo "  TC-DT-03 explicit designator: every start/end/created/processed ends with +00:00 (this impl) or Z"
echo "  TC-DT-04 cross-field consist: same booking start_time identical in create/get/list/availability/export"
echo "  TC-DT-05 comparisons in UTC : see TC-BOOK-31, TC-BOOK-20, TC-USE-07"

echo -e "\n\033[1;32mDONE.\033[0m Diff EXPECT vs ACTUAL above. Re-run against a FRESH db (docker compose down -v && up) for exact id/count matches."
