# limewood-monitoring-infra

[![ci](https://github.com/Limewood-Innovations/limewood-monitoring-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/Limewood-Innovations/limewood-monitoring-infra/actions/workflows/ci.yml)

Bicep IaC for the **shared** Alpenland observability stack:

- **Log Analytics Workspace** — backing store for traces, metrics, dependencies.
- **Application Insights** (workspace-based) — connection string consumed by
  all 24 Alpenland tools via the
  [`limewood-observability`](https://github.com/Limewood-Innovations/limewood-observability)
  Python library.
- **PostgreSQL Flexible Server** — cold-path storage. Provisioned by default;
  opt out via `provisionPostgres = false` to bring your own existing server.

> **Alerting / on-call routing is intentionally NOT bundled.**
> Tools route their own heartbeats (e.g. doc_search uses
> `HEARTBEAT_URL/USER/KEY` env vars) — that path is unchanged.
> Azure-Monitor-driven alerts (anomaly detection, AppInsights availability,
> ingestion-cap alarms) can be added later as a separate concern via your
> own Action Group(s) — they are out of scope of this Bicep so the stack
> stays decoupled from any specific JSM/PagerDuty/SendGrid integration.

Pairs with:

- [`limewood-observability`](https://github.com/Limewood-Innovations/limewood-observability) — the Python library tools import
- [`limewood-observability-db`](https://github.com/Limewood-Innovations/limewood-observability-db) — SQLAlchemy schema + repositories + migrations

---

## Table of contents

1. [Single shared deployment — why](#single-shared-deployment)
2. [Layout](#layout)
3. [Deploy — step by step](#deploy--step-by-step)
   1. [Pre-flight](#21-pre-flight-one-time)
   2. [Bicep deploy](#22-bicep-deploy-10-min)
   3. [Postgres bootstrap](#23-bootstrap-postgres-2-min)
   4. [KeyVault secrets](#24-stash-secrets-in-keyvault)
   5. [Wire one tool](#25-wire-one-tool-doc_search-as-the-pilot)
   6. [Verify end-to-end](#26-verify-telemetry-is-flowing-end-to-end)
4. [Bring Your Own Postgres](#bring-your-own-postgres)
5. [What gets created](#what-gets-created)
6. [Outputs](#outputs)
7. [Cost reference](#cost-reference)
8. [Tools consume it](#tools-consume-it)
9. [Day-2 operations](#day-2-operations)
10. [Troubleshooting](#troubleshooting)
11. [Related docs](#related)

---

## Single shared deployment

**One** resource group, **one** Application Insights, **one** Log Analytics
Workspace, **one** Postgres — shared across `dev` / `stage` / `prod`. Tools
tag every event with `app_env`; dashboards filter at query time:

```kql
customEvents | where customDimensions.app_env == "prod"
```

```sql
SELECT * FROM observability.runs WHERE app_env = 'prod';
```

Why shared? At Alpenland's volume (~MB/day across 24 tools), three separate
instances would cost ~€60/month more without measurable risk reduction. The
trade-offs are documented in the *Alpenland — Observability Concept* note in
Obsidian.

---

## Layout

```
bicep/
├── main.bicep                  # subscription-scope entry, composes modules
├── modules/
│   ├── log-analytics.bicep
│   ├── app-insights.bicep
│   └── postgres-flexible.bicep # only when provisionPostgres=true
└── parameters/
    └── main.bicepparam         # the one and only parameter file
scripts/
├── deploy.sh                   # apply / what-if
└── setup-postgres.sh           # post-deploy: schema + roles + migration
```

---

## Deploy — step by step

Six ordered steps end-to-end. Each step has a verification gate; don't
proceed until the previous step passes its check.

### 2.1 Pre-flight (one-time)

| # | Action | Verify |
|---|--------|--------|
| 1 | `az login --tenant <alpenland-tenant>` + `az account set --subscription <sub>` | `az account show` shows the right subscription |
| 2 | `az provider register --namespace Microsoft.Insights` (and `Microsoft.OperationalInsights`, `Microsoft.DBforPostgreSQL`) | `az provider show -n <ns> --query registrationState` returns `Registered` |
| 3 | Generate Postgres admin password: `openssl rand -base64 32` | safe spot for the value |
| 4 | `az ad signed-in-user show --query id -o tsv` → record OBJECT_ID for AAD admin | GUID printed |

### 2.2 Bicep deploy (~10 min)

```bash
git clone https://github.com/Limewood-Innovations/limewood-monitoring-infra
cd limewood-monitoring-infra
cp .env.example .env
# edit .env — see "Required env vars" table below

set -a; source .env; set +a   # exports vars to current shell
./scripts/deploy.sh --whatif  # dry-run, see the diff
./scripts/deploy.sh           # apply
```

#### Required env vars

| Variable | Required when | Source |
|----------|---------------|--------|
| `PG_ADMIN_PASSWORD` | `provisionPostgres=true` (default) | step 3 |
| `PG_AAD_ADMIN_OBJECT_ID` | `provisionPostgres=true` | step 4 |
| `PG_AAD_ADMIN_NAME` | `provisionPostgres=true` | your display name |

deploy.sh fails fast with a helpful message if any required var is missing.

**Verify:**
```bash
az group show -n alpenland-observability-rg --query provisioningState -o tsv
# expect: Succeeded
az postgres flexible-server show -n alpenland-observability-pg \
    -g alpenland-observability-rg --query state -o tsv
# expect: Ready
```

### 2.3 Bootstrap Postgres (~2 min)

Bicep created the server + an empty `observability` database. The schema,
roles, and migration are applied via:

```bash
export PG_HOST="alpenland-observability-pg.postgres.database.azure.com"  # POSTGRESFQDN output
export PG_ADMIN_PASSWORD="$PG_ADMIN_PASSWORD"   # same value used in deploy
./scripts/setup-postgres.sh
```

The script is **idempotent** — safe to re-run. It:

1. Creates the `observability` schema
2. Creates `obs_writer` (least-privilege, no DDL) and `obs_reader` roles —
   passwords are auto-generated and printed at the end
3. Pulls the latest migration from
   [limewood-observability-db@main](https://github.com/Limewood-Innovations/limewood-observability-db/blob/main/src/limewood_observability_db/migrations/001_init_postgres.sql)
   and applies it
4. Prints two ready-to-paste SQLAlchemy URLs (writer + reader)

**Verify:**
```sql
psql "host=$PG_HOST user=pgadmin dbname=observability sslmode=require" \
     -c "\dt observability.*"
-- expect 3 rows: runs, metric_samples, external_calls
```

### 2.4 Stash secrets in KeyVault

```bash
KV="alpenland-secrets-shared-kv"   # adjust to your shared KV name

# AppInsights connection string (from 2.2 output)
az keyvault secret set --vault-name $KV \
    --name appinsights-connection-string \
    --value "InstrumentationKey=...;IngestionEndpoint=..."

# Postgres URLs (printed at the end of 2.3)
az keyvault secret set --vault-name $KV \
    --name observability-sql-url \
    --value "postgresql+psycopg://obs_writer:..."

az keyvault secret set --vault-name $KV \
    --name observability-sql-url-readonly \
    --value "postgresql+psycopg://obs_reader:..."
```

If your KV is named differently — every Alpenland project has its own KV
today — pick the one your tools already read from, OR create a new shared
one for cross-tool secrets.

### 2.5 Wire one tool (doc_search as the pilot)

In the tool's runtime env (Container App settings, Function App config,
docker-compose `.env`, k8s secret — wherever `APP_ENV` already lives):

```
APP_ENV=dev   # or stage / prod
APPLICATIONINSIGHTS_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=https://<kv>.vault.azure.net/secrets/appinsights-connection-string/)
OBSERVABILITY_SQL_URL=@Microsoft.KeyVault(SecretUri=https://<kv>.vault.azure.net/secrets/observability-sql-url/)
OBSERVABILITY_TOOL_VERSION=${GIT_VERSION}    # already set in doc_search Dockerfile
```

The library auto-discovers both exporters from those env vars. Both unset is
fine for local dev — the library falls back to a `NoopExporter`.

#### Trigger the pilot

```bash
# Container App job:
az containerapp job start --name doc-search-dev --resource-group ...
# k8s:
kubectl create job --from=cronjob/doc-search doc-search-manual-001
```

### 2.6 Verify telemetry is flowing end-to-end

**SQL side:**
```bash
psql "host=$PG_HOST user=obs_reader dbname=observability sslmode=require"
```
```sql
SELECT run_id, tool_name, app_env, success, duration_ms, started_at
FROM observability.runs
ORDER BY started_at DESC
LIMIT 5;
-- expect: at least 1 row with tool_name='doc_search', success=true

SELECT target, operation, http_status, COUNT(*)
FROM observability.external_calls
WHERE started_at > NOW() - INTERVAL '1 hour'
GROUP BY target, operation, http_status;
-- expect: rows for target='enaio', operation='documents/search/...'

SELECT metric_name, SUM(metric_value)
FROM observability.metric_samples
WHERE sampled_at > NOW() - INTERVAL '1 hour'
GROUP BY metric_name;
-- expect: pipeline.docs_added, pipeline.errors, etc.
```

**KQL side** (Azure Portal → Log Analytics workspace `alpenland-obs-shared-law` → Logs):
```kql
customEvents
| where timestamp > ago(1h)
| where customDimensions.tool_name == "doc_search"
| project timestamp, name,
          run_id      = tostring(customDimensions.run_id),
          app_env     = tostring(customDimensions.app_env),
          duration_ms = toint(customDimensions.duration_ms),
          success     = tobool(customDimensions.success)
| order by timestamp desc
```

### Day-2 — roll out to the next tool

Repeat 2.5 → 2.6 for each remaining tool. Migration template is one PR per
tool — see the per-tool migration template in
[`limewood-observability/README.md`](https://github.com/Limewood-Innovations/limewood-observability#three-line-adoption).

---

## Bring Your Own Postgres

Want to reuse Alpenland's existing Postgres server (the one Portal Backend /
DTE / Sync Service API GW already use) instead of a dedicated one?

1. Edit `bicep/parameters/main.bicepparam`: set `provisionPostgres = false`.
2. `./scripts/deploy.sh` then only deploys AppInsights + Log Analytics.
3. Run `setup-postgres.sh` against your existing server:
   ```bash
   export PG_HOST="<existing-server>.postgres.database.azure.com"
   export PG_ADMIN_PASSWORD="<existing-admin-password>"
   # The script needs CREATE DATABASE — it must connect as a server admin OR
   # the `observability` database must already exist (then it just runs the
   # schema setup inside it).
   ./scripts/setup-postgres.sh
   ```

**Tradeoff:** ~€270/month saved, but you share the existing server's
connection pool with portal/sync workloads. Telemetry-volume is small
(~MB/day at Alpenland's scale) so the impact is negligible — but a runaway
metric-emit loop in a misbehaving tool could exhaust connections shared with
the portal.

---

## What gets created

When `provisionPostgres = true` (default):

| Resource | Name | Purpose |
|----------|------|---------|
| Resource Group | `alpenland-observability-rg` | Holds everything |
| Log Analytics Workspace | `alpenland-obs-shared-law` | Backing store for AppInsights |
| Application Insights | `alpenland-obs-shared-ai` | Hot-path telemetry sink |
| Postgres Flexible Server | `alpenland-observability-pg` | Cold-path storage |
| Postgres Database | `observability` | The DB tools write to |

When `provisionPostgres = false`: only the first three are created.

> **Not created here:** Action Groups, Alert Rules, on-call routing.
> Out of scope — see the rationale at the top of this README.

---

## Outputs

After `./scripts/deploy.sh` succeeds, it prints (and the operator pastes
the relevant ones into KeyVault):

```
RESOURCEGROUPNAME=alpenland-observability-rg
APPINSIGHTSCONNECTIONSTRING=InstrumentationKey=…;IngestionEndpoint=…
LOGANALYTICSWORKSPACEID=/subscriptions/…/workspaces/alpenland-obs-shared-law
POSTGRESPROVISIONED=true
POSTGRESFQDN=alpenland-observability-pg.postgres.database.azure.com
```

`setup-postgres.sh` then prints:

```
✓ Postgres setup complete.

Stash these in KeyVault:
  observability-sql-url           postgresql+psycopg://obs_writer:...
  observability-sql-url-readonly  postgresql+psycopg://obs_reader:...
```

---

## Cost reference

westeurope, monthly estimates:

| Component | Monthly |
|-----------|---------|
| Log Analytics + AppInsights (5 GB/d cap) | €30–60 |
| Postgres D2s_v3 + zone-redundant HA | ~€270 |
| **Total (provisioned default)** | **~€300–330** |
| BYO mode (skip dedicated Postgres) | **~€30–60** |

Hitting the AppInsights cap? Bump `dailyQuotaGb` in
`bicep/parameters/main.bicepparam` cautiously — at €2.50/GB you can do worse
damage with a typo than with a runaway dev loop.

---

## Tools consume it

Each instrumented tool (doc_search, hermes, …) sets the same env vars
across **all three** environments — only `APP_ENV` differs:

```
APP_ENV=dev|stage|prod
APPLICATIONINSIGHTS_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=…/appinsights-connection-string/…)
OBSERVABILITY_SQL_URL=@Microsoft.KeyVault(SecretUri=…/observability-sql-url/…)
OBSERVABILITY_TOOL_VERSION=${GIT_VERSION}   # optional, recommended
```

In code:

```python
from limewood_observability import Observability

obs = Observability(tool_name="hermes", app_env=os.environ["APP_ENV"])
async with obs.run() as run:
    await existing_main()
```

See [`limewood-observability/README.md`](https://github.com/Limewood-Innovations/limewood-observability#three-line-adoption)
for the full library API.

---

## Day-2 operations

For incident playbooks (telemetry stopped flowing, AppInsights cap exceeded,
PG connection pool exhausted, schema migration broke a tool), backup &
restore, schema migration procedure, cost monitoring, and on-call cheat-sheet
— see the **Run Book** in Obsidian:

- *Limewood Observability — Run Book* (Obsidian)
- *Limewood Observability — Operator Guide* (Obsidian) — broader operator+developer guide
- *Alpenland — Observability Concept* (Obsidian) — design rationale + history

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `runs` table empty after deploy | `OBSERVABILITY_SQL_URL` not set in tool env | Check Container App settings; check KV reference resolves |
| AppInsights shows nothing | `APPLICATIONINSIGHTS_CONNECTION_STRING` not set OR daily cap exceeded | Check env var; check `Workspace → Usage and estimated costs` |
| `psycopg.OperationalError: connection refused` | Postgres firewall blocks the tool's outbound IP | Add firewall rule on the Postgres server (or use private endpoint) |
| `permission denied for schema observability` | Tool is connecting as the wrong user | Verify the URL secret uses `obs_writer`, not `obs_reader` |
| `relation observability.runs does not exist` | Migration wasn't applied | Re-run `./scripts/setup-postgres.sh` |
| Heartbeat fires but `success = false` in `runs` | Implementation bug — heartbeat should be gated on `success` | See doc_search:`main()` — `success` flag pattern |
| `setup-postgres.sh: psql not found` | psql client missing | `brew install libpq && brew link --force libpq` |
| `setup-postgres.sh: PG_HOST must be set` | Forgot to export the FQDN | `export PG_HOST=alpenland-observability-pg.postgres.database.azure.com` |
| `deploy.sh: PG_ADMIN_PASSWORD must be set` | provisionPostgres=true but no admin pwd in env | `export PG_ADMIN_PASSWORD=$(openssl rand -base64 32)` and stash it in KV |
| Bicep `if (provisionPostgres)` won't compile | Bicep CLI < 0.30 | `az bicep upgrade` |

---

## Related

In Obsidian (LimeWood/Customers/Alpenland/Observability/):

- **Operator Guide** — full deploy walkthrough + library API + KQL/SQL snippets
- **Run Book** — incident playbooks, backups, schema migrations, on-call
- **Observability Concept** — design rationale, trade-offs, roadmap

In code:

- [`limewood-observability`](https://github.com/Limewood-Innovations/limewood-observability) — the Python library
- [`limewood-observability-db`](https://github.com/Limewood-Innovations/limewood-observability-db) — schema + repositories + migrations
