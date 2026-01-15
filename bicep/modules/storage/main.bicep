targetScope = 'resourceGroup'

param location string
param deploymentId string
param scannerIdentityId string
param scannerIdentityPrincipalId string
param privateEndpointSubnetId string
param blobDnsZoneId string
param tags object

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'qualysst${deploymentId}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scannerIdentityId}': {}
    }
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    allowSharedKeyAccess: true
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
  tags: tags
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    isVersioningEnabled: false
  }
}

resource functionPackagesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'function-app-packages'
  properties: {
    publicAccess: 'None'
  }
}

resource scannerBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, scannerIdentityPrincipalId, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: scannerIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource scannerQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, scannerIdentityPrincipalId, 'Storage Queue Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: scannerIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource storageBlobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'qualys-storage-pe-${deploymentId}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'storage-blob-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
  tags: tags
}

resource storageBlobDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: storageBlobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-dns-config'
        properties: {
          privateDnsZoneId: blobDnsZoneId
        }
      }
    ]
  }
}

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'qualys-sb-${deploymentId}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  tags: tags
}

resource discoveryQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: 'discovery-queue'
  properties: {
    enablePartitioning: false
    maxDeliveryCount: 10
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P1D'
  }
}

resource scanningQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: 'scanning-queue'
  properties: {
    enablePartitioning: false
    maxDeliveryCount: 10
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P1D'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output storageAccountPrimaryBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
#disable-next-line outputs-should-not-contain-secrets
output storageAccountKey string = storageAccount.listKeys().keys[0].value
output storageContainerName string = functionPackagesContainer.name
output serviceBusNamespace string = serviceBusNamespace.name
output serviceBusNamespaceId string = serviceBusNamespace.id
#disable-next-line outputs-should-not-contain-secrets
output serviceBusConnectionString string = listKeys('${serviceBusNamespace.id}/AuthorizationRules/RootManageSharedAccessKey', serviceBusNamespace.apiVersion).primaryConnectionString
