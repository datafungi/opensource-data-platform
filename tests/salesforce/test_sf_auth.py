from __future__ import annotations

from conftest import load_script_module


def test_get_salesforce_connection_prefers_session_env(monkeypatch):
    mod = load_script_module("sf_auth")
    captured = {}

    def fake_salesforce(**kwargs):
        captured.update(kwargs)
        return {"kind": "session", **kwargs}

    monkeypatch.setattr(mod, "Salesforce", fake_salesforce)
    monkeypatch.setenv("SALESFORCE_SESSION_ID", "session-token")
    monkeypatch.setenv("SALESFORCE_INSTANCE_URL", "https://example.my.salesforce.com")
    monkeypatch.delenv("SALESFORCE_DOMAIN", raising=False)
    monkeypatch.delenv("SALESFORCE_CONSUMER_KEY", raising=False)
    monkeypatch.delenv("SALESFORCE_CONSUMER_SECRET", raising=False)

    conn = mod.get_salesforce_connection()

    assert conn["kind"] == "session"
    assert captured["session_id"] == "session-token"
    assert captured["instance_url"] == "https://example.my.salesforce.com"


def test_get_salesforce_connection_falls_back_to_connected_app_env(monkeypatch):
    mod = load_script_module("sf_auth")
    captured = {}

    def fake_salesforce(**kwargs):
        captured.update(kwargs)
        return {"kind": "connected-app", **kwargs}

    monkeypatch.setattr(mod, "Salesforce", fake_salesforce)
    monkeypatch.delenv("SALESFORCE_SESSION_ID", raising=False)
    monkeypatch.delenv("SALESFORCE_INSTANCE_URL", raising=False)
    monkeypatch.setenv("SALESFORCE_DOMAIN", "test")
    monkeypatch.setenv("SALESFORCE_CONSUMER_KEY", "key")
    monkeypatch.setenv("SALESFORCE_CONSUMER_SECRET", "secret")

    conn = mod.get_salesforce_connection()

    assert conn["kind"] == "connected-app"
    assert captured["domain"] == "test"
    assert captured["consumer_key"] == "key"
    assert captured["consumer_secret"] == "secret"


def test_get_salesforce_connection_uses_cli_alias(monkeypatch):
    mod = load_script_module("sf_auth")
    monkeypatch.delenv("SALESFORCE_SESSION_ID", raising=False)
    monkeypatch.delenv("SALESFORCE_INSTANCE_URL", raising=False)
    monkeypatch.delenv("SALESFORCE_DOMAIN", raising=False)
    monkeypatch.delenv("SALESFORCE_CONSUMER_KEY", raising=False)
    monkeypatch.delenv("SALESFORCE_CONSUMER_SECRET", raising=False)
    monkeypatch.setenv("SALESFORCE_ORG_ALIAS", "env-org")

    calls = {}

    def fake_from_cli(alias):
        calls["alias"] = alias
        return {"kind": "cli", "alias": alias}

    monkeypatch.setattr(mod, "salesforce_from_cli_alias", fake_from_cli)

    conn = mod.get_salesforce_connection()

    assert conn["kind"] == "cli"
    assert calls["alias"] == "env-org"


def test_get_salesforce_connection_explicit_target_org_overrides_env(monkeypatch):
    mod = load_script_module("sf_auth")
    monkeypatch.delenv("SALESFORCE_SESSION_ID", raising=False)
    monkeypatch.delenv("SALESFORCE_INSTANCE_URL", raising=False)
    monkeypatch.delenv("SALESFORCE_DOMAIN", raising=False)
    monkeypatch.delenv("SALESFORCE_CONSUMER_KEY", raising=False)
    monkeypatch.delenv("SALESFORCE_CONSUMER_SECRET", raising=False)
    monkeypatch.setenv("SALESFORCE_ORG_ALIAS", "env-org")

    calls = {}

    def fake_from_cli(alias):
        calls["alias"] = alias
        return {"kind": "cli", "alias": alias}

    monkeypatch.setattr(mod, "salesforce_from_cli_alias", fake_from_cli)

    conn = mod.get_salesforce_connection(target_org="explicit-org")

    assert conn["kind"] == "cli"
    assert calls["alias"] == "explicit-org"
