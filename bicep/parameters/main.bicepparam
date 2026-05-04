using '../main.bicep'

// Shared observability stack — one resource group, one of each component,
// servicing all environments (dev / stage / prod). Tools differentiate via
// the `app_env` field on every event/metric.

param location = 'westeurope'
param resourceGroupName = 'alpenland-observability-rg'

// Global daily ingest cap across all envs and all 24 tools.
// Hit a wall? Bump cautiously — at €2.50/GB you can do worse damage with a typo.
param dailyQuotaGb = 5

param opsgenieWebhookUrl = readEnvironmentVariable('OPSGENIE_WEBHOOK_URL', '')

// === Postgres ============================================================
//
// DEFAULT: BYO — reuse Alpenland's existing Azure Postgres Flexible Server
// (the one Portal Backend / DTE / Sync Service API GW already use). One extra
// `observability` database on it costs ~€0.
//
// Manual one-time setup on the existing server (see README "Bring Your Own
// Postgres"):
//   1. CREATE DATABASE observability
//   2. Run migrations/001_init_postgres.sql as the server admin
//   3. CREATE ROLE obs_writer / obs_reader (least-privilege)
//   4. Stash the resulting connection string in
//      kv-secret/observability-sql-url
//
// To OPT INTO a dedicated managed server instead: flip provisionPostgres = true
// and fill the pg* params below (or pass them via env vars).

param provisionPostgres = false

// All pg* params below are only consumed when provisionPostgres = true.
param pgServerName = 'alpenland-observability-pg'
param pgSkuName = 'Standard_D2s_v3'
param pgStorageSizeGB = 128
param pgBackupRetentionDays = 35
param pgAdminUsername = 'pgadmin'
param pgAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param pgAadAdminObjectId = readEnvironmentVariable('PG_AAD_ADMIN_OBJECT_ID', '')
param pgAadAdminPrincipalName = readEnvironmentVariable('PG_AAD_ADMIN_NAME', '')
