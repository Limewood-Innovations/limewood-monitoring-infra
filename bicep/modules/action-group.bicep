// Azure Monitor Action Group — bridge from Azure Monitor metric/log alerts
// into the existing Atlassian on-call rotation.
//
// IMPORTANT: the legacy OpsGenie "Azure Monitor" integration is **deprecated**
// since the JSM (Jira Service Management) migration. The webhook URL we accept
// here must come from a generic JSM Ops integration:
//
//   JSM → Operations → Settings → Integrations → API (or Webhook)
//   → copy the URL of shape:
//     https://api.atlassian.com/jsm/ops/integration/v2/<id>/<key>
//
// We send Azure Common Alert Schema as the payload (`useCommonAlertSchema: true`
// below). On the JSM side a "Webhook" integration with field-mapping is the
// easiest route — see the operator guide for the field-mapping template.

@description('Action Group name.')
param name string

@description('Action Group short name (≤12 chars, used in SMS / push).')
@maxLength(12)
param shortName string

@description('JSM Ops API/Webhook integration URL (api.atlassian.com/jsm/ops/integration/v2/<id>/<key>).')
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
        name: 'jsm-ops'
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
