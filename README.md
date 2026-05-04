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

## Default deployment: Bicep provisions Postgres

After `./scripts/deploy.sh` finishes, Bicep has created a managed Postgres
Flexible Server (default `Standard_D2s_v3` + zone-redundant HA in prod) and
an empty `observability` database. The schema, roles, and migrations are
applied via a one-liner post-deploy:

```bash
export PG_HOST="alpenland-observability-pg.postgres.database.azure.com"  # from POSTGRESFQDN output
export PG_ADMIN_PASSWORD="$PG_ADMIN_PASSWORD"   # same value used in deploy
./scripts/setup-postgres.sh
```

The script:

1. Creates the `observability` schema
2. Creates `obs_writer` (least-privilege, no DDL) and `obs_reader` roles
3. Pulls and runs the latest migration from `limewood-observability-db@main`
4. Prints two SQLAlchemy URLs to paste into KeyVault

Idempotent — re-running on an already-bootstrapped DB is a no-op.

## Alternative: Bring Your Own Postgres

Want to reuse Alpenland's existing Postgres server (the one Portal Backend /
DTE / Sync Service API GW already use) instead of a dedicated one?

1. Edit `bicep/parameters/main.bicepparam`: set `provisionPostgres = false`.
2. `./scripts/deploy.sh` then only deploys AppInsights + Log Analytics +
   Action Group.
3. Run `setup-postgres.sh` against your existing server (set
   `PG_HOST=<existing-fqdn>`, `PG_ADMIN_PASSWORD=<existing-admin-pwd>`).
   Same script, just points at a different server.

Tradeoff: ~€270/month saved, but you share the existing server's connection
pool with portal/sync workloads.

### Tools consume it

Each instrumented tool (doc_search, hermes, …) sets the same two ENV vars
in **all three** environments — only `APP_ENV` differs:

```
OBSERVABILITY_SQL_URL=@Microsoft.KeyVault(SecretUri=…/observability-sql-url/…)
APPLICATIONINSIGHTS_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=…/appinsights-connection-string/…)
APP_ENV=dev|stage|prod
```

## Cost reference (westeurope, monthly estimates)

| Component | Monthly |
|-----------|---------|
| Log Analytics + AppInsights (5 GB/d cap) | €30–60 |
| Action Group | ~€0 |
| Postgres D2s_v3 + zone-redundant HA (default) | ~€270 |
| **Total Bicep-managed (provisioned)** | **~€300–330** |
| BYO mode: skip dedicated Postgres | **~€30–60** |

Hitting the AppInsights cap? Bump `dailyQuotaGb` in
`bicep/parameters/main.bicepparam` cautiously — at €2.50/GB you can do worse
damage with a typo than with a runaway dev loop.
