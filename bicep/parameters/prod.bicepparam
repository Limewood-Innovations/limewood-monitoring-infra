using '../main.bicep'

param env = 'prod'
param location = 'westeurope'
param dailyQuotaGb = 5
param opsgenieWebhookUrl = readEnvironmentVariable('OPSGENIE_WEBHOOK_URL', '')

// Postgres prod: General Purpose, zone-redundant HA enabled (in module)
param pgSkuName = 'Standard_D2s_v3'
param pgStorageSizeGB = 128
param pgBackupRetentionDays = 35
param pgAdminUsername = 'pgadmin'
param pgAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param pgAadAdminObjectId = readEnvironmentVariable('PG_AAD_ADMIN_OBJECT_ID', '')
param pgAadAdminPrincipalName = readEnvironmentVariable('PG_AAD_ADMIN_NAME', '')
