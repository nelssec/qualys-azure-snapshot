targetScope = 'resourceGroup'

param location string
param deploymentId string
param tenantId string
param deployerObjectId string
@secure()
param qualysSubscriptionToken string
param targetLocations array
param roleBoundary string
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
  name: guid(secretsKeyVault.id, scannerIdentity.properties.principalId, 'Key Vault Secrets User')
  scope: secretsKeyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: scannerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource logicAppKeyVaultReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(secretsKeyVault.id, logicAppIdentity.properties.principalId, 'Key Vault Secrets User')
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
    enableRbacAuthorization: true
    enabledForDiskEncryption: true
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
}]

resource deployerDiskKvAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (loc, i) in targetLocations: {
  name: guid(diskEncryptionKeyVaults[i].id, deployerObjectId, 'Key Vault Administrator')
  scope: diskEncryptionKeyVaults[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
    principalId: deployerObjectId
    principalType: 'User'
  }
}]

resource scannerDiskKvCrypto 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (loc, i) in targetLocations: {
  name: guid(diskEncryptionKeyVaults[i].id, scannerIdentity.properties.principalId, 'Key Vault Crypto User')
  scope: diskEncryptionKeyVaults[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '12338af0-0e69-4776-bea7-57ae8d297424')
    principalId: scannerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource diskEncryptionKeys 'Microsoft.KeyVault/vaults/keys@2023-07-01' = [for (loc, i) in targetLocations: {
  parent: diskEncryptionKeyVaults[i]
  name: 'disk-encryption-key'
  properties: {
    kty: 'RSA'
    keySize: 2048
    keyOps: ['decrypt', 'encrypt', 'sign', 'unwrapKey', 'verify', 'wrapKey']
  }
  dependsOn: [deployerDiskKvAdmin]
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
  dependsOn: [scannerDiskKvCrypto]
}]

resource functionAppRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(roleBoundary, 'Qualys Scanner Function App Role', deploymentId)
  properties: {
    roleName: 'Qualys Scanner Function App Role ${deploymentId}'
    description: 'Custom role for Qualys Snapshot Scanner Function App'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/virtualMachineScaleSets/read'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read'
          'Microsoft.Compute/disks/read'
          'Microsoft.Compute/snapshots/read'
          'Microsoft.Network/networkInterfaces/read'
          'Microsoft.Network/publicIPAddresses/read'
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/read'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*'
        ]
      }
    ]
    assignableScopes: [roleBoundary]
  }
}

resource logicAppRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(roleBoundary, 'Qualys Scanner Logic App Role', deploymentId)
  properties: {
    roleName: 'Qualys Scanner Logic App Role ${deploymentId}'
    description: 'Custom role for Qualys Snapshot Scanner Logic Apps'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/virtualMachines/write'
          'Microsoft.Compute/virtualMachines/delete'
          'Microsoft.Compute/virtualMachines/runCommand/action'
          'Microsoft.Compute/virtualMachineScaleSets/read'
          'Microsoft.Compute/disks/read'
          'Microsoft.Compute/disks/write'
          'Microsoft.Compute/disks/delete'
          'Microsoft.Compute/disks/beginGetAccess/action'
          'Microsoft.Compute/disks/endGetAccess/action'
          'Microsoft.Compute/snapshots/read'
          'Microsoft.Compute/snapshots/write'
          'Microsoft.Compute/snapshots/delete'
          'Microsoft.Compute/snapshots/beginGetAccess/action'
          'Microsoft.Compute/snapshots/endGetAccess/action'
          'Microsoft.Network/networkInterfaces/read'
          'Microsoft.Network/networkInterfaces/write'
          'Microsoft.Network/networkInterfaces/delete'
          'Microsoft.Network/networkInterfaces/join/action'
          'Microsoft.Network/publicIPAddresses/read'
          'Microsoft.Network/publicIPAddresses/write'
          'Microsoft.Network/publicIPAddresses/delete'
          'Microsoft.Network/publicIPAddresses/join/action'
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/read'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
          'Microsoft.Network/networkSecurityGroups/read'
          'Microsoft.Network/networkSecurityGroups/join/action'
          'Microsoft.Logic/workflows/read'
          'Microsoft.Logic/workflows/write'
          'Microsoft.Logic/workflows/run/action'
          'Microsoft.Logic/workflows/triggers/run/action'
          'Microsoft.Web/sites/read'
          'Microsoft.Web/sites/restart/action'
          'Microsoft.Storage/storageAccounts/read'
          'Microsoft.Storage/storageAccounts/listKeys/action'
          'Microsoft.Storage/storageAccounts/blobServices/containers/read'
          'Microsoft.Storage/storageAccounts/blobServices/containers/write'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
      }
    ]
    assignableScopes: [roleBoundary]
  }
}

resource targetScannerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(roleBoundary, 'Qualys Target Scanner Role', deploymentId)
  properties: {
    roleName: 'Qualys Target Scanner Role ${deploymentId}'
    description: 'Custom role for scanning VMs in target subscriptions'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/virtualMachineScaleSets/read'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read'
          'Microsoft.Compute/disks/read'
          'Microsoft.Compute/disks/beginGetAccess/action'
          'Microsoft.Compute/snapshots/read'
          'Microsoft.Compute/snapshots/write'
          'Microsoft.Compute/snapshots/delete'
          'Microsoft.Network/networkInterfaces/read'
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/read'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
      }
    ]
    assignableScopes: [roleBoundary]
  }
}

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
output diskEncryptionSetIds object = reduce(targetLocations, {}, (cur, loc, i) => union(cur, { '${loc}': diskEncryptionSets[i].id }))
output functionAppRoleId string = functionAppRole.id
output logicAppRoleId string = logicAppRole.id
output targetScannerRoleId string = targetScannerRole.id
