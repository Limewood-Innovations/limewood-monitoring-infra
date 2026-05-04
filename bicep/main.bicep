// Alpenland observability stack — single shared deployment.
//
// Strategy (decided 2026-05-04): one resource group, one Application Insights,
// one Log Analytics Workspace, one Action Group — shared across dev / stage /
// prod. Tools tag every event with `app_env` so dashboards filter at query
// time.
//
// Postgres: by default this Bicep does NOT provision a managed Postgres
// server. Alpenland already runs 9 services on Azure Database for PostgreSQL
// Flexible Server, and one extra `observability` database on the existing
// instance is much cheaper than a new dedicated server. Set
// `provisionPostgres = true` to opt into a dedicated managed server.

targetScope = 'subscription'

@description('Azure region.')
param location string = 'westeurope'

@description('Resource group name — single RG holds the whole observability stack.')
param resourceGroupName string = 'alpenland-observability-rg'

@description('Daily ingestion cap in GB for Log Analytics — sized for ALL envs together. 0 = no cap.')
param dailyQuotaGb int = 5

@description('OpsGenie integration URL (Azure Monitor webhook).')
@secure()
param opsgenieWebhookUrl string

// --- Optional: provision a dedicated Postgres server ---------------------
@description('Provision a managed Postgres server in this RG. Default false — bring your own DB (recommended for Alpenland: reuse the existing portal-pg server with a new `observability` database).')
param provisionPostgres bool = false

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

@description('Object ID of the AAD principal that becomes Postgres AAD admin.')
param pgAadAdminObjectId string = ''

@description('Display name for the AAD admin (cosmetic).')
param pgAadAdminPrincipalName string = ''

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

module actionGroup 'modules/action-group.bicep' = {
  scope: rg
  name: 'action-group'
  params: {
    name: 'alpenland-obs-shared-ag'
    shortName: 'opsg-shared'
    opsgenieWebhookUrl: opsgenieWebhookUrl
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
    aadAdminObjectId: pgAadAdminObjectId
    aadAdminPrincipalName: pgAadAdminPrincipalName
  }
}

// ---------------------------------------------------------------------------
// Outputs (printed by deploy.sh for operator paste-into-KeyVault)
// ---------------------------------------------------------------------------

output resourceGroupName string = rg.name
output appInsightsConnectionString string = appInsights.outputs.connectionString
output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId
output actionGroupId string = actionGroup.outputs.actionGroupId
output postgresProvisioned bool = provisionPostgres
output postgresFqdn string = provisionPostgres
  ? postgres!.outputs.serverFqdn
  : '(BYO Postgres — set OBSERVABILITY_SQL_URL manually, see README)'
