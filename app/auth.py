"""Authentication: password hashing, JWT issue/verify, request dependencies."""
import hashlib
import hmac
import os
import threading
import uuid
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from .config import (
    ACCESS_TOKEN_EXPIRE_MINUTES,
    JWT_ALGORITHM,
    JWT_SECRET,
    REFRESH_TOKEN_EXPIRE_DAYS,
)
from .database import get_db
from .errors import AppError
from .models import User

# Access tokens presented to /auth/logout are recorded here so they can no
# longer be used.
_revoked_tokens: set[str] = set()

# Refresh tokens are single-use: each presented token's jti is recorded here
# once it has been exchanged so it cannot be replayed.
_revoked_refresh_tokens: set[str] = set()
_refresh_lock = threading.Lock()

_PBKDF2_ROUNDS = 100_000


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _PBKDF2_ROUNDS)
    return f"{salt.hex()}:{dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        salt_hex, dk_hex = stored.split(":")
    except ValueError:
        return False
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt_hex), _PBKDF2_ROUNDS)
    return hmac.compare_digest(dk.hex(), dk_hex)


def _now_ts() -> int:
    return int(datetime.now(timezone.utc).timestamp())


def create_access_token(user: User) -> str:
    iat = _now_ts()
    lifetime = timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    payload = {
        "sub": str(user.id),
        "org": user.org_id,
        "role": user.role,
        "jti": uuid.uuid4().hex,
        "iat": iat,
        "exp": iat + int(lifetime.total_seconds()),
        "type": "access",
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def create_refresh_token(user: User) -> str:
    iat = _now_ts()
    lifetime = timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    payload = {
        "sub": str(user.id),
        "org": user.org_id,
        "role": user.role,
        "jti": uuid.uuid4().hex,
        "iat": iat,
        "exp": iat + int(lifetime.total_seconds()),
        "type": "refresh",
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


# Claims every token we issue carries. A validly-signed token missing any of
# them (e.g. a forged one) must be rejected here, not left to 500 later when
# int(sub) / payload[jti] dereference it.
_REQUIRED_CLAIMS = {"sub", "org", "role", "jti", "iat", "exp", "type"}


def decode_token(token: str) -> dict:
    try:
        data = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except jwt.PyJWTError:
        raise AppError(401, "UNAUTHORIZED", "Invalid or expired token")
    if not _REQUIRED_CLAIMS <= data.keys():
        raise AppError(401, "UNAUTHORIZED", "Invalid token payload")
    try:
        int(data["sub"])
    except (TypeError, ValueError):
        raise AppError(401, "UNAUTHORIZED", "Invalid token payload")
    return data


def revoke_access_token(payload: dict) -> None:
    _revoked_tokens.add(payload["jti"])


def try_consume_refresh_token(payload: dict) -> bool:
    """Atomically check-and-mark a refresh token's jti as used.

    Returns False if the jti was already revoked (replay).
    """
    with _refresh_lock:
        jti = payload.get("jti")
        if jti in _revoked_refresh_tokens:
            return False
        _revoked_refresh_tokens.add(jti)
        return True


# auto_error=False so missing/malformed headers raise our contract 401 (not 403).
_bearer_scheme = HTTPBearer(auto_error=False)


def get_token_payload(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer_scheme),
) -> dict:
    if credentials is None:
        raise AppError(401, "UNAUTHORIZED", "Missing bearer token")
    payload = decode_token(credentials.credentials.strip())
    if payload.get("type") != "access":
        raise AppError(401, "UNAUTHORIZED", "Wrong token type")
    if payload.get("jti") in _revoked_tokens:
        raise AppError(401, "UNAUTHORIZED", "Token has been revoked")
    return payload


def get_current_user(
    payload: dict = Depends(get_token_payload),
    db: Session = Depends(get_db),
) -> User:
    user = db.query(User).filter(User.id == int(payload["sub"])).first()
    if user is None:
        raise AppError(401, "UNAUTHORIZED", "Unknown user")
    return user


def require_admin(user: User = Depends(get_current_user)) -> User:
    if user.role != "admin":
        raise AppError(403, "FORBIDDEN", "Admin privileges required")
    return user
