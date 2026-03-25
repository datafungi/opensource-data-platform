"""Pytest fixtures for the mock ServiceNow service tests."""

from __future__ import annotations

import base64
import os
import tempfile

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(scope="session", autouse=True)
def _configure_test_env(tmp_path_factory):
    """Point the app at a small in-memory-like dataset for fast tests."""
    db_path = tmp_path_factory.mktemp("db") / "test.duckdb"
    os.environ["MOCK_SN_DB_PATH"] = str(db_path)
    os.environ["MOCK_SN_TOTAL_RECORDS"] = "100"
    os.environ["MOCK_SN_SEED"] = "42"
    os.environ["MOCK_SN_USERNAME"] = "testuser"
    os.environ["MOCK_SN_PASSWORD"] = "testpass"


@pytest.fixture(scope="session")
def client(_configure_test_env):
    # Import after env vars are set so module-level constants pick them up
    from app.data import DB_READY
    from app.main import app

    with TestClient(app) as c:
        # Block until background data generation completes (100 records is fast)
        assert DB_READY.wait(timeout=60), "Database initialisation timed out"
        yield c


def _basic_header(username: str, password: str) -> dict[str, str]:
    token = base64.b64encode(f"{username}:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


@pytest.fixture(scope="session")
def auth_headers():
    return _basic_header("testuser", "testpass")


@pytest.fixture(scope="session")
def bad_auth_headers():
    return _basic_header("wrong", "credentials")
