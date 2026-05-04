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

// ---------------------------------------------------------------------------
// Resource group
// ---------------------------------------------------------------------------

var rgName = 'alpenland-observability-${env}-rg'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: {
    system: 'observability'
    managedBy: 'alpenland-monitoring-infra'
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

// ---------------------------------------------------------------------------
// Outputs (read by scripts/deploy.sh and printed for operator paste-in)
// ---------------------------------------------------------------------------

output appInsightsConnectionString string = appInsights.outputs.connectionString
output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId
output actionGroupId string = actionGroup.outputs.actionGroupId
output resourceGroupName string = rg.name
