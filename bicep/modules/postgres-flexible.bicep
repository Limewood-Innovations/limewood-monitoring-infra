// Azure Database for PostgreSQL Flexible Server — cold-path observability store.
//
// Provisions:
//   * a Flexible Server (Burstable for dev/stage, General Purpose for prod)
//   * the `observability` database
//   * a SQL admin login (no AAD — pure SQL auth, simpler operationally)
//   * firewall rule "AllowAllAzure" to let Azure-hosted tools connect
//
// Application-level roles (`obs_writer`, `obs_reader`) and the schema are
// created post-deploy by `scripts/setup-postgres.sh`.

@description('PostgreSQL server name (must be globally unique in *.postgres.database.azure.com).')
param name string

@description('Azure region.')
param location string

@description('Environment tag.')
param env string

@description('Postgres major version.')
@allowed([
  '14'
  '15'
  '16'
])
param postgresVersion string = '16'

@description('Compute tier + SKU. Burstable B1ms is enough for dev/stage telemetry; prod uses GP_Standard_D2s_v3.')
param skuName string

@description('Storage size in GB.')
param storageSizeGB int

@description('Backup retention in days.')
@minValue(7)
@maxValue(35)
param backupRetentionDays int

@description('SQL admin login.')
param adminUsername string

@description('SQL admin password (use KeyVault reference at deploy time).')
@secure()
param adminPassword string

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: name
  location: location
  sku: {
    name: skuName
    tier: startsWith(skuName, 'Standard_B') ? 'Burstable' : 'GeneralPurpose'
  }
  properties: {
    version: postgresVersion
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: storageSizeGB
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: env == 'prod' ? 'Enabled' : 'Disabled'
    }
    highAvailability: {
      mode: env == 'prod' ? 'ZoneRedundant' : 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
  }
  tags: {
    system: 'observability'
    env: env
  }
}

resource db 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pg
  name: 'observability'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Allow Azure-hosted services (Functions, Container Apps, …) to connect.
// Tighten this with private endpoints in a follow-up iteration.
resource fwAllowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: pg
  name: 'AllowAllAzureIPs'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

output serverFqdn string = pg.properties.fullyQualifiedDomainName
output databaseName string = db.name
output serverResourceId string = pg.id
