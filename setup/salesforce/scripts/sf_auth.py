"""
Salesforce auth helpers.

Auth resolution order:
1) Explicit session env vars (SALESFORCE_SESSION_ID + SALESFORCE_INSTANCE_URL)
2) Existing connected-app env vars (domain/consumer key/secret)
3) Salesforce CLI authenticated org alias (default: dev-org)
"""

from __future__ import annotations

import json
import os
import subprocess

from dotenv import load_dotenv
from simple_salesforce.api import Salesforce

load_dotenv()


def salesforce_from_cli_alias(target_org: str) -> Salesforce:
    result = subprocess.run(
        [
            "sf",
            "org",
            "display",
            "--target-org",
            target_org,
            "--verbose",
            "--json",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    org = payload["result"]
    return Salesforce(
        instance_url=org["instanceUrl"],
        session_id=org["accessToken"],
    )


def get_salesforce_connection(target_org: str | None = None) -> Salesforce:
    session_id = os.getenv("SALESFORCE_SESSION_ID")
    instance_url = os.getenv("SALESFORCE_INSTANCE_URL")
    if session_id and instance_url:
        return Salesforce(instance_url=instance_url, session_id=session_id)

    domain = os.getenv("SALESFORCE_DOMAIN")
    consumer_key = os.getenv("SALESFORCE_CONSUMER_KEY")
    consumer_secret = os.getenv("SALESFORCE_CONSUMER_SECRET")
    if domain and consumer_key and consumer_secret:
        return Salesforce(
            domain=domain,
            consumer_key=consumer_key,
            consumer_secret=consumer_secret,
        )

    resolved_org = target_org or os.getenv("SALESFORCE_ORG_ALIAS", "dev-org")
    return salesforce_from_cli_alias(resolved_org)
