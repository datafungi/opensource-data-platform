#!/usr/bin/env bash

set -euo pipefail

template="/opt/ranger/templates/install.properties.template"
install_properties="${RANGER_USERSYNC_HOME}/install.properties"
state_dir="/var/lib/ranger-usersync"
setup_marker="${state_dir}/.setup-complete"
truststore="${state_dir}/usersync-truststore.jks"

mkdir -p "${state_dir}" /var/log/ranger/usersync

if [[ ! -f "${template}" ]]; then
  echo "missing usersync template: ${template}" >&2
  exit 1
fi

if [[ -n "${USERSYNC_CACERT_PATH:-}" ]]; then
  keytool -importcert -noprompt \
    -alias ldapca \
    -file "${USERSYNC_CACERT_PATH}" \
    -keystore "${truststore}" \
    -storepass changeit >/dev/null 2>&1 || true
  export CRED_KEYSTORE_FILENAME="${truststore}"
else
  export CRED_KEYSTORE_FILENAME=""
fi

envsubst < "${template}" > "${install_properties}"

if [[ ! -f "${setup_marker}" ]]; then
  (
    cd "${RANGER_USERSYNC_HOME}"
    ./setup.sh
  )
  touch "${setup_marker}"
fi

(
  cd "${RANGER_USERSYNC_HOME}"
  ./ranger-usersync-services.sh start
)

log_file="/var/log/ranger/usersync/usersync.log"
touch "${log_file}"
tail -n +1 -F "${log_file}"
