using '../main.bicep'

param env = 'dev'
param location = 'westeurope'
param dailyQuotaGb = 1     // small cap for dev
// In dev we accept the secret in the env directly; in stage/prod it's pulled
// from a KeyVault reference at deploy time.
param opsgenieWebhookUrl = readEnvironmentVariable('OPSGENIE_WEBHOOK_URL', '')
