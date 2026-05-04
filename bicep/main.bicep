// Alpenland observability stack — single shared deployment.
//
// Strategy (decided 2026-05-04): one resource group, one Application Insights,
// one Log Analytics Workspace — shared across dev / stage / prod. Tools tag
// every event with `app_env` so dashboards filter at query time.
//
// Postgres: by default this Bicep provisions a managed PostgreSQL Flexible
// Server in this RG. Set `provisionPostgres = false` to bring your own
// existing server; the schema is then bootstrapped on it via
// `scripts/setup-postgres.sh`.
//
// Alerting / on-call routing is intentionally NOT bundled here. Heartbeats
// from individual tools (e.g. doc_search) keep using their existing
// HEARTBEAT_URL/USER/KEY env vars — that path is unchanged. Azure Monitor
// alert rules + Action Groups can be added later as a separate concern.

targetScope = 'subscription'

@description('Azure region.')
param location string = 'westeurope'

@description('Resource group name — single RG holds the whole observability stack.')
param resourceGroupName string = 'alpenland-observability-rg'

@description('Daily ingestion cap in GB for Log Analytics — sized for ALL envs together. 0 = no cap.')
param dailyQuotaGb int = 5

// --- Optional: provision a dedicated Postgres server ---------------------
@description('Provision a managed Postgres server in this RG. Default true. Set false to bring your own existing Postgres (run setup-postgres.sh against it instead).')
param provisionPostgres bool = true

@description('Postgres server name (only used when provisionPostgres=true).')
param pgServerName string = 'alpenland-observability-pg'

@description('Postgres SKU.')
param pgSkuName string = 'Standard_D2s_v3'

@description('Postgres storage GB.')
param pgStorageSizeGB int = 128

@description('Postgres backup retention days.')
param pgBackupRetentionDays int = 35

@description('Postgres SQL admin login.')
param pgAdminUsername string = 'pgadmin'

@description('Postgres SQL admin password — KeyVault reference recommended. Empty when provisionPostgres=false.')
@secure()
param pgAdminPassword string = ''

// ---------------------------------------------------------------------------
// Resource group
// ---------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    system: 'observability'
    managedBy: 'limewood-monitoring-infra'
    customer: 'alpenland'
    scope: 'shared (dev/stage/prod)'
  }
}

// ---------------------------------------------------------------------------
// Modules — single instance each, shared across all envs
// ---------------------------------------------------------------------------

module logAnalytics 'modules/log-analytics.bicep' = {
  scope: rg
  name: 'log-analytics'
  params: {
    name: 'alpenland-obs-shared-law'
    location: location
    dailyQuotaGb: dailyQuotaGb
    env: 'shared'
  }
}

module appInsights 'modules/app-insights.bicep' = {
  scope: rg
  name: 'app-insights'
  params: {
    name: 'alpenland-obs-shared-ai'
    location: location
    workspaceResourceId: logAnalytics.outputs.workspaceId
    env: 'shared'
  }
}

module postgres 'modules/postgres-flexible.bicep' = if (provisionPostgres) {
  scope: rg
  name: 'postgres'
  params: {
    name: pgServerName
    location: location
    env: 'shared'
    skuName: pgSkuName
    storageSizeGB: pgStorageSizeGB
    backupRetentionDays: pgBackupRetentionDays
    adminUsername: pgAdminUsername
    adminPassword: pgAdminPassword
  }
}

// ---------------------------------------------------------------------------
// Outputs (printed by deploy.sh for operator paste-into-KeyVault)
// ---------------------------------------------------------------------------

output resourceGroupName string = rg.name
output appInsightsConnectionString string = appInsights.outputs.connectionString
output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId
output postgresProvisioned bool = provisionPostgres
output postgresFqdn string = provisionPostgres
  ? postgres!.outputs.serverFqdn
  : '(BYO Postgres — set OBSERVABILITY_SQL_URL manually, see README)'
