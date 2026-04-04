from __future__ import annotations

from conftest import load_script_module


def test_resolve_references_only_maps_true_reference_fields():
    mod = load_script_module("load_sales_pipeline")
    mod.id_map["Account"] = {"42": "001xx0000000001AAA"}

    records = [
        {
            "id": "1",
            "AccountId": "42",
            "ParentId": "42",
            "Implementation_Months__c": "42",
            "Name": "Sample Opportunity",
        }
    ]
    resolved = mod.resolve_references(records)

    assert resolved[0]["AccountId"] == "001xx0000000001AAA"
    assert resolved[0]["ParentId"] == "001xx0000000001AAA"
    assert resolved[0]["Implementation_Months__c"] == "42"
    assert "id" not in resolved[0]


def test_can_resolve_record_treats_non_reference_numeric_values_as_ready():
    mod = load_script_module("load_sales_pipeline")
    mod.id_map["Account"] = {}

    unresolved = {"id": "1", "AccountId": "7", "Implementation_Months__c": "7"}
    ready = {"id": "2", "Implementation_Months__c": "7", "Amount": "100000"}

    assert mod.can_resolve_record(unresolved) is False
    assert mod.can_resolve_record(ready) is True
