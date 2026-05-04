// Alpenland observability stack — entry point.
//
// Provisions a Log Analytics Workspace + workspace-based Application Insights
// + an Action Group that bridges Azure Monitor alerts into OpsGenie.

targetScope = 'subscription'

@description('Deployment environment: dev | stage | prod.')
@allowed([
  'dev'
  'stage'
  'prod'
])
param env string

@description('Azure region for the observability resources.')
param location string = 'westeurope'

@description('Daily ingestion quota in GB for the Log Analytics workspace. 0 = no cap.')
param dailyQuotaGb int

@description('OpsGenie integration URL (Azure Monitor webhook). Pulled from KeyVault in prod.')
@secure()
param opsgenieWebhookUrl string

// --- PostgreSQL params (cold-path observability store) -------------------
@description('PostgreSQL admin SQL login. KeyVault reference recommended.')
@secure()
param pgAdminPassword string
@description('PostgreSQL admin SQL username.')
param pgAdminUsername string = 'pgadmin'
@description('Object ID of the AAD principal that becomes Postgres AAD admin.')
param pgAadAdminObjectId string
@description('Display name for the AAD admin (cosmetic).')
param pgAadAdminPrincipalName string
@description('Postgres SKU per env (B1ms for dev/stage, D2s_v3 for prod).')
param pgSkuName string
@description('Postgres storage GB.')
param pgStorageSizeGB int = 32
@description('Postgres backup retention days.')
param pgBackupRetentionDays int = 7

// ---------------------------------------------------------------------------
// Resource group
// ---------------------------------------------------------------------------

var rgName = 'limewood-observability-${env}-rg'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: {
    system: 'observability'
    managedBy: 'limewood-monitoring-infra'
    env: env
  }
}

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

module logAnalytics 'modules/log-analytics.bicep' = {
  scope: rg
  name: 'log-analytics'
  params: {
    name: 'alpenland-obs-${env}-law'
    location: location
    dailyQuotaGb: dailyQuotaGb
    env: env
  }
}

module appInsights 'modules/app-insights.bicep' = {
  scope: rg
  name: 'app-insights'
  params: {
    name: 'alpenland-obs-${env}-ai'
    location: location
    workspaceResourceId: logAnalytics.outputs.workspaceId
    env: env
  }
}

module actionGroup 'modules/action-group.bicep' = {
  scope: rg
  name: 'action-group'
  params: {
    name: 'alpenland-obs-${env}-ag'
    shortName: 'opsg-${env}'
    opsgenieWebhookUrl: opsgenieWebhookUrl
    env: env
  }
}

module postgres 'modules/postgres-flexible.bicep' = {
  scope: rg
  name: 'postgres'
  params: {
    name: 'alpenland-obs-${env}-pg'
    location: location
    env: env
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
// Outputs (read by scripts/deploy.sh and printed for operator paste-in)
// ---------------------------------------------------------------------------

output appInsightsConnectionString string = appInsights.outputs.connectionString
output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId
output actionGroupId string = actionGroup.outputs.actionGroupId
output resourceGroupName string = rg.name
output postgresFqdn string = postgres.outputs.serverFqdn
output postgresDatabase string = postgres.outputs.databaseName
output observabilitySqlUrl string = 'postgresql+psycopg://<user>:<pwd>@${postgres.outputs.serverFqdn}:5432/${postgres.outputs.databaseName}?sslmode=require'
