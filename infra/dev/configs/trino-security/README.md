# Trino security dev stack

This directory contains the assets needed to run `infra/dev/compose/trino.yaml` with:

- HTTPS on Trino
- LDAP authentication
- Apache Ranger access control
- Iceberg REST catalog authentication to Polaris

## What this stack secures

- Trino user access is authenticated against OpenLDAP over LDAPS.
- Trino authorization is delegated to Ranger.
- Iceberg catalog operations still go through Polaris, which remains the Iceberg REST catalog.
- SeaweedFS credentials remain the local object-store access mechanism for this dev stack. Polaris OAuth2 secures catalog access, not row or column security.

## Bootstrap

1. Generate certificates:

   ```bash
   ./infra/dev/configs/trino-security/gen-certs.sh
   ```

2. Copy the environment template and fill in secrets:

   ```bash
   cp .env.example .env
   ```

   Keep `LDAP_DOMAIN` and `LDAP_BASE_DN` aligned with the checked-in LDAP and Trino config unless you also update the files under `infra/dev/configs/ldap` and `infra/dev/configs/trino`.

3. Start the stack:

   ```bash
   make up trino
   ```

## Built-in LDAP users

- `alice` / `alice-password` in LDAP group `trino_admin`
- `bob` / `bob-password` in LDAP group `analyst`
- `carol` / `carol-password` in LDAP group `pii_restricted`

Only users in one of these groups are allowed to authenticate to Trino.

## Ranger setup

Open Ranger at `http://localhost:6080/login.jsp`.

- Default admin user: `admin`
- Default admin password: `rangerR0cks!`

Create a Trino service named `trino_dev` in Ranger. Ranger 2.8.0 already includes the Trino service definition.

Create at least these policies:

1. Query policy granting `execute` on `*` to the users or groups that should run queries.
2. User impersonation policy granting self-`impersonate` for each Trino user.
3. Procedure policy granting `execute` on `system.runtime.kill_query` only to `trino_admin`.
4. Catalog/table/column policies for `iceberg`, `postgresql`, and `clickhouse`.
5. A row filter policy on one Iceberg table for `analyst`.
6. A column masking policy on one sensitive Iceberg column for `analyst`.

Ranger users and groups can be synchronized from LDAP by the optional `ranger-usersync` service.

The default `make up trino` path does not build `ranger-usersync`, because it depends on downloading the Ranger usersync distribution during image build.

To enable it explicitly, run:

```bash
COMPOSE_PROFILES=usersync make up trino
```

## Polaris setup

The Iceberg catalog now expects Polaris OAuth2 credentials via `POLARIS_CLIENT_CREDENTIAL`.

Create a dedicated Polaris service principal for Trino and grant it broad enough catalog or namespace permissions for the Iceberg operations you want Trino to perform. The Trino-side config now uses:

- `iceberg.rest-catalog.security=OAUTH2`
- `iceberg.security=SYSTEM`

This means:

- Ranger remains the SQL authorization layer.
- Polaris remains the Iceberg REST catalog and engine principal authority.

If Polaris permissions are too narrow, Trino queries allowed by Ranger can still fail later with Polaris authorization errors.

## Verifying

- Trino UI/API: `https://localhost:8085`
- Trino health endpoint:

  ```bash
  curl --insecure https://localhost:8085/v1/info
  ```

- Example CLI connection:

  ```bash
  docker exec -it "$(docker ps -q --filter name=trino)" trino \
    --server https://localhost:8443 \
    --insecure \
    --user alice \
    --password
  ```

## Notes

- This is a dev-first implementation. Ranger Admin is left on HTTP in local compose for simpler bootstrap.
- Production hardening should move Ranger and Polaris to TLS, replace local secrets with Docker secrets or Vault, and replace the local LDAP container with your real LDAP or AD service.
- The `Makefile` passes the project root `.env` into `docker compose`, so the same variables work for both `make` and direct compose commands.
- Without the `usersync` profile, create the needed Ranger users, groups, and policies manually for local testing.
