targetScope = 'resourceGroup'

param location string
param deploymentId string
param targetLocations array
param targetCloud string
param tags object

var dnsSuffixes = {
  AzureCloud: {
    keyvault: 'privatelink.vaultcore.azure.net'
    blob: 'privatelink.blob.core.windows.net'
    cosmos: 'privatelink.documents.azure.com'
    web: 'privatelink.azurewebsites.net'
  }
  AzureUSGovernment: {
    keyvault: 'privatelink.vaultcore.usgovcloudapi.net'
    blob: 'privatelink.blob.core.usgovcloudapi.net'
    cosmos: 'privatelink.documents.azure.us'
    web: 'privatelink.azurewebsites.us'
  }
  AzureChinaCloud: {
    keyvault: 'privatelink.vaultcore.azure.cn'
    blob: 'privatelink.blob.core.chinacloudapi.cn'
    cosmos: 'privatelink.documents.azure.cn'
    web: 'privatelink.chinacloudsites.cn'
  }
}

var dns = dnsSuffixes[targetCloud]

resource scannerNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'qualys-scanner-nsg-${deploymentId}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHTTPSOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSSHOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
  tags: tags
}

resource serviceNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'qualys-service-nsg-${deploymentId}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHTTPSInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
  tags: tags
}

resource serviceVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'qualys-service-vnet-${deploymentId}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'function-app-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: serviceNsg.id
          }
          delegations: [
            {
              name: 'function-app-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'private-endpoints-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
  tags: tags
}

resource scannerVnets 'Microsoft.Network/virtualNetworks@2023-09-01' = [for (loc, i) in targetLocations: {
  name: 'qualys-scanner-vnet-${loc}-${deploymentId}'
  location: loc
  properties: {
    addressSpace: {
      addressPrefixes: ['10.${i + 1}.0.0/16']
    }
    subnets: [
      {
        name: 'scanner-subnet'
        properties: {
          addressPrefix: '10.${i + 1}.1.0/24'
          networkSecurityGroup: {
            id: scannerNsg.id
          }
        }
      }
    ]
  }
  tags: tags
}]

resource scannerToServicePeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = [for (loc, i) in targetLocations: {
  parent: scannerVnets[i]
  name: 'scanner-to-service-${loc}'
  properties: {
    remoteVirtualNetwork: {
      id: serviceVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}]

resource serviceToScannerPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = [for (loc, i) in targetLocations: {
  parent: serviceVnet
  name: 'service-to-scanner-${loc}'
  properties: {
    remoteVirtualNetwork: {
      id: scannerVnets[i].id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}]

resource keyvaultDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dns.keyvault
  location: 'global'
  tags: tags
}

resource blobDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dns.blob
  location: 'global'
  tags: tags
}

resource cosmosDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dns.cosmos
  location: 'global'
  tags: tags
}

resource keyvaultDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: keyvaultDnsZone
  name: 'keyvault-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: serviceVnet.id
    }
    registrationEnabled: false
  }
  tags: tags
}

resource blobDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: blobDnsZone
  name: 'blob-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: serviceVnet.id
    }
    registrationEnabled: false
  }
  tags: tags
}

resource cosmosDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: cosmosDnsZone
  name: 'cosmos-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: serviceVnet.id
    }
    registrationEnabled: false
  }
  tags: tags
}

output serviceVnetId string = serviceVnet.id
output serviceVnetName string = serviceVnet.name
output functionAppSubnetId string = serviceVnet.properties.subnets[0].id
output privateEndpointSubnetId string = serviceVnet.properties.subnets[1].id
output scannerVnetIds object = reduce(targetLocations, {}, (cur, loc, i) => union(cur, { '${loc}': scannerVnets[i].id }))
output scannerSubnetIds object = reduce(targetLocations, {}, (cur, loc, i) => union(cur, { '${loc}': scannerVnets[i].properties.subnets[0].id }))
output keyvaultDnsZoneId string = keyvaultDnsZone.id
output blobDnsZoneId string = blobDnsZone.id
output cosmosDnsZoneId string = cosmosDnsZone.id
