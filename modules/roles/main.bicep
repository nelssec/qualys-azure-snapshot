targetScope = 'subscription'

param deploymentId string

@description('Role boundary scope - subscription ID or management group ID for tenant-wide scanning')
param roleBoundary string = subscription().id

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
          'Microsoft.DocumentDB/databaseAccounts/read'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/read'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/write'
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

output functionAppRoleId string = functionAppRole.id
output logicAppRoleId string = logicAppRole.id
output targetScannerRoleId string = targetScannerRole.id
