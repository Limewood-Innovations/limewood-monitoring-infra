#!/usr/bin/env bash
# Post-deploy Postgres bootstrapping for the observability stack.
#
# Bicep creates the Postgres flexible server + the empty `observability`
# database. This script does the SQL-layer setup that Bicep can't:
#
#   1. Creates the `observability` schema
#   2. Creates `obs_writer` (used by tools — least-privilege, no DDL)
#   3. Creates `obs_reader` (used by PowerBI / dashboards — read-only)
#   4. Applies the schema migration (CREATE TABLE / INDEX / VIEW)
#   5. Prints two SQLAlchemy URLs ready for KeyVault
#
# Idempotent: re-running on an already-bootstrapped DB is a no-op.
# Re-running after rotating a password applies the new password (ALTER ROLE).
#
# Usage:
#   source .env             # see .env.example for all required vars
#   ./scripts/setup-postgres.sh
#
# Required env vars:
#   PG_HOST                FQDN of the Postgres server (POSTGRESFQDN deploy output)
#   PG_ADMIN_USERNAME      Server admin login (default 'pgadmin' if unset)
#   PG_ADMIN_PASSWORD      Same value passed to deploy.sh
#   OBS_WRITER_USERNAME    Default 'obs_writer' if unset
#   OBS_WRITER_PASSWORD    Required (no auto-generation — you set + KV)
#   OBS_READER_USERNAME    Default 'obs_reader' if unset
#   OBS_READER_PASSWORD    Required
#
# Optional env vars:
#   PG_DATABASE            Default 'observability'
#   MIGRATIONS_REPO        Default github.com/Limewood-Innovations/limewood-observability-db@main
#   MIGRATIONS_FILE        Default src/limewood_observability_db/migrations/001_init_postgres.sql

set -euo pipefail

# --------------------------------------------------------------------------
# Auto-source .env from the repo root if any required var is still unset
# after the operator's own export. deploy.sh writes PG_HOST into .env after
# a successful deploy, so a fresh terminal session can pick it up without a
# manual `source` step.
# --------------------------------------------------------------------------
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
env_file="${repo_root}/.env"
if [[ -f "${env_file}" ]] && [[ -z "${PG_HOST:-}" || -z "${PG_ADMIN_PASSWORD:-}" ]]; then
    echo "→ Auto-loading ${env_file}"
    # shellcheck source=/dev/null
    set -a; source "${env_file}"; set +a
fi

: "${PG_HOST:?PG_HOST must be set. Run deploy.sh first (it writes PG_HOST into .env), or export PG_HOST=<your-server>.postgres.database.azure.com}"
: "${PG_ADMIN_PASSWORD:?PG_ADMIN_PASSWORD must be set (same value used in deploy.sh)}"
: "${OBS_WRITER_PASSWORD:?OBS_WRITER_PASSWORD must be set in .env}"
: "${OBS_READER_PASSWORD:?OBS_READER_PASSWORD must be set in .env}"

# Catch the .env.example placeholder text — better fail loud now than silently
# create database roles with literal "__GENERATE_AND_PUT_INTO_KEYVAULT__" as
# their password.
for var in PG_ADMIN_PASSWORD OBS_WRITER_PASSWORD OBS_READER_PASSWORD; do
    if [[ "${!var}" == *__GENERATE* ]]; then
        echo "ERROR: ${var} still contains the .env.example placeholder." >&2
        echo "       Generate a real password: openssl rand -base64 32" >&2
        exit 1
    fi
done

PG_DATABASE="${PG_DATABASE:-observability}"
PG_ADMIN_USERNAME="${PG_ADMIN_USERNAME:-pgadmin}"
OBS_WRITER_USERNAME="${OBS_WRITER_USERNAME:-obs_writer}"
OBS_READER_USERNAME="${OBS_READER_USERNAME:-obs_reader}"
MIGRATIONS_REPO="${MIGRATIONS_REPO:-https://raw.githubusercontent.com/Limewood-Innovations/limewood-observability-db/main}"
MIGRATIONS_FILE="${MIGRATIONS_FILE:-src/limewood_observability_db/migrations/001_init_postgres.sql}"

if ! command -v psql >/dev/null 2>&1; then
    echo "ERROR: psql is not installed. Install with 'brew install libpq && brew link --force libpq'" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 — schema + roles
# ---------------------------------------------------------------------------

echo "→ Creating schema + ${OBS_WRITER_USERNAME} / ${OBS_READER_USERNAME} roles on ${PG_HOST}/${PG_DATABASE}"

