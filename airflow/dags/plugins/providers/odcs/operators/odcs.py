"""ODCSOperator — placeholder. Full implementation in progress."""

from __future__ import annotations

from airflow.models import BaseOperator


class ODCSOperator(BaseOperator):
    """Validates an ODCS data contract by running its embedded SodaCL quality checks.

    Args:
        contract_path: Path to the ODCS contract YAML file.
        data_source: Soda data source name defined in soda/configuration.yml.
        soda_config_path: Path to the Soda configuration file.
    """

    template_fields = ("contract_path", "data_source", "soda_config_path")

    def __init__(
        self,
        *,
        contract_path: str,
        data_source: str,
        soda_config_path: str = "soda/configuration.yml",
        **kwargs,
    ) -> None:
        super().__init__(**kwargs)
        self.contract_path = contract_path
        self.data_source = data_source
        self.soda_config_path = soda_config_path

    def execute(self, context):
        raise NotImplementedError(
            "ODCSOperator is a placeholder. "
            "Implement by extracting quality.specification from the ODCS contract "
            "and running soda scan against the declared data source."
        )
