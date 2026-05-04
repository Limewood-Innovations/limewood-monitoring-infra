using '../main.bicep'

param env = 'stage'
param location = 'westeurope'
param dailyQuotaGb = 2
param opsgenieWebhookUrl = readEnvironmentVariable('OPSGENIE_WEBHOOK_URL', '')
