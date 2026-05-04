using '../main.bicep'

param env = 'prod'
param location = 'westeurope'
param dailyQuotaGb = 5
param opsgenieWebhookUrl = readEnvironmentVariable('OPSGENIE_WEBHOOK_URL', '')
