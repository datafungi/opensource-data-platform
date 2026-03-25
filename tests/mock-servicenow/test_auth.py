"""Authentication tests for the mock ServiceNow API."""


def test_no_credentials_returns_401(client):
    response = client.get("/api/now/table/incident")
    assert response.status_code == 401


def test_wrong_credentials_returns_401(client, bad_auth_headers):
    response = client.get("/api/now/table/incident", headers=bad_auth_headers)
    assert response.status_code == 401


def test_correct_credentials_returns_200(client, auth_headers):
    response = client.get("/api/now/table/incident", headers=auth_headers)
    assert response.status_code == 200


def test_health_requires_no_auth(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] in ("ready", "initializing")
