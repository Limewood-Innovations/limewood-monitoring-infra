#!/usr/bin/env bash
# Post-deploy Postgres bootstrapping for the observability stack.
#
# Bicep creates the Postgres flexible server + the empty `observability`
# database. This script does the SQL-layer setup that Bicep can't do:
#
#   1. Creates the `observability` schema
#   2. Creates least-privilege roles `obs_writer` (used by tools)
#      and `obs_reader` (used by PowerBI / dashboards)
#   3. Applies the schema migration (CREATE TABLE / INDEX / VIEW)
#   4. Prints two SQLAlchemy URLs for paste-into-KeyVault
#
# Idempotent: re-running on an already-bootstrapped DB is a no-op (uses
# IF NOT EXISTS / CREATE OR REPLACE consistently).
#
# Usage:
#   ./scripts/setup-postgres.sh
#
# Required env vars:
#   PG_HOST              FQDN of the Postgres server (e.g. from `deploy.sh` POSTGRESFQDN output)
#   PG_ADMIN_PASSWORD    Same value passed to `deploy.sh`
#
# Optional env vars:
#   PG_DATABASE          default: observability
#   PG_ADMIN_USER        default: pgadmin
#   PG_WRITER_PASSWORD   default: auto-generated, printed at the end
#   PG_READER_PASSWORD   default: auto-generated, printed at the end
#   MIGRATIONS_REPO      default: pull from github (Limewood-Innovations/limewood-observability-db@main)
#   MIGRATIONS_FILE      default: 001_init_postgres.sql

set -euo pipefail

: "${PG_HOST:?PG_HOST must be set (e.g. alpenland-observability-pg.postgres.database.azure.com)}"
: "${PG_ADMIN_PASSWORD:?PG_ADMIN_PASSWORD must be set}"

PG_DATABASE="${PG_DATABASE:-observability}"
PG_ADMIN_USER="${PG_ADMIN_USER:-pgadmin}"
PG_WRITER_PASSWORD="${PG_WRITER_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)}"
PG_READER_PASSWORD="${PG_READER_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)}"
MIGRATIONS_REPO="${MIGRATIONS_REPO:-https://raw.githubusercontent.com/Limewood-Innovations/limewood-observability-db/main}"
MIGRATIONS_FILE="${MIGRATIONS_FILE:-src/limewood_observability_db/migrations/001_init_postgres.sql}"

if ! command -v psql >/dev/null 2>&1; then
    echo "ERROR: psql is not installed. Install with 'brew install libpq && brew link --force libpq'" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 — schema + roles
# ---------------------------------------------------------------------------

echo "→ Creating schema + obs_writer / obs_reader roles on ${PG_HOST}/${PG_DATABASE}"

PGPASSWORD="${PG_ADMIN_PASSWORD}" psql \
    "host=${PG_HOST} port=5432 user=${PG_ADMIN_USER} dbname=${PG_DATABASE} sslmode=require" \
    -v ON_ERROR_STOP=1 \
    -v writer_pwd="${PG_WRITER_PASSWORD}" \
    -v reader_pwd="${PG_READER_PASSWORD}" \
    <<'SQL'

CREATE SCHEMA IF NOT EXISTS observability;

-- Writer role (idempotent via DO block)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'obs_writer') THEN
        CREATE ROLE obs_writer LOGIN PASSWORD :'writer_pwd';
    ELSE
        ALTER ROLE obs_writer WITH PASSWORD :'writer_pwd';
    END IF;
END$$;

GRANT CONNECT ON DATABASE observability TO obs_writer;
GRANT USAGE   ON SCHEMA observability TO obs_writer;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA observability TO obs_writer;
GRANT USAGE   ON ALL SEQUENCES IN SCHEMA observability TO obs_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT SELECT, INSERT, UPDATE ON TABLES TO obs_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT USAGE ON SEQUENCES TO obs_writer;

-- Reader role
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'obs_reader') THEN
        CREATE ROLE obs_reader LOGIN PASSWORD :'reader_pwd';
    ELSE
        ALTER ROLE obs_reader WITH PASSWORD :'reader_pwd';
    END IF;
END$$;

GRANT CONNECT ON DATABASE observability TO obs_reader;
GRANT USAGE   ON SCHEMA observability TO obs_reader;
GRANT SELECT  ON ALL TABLES IN SCHEMA observability TO obs_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT SELECT ON TABLES TO obs_reader;

SQL

# ---------------------------------------------------------------------------
# Step 2 — migration (tables + indexes + view)
# ---------------------------------------------------------------------------

migration_url="${MIGRATIONS_REPO}/${MIGRATIONS_FILE}"
echo "→ Fetching migration: ${migration_url}"

migration_tmp="$(mktemp -t observability-migration-XXXXXX.sql)"
trap 'rm -f "${migration_tmp}"' EXIT

curl -fsSL "${migration_url}" -o "${migration_tmp}"

echo "→ Applying migration"
PGPASSWORD="${PG_ADMIN_PASSWORD}" psql \
    "host=${PG_HOST} port=5432 user=${PG_ADMIN_USER} dbname=${PG_DATABASE} sslmode=require" \
    -v ON_ERROR_STOP=1 \
    -f "${migration_tmp}"

# ---------------------------------------------------------------------------
# Step 3 — verify
# ---------------------------------------------------------------------------

echo "→ Verifying schema"
PGPASSWORD="${PG_ADMIN_PASSWORD}" psql \
    "host=${PG_HOST} port=5432 user=${PG_ADMIN_USER} dbname=${PG_DATABASE} sslmode=require" \
    -v ON_ERROR_STOP=1 -t -A -c \
    "SELECT table_name FROM information_schema.tables WHERE table_schema='observability' ORDER BY table_name;" \
    | tee /tmp/obs-tables.txt
got="$(grep -v '^$' /tmp/obs-tables.txt || true)"
# Expected tables: runs, metric_samples, external_calls.
# (v_runs_24h is a view, listed separately by \dv — not checked here.)
if [[ "${got}" != *"runs"* || "${got}" != *"metric_samples"* || "${got}" != *"external_calls"* ]]; then
    echo "ERROR: expected tables not found." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 4 — print URLs for KeyVault
# ---------------------------------------------------------------------------

writer_url="postgresql+psycopg://obs_writer:${PG_WRITER_PASSWORD}@${PG_HOST}:5432/${PG_DATABASE}?sslmode=require"
reader_url="postgresql+psycopg://obs_reader:${PG_READER_PASSWORD}@${PG_HOST}:5432/${PG_DATABASE}?sslmode=require"

cat <<EOF

✓ Postgres setup complete.

Stash these in KeyVault — tools and dashboards read them from there:

  az keyvault secret set --vault-name <kv> \\
      --name observability-sql-url \\
      --value '${writer_url}'

  az keyvault secret set --vault-name <kv> \\
      --name observability-sql-url-readonly \\
      --value '${reader_url}'

EOF
