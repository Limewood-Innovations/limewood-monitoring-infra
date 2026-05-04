using '../main.bicep'

param env = 'stage'
param location = 'westeurope'
param dailyQuotaGb = 2
param opsgenieWebhookUrl = readEnvironmentVariable('OPSGENIE_WEBHOOK_URL', '')

// Postgres stage: still burstable, larger disk + longer retention
param pgSkuName = 'Standard_B2ms'
param pgStorageSizeGB = 64
param pgBackupRetentionDays = 14
param pgAdminUsername = 'pgadmin'
param pgAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param pgAadAdminObjectId = readEnvironmentVariable('PG_AAD_ADMIN_OBJECT_ID', '')
param pgAadAdminPrincipalName = readEnvironmentVariable('PG_AAD_ADMIN_NAME', '')
