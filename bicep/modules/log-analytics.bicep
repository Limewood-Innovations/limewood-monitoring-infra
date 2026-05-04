// Log Analytics Workspace — backing store for Application Insights
// (workspace-based AI sends all telemetry here).

@description('Workspace name.')
param name string

@description('Azure region.')
param location string

@description('Deployment environment tag.')
param env string

@description('Daily ingestion cap in GB. 0 = no cap.')
param dailyQuotaGb int

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: env == 'prod' ? 90 : 30
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb == 0 ? -1 : dailyQuotaGb
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
  tags: {
    system: 'observability'
    env: env
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output customerId string = workspace.properties.customerId
