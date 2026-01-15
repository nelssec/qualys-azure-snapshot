targetScope = 'resourceGroup'

param location string
param deploymentId string
param subscriptionId string
param tenantId string
param logicAppIdentityId string
param logicAppIdentityPrincipalId string
param scannerIdentityId string
param scannerIdentityClientId string
param secretsKeyVaultName string
param qualysTokenSecretName string
param qualysEndpoint string
param functionAppHostname string
param functionAppName string
param storageAccountName string
param storageContainerName string
param cosmosDbEndpoint string
param serviceBusNamespace string
param targetLocations array
param targetSubscriptions array
param eventBasedDiscovery bool
param appVersion string
param tags object

var workflowPrefix = 'qualys'

resource keyvaultConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'keyvault-${deploymentId}'
  location: location
  kind: 'V1'
  properties: {
    displayName: 'Key Vault Connection'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'keyvault')
    }
    parameterValueType: 'Alternative'
    alternativeParameterValues: {
      vaultName: secretsKeyVaultName
    }
  }
}

resource keyvaultConnectionAccess 'Microsoft.Web/connections/accessPolicies@2016-06-01' = {
  parent: keyvaultConnection
  name: 'logic-app-access'
  location: location
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        tenantId: tenantId
        objectId: logicAppIdentityPrincipalId
      }
    }
  }
}

resource functionAppSyncer 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-function-app-syncer-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        Recurrence: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Hour'
            interval: 1
          }
        }
      }
      actions: {
        GetQualysToken: {
          type: 'ApiConnection'
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'keyvault\'][\'connectionId\']'
              }
            }
            method: 'get'
            path: '/secrets/@{encodeURIComponent(\'${qualysTokenSecretName}\')}/value'
          }
          runAfter: {}
        }
        DownloadFunctionAppZip: {
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: '${qualysEndpoint}/qflow/snapshot/v2/azure-snapshot-scanner-${appVersion}-functionapps.zip?format=binary&useCache=true'
            headers: {
              Authorization: 'Bearer @{body(\'GetQualysToken\')?[\'value\']}'
            }
            retryPolicy: {
              type: 'fixed'
              count: 3
              interval: 'PT30S'
            }
          }
          runAfter: {
            GetQualysToken: ['Succeeded']
          }
          limit: {
            timeout: 'PT5M'
          }
        }
        UploadToBlob: {
          type: 'Http'
          inputs: {
            method: 'PUT'
            uri: 'https://${storageAccountName}.blob.core.windows.net/${storageContainerName}/released-package.zip'
            headers: {
              'x-ms-blob-type': 'BlockBlob'
              'x-ms-version': '2020-10-02'
              'x-ms-date': '@{utcNow(\'R\')}'
              'Content-Type': 'application/octet-stream'
            }
            body: '@body(\'DownloadFunctionAppZip\')'
            authentication: {
              type: 'ManagedServiceIdentity'
              identity: logicAppIdentityId
              audience: 'https://storage.azure.com/'
            }
            retryPolicy: {
              type: 'fixed'
              count: 3
              interval: 'PT60S'
            }
          }
          runAfter: {
            DownloadFunctionAppZip: ['Succeeded']
          }
          limit: {
            timeout: 'PT5M'
          }
        }
      }
    }
    parameters: {
      '$connections': {
        value: {
          keyvault: {
            connectionId: keyvaultConnection.id
            connectionName: keyvaultConnection.name
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: logicAppIdentityId
              }
            }
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'keyvault')
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [keyvaultConnectionAccess]
}

resource registerServiceAccount 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-register-service-account-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {}
          }
        }
      }
      actions: {
        GetQualysToken: {
          type: 'ApiConnection'
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'keyvault\'][\'connectionId\']'
              }
            }
            method: 'get'
            path: '/secrets/@{encodeURIComponent(\'${qualysTokenSecretName}\')}/value'
          }
          runAfter: {}
        }
        RegisterWithQualys: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '${qualysEndpoint}/conn/snapshot/v1.0/azure/serviceaccount'
            headers: {
              Authorization: 'Bearer @{body(\'GetQualysToken\')?[\'value\']}'
              'Content-Type': 'application/json'
            }
            body: {
              subscriptionId: subscriptionId
              tenantId: tenantId
              managedIdentityId: scannerIdentityClientId
              resourceGroupName: resourceGroup().name
              deploymentId: deploymentId
            }
            retryPolicy: {
              type: 'fixed'
              count: 3
              interval: 'PT30S'
            }
          }
          runAfter: {
            GetQualysToken: ['Succeeded']
          }
        }
      }
    }
    parameters: {
      '$connections': {
        value: {
          keyvault: {
            connectionId: keyvaultConnection.id
            connectionName: keyvaultConnection.name
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: logicAppIdentityId
              }
            }
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'keyvault')
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [keyvaultConnectionAccess]
}

resource deregisterServiceAccount 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-deregister-service-account-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {}
          }
        }
      }
      actions: {}
    }
    parameters: {
      '$connections': {
        value: {
          keyvault: {
            connectionId: keyvaultConnection.id
            connectionName: keyvaultConnection.name
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: logicAppIdentityId
              }
            }
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'keyvault')
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [keyvaultConnectionAccess]
}

resource discoverResources 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-discover-resources-v2-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource pollBasedDiscover 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-poll-based-discover-vms-v2-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource eventBasedDiscover 'Microsoft.Logic/workflows@2019-05-01' = if (eventBasedDiscovery) {
  name: '${workflowPrefix}-event-based-discover-vms-v2-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource createSnapshots 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-create-snapshots-v2-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource createDisks 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-create-disks-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource prepareScanner 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-prepare-scanner-machine-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource runCommands 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-run-commands-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource concurrentScanner 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-concurrent-scanner-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource findScanCandidates 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-find-scan-candidates-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource deleteSnapshots 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-delete-snapshots-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource deleteDisks 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-delete-disks-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource deleteNics 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-delete-nics-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource deletePublicIps 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-delete-public-ips-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource deleteScannerMachines 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-delete-scanner-machines-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

resource cleanupResources 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-cleanup-resources-v2-${deploymentId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${logicAppIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {}
      actions: {}
    }
  }
  tags: tags
}

output functionAppSyncerName string = functionAppSyncer.name
output registerServiceAccountName string = registerServiceAccount.name
output workflowNames object = {
  functionAppSyncer: functionAppSyncer.name
  registerServiceAccount: registerServiceAccount.name
  discoverResources: discoverResources.name
  createSnapshots: createSnapshots.name
  prepareScanner: prepareScanner.name
  cleanupResources: cleanupResources.name
}
