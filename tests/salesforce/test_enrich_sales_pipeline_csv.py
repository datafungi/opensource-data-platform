from __future__ import annotations

import random

from conftest import load_script_module


def test_segment_from_employees_boundaries():
    mod = load_script_module("enrich_sales_pipeline_csv")

    assert mod.segment_from_employees(149) == "Developer Team"
    assert mod.segment_from_employees(150) == "SME"
    assert mod.segment_from_employees(4999) == "SME"
    assert mod.segment_from_employees(5000) == "Enterprise"


def test_add_account_custom_fields_sets_expected_analytics_fields():
    mod = load_script_module("enrich_sales_pipeline_csv")
    rows = [
        {
            "id": "1",
            "Description": "SaaS-only customer in APAC startup segment",
            "BillingCountry": "Vietnam",
            "NumberOfEmployees": "120",
        },
        {
            "id": "2",
            "Description": "Long-term services-only customer with managed support",
            "BillingCountry": "United States",
            "NumberOfEmployees": "8200",
        },
    ]

    account_index = mod.add_account_custom_fields(rows, random.Random(7))

    assert rows[0]["Engagement_Model__c"] == "SaaS Only"
    assert rows[0]["Primary_Offering__c"] == "SaaS"
    assert rows[0]["Region__c"] == "APAC"
    assert rows[0]["Customer_Segment__c"] == "Developer Team"
    assert account_index["1"]["offering"] == "SaaS"

    assert rows[1]["Engagement_Model__c"] == "Services Only"
    assert rows[1]["Primary_Offering__c"] == "Services"
    assert rows[1]["Region__c"] == "US"
    assert rows[1]["Customer_Segment__c"] == "Enterprise"
    assert account_index["2"]["offering"] == "Services"


def test_add_opportunity_custom_fields_sets_cross_sell_and_volume_tier():
    mod = load_script_module("enrich_sales_pipeline_csv")
    opportunities = [
        {
            "id": "10",
            "Name": "Subsidiary SaaS Expansion - Monitoring Rollout",
            "Description": "Expansion deal",
            "Amount": "120000",
            "AccountId": "1",
        },
        {
            "id": "11",
            "Name": "New services project",
            "Description": "Implementation services for migration",
            "Amount": "900000",
            "AccountId": "2",
        },
    ]
    account_index = {
        "1": {"offering": "Services"},
        "2": {"offering": "Services"},
    }

    mod.add_opportunity_custom_fields(opportunities, account_index, random.Random(5))

    first = opportunities[0]
    assert first["Offering_Type__c"] == "Cross-sell SaaS"
    assert first["Cross_Sell_From__c"] == "Services"
    assert first["Contract_Model__c"] == "Subscription"
    assert first["Data_Volume_Tier__c"] == "Medium"

    second = opportunities[1]
    assert second["Offering_Type__c"] == "Services New Logo"
    assert second["Cross_Sell_From__c"] == "None"
    assert second["Data_Volume_Tier__c"] == "Very High"
