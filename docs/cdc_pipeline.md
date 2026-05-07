# CDC Pipeline: Debezium + Redpanda + PostgreSQL

Change Data Capture (CDC) pipeline that streams row-level changes from a PostgreSQL
source database into Redpanda topics in real time, using Debezium as the connector layer.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Key Concepts](#2-key-concepts)
3. [Prerequisites](#3-prerequisites)
4. [PostgreSQL Setup](#4-postgresql-setup)
5. [Starting the Stack](#5-starting-the-stack)
6. [Registering a Connector](#6-registering-a-connector)
7. [Verifying the Pipeline](#7-verifying-the-pipeline)
8. [Topic Schema and Message Format](#8-topic-schema-and-message-format)
9. [Best Practices](#9-best-practices)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Architecture

```
PostgreSQL (home lab)
  wal_level=logical
  publication: debezium_publication
  replication slot: debezium_slot
        │
        │  pgoutput logical replication protocol (port 5432)
        ▼
  ┌─────────────────────────────────────┐
  │  Debezium Connect  (port 8083)      │
  │  quay.io/debezium/connect:3.5.0     │
  │                                     │
  │  Kafka Connect worker               │
  │  ├── pg-cdc-connector (source)      │
  │  │   ├── initial snapshot           │
  │  │   └── ongoing streaming (WAL)    │
  │  └── coordination topics:           │
  │      _connect_configs               │
  │      _connect_offsets               │
  │      _connect_statuses              │
  └───────────────┬─────────────────────┘
                  │  Kafka protocol (port 9092, internal)
                  ▼
  ┌──────────────────────────────────────┐
  │  Redpanda  (ports 9092/19092/8081)   │
  │  redpanda:v26.1.6                    │
  │                                      │
  │  Topics (cdc.<schema>.<table>):      │
  │  ├── cdc.public.invoices             │
  │  ├── cdc.public.payment_attempts     │
  │  └── cdc.public.subscriptions        │
  └──────────────────────────────────────┘
                  │
                  ▼
         Consumers (Flink, Spark, dbt, etc.)
```

**Component roles:**

| Component                            | Role                                                                         |
|--------------------------------------|------------------------------------------------------------------------------|
| PostgreSQL `wal_level=logical`       | Enables logical decoding — emits row-level change events via WAL             |
| Publication (`debezium_publication`) | Declares which tables PostgreSQL will stream; filters events at source       |
| Replication slot (`debezium_slot`)   | Cursor that tracks Debezium's read position in the WAL; prevents WAL cleanup |
| Debezium PostgreSQL connector        | Reads from the replication slot, converts events to Kafka-compatible records |
| Kafka Connect worker                 | Manages connector lifecycle, offset storage, and fault tolerance             |
| Redpanda                             | Stores and serves the change event stream; drop-in Kafka API replacement     |

---

## 2. Key Concepts

### Write-Ahead Log (WAL) and Logical Decoding

PostgreSQL writes every change to the WAL before applying it. With `wal_level=logical`,
the WAL includes enough information to reconstruct individual row changes. The `pgoutput`
plugin decodes this binary WAL stream into structured row events (INSERT/UPDATE/DELETE).

`pgoutput` is built into PostgreSQL 10+ and requires no installation. Older alternatives
(`decoderbufs`, `wal2json`) require manual installation — avoid them.

### Replication Slot

A replication slot is a server-side cursor that:
- Tracks the WAL position up to which Debezium has consumed events
- Prevents PostgreSQL from reclaiming WAL segments that haven't been read yet

**Critical:** If Debezium goes offline for an extended period, the slot causes WAL
accumulation on the PostgreSQL host, potentially exhausting disk space. Monitor
`pg_replication_slots` and set `wal_keep_size` as a safety limit.

### Publication

A PostgreSQL publication is a named set of tables that participates in logical replication.
It acts as a server-side filter — only changes to published tables are streamed through
the replication slot.

```sql
-- Capture all tables (including future ones):
CREATE PUBLICATION debezium_publication FOR ALL TABLES;

-- Capture specific tables only (lower overhead):
CREATE PUBLICATION debezium_publication FOR TABLE public.invoices, public.subscriptions;
```

### Initial Snapshot vs. Ongoing Streaming

When a connector first starts with `snapshot.mode=initial`, Debezium:
1. Takes a consistent snapshot of all table rows (SELECT scan) and publishes them as
   synthetic INSERT events
2. Switches to streaming mode, replaying WAL changes that occurred during and after
   the snapshot

Subsequent restarts resume from the stored offset in `_connect_offsets` — no re-snapshot.

### REPLICA IDENTITY

Controls what column values appear in the `before` image of UPDATE and DELETE events:

| Mode                 | Before-image contents    | Use case                                |
|----------------------|--------------------------|-----------------------------------------|
| `DEFAULT` (built-in) | Primary key columns only | Low overhead; PK-only before-image      |
| `FULL`               | All columns              | Full row diff; required if no PK exists |
| `NOTHING`            | No before-image          | Minimal WAL; before-image not needed    |
| `USING INDEX`        | Index columns            | Specific unique index as identity       |

```sql
-- Enable full before-image for all columns:
ALTER TABLE public.invoices REPLICA IDENTITY FULL;
```

### Kafka Connect Offset Tracking

Debezium stores its WAL read position (LSN) in the `_connect_offsets` Kafka topic.
This is the source of truth for resumption after restart — it is separate from the
replication slot position. Both must be consistent; deleting either without the other
will cause re-processing or data loss.

---

## 3. Prerequisites

### Host requirements

- Docker and Docker Compose (for the Debezium + Redpanda stack)
- `make` (for convenience targets)
- Network access from the Docker host to the PostgreSQL source on port 5432

### Environment variables (`.env`)

```env
# Source PostgreSQL — external instance targeted by the CDC connector
POSTGRES_HOST=<ip-or-hostname>
POSTGRES_PORT=5432
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=<password>
POSTGRES_DBNAME=billing          # database to capture; one connector per database
```

### PostgreSQL user permissions

The database user configured in the connector must have:
- `LOGIN` — to connect
- `REPLICATION` — to create/use a replication slot
- `SELECT` on all captured tables — for the initial snapshot

```sql
-- If using a dedicated replication user (recommended for production):
CREATE USER replicator WITH REPLICATION LOGIN PASSWORD 'strongpassword';
GRANT CONNECT ON DATABASE billing TO replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO replicator;
```

---

## 4. PostgreSQL Setup

These steps are run once on the source PostgreSQL instance. They require superuser
privileges and a server restart for `wal_level`.

### Step 1 — Enable logical replication

```sql
ALTER SYSTEM SET wal_level = 'logical';
SELECT pg_reload_conf();          -- detects the pending change
-- Then restart PostgreSQL to apply:
-- systemctl restart postgresql   (native install)
-- docker restart <container>     (Docker)
```

Verify after restart:
```sql
SHOW wal_level;    -- must return 'logical'
```

`max_wal_senders` (default 10) and `max_replication_slots` (default 10) are sufficient
for most deployments and do not require tuning unless running many concurrent connectors.

### Step 2 — Create the publication

Run against the target database (e.g., `billing`):

```sql
CREATE PUBLICATION debezium_publication FOR ALL TABLES;
```

Verify:
```sql
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
FROM pg_publication;
```

> **Note:** If you only want to capture specific tables, use
> `FOR TABLE schema.table1, schema.table2` and set
> `publication.autocreate.mode=filtered` in the connector config.

### Step 3 — pg_hba.conf (if using a dedicated replication user)

Ensure the replication user can connect:
```
# TYPE     DATABASE    USER         ADDRESS       METHOD
host       replication replicator   0.0.0.0/0     scram-sha-256
host       billing     replicator   0.0.0.0/0     scram-sha-256
```

Reload: `SELECT pg_reload_conf();`

---

## 5. Starting the Stack

```bash
# Start Redpanda + Debezium Connect
make up debezium

# Debezium takes ~30s to reach healthy status.
# Watch progress:
docker logs -f debezium
```

`make up debezium` starts both `infra/dev/compose/redpanda.yaml` and
`infra/dev/compose/debezium.yaml` together. Debezium's `depends_on` waits for
Redpanda's health check before starting the Connect worker.

**Ports:**

| Service                  | Port  | Purpose                         |
|--------------------------|-------|---------------------------------|
| Redpanda Kafka           | 19092 | External Kafka client access    |
| Redpanda Schema Registry | 18081 | External schema registry access |
| Redpanda HTTP Proxy      | 18082 | Pandaproxy REST API             |
| Redpanda Admin           | 19644 | Admin API (rpk, Console)        |
| Redpanda Console         | 8080  | Web UI                          |
| Debezium Connect         | 8083  | Kafka Connect REST API          |

---

## 6. Registering a Connector

Once the stack is healthy, register the PostgreSQL connector:

```bash
make debezium-init
```

This POSTs the connector configuration to the Kafka Connect REST API using credentials
from `.env`. The connector will:
1. Create the `debezium_slot` replication slot on the source database if it doesn't exist
2. Run an initial snapshot (SELECT scan of all published tables)
3. Switch to streaming mode, consuming WAL changes in real time

### Manual registration

```bash
curl -s -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pg-cdc-connector",
    "config": {
      "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
      "tasks.max": "1",
      "database.hostname": "<POSTGRES_HOST>",
      "database.port": "5432",
      "database.user": "<POSTGRES_USERNAME>",
      "database.password": "<POSTGRES_PASSWORD>",
      "database.dbname": "<POSTGRES_DBNAME>",
      "topic.prefix": "cdc",
      "plugin.name": "pgoutput",
      "slot.name": "debezium_slot",
      "publication.name": "debezium_publication",
      "publication.autocreate.mode": "all_tables",
      "snapshot.mode": "initial",
      "key.converter": "org.apache.kafka.connect.json.JsonConverter",
      "value.converter": "org.apache.kafka.connect.json.JsonConverter",
      "key.converter.schemas.enable": "false",
      "value.converter.schemas.enable": "false"
    }
  }'
```

### Connector management commands

```bash
# Check connector and task status
curl -s http://localhost:8083/connectors/pg-cdc-connector/status | python3 -m json.tool

# List all connectors
curl -s http://localhost:8083/connectors

# Pause / resume streaming (snapshot continues if in progress)
curl -X PUT http://localhost:8083/connectors/pg-cdc-connector/pause
curl -X PUT http://localhost:8083/connectors/pg-cdc-connector/resume

# Delete connector (does NOT drop the replication slot)
curl -X DELETE http://localhost:8083/connectors/pg-cdc-connector
```

### Adding a second database

Each database requires a separate connector with a unique slot name and topic prefix:

```bash
curl -s -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pg-cdc-crm",
    "config": {
      "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
      "database.hostname": "<POSTGRES_HOST>",
      "database.dbname": "crm",
      "topic.prefix": "cdc_crm",
      "plugin.name": "pgoutput",
      "slot.name": "debezium_slot_crm",
      "publication.name": "debezium_publication",
      ...
    }
  }'
```

---

## 7. Verifying the Pipeline

### Check topic creation

```bash
docker exec redpanda rpk topic list
```

Expected output after a successful snapshot:
```
NAME                         PARTITIONS  REPLICAS
_connect_configs             1           1
_connect_offsets             25          1
_connect_statuses            5           1
cdc.public.invoices          1           1
cdc.public.payment_attempts  1           1
cdc.public.subscriptions     1           1
```

### Consume a topic

```bash
# Tail the last 10 messages from the invoices topic
docker exec redpanda rpk topic consume cdc.public.invoices --num 10
```

### Check replication slot health

```sql
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

The `lag` column shows how far behind the slot is from the current WAL position.
A value above a few MB warrants investigation.

---

## 8. Topic Schema and Message Format

### Topic naming

Topics follow the pattern `<topic.prefix>.<schema>.<table>`:

| Table                     | Topic                         |
|---------------------------|-------------------------------|
| `public.invoices`         | `cdc.public.invoices`         |
| `public.payment_attempts` | `cdc.public.payment_attempts` |
| `public.subscriptions`    | `cdc.public.subscriptions`    |

### Message envelope

Each Kafka message has a key (row identity) and a value (change event). With
`schemas.enable=false` (current config), both are flat JSON:

**Key** — primary key columns:
```json
{"id": 1001}
```

**Value** — Debezium change envelope:
```json
{
  "before": null,
  "after": {
    "id": 1001,
    "customer_id": 42,
    "amount": 9900,
    "status": "paid",
    "created_at": 1746662400000000
  },
  "source": {
    "version": "3.5.0.Final",
    "connector": "postgresql",
    "name": "cdc",
    "ts_ms": 1746662400123,
    "db": "billing",
    "schema": "public",
    "table": "invoices",
    "txId": 1234,
    "lsn": 87654321,
    "xmin": null
  },
  "op": "c",
  "ts_ms": 1746662400456
}
```

**`op` values:**

| Value | Event           | `before`                                  | `after`      |
|-------|-----------------|-------------------------------------------|--------------|
| `c`   | INSERT (create) | `null`                                    | new row      |
| `u`   | UPDATE          | previous row (if `REPLICA IDENTITY FULL`) | updated row  |
| `d`   | DELETE          | previous row (if `REPLICA IDENTITY FULL`) | `null`       |
| `r`   | READ (snapshot) | `null`                                    | snapshot row |

**`before` is only populated for UPDATE and DELETE when `REPLICA IDENTITY FULL` is set.**
With the default `REPLICA IDENTITY DEFAULT`, `before` contains only primary key columns.

### Timestamp encoding

PostgreSQL `TIMESTAMP` and `TIMESTAMPTZ` columns are encoded as **microseconds since
epoch** (not milliseconds). Divide by 1000 to convert to milliseconds for JavaScript,
or use `from_unixtime(ts / 1000000)` in Flink/Spark SQL.

---

## 9. Best Practices

### Set REPLICA IDENTITY FULL on tables without primary keys

Tables with no primary key default to `REPLICA IDENTITY DEFAULT`, which means UPDATE
and DELETE events carry no before-image at all — the event is emitted without enough
information to identify which row changed. Set `FULL` on these tables:

```sql
ALTER TABLE public.audit_log REPLICA IDENTITY FULL;
```

### Monitor WAL lag and replication slot size

An offline or slow Debezium instance will cause WAL accumulation on the PostgreSQL host.
Monitor with:

```sql
SELECT slot_name,
       active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_lag,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

Set a WAL retention cap as a safety net:
```sql
-- Keep at most 2 GB of WAL regardless of slot state (PostgreSQL 13+):
ALTER SYSTEM SET max_slot_wal_keep_size = '2GB';
SELECT pg_reload_conf();
```

When `max_slot_wal_keep_size` is exceeded, PostgreSQL invalidates the slot and Debezium
must re-snapshot. This is disruptive but prevents disk exhaustion.

### One connector per database

PostgreSQL logical replication slots are database-scoped. A connector targeting
`database.dbname=billing` cannot see changes in `crm`. Register a separate connector
with a distinct `slot.name` and `topic.prefix` for each source database.

### Avoid capturing system schemas

The default publication `FOR ALL TABLES` captures `pg_catalog` and `information_schema`
changes, which are verbose and useless for CDC. Use a targeted publication instead:

```sql
-- Capture only the public schema:
CREATE PUBLICATION debezium_publication FOR TABLES IN SCHEMA public;
```

And set `publication.autocreate.mode=filtered` in the connector config.

### Don't delete the replication slot without also deleting the connector offset

The Kafka Connect offset stored in `_connect_offsets` and the replication slot position
in PostgreSQL must remain in sync. If you drop the slot and re-create it without also
clearing the offset, Debezium will try to resume from a WAL position that no longer
exists and fail. Clean both together:

```bash
# 1. Delete the connector
curl -X DELETE http://localhost:8083/connectors/pg-cdc-connector

# 2. Drop the slot in PostgreSQL
psql -c "SELECT pg_drop_replication_slot('debezium_slot');"

# 3. Delete the offset from Redpanda (forces re-snapshot on next connector start)
docker exec redpanda rpk topic delete _connect_offsets
# Or selectively reset via the Kafka Connect API — see Troubleshooting section.
```

---

## 10. Troubleshooting

### Connector task is FAILED

```bash
curl -s http://localhost:8083/connectors/pg-cdc-connector/status | python3 -m json.tool
```

Look at `tasks[0].trace` for the exception. Common causes:

| Error                                                    | Cause                                        | Fix                                                                            |
|----------------------------------------------------------|----------------------------------------------|--------------------------------------------------------------------------------|
| `Connection refused` to PostgreSQL                       | Network unreachable or wrong `POSTGRES_HOST` | Verify `POSTGRES_HOST` in `.env`; check firewall                               |
| `FATAL: replication slot "debezium_slot" does not exist` | Slot was dropped externally                  | Restart connector — it will re-create the slot                                 |
| `ERROR: requested WAL segment has already been removed`  | Slot fell too far behind; WAL was reclaimed  | Drop slot + clear offsets + re-register (full re-snapshot)                     |
| `permission denied for table`                            | Connector user lacks SELECT on a table       | `GRANT SELECT ON ALL TABLES IN SCHEMA public TO <user>;`                       |
| `publication "debezium_publication" does not exist`      | Publication was never created or was dropped | Run `CREATE PUBLICATION debezium_publication FOR ALL TABLES;` in the source DB |

Restart a failed task without re-registering:
```bash
curl -X POST http://localhost:8083/connectors/pg-cdc-connector/tasks/0/restart
```

### No topics appear after connector is RUNNING

Debezium is running but snapshot hasn't produced topics yet. Check Debezium logs:

```bash
docker logs debezium 2>&1 | grep -E "ERROR|WARN|snapshot|Starting"
```

If the snapshot took a long time and the task exited, check the database for active
snapshot transactions (long-running `SELECT` from Debezium's snapshot phase can block
other writes on tables with `ACCESS EXCLUSIVE` locks).

### Topics exist but no new messages after a change

1. Verify the replication slot is active:
   ```sql
   SELECT active FROM pg_replication_slots WHERE slot_name = 'debezium_slot';
   ```
   `active = f` means Debezium is not connected. Check `docker logs debezium`.

2. Verify the publication covers the changed table:
   ```sql
   SELECT * FROM pg_publication_tables WHERE pubname = 'debezium_publication';
   ```

3. Check that the table has a primary key or `REPLICA IDENTITY FULL`. UPDATE/DELETE on
   a table with `REPLICA IDENTITY DEFAULT` and no PK are silently dropped by `pgoutput`.

### Connector was pointed at the wrong database

If the connector was registered with the wrong `database.dbname`:

```bash
# 1. Delete connector
curl -X DELETE http://localhost:8083/connectors/pg-cdc-connector

# 2. Drop the slot from the wrong database
psql -d <wrong_db> -c "SELECT pg_drop_replication_slot('debezium_slot');"

# 3. Create publication in the correct database
psql -d <correct_db> -c "CREATE PUBLICATION debezium_publication FOR ALL TABLES;"

# 4. Update POSTGRES_DBNAME in .env, then re-register
make debezium-init
```

### Debezium container won't start / crashes immediately

Check logs: `docker logs debezium`

Common causes:
- `BOOTSTRAP_SERVERS` unreachable — Redpanda not yet healthy; `depends_on` should
  prevent this, but if starting Debezium standalone, ensure Redpanda is up first
- Internal topics could not be created — check `CONNECT_*_REPLICATION_FACTOR` is `1`
  for single-broker Redpanda (the default for multi-broker of `3` will fail)
