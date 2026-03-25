"""Functional tests for the incident table endpoint."""


def test_response_has_result_key(client, auth_headers):
    response = client.get("/api/now/table/incident", headers=auth_headers)
    assert "result" in response.json()


def test_default_limit_is_10(client, auth_headers):
    response = client.get("/api/now/table/incident", headers=auth_headers)
    assert len(response.json()["result"]) == 10


def test_sysparm_limit(client, auth_headers):
    response = client.get("/api/now/table/incident?sysparm_limit=5", headers=auth_headers)
    assert len(response.json()["result"]) == 5


def test_sysparm_offset_returns_different_records(client, auth_headers):
    page1 = client.get("/api/now/table/incident?sysparm_limit=5&sysparm_offset=0", headers=auth_headers)
    page2 = client.get("/api/now/table/incident?sysparm_limit=5&sysparm_offset=5", headers=auth_headers)
    ids1 = {r["sys_id"] for r in page1.json()["result"]}
    ids2 = {r["sys_id"] for r in page2.json()["result"]}
    assert ids1.isdisjoint(ids2)


def test_sysparm_fields_projects_columns(client, auth_headers):
    response = client.get(
        "/api/now/table/incident?sysparm_fields=sys_id,number",
        headers=auth_headers,
    )
    for record in response.json()["result"]:
        assert set(record.keys()) == {"sys_id", "number"}


def test_sysparm_query_single_field(client, auth_headers):
    response = client.get(
        "/api/now/table/incident?sysparm_limit=100&sysparm_query=state=1",
        headers=auth_headers,
    )
    for record in response.json()["result"]:
        assert record["state"] == "1"


def test_sysparm_query_multiple_fields(client, auth_headers):
    response = client.get(
        "/api/now/table/incident?sysparm_limit=100&sysparm_query=state=1^priority=2",
        headers=auth_headers,
    )
    for record in response.json()["result"]:
        assert record["state"] == "1"
        assert record["priority"] == "2"


def test_deterministic_results(client, auth_headers):
    first = client.get("/api/now/table/incident?sysparm_limit=20", headers=auth_headers)
    second = client.get("/api/now/table/incident?sysparm_limit=20", headers=auth_headers)
    assert first.json() == second.json()


def test_unknown_table_returns_empty(client, auth_headers):
    response = client.get("/api/now/table/nonexistent_table", headers=auth_headers)
    assert response.json() == {"result": []}


def test_incident_record_has_expected_fields(client, auth_headers):
    response = client.get("/api/now/table/incident?sysparm_limit=1", headers=auth_headers)
    record = response.json()["result"][0]
    for field in ("sys_id", "number", "short_description", "state", "priority"):
        assert field in record


def test_incident_number_format(client, auth_headers):
    response = client.get("/api/now/table/incident?sysparm_limit=10", headers=auth_headers)
    for record in response.json()["result"]:
        assert record["number"].startswith("INC")


def test_offset_beyond_total_returns_empty(client, auth_headers):
    response = client.get(
        "/api/now/table/incident?sysparm_limit=10&sysparm_offset=99999",
        headers=auth_headers,
    )
    assert response.json()["result"] == []
