targetScope = 'resourceGroup'

param location string
param deploymentId string
param tenantId string
param deployerObjectId string
@secure()
param qualysSubscriptionToken string
param targetLocations array
param tags object

var locationAbbrev = {
  eastus: 'eus'
  eastus2: 'eus2'
  westus: 'wus'
  westus2: 'wus2'
  westus3: 'wus3'
  centralus: 'cus'
  northcentralus: 'ncus'
  southcentralus: 'scus'
  westcentralus: 'wcus'
  canadacentral: 'cac'
  canadaeast: 'cae'
  brazilsouth: 'brs'
  northeurope: 'neu'
  westeurope: 'weu'
  uksouth: 'uks'
  ukwest: 'ukw'
  francecentral: 'frc'
  francesouth: 'frs'
  germanywestcentral: 'gwc'
  norwayeast: 'noe'
  switzerlandnorth: 'swn'
  uaenorth: 'uan'
  southafricanorth: 'san'
  australiaeast: 'aue'
  australiasoutheast: 'ause'
  australiacentral: 'auc'
  eastasia: 'ea'
  southeastasia: 'sea'
  japaneast: 'jpe'
  japanwest: 'jpw'
  koreacentral: 'krc'
  koreasouth: 'krs'
  centralindia: 'inc'
  southindia: 'ins'
  westindia: 'inw'
  usgovvirginia: 'ugv'
  usgovarizona: 'uga'
  usgovtexas: 'ugt'
}

resource scannerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'qualys-snapshot-scanner-target-cmi-${deploymentId}'
  location: location
  tags: tags
}

resource logicAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'qualys-snapshot-scanner-service-cmi-${deploymentId}'
  location: location
  tags: tags
}

resource secretsKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'qualyskv${deploymentId}'
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
  tags: tags
}

resource deployerKeyVaultAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(secretsKeyVault.id, deployerObjectId, 'Key Vault Administrator')
  scope: secretsKeyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
    principalId: deployerObjectId
    principalType: 'User'
  }
}

resource scannerKeyVaultReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(secretsKeyVault.id, scannerIdentity.id, 'Key Vault Secrets User')
  scope: secretsKeyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: scannerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource logicAppKeyVaultReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(secretsKeyVault.id, logicAppIdentity.id, 'Key Vault Secrets User')
  scope: secretsKeyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: logicAppIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource qualysTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: secretsKeyVault
  name: 'qualys-subscription-token'
  properties: {
    value: qualysSubscriptionToken
  }
  dependsOn: [deployerKeyVaultAdmin]
}

resource diskEncryptionKeyVaults 'Microsoft.KeyVault/vaults@2023-07-01' = [for loc in targetLocations: {
  name: 'qualysdisk${locationAbbrev[loc]}${deploymentId}'
  location: loc
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enabledForDiskEncryption: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    accessPolicies: [
      {
        tenantId: tenantId
        objectId: deployerObjectId
        permissions: {
          keys: ['all']
          secrets: ['all']
        }
      }
      {
        tenantId: tenantId
        objectId: scannerIdentity.properties.principalId
        permissions: {
          keys: ['get', 'wrapKey', 'unwrapKey']
        }
      }
    ]
  }
  tags: tags
}]

resource diskEncryptionKeys 'Microsoft.KeyVault/vaults/keys@2023-07-01' = [for (loc, i) in targetLocations: {
  parent: diskEncryptionKeyVaults[i]
  name: 'disk-encryption-key'
  properties: {
    kty: 'RSA'
    keySize: 2048
    keyOps: ['decrypt', 'encrypt', 'sign', 'unwrapKey', 'verify', 'wrapKey']
  }
}]

resource diskEncryptionSets 'Microsoft.Compute/diskEncryptionSets@2023-10-02' = [for (loc, i) in targetLocations: {
  name: 'qualys-disk-encryption-${loc}-${deploymentId}'
  location: loc
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scannerIdentity.id}': {}
    }
  }
  properties: {
    activeKey: {
      keyUrl: diskEncryptionKeys[i].properties.keyUriWithVersion
    }
    encryptionType: 'EncryptionAtRestWithCustomerKey'
  }
  tags: tags
}]

output scannerIdentityId string = scannerIdentity.id
output scannerIdentityClientId string = scannerIdentity.properties.clientId
output scannerIdentityPrincipalId string = scannerIdentity.properties.principalId
output logicAppIdentityId string = logicAppIdentity.id
output logicAppIdentityClientId string = logicAppIdentity.properties.clientId
output logicAppIdentityPrincipalId string = logicAppIdentity.properties.principalId
output secretsKeyVaultId string = secretsKeyVault.id
output secretsKeyVaultName string = secretsKeyVault.name
output secretsKeyVaultUri string = secretsKeyVault.properties.vaultUri
output qualysTokenSecretName string = qualysTokenSecret.name
output diskEncryptionSetIds array = [for (loc, i) in targetLocations: { location: loc, id: diskEncryptionSets[i].id }]
