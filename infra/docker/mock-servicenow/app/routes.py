"""API routes for the mock ServiceNow Table API."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query

from app.auth import verify_credentials
from app.data import DB_READY, TABLE_SCHEMAS, query_table

router = APIRouter()


def _parse_sysparm_query(sysparm_query: str | None) -> list[tuple[str, str]]:
    """Parse a simplified ServiceNow query string into (field, value) pairs.

    Supports: ``field=value`` joined by ``^`` (AND).
    Example: ``state=1^priority=2`` → [("state", "1"), ("priority", "2")]
    """
    if not sysparm_query:
        return []
    filters: list[tuple[str, str]] = []
    for clause in sysparm_query.split("^"):
        if "=" in clause:
            field, _, value = clause.partition("=")
            filters.append((field.strip(), value.strip()))
    return filters


@router.get("/health")
def health() -> dict:
    return {"status": "ready" if DB_READY.is_set() else "initializing"}


@router.get("/api/now/table/{table_name}")
def get_table(
    table_name: str,
    sysparm_limit: int = Query(default=10, ge=1, le=10000),
    sysparm_offset: int = Query(default=0, ge=0),
    sysparm_fields: str | None = Query(default=None),
    sysparm_query: str | None = Query(default=None),
    _: str = Depends(verify_credentials),
) -> dict:
    if not DB_READY.is_set():
        raise HTTPException(status_code=503, detail="Service is initializing, please retry shortly")

    if table_name not in TABLE_SCHEMAS:
        return {"result": []}

    fields = [f.strip() for f in sysparm_fields.split(",")] if sysparm_fields else None
    filters = _parse_sysparm_query(sysparm_query)

    records = query_table(
        table_name,
        limit=sysparm_limit,
        offset=sysparm_offset,
        fields=fields,
        filters=filters,
    )
    return {"result": records}