PGPASSWORD="${PG_ADMIN_PASSWORD}" psql \
    "host=${PG_HOST} port=5432 user=${PG_ADMIN_USERNAME} dbname=${PG_DATABASE} sslmode=require" \
    -v ON_ERROR_STOP=1 \
    -v writer_user="${OBS_WRITER_USERNAME}" \
    -v writer_pwd="${OBS_WRITER_PASSWORD}" \
    -v reader_user="${OBS_READER_USERNAME}" \
    -v reader_pwd="${OBS_READER_PASSWORD}" \
    <<'SQL'

CREATE SCHEMA IF NOT EXISTS observability;

-- Writer role (idempotent: create or update password)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'writer_user') THEN
        EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'writer_user', :'writer_pwd');
    ELSE
        EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', :'writer_user', :'writer_pwd');
    END IF;
END$$;

EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'writer_user');
GRANT USAGE   ON SCHEMA observability TO :"writer_user";
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA observability TO :"writer_user";
GRANT USAGE   ON ALL SEQUENCES IN SCHEMA observability TO :"writer_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT SELECT, INSERT, UPDATE ON TABLES TO :"writer_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT USAGE ON SEQUENCES TO :"writer_user";

-- Reader role
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'reader_user') THEN
        EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'reader_user', :'reader_pwd');
    ELSE
        EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', :'reader_user', :'reader_pwd');
    END IF;
END$$;

EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'reader_user');
GRANT USAGE   ON SCHEMA observability TO :"reader_user";
GRANT SELECT  ON ALL TABLES IN SCHEMA observability TO :"reader_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT SELECT ON TABLES TO :"reader_user";

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
    "host=${PG_HOST} port=5432 user=${PG_ADMIN_USERNAME} dbname=${PG_DATABASE} sslmode=require" \
    -v ON_ERROR_STOP=1 \
    -f "${migration_tmp}"

# ---------------------------------------------------------------------------
# Step 3 — verify
# ---------------------------------------------------------------------------

echo "→ Verifying schema"
PGPASSWORD="${PG_ADMIN_PASSWORD}" psql \
    "host=${PG_HOST} port=5432 user=${PG_ADMIN_USERNAME} dbname=${PG_DATABASE} sslmode=require" \
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
# Step 4 — write URLs directly into KeyVault (no manual copy-paste)
# ---------------------------------------------------------------------------

writer_url="postgresql+psycopg://${OBS_WRITER_USERNAME}:${OBS_WRITER_PASSWORD}@${PG_HOST}:5432/${PG_DATABASE}?sslmode=require"
reader_url="postgresql+psycopg://${OBS_READER_USERNAME}:${OBS_READER_PASSWORD}@${PG_HOST}:5432/${PG_DATABASE}?sslmode=require"
admin_url="postgresql+psycopg://${PG_ADMIN_USERNAME}:${PG_ADMIN_PASSWORD}@${PG_HOST}:5432/${PG_DATABASE}?sslmode=require"

if [[ -n "${KV_NAME:-}" ]]; then
    if ! command -v az >/dev/null 2>&1; then
        echo "ERROR: az CLI not found — can't write KV secrets automatically." >&2
        echo "       The 3 SQLAlchemy URLs are printed below; store them manually." >&2
        kv_auto=false
    else
        echo
        echo "→ Writing 3 secrets into KeyVault ${KV_NAME}"
        az keyvault secret set --vault-name "${KV_NAME}" \
            --name observability-pg-admin-url --value "${admin_url}" --output none
        az keyvault secret set --vault-name "${KV_NAME}" \
            --name observability-sql-url --value "${writer_url}" --output none
        az keyvault secret set --vault-name "${KV_NAME}" \
            --name observability-sql-url-readonly --value "${reader_url}" --output none
        kv_auto=true
    fi
else
    kv_auto=false
fi

if ${kv_auto}; then
    cat <<EOF

✓ Postgres setup complete. Three secrets written to KV ${KV_NAME}:

  observability-pg-admin-url      (admin role — for migrations / DBA work)
  observability-sql-url           (obs_writer — for tools)
  observability-sql-url-readonly  (obs_reader — for PowerBI / dashboards)

Tools reference them via @Microsoft.KeyVault(SecretUri=...). Verify with:
  az keyvault secret list --vault-name ${KV_NAME} --query '[].name' -o tsv

After verifying KV contents, you can scrub the password lines from .env.
EOF
else
    cat <<EOF

✓ Postgres setup complete. KV_NAME not set in .env — store these in KeyVault
manually:

  KV="<your-keyvault-name>"

  az keyvault secret set --vault-name "\$KV" \\
      --name observability-pg-admin-url \\
      --value '${admin_url}'

  az keyvault secret set --vault-name "\$KV" \\
      --name observability-sql-url \\
      --value '${writer_url}'

  az keyvault secret set --vault-name "\$KV" \\
      --name observability-sql-url-readonly \\
      --value '${reader_url}'

After the secrets are stored, you can scrub the password lines from .env.
EOF
fi
