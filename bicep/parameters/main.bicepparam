using '../main.bicep'

// Shared observability stack — one resource group, one of each component,
// servicing all environments (dev / stage / prod). Tools differentiate via
// the `app_env` field on every event/metric.

param location = 'westeurope'
param resourceGroupName = 'alpenland-observability-rg'

// Global daily ingest cap across all envs and all 24 tools.
// Hit a wall? Bump cautiously — at €2.50/GB you can do worse damage with a typo.
param dailyQuotaGb = 5

// === KeyVault ============================================================
//
// Name must be globally unique across Azure. Default is reserved by us.
// If the deploy errors with "VaultNameNotAvailable", change it.
param keyVaultName = readEnvironmentVariable('KV_NAME', 'alpenland-obs-shared-kv')

// AAD object ID of the principal running deploy.sh — gets KV "Secrets
// Officer" so setup-postgres.sh can write secrets directly.
//   Get the OID:  az ad signed-in-user show --query id -o tsv
// In CI: use the SP's object ID (NOT the application/client id).
param deployerObjectId = readEnvironmentVariable('AZ_DEPLOYER_OBJECT_ID', '')

// === Postgres ============================================================
//
// DEFAULT: provision a dedicated Azure Postgres Flexible Server in this RG.
// Bicep creates the server + the `observability` database. The
// schema/tables/roles are then set up post-deploy via
// `scripts/setup-postgres.sh` (a single psql run).
//
// To OPT OUT (BYO — reuse an existing Postgres server, e.g. Alpenland's
// portal-pg): flip provisionPostgres = false. The pg* params below are then
// ignored. See README "Bring Your Own Postgres" for the manual psql setup.

param provisionPostgres = true

param pgServerName = 'alpenland-observability-pg'
param pgSkuName = 'Standard_D2s_v3'      // prod-grade — single server serves all envs
param pgStorageSizeGB = 128
param pgBackupRetentionDays = 35
param pgAdminUsername = readEnvironmentVariable('PG_ADMIN_USERNAME', 'pgadmin')
param pgAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
