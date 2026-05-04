// Azure KeyVault — single shared vault for the observability stack.
//
// Stores:
//   * appinsights-connection-string
//   * observability-pg-admin-url
//   * observability-sql-url            (obs_writer)
//   * observability-sql-url-readonly   (obs_reader)
//
// Tools (doc_search, hermes, ...) reference these via
// `@Microsoft.KeyVault(SecretUri=...)` in their Container App / Function App
// config — they don't need any direct KV-RBAC themselves; that's resolved by
// the Container App's system-assigned identity at runtime, granted "Key Vault
// Secrets User" elsewhere when each tool is wired up.
//
// The deploying user / SP gets "Key Vault Secrets Officer" so
// setup-postgres.sh can write the secrets directly.

@description('KeyVault name. Must be globally unique. Default: alpenland-obs-shared-kv (23 chars).')
@maxLength(24)
@minLength(3)
param name string = 'alpenland-obs-shared-kv'

@description('Azure region.')
param location string

@description('Environment tag.')
param env string

@description('Object ID of the principal that should be able to write secrets (the deployer running deploy.sh + setup-postgres.sh).')
param deployerObjectId string

@description('AAD tenant ID. Defaults to the subscription tenant.')
param tenantId string = subscription().tenantId

resource kv 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: name
  location: location
  properties: {
    sku: {
      name: 'standard'
      family: 'A'
    }
    tenantId: tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: env == 'prod' ? true : null
    publicNetworkAccess: 'Enabled'
  }
  tags: {
    system: 'observability'
    env: env
  }
}

// "Key Vault Secrets Officer" — read+write secrets, no key/cert permissions.
// The deployer needs this so setup-postgres.sh can store the connection
// strings without manual portal clicks.
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource secretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, deployerObjectId, secretsOfficerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      secretsOfficerRoleId
    )
    principalId: deployerObjectId
    principalType: 'User'
  }
}

output vaultName string = kv.name
output vaultUri string = kv.properties.vaultUri
output vaultId string = kv.id
