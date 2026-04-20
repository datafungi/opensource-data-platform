"""FastAPI application factory for the mock ServiceNow service."""

from __future__ import annotations

import logging
import threading
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.data import DB_READY, initialise_database
from app.routes import router

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s — %(message)s")


def _init_in_background() -> None:
    try:
        initialise_database()
    except Exception:
        logging.getLogger(__name__).exception("Database initialisation failed")
        DB_READY.set()  # unblock waiters so the service doesn't hang forever


@asynccontextmanager
async def lifespan(application: FastAPI):  # noqa: ANN001
    thread = threading.Thread(target=_init_in_background, daemon=True)
    thread.start()
    yield


app = FastAPI(title="Mock ServiceNow API", lifespan=lifespan)
app.include_router(router)
