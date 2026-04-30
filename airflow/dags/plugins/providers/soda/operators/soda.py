"""SodaScanOperator — placeholder. Full implementation in progress."""

from __future__ import annotations

from airflow.models import BaseOperator


class SodaScanOperator(BaseOperator):
    """Runs a Soda Core scan against a configured data source.

    Args:
        data_source: Soda data source name defined in soda/configuration.yml.
        checks_path: Path to the SodaCL checks YAML file.
        soda_config_path: Path to the Soda configuration file.
    """

    template_fields = ("data_source", "checks_path", "soda_config_path")

    def __init__(
        self,
        *,
        data_source: str,
        checks_path: str,
        soda_config_path: str = "soda/configuration.yml",
        **kwargs,
    ) -> None:
        super().__init__(**kwargs)
        self.data_source = data_source
        self.checks_path = checks_path
        self.soda_config_path = soda_config_path

    def execute(self, context):
        raise NotImplementedError(
            "SodaScanOperator is a placeholder. "
            "Implement by invoking soda scan with the configured data source "
            "and checks file, raising AirflowException on any check failure."
        )
