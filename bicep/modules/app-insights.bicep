// Workspace-based Application Insights — the single hot-path sink for all
// 24 Alpenland tools. Each tool sets APPINSIGHTS_CONNECTION_STRING in its
// .env / Function-App config and the alpenland-observability library does
// the rest.

@description('Resource name.')
param name string

@description('Azure region.')
param location string

@description('Backing Log Analytics workspace ARM resource ID.')
param workspaceResourceId string

@description('Deployment environment tag.')
param env string

resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceResourceId
    IngestionMode: 'LogAnalytics'
    DisableLocalAuth: false
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
  tags: {
    system: 'observability'
    env: env
  }
}

output connectionString string = ai.properties.ConnectionString
output instrumentationKey string = ai.properties.InstrumentationKey
output appInsightsId string = ai.id
