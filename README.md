# alpenland-monitoring-infra

[![ci](https://github.com/Limewood-Innovations/alpenland-monitoring-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/Limewood-Innovations/alpenland-monitoring-infra/actions/workflows/ci.yml)

Bicep IaC for the shared Alpenland observability stack:

- **Log Analytics Workspace** (one per environment) — backing store for traces,
  metrics, and dependencies.
- **Application Insights** (workspace-based) — per-tenant connection string
  consumed by all 24 Alpenland tools via the
  [`alpenland-observability`](https://github.com/Limewood-Innovations/alpenland-observability)
  Python library.
- **Action Group** — wires Azure Monitor alerts into the existing OpsGenie
  on-call rotation.

Implements the storage/transport tier of
[[Alpenland — Observability Concept]] (M-006).

## Layout

```
bicep/
├── main.bicep                  # entry: composes modules per env
├── modules/
│   ├── log-analytics.bicep
│   ├── app-insights.bicep
│   └── action-group.bicep
└── parameters/
    ├── dev.bicepparam
    ├── stage.bicepparam
    └── prod.bicepparam
scripts/
└── deploy.sh                   # az deployment sub create --location ... --template-file ...
```

## Deploy

```bash
# Pre-req: Azure CLI logged in to the Alpenland tenant.
./scripts/deploy.sh dev
./scripts/deploy.sh stage
./scripts/deploy.sh prod
```

Each invocation creates / updates resource group `alpenland-observability-{env}-rg`
and the resources inside. Idempotent: re-running on an unchanged template is a
no-op.

## Outputs

After a successful deploy, the script prints:

```
APPINSIGHTS_CONNECTION_STRING=InstrumentationKey=...
LOG_ANALYTICS_WORKSPACE_ID=/subscriptions/.../workspaces/alpenland-obs-prod
```

These are the values to paste into each tool's `.env` (or k8s/Function-App
config) so the `alpenland-observability` library knows where to ship telemetry.

## Cost cap

`dailyQuotaGb` is set per environment in `parameters/`. Default values:

| Env   | Daily cap | Reason |
|-------|-----------|--------|
| dev   | 0.2 GB    | Cheap; just enough for smoke tests |
| stage | 1 GB      | Same shape as prod, lower volume |
| prod  | 5 GB      | Sized for ~25 tools × ~10 MB/d telemetry headroom |

Drop behaviour: once the cap is hit, AppInsights silently discards new
events until the next UTC day. The `alpenland-observability` library emits
a single WARN log line on each drop so debugging is still possible.
