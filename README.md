# limewood-monitoring-infra

[![ci](https://github.com/Limewood-Innovations/limewood-monitoring-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/Limewood-Innovations/limewood-monitoring-infra/actions/workflows/ci.yml)

Bicep IaC for the **shared** Alpenland observability stack:

- **Log Analytics Workspace** — backing store for traces, metrics, dependencies.
- **Application Insights** (workspace-based) — connection string consumed by
  all 24 Alpenland tools via the
  [`limewood-observability`](https://github.com/Limewood-Innovations/limewood-observability)
  Python library.
- **Action Group** — Azure Monitor alerts → existing OpsGenie rotation.
- **Postgres** *(optional)* — by default **NOT** provisioned. Reuse Alpenland's
  existing Azure Postgres Flexible Server with one extra `observability`
  database. See [Bring Your Own Postgres](#bring-your-own-postgres) below.

## Single shared deployment

**One** resource group, **one** Application Insights, **one** Log Analytics
Workspace, **one** Action Group — shared across `dev` / `stage` / `prod`.
Tools tag every event with `app_env`, dashboards filter at query time:

```kql
customEvents | where customDimensions.app_env == "prod"
```

```sql
SELECT * FROM observability.runs WHERE app_env = 'prod';
```

Why shared? At Alpenland's volume (~MB/day across 24 tools), three separate
instances would cost ~€60/month more without measurable risk reduction. The
trade-offs are documented in the Observability Concept (Obsidian).

## Layout

```
bicep/
├── main.bicep                  # subscription-scope entry, composes modules
├── modules/
│   ├── log-analytics.bicep
│   ├── app-insights.bicep
│   ├── action-group.bicep
│   └── postgres-flexible.bicep # only when provisionPostgres=true
└── parameters/
    └── main.bicepparam         # the one and only parameter file
scripts/
└── deploy.sh
```

## Deploy

```bash
# Pre-req: az CLI logged in to the Alpenland tenant + OPSGENIE_WEBHOOK_URL set
./scripts/deploy.sh --whatif    # dry-run, see the diff
./scripts/deploy.sh             # apply
```

Idempotent — re-running on an unchanged template is a no-op.

### Outputs (operator pastes into KeyVault)

```
RESOURCEGROUPNAME=alpenland-observability-rg
APPINSIGHTSCONNECTIONSTRING=InstrumentationKey=…;IngestionEndpoint=…
LOGANALYTICSWORKSPACEID=/subscriptions/…/workspaces/alpenland-obs-shared-law
ACTIONGROUPID=/subscriptions/…/microsoft.insights/actionGroups/alpenland-obs-shared-ag
POSTGRESPROVISIONED=false
POSTGRESFQDN=(BYO Postgres — set OBSERVABILITY_SQL_URL manually, see README)
```

## Bring Your Own Postgres

Alpenland already runs ~9 services on Azure Database for PostgreSQL Flexible
Server. Add a single new **database** to that existing server instead of
provisioning a new one — cheaper and the operations team already knows it.

### One-time DBA setup

Run as the existing server admin:

```bash
psql "host=<existing-server>.postgres.database.azure.com user=<admin> sslmode=require" <<'SQL'

-- 1. Dedicated database (no mixing with portal data)
CREATE DATABASE observability
    WITH ENCODING = 'UTF8'
         LC_COLLATE = 'en_US.utf8'
         LC_CTYPE = 'en_US.utf8'
         TEMPLATE = template0;

\c observability

-- 2. Schema
CREATE SCHEMA IF NOT EXISTS observability;

-- 3. Write user (least-privilege — no DDL)
CREATE ROLE obs_writer LOGIN PASSWORD '<random-32-chars>';
GRANT CONNECT ON DATABASE observability TO obs_writer;
GRANT USAGE  ON SCHEMA observability TO obs_writer;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA observability TO obs_writer;
GRANT USAGE  ON ALL SEQUENCES IN SCHEMA observability TO obs_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT SELECT, INSERT, UPDATE ON TABLES TO obs_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT USAGE ON SEQUENCES TO obs_writer;

-- 4. Read-only user (PowerBI / dashboards)
CREATE ROLE obs_reader LOGIN PASSWORD '<random-32-chars>';
GRANT CONNECT ON DATABASE observability TO obs_reader;
GRANT USAGE  ON SCHEMA observability TO obs_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA observability TO obs_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA observability
    GRANT SELECT ON TABLES TO obs_reader;

SQL
```

### Apply schema migrations

As `pgadmin` (the writer role intentionally has no DDL):

```bash
git clone https://github.com/Limewood-Innovations/limewood-observability-db.git
psql "host=<existing-server>.postgres.database.azure.com user=pgadmin dbname=observability sslmode=require" \
    -f limewood-observability-db/src/limewood_observability_db/migrations/001_init_postgres.sql
```

Verify:

```sql
\c observability
\dt observability.*       -- expect: runs, metric_samples, external_calls
\dv observability.*       -- expect: v_runs_24h
```

### Stash connection string in KeyVault

```bash
URL="postgresql+psycopg://obs_writer:<password>@<existing-server>.postgres.database.azure.com:5432/observability?sslmode=require"
az keyvault secret set --vault-name <shared-kv> \
    --name observability-sql-url \
    --value "$URL"
```

### Tools consume it

Each instrumented tool (doc_search, hermes, …) sets the same two ENV vars
in **all three** environments — only `APP_ENV` differs:

```
OBSERVABILITY_SQL_URL=@Microsoft.KeyVault(SecretUri=…/observability-sql-url/…)
APPLICATIONINSIGHTS_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=…/appinsights-connection-string/…)
APP_ENV=dev|stage|prod
```

## Opt out: dedicated managed Postgres

If you ever decide *against* BYO and want a managed Postgres dedicated to
observability:

```bash
export PG_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export PG_AAD_ADMIN_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
export PG_AAD_ADMIN_NAME="<your display name>"
# Edit bicep/parameters/main.bicepparam → set provisionPostgres = true
./scripts/deploy.sh
```

## Cost reference (westeurope, monthly estimates)

| Component | Monthly |
|-----------|---------|
| Log Analytics + AppInsights (5 GB/d cap) | €30–60 |
| Action Group | ~€0 |
| **Total Bicep-managed (BYO mode)** | **~€30–60** |
| Postgres extra DB on existing server | ~€0 |
| Optional dedicated Postgres D2s_v3 + HA | +€270 |

Hitting the AppInsights cap? Bump `dailyQuotaGb` in
`bicep/parameters/main.bicepparam` cautiously — at €2.50/GB you can do worse
damage with a typo than with a runaway dev loop.
