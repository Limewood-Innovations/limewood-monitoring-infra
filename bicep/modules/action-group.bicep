// Azure Monitor Action Group — bridge from Azure Monitor metric/log alerts
// into the existing OpsGenie on-call rotation. Used by alert rules created
// later (anomaly detection, AppInsights availability, ingestion-cap alarms).

@description('Action Group name.')
param name string

@description('Action Group short name (≤12 chars, used in SMS / push).')
@maxLength(12)
param shortName string

@description('OpsGenie integration webhook URL.')
@secure()
param opsgenieWebhookUrl string

@description('Environment tag.')
param env string

resource ag 'Microsoft.Insights/actionGroups@2024-10-01-preview' = {
  name: name
  location: 'global'
  properties: {
    enabled: true
    groupShortName: shortName
    webhookReceivers: [
      {
        name: 'opsgenie'
        serviceUri: opsgenieWebhookUrl
        useCommonAlertSchema: true
      }
    ]
  }
  tags: {
    system: 'observability'
    env: env
  }
}

output actionGroupId string = ag.id
