from __future__ import annotations

import logging
import os
from airflow.secrets import BaseSecretsBackend

log = logging.getLogger(__name__)


class DockerSecretsBackend(BaseSecretsBackend):
    """
    Reads Airflow connections, variables, and config from
    Docker secrets mounted at /run/secrets/.

    Naming conventions (all lowercase, underscores):
        Connections : /run/secrets/airflow_connection_<conn_id>
        Variables   : /run/secrets/airflow_variable_<conn_id>
        Config      : /run/secrets/airflow_config_<conn_id>

    File content for connections must be a valid Airflow
    Connection URI string, e.g.:
      postgresql://user:password@host:5432/dbname

    Configuration:
        [secrets]
        backend = airflow.plugins.docker_secrets_backend.DockerSecretsBackend
        backend_kwargs = {"secret_mounting_dir": "/run/secrets",
                          "conn_prefix: "airflow_connection_",
                          "var_prefix: "airflow_variable_",
                          "config_prefix: "airflow_config_"}
    """

    def __init__(
        self,
        secret_mounting_dir: str = "/run/secrets",
        conn_prefix: str = "airflow_connection",
        var_prefix: str = "airflow_variable",
        config_prefix: str = "airflow_config_",
    ):
        self.secret_mounting_dir = secret_mounting_dir
        self.conn_prefix = conn_prefix
        self.var_prefix = var_prefix
        self.config_prefix = config_prefix
        super().__init__()

    def _read_secret(self, filename: str) -> str | None:
        """Read and return a secret file, stripping trailing whitespace"""
        path = os.path.join(self.secret_mounting_dir, filename)
        try:
            with open(path) as fh:
                value = fh.read().strip()
                if not value:
                    log.warning("DockerSecretsBackend: secret file %s is empty", path)
                    return None
                return value
        except FileNotFoundError:
            return None
        except PermissionError:
            log.error("DockerSecretsBackend: permission denied reading %s", path)
            return None

    def get_conn_value(self, conn_id: str) -> str | None:
        """
        Return a connection URI string for the given conn_id.
        Airflow will parse the URI into a connection object.
        """
        filename = f"{self.conn_prefix}{conn_id.lower()}"
        return self._read_secret(filename)

    def get_variable(self, key: str) -> str | None:
        """Return the value of an Airflow Variable."""
        filename = f"{self.var_prefix}{key.lower()}"
        return self._read_secret(filename)

    def get_config(self, key: str) -> str | None:
        """
        Return an Airflow config value.
        Note: only config keys in the _CMD allowlist are fully supported.
        """
        filename = f"{self.config_prefix}{key.lower()}"
        return self._read_secret(filename)
