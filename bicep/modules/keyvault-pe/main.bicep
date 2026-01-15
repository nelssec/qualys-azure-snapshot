targetScope = 'resourceGroup'

param location string
param deploymentId string
param keyVaultId string
param privateEndpointSubnetId string
param keyvaultDnsZoneId string
param tags object

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'qualys-kv-pe-${deploymentId}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'keyvault-connection'
        properties: {
          privateLinkServiceId: keyVaultId
          groupIds: ['vault']
        }
      }
    ]
  }
  tags: tags
}

resource keyVaultDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'keyvault-dns-config'
        properties: {
          privateDnsZoneId: keyvaultDnsZoneId
        }
      }
    ]
  }
}

output privateEndpointId string = keyVaultPrivateEndpoint.id
