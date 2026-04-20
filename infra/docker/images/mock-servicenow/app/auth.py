"""HTTP Basic Auth dependency for the mock ServiceNow API."""

from __future__ import annotations

import os
import secrets

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials

security = HTTPBasic()

_USERNAME = os.getenv("MOCK_SN_USERNAME", "admin")
_PASSWORD = os.getenv("MOCK_SN_PASSWORD", "admin")


def verify_credentials(credentials: HTTPBasicCredentials = Depends(security)) -> str:
    valid_username = secrets.compare_digest(credentials.username.encode(), _USERNAME.encode())
    valid_password = secrets.compare_digest(credentials.password.encode(), _PASSWORD.encode())
    if not (valid_username and valid_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username
