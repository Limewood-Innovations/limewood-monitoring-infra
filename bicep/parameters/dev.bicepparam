using '../main.bicep'

param env = 'dev'
param location = 'westeurope'
param dailyQuotaGb = 1
param opsgenieWebhookUrl = readEnvironmentVariable('OPSGENIE_WEBHOOK_URL', '')

// Postgres dev: cheap burstable
param pgSkuName = 'Standard_B1ms'
param pgStorageSizeGB = 32
param pgBackupRetentionDays = 7
param pgAdminUsername = 'pgadmin'
param pgAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param pgAadAdminObjectId = readEnvironmentVariable('PG_AAD_ADMIN_OBJECT_ID', '')
param pgAadAdminPrincipalName = readEnvironmentVariable('PG_AAD_ADMIN_NAME', '')
