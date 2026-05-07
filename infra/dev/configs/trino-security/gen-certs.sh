#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cert_dir="${script_dir}/certs"

mkdir -p "${cert_dir}"

openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
  -keyout "${cert_dir}/ca.key" \
  -out "${cert_dir}/ca.crt" \
  -subj "/CN=oss-data-platform-dev-ca"

cat > "${cert_dir}/trino.cnf" <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = trino

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = trino
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

openssl req -new -newkey rsa:4096 -nodes \
  -keyout "${cert_dir}/trino-key.pem" \
  -out "${cert_dir}/trino.csr" \
  -config "${cert_dir}/trino.cnf"

openssl x509 -req -days 3650 \
  -in "${cert_dir}/trino.csr" \
  -CA "${cert_dir}/ca.crt" \
  -CAkey "${cert_dir}/ca.key" \
  -CAcreateserial \
  -out "${cert_dir}/trino-cert.pem" \
  -extensions v3_req \
  -extfile "${cert_dir}/trino.cnf"

cat "${cert_dir}/trino-key.pem" "${cert_dir}/trino-cert.pem" > "${cert_dir}/trino.pem"

cat > "${cert_dir}/ldap.cnf" <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = openldap

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = openldap
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

openssl req -new -newkey rsa:4096 -nodes \
  -keyout "${cert_dir}/ldap.key" \
  -out "${cert_dir}/ldap.csr" \
  -config "${cert_dir}/ldap.cnf"

openssl x509 -req -days 3650 \
  -in "${cert_dir}/ldap.csr" \
  -CA "${cert_dir}/ca.crt" \
  -CAkey "${cert_dir}/ca.key" \
  -CAcreateserial \
  -out "${cert_dir}/ldap.crt" \
  -extensions v3_req \
  -extfile "${cert_dir}/ldap.cnf"

rm -f "${cert_dir}/trino.csr" "${cert_dir}/ldap.csr" "${cert_dir}/trino.cnf" "${cert_dir}/ldap.cnf"

printf 'Generated certificates in %s\n' "${cert_dir}"
