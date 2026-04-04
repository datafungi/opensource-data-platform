from __future__ import annotations

from conftest import load_script_module


class _BulkObject:
    def __init__(self, results):
        self._results = results

    def delete(self, records, batch_size=200):
        return self._results


class _Bulk:
    def __init__(self, results):
        self.Account = _BulkObject(results)


class _FakeSF:
    def __init__(self, records, delete_results):
        self._records = records
        self.bulk = _Bulk(delete_results)

    def query_all(self, _query):
        return {"records": self._records}


def test_bulk_delete_all_returns_zero_when_no_records():
    mod = load_script_module("purge_sales_data")
    sf = _FakeSF(records=[], delete_results=[])

    success, failed = mod.bulk_delete_all(sf, "Account")

    assert success == 0
    assert failed == 0


def test_bulk_delete_all_counts_success_and_failures():
    mod = load_script_module("purge_sales_data")
    sf = _FakeSF(
        records=[{"Id": "001A"}, {"Id": "001B"}, {"Id": "001C"}],
        delete_results=[
            {"success": True},
            {"success": False},
            {"success": True},
        ],
    )

    success, failed = mod.bulk_delete_all(sf, "Account")

    assert success == 2
    assert failed == 1
