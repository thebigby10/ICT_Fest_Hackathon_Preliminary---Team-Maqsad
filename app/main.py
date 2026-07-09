"""CoWork API application entrypoint."""
from fastapi import FastAPI

from .database import Base, SessionLocal, engine
from .errors import AppError, app_error_handler
from .routers import admin, auth, bookings, health, rooms
from .services import reference, stats

Base.metadata.create_all(bind=engine)

# Seed in-memory stats and the reference counter from the DB before serving:
# a create/cancel that ran before the first lazy init could corrupt the stats
# baseline (e.g. negative revenue after a post-restart cancel).
with SessionLocal() as _db:
    stats.ensure_initialized(_db)
    reference.ensure_initialized(_db)

app = FastAPI(title="CoWork API", version="1.0.0")

app.add_exception_handler(AppError, app_error_handler)

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(rooms.router)
app.include_router(bookings.router)
app.include_router(admin.router)
