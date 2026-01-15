targetScope = 'resourceGroup'

param location string
param deploymentId string
param subscriptionId string
param tenantId string
param logicAppIdentityId string
#disable-next-line secure-secrets-in-params
param secretsKeyVaultName string
param qualysTokenSecretName string
param qualysEndpoint string
param functionAppHostname string
param storageAccountName string
param storageContainerName string
param eventBasedDiscovery bool
param appVersion string
param pollIntervalHours int = 4
param scanIntervalHours int = 24
param locationConcurrency int = 5
param scannersPerLocation int = 1
param tags object

var workflowPrefix = 'qualys'
var functionAppUrl = 'https://${functionAppHostname}'
var storageSuffix = environment().suffixes.storage
var scannerIdentityResourceId = '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/qualys-snapshot-scanner-service-cmi-${deploymentId}'

#disable-next-line BCP037
resource keyvaultConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'keyvault-${deploymentId}'
  location: location
  properties: {
    displayName: 'Key Vault Connection'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'keyvault')
    }
    #disable-next-line BCP037
    parameterValueType: 'Alternative'
    #disable-next-line BCP037
    alternativeParameterValues: {
      vaultName: secretsKeyVaultName
    }
  }
  tags: tags
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
            uri: 'https://${storageAccountName}.blob.${storageSuffix}/${storageContainerName}/released-package.zip'
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
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        RegisterServiceAccountApi: {
          type: 'Http'
          limit: {
            timeout: 'PT10S'
          }
          inputs: {
            uri: '${qualysEndpoint}/conn/snapshot/v1.0/register-service-account/azure'
            headers: {
              Authorization: '@{concat(\'Bearer \', body(\'GetQualysToken\')?[\'value\'])}'
            }
            method: 'POST'
            body: {
              accountId: subscriptionId
              schedule: '0 * * ? * * *'
              tags: [
                {
                  tagKey: 'QUALYS_SNAPSHOT_ENABLED'
                  tagValue: 'true'
                }
              ]
            }
            retryPolicy: {
              type: 'none'
            }
          }
          runAfter: {
            GetQualysToken: ['Succeeded']
          }
        }
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
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@outputs(\'RegisterServiceAccountApi\')'
            }
          }
          runAfter: {
            RegisterServiceAccountApi: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: '@if(equals(outputs(\'RegisterServiceAccountApi\')[\'statusCode\'], 304), 200, outputs(\'RegisterServiceAccountApi\')[\'statusCode\'])'
            body: {
              message: '@outputs(\'RegisterServiceAccountApi\')'
            }
          }
          runAfter: {
            RegisterServiceAccountApi: ['TIMEDOUT', 'FAILED', 'SKIPPED']
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
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
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
        DeRegisterServiceAccountApi: {
          type: 'Http'
          limit: {
            timeout: 'PT10S'
          }
          inputs: {
            uri: '${qualysEndpoint}/conn/snapshot/v1.0/deregister-service-account/azure/${tenantId}'
            headers: {
              Authorization: '@{concat(\'Bearer \', body(\'GetQualysToken\')?[\'value\'])}'
            }
            method: 'DELETE'
            retryPolicy: {
              type: 'none'
            }
          }
          runAfter: {
            GetQualysToken: ['Succeeded']
          }
        }
        DisableRegisterServiceAccount: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/arm/logic'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              resource: 'workflows'
              method: 'disable'
              parameters: ['qualys-snapshot-scanner', 'qualys-register-service-account-${deploymentId}']
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            DeRegisterServiceAccountApi: ['Succeeded']
          }
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: {
                DeRegisterServiceAccountApi: '@outputs(\'DeRegisterServiceAccountApi\')'
                DisableRegisterServiceAccount: '@outputs(\'DisableRegisterServiceAccount\')'
              }
            }
          }
          runAfter: {
            DisableRegisterServiceAccount: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 422
            body: {
              message: {
                DeRegisterServiceAccountApi: '@outputs(\'DeRegisterServiceAccountApi\')'
                DisableRegisterServiceAccount: '@outputs(\'DisableRegisterServiceAccount\')'
              }
            }
          }
          runAfter: {
            DisableRegisterServiceAccount: ['TIMEDOUT', 'FAILED', 'SKIPPED']
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
      parameters: {}
      triggers: {
        Poll: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Hour'
            interval: pollIntervalHours
          }
          runtimeConfiguration: {
            concurrency: {
              runs: 1
            }
          }
        }
      }
      actions: {
        PrepareJobsForDiscoverVMs: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/functions/DiscoveryTasksOrchestrator'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              workflow: '@{last(split(workflow().run.id, \'/\'))}'
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {}
        }
        IfJobsPrepared: {
          type: 'If'
          expression: {
            and: [
              {
                equals: ['@outputs(\'PrepareJobsForDiscoverVMs\')[\'statusCode\']', 200]
              }
              {
                not: {
                  equals: ['@body(\'PrepareJobsForDiscoverVMs\')', null]
                }
              }
            ]
          }
          actions: {
            ExecuteTasks: {
              type: 'Workflow'
              inputs: {
                host: {
                  workflow: {
                    id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-discover-resources-v2-${deploymentId}'
                  }
                  triggerName: 'HttpTrigger'
                }
                headers: {
                  'content-type': 'application/json'
                }
                body: {}
                retryPolicy: {
                  type: 'none'
                }
              }
              limit: {
                timeout: 'PT60S'
              }
              runAfter: {}
            }
            SuppressErrorExecuteTasks: {
              type: 'Compose'
              inputs: ''
              runAfter: {
                ExecuteTasks: ['TIMEDOUT', 'FAILED']
              }
            }
          }
          runAfter: {
            PrepareJobsForDiscoverVMs: ['Succeeded']
          }
        }
        LogPrepareJobsForDiscoverVMs: {
          type: 'Scope'
          actions: {
            PrepareJobsForDiscoverVMsEventLog: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/db/create'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  container: 'event-logs'
                  body: {
                    item: {
                      runId: '@{workflow()[\'run\'][\'name\']}'
                      resource: 'FunctionApp'
                      location: location
                      subscriptionId: subscriptionId
                      state: 'PrepareJobsForDiscoverVMs'
                      input: {
                        workflow: '@{last(split(workflow().run.id, \'/\'))}'
                      }
                      output: {
                        PrepareJobsForDiscoverVMs: '@outputs(\'PrepareJobsForDiscoverVMs\')'
                      }
                      error: '@if(equals(actions(\'PrepareJobsForDiscoverVMs\')[\'status\'], \'Succeeded\'), false, true)'
                    }
                  }
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  type: 'none'
                }
              }
              runAfter: {}
            }
            PrepareJobsForDiscoverVMsEventLogSuppressError: {
              type: 'Compose'
              inputs: ''
              runAfter: {
                PrepareJobsForDiscoverVMsEventLog: ['TIMEDOUT', 'FAILED']
              }
            }
          }
          runAfter: {
            PrepareJobsForDiscoverVMs: ['Succeeded', 'FAILED', 'TIMEDOUT']
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [discoverResources]
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
      parameters: {}
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {
            concurrency: {
              runs: 1
            }
          }
        }
      }
      actions: {
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 202
            body: {
              message: 'Accepted'
            }
          }
          operationOptions: 'Asynchronous'
          runAfter: {}
        }
        ExecuteTaks: {
          type: 'Until'
          expression: '@and(equals(outputs(\'Query\')[\'statusCode\'], 200), equals(length(body(\'Query\').resources), 0))'
          actions: {
            Query: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/db/query'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  body: {
                    query: 'SELECT * FROM c WHERE c.status = 0 AND c.retry < 3 ORDER BY c._ts DESC, c.priority DESC OFFSET 0 LIMIT 50'
                    incr: true
                    key: 'workflow'
                  }
                  container: 'tasks'
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            ForEachTask: {
              type: 'Foreach'
              foreach: '@body(\'Query\').resources'
              actions: {
                DiscoverVMs: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/functions/DiscoverVMsOrchestrator'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: '@item()'
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {}
                }
                LogDiscoverVMs: {
                  type: 'Scope'
                  actions: {
                    DiscoverVMsEventLog: {
                      type: 'Http'
                      inputs: {
                        uri: '${functionAppUrl}/api/db/create'
                        headers: {
                          'Content-Type': 'application/json'
                        }
                        body: {
                          container: 'event-logs'
                          body: {
                            item: {
                              runId: '@{workflow()[\'run\'][\'name\']}'
                              resource: 'DurableFunction'
                              location: '@item()[\'locations\']'
                              subscriptionId: '@item()[\'subscription\']'
                              state: 'DiscoverVMs'
                              input: '@item()'
                              output: {
                                DiscoverVMs: '@outputs(\'DiscoverVMs\')'
                              }
                              error: '@if(equals(actions(\'DiscoverVMs\')[\'status\'], \'Succeeded\'), false, true)'
                            }
                          }
                        }
                        method: 'POST'
                        authentication: {
                          identity: scannerIdentityResourceId
                          type: 'ManagedServiceIdentity'
                        }
                        retryPolicy: {
                          type: 'none'
                        }
                      }
                      runAfter: {}
                    }
                    DiscoverVMsEventLogSuppressError: {
                      type: 'Compose'
                      inputs: ''
                      runAfter: {
                        DiscoverVMsEventLog: ['TIMEDOUT', 'FAILED']
                      }
                    }
                  }
                  runAfter: {
                    DiscoverVMs: ['Succeeded', 'FAILED', 'TIMEDOUT']
                  }
                }
              }
              runtimeConfiguration: {
                concurrency: {
                  repetitions: 50
                }
              }
              runAfter: {
                Query: ['Succeeded']
              }
            }
          }
          limit: {
            count: 1000
            timeout: 'PT1440S'
          }
          runAfter: {
            SuccessResponse: ['Succeeded']
          }
        }
        CreateSnapshots: {
          type: 'Workflow'
          inputs: {
            host: {
              workflow: {
                id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-create-snapshots-v2-${deploymentId}'
              }
              triggerName: 'HttpTrigger'
            }
            headers: {
              'content-type': 'application/json'
            }
            body: {}
            retryPolicy: {
              type: 'none'
            }
          }
          limit: {
            timeout: 'PT60S'
          }
          runAfter: {
            ExecuteTaks: ['Succeeded', 'TIMEDOUT', 'FAILED']
          }
        }
        SuppressErrorCreateSnapshot: {
          type: 'Compose'
          inputs: ''
          runAfter: {
            CreateSnapshots: ['TIMEDOUT', 'FAILED']
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [createSnapshots]
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
      parameters: {}
      triggers: {
        Poll: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Minute'
            interval: 3
          }
          runtimeConfiguration: {
            concurrency: {
              runs: 10
            }
          }
        }
      }
      actions: {
        Until: {
          type: 'Until'
          expression: '@and(equals(outputs(\'FetchMessages\')[\'statusCode\'], 200),equals(length(body(\'FetchMessages\')),0))'
          actions: {
            FetchMessages: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/messages/list'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {}
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 1
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            HasMessage: {
              type: 'If'
              expression: {
                and: [
                  {
                    equals: ['@outputs(\'FetchMessages\')[\'statusCode\']', 200]
                  }
                  {
                    greater: ['@length(body(\'FetchMessages\'))', 0]
                  }
                ]
              }
              actions: {
                GetTags: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/format/parse-tags'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {}
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {}
                }
                ExecuteTasks: {
                  type: 'Workflow'
                  inputs: {
                    host: {
                      workflow: {
                        id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-discover-resources-v2-${deploymentId}'
                      }
                      triggerName: 'HttpTrigger'
                    }
                    headers: {
                      'content-type': 'application/json'
                    }
                    body: {}
                    retryPolicy: {
                      type: 'none'
                    }
                  }
                  limit: {
                    timeout: 'PT60S'
                  }
                  runAfter: {
                    GetTags: ['Succeeded']
                  }
                }
                SuppressErrorExecuteTasks: {
                  type: 'Compose'
                  inputs: ''
                  runAfter: {
                    ExecuteTasks: ['TIMEDOUT', 'FAILED']
                  }
                }
                CreateSnapshots: {
                  type: 'Workflow'
                  inputs: {
                    host: {
                      workflow: {
                        id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-create-snapshots-v2-${deploymentId}'
                      }
                      triggerName: 'HttpTrigger'
                    }
                    headers: {
                      'content-type': 'application/json'
                    }
                    body: {
                      parentId: '@workflow()[\'run\'][\'name\']'
                    }
                    retryPolicy: {
                      type: 'none'
                    }
                  }
                  limit: {
                    timeout: 'PT60S'
                  }
                  runAfter: {
                    ExecuteTasks: ['Succeeded', 'TIMEDOUT', 'FAILED']
                  }
                }
                SuppressErrorCreateSnapshot: {
                  type: 'Compose'
                  inputs: ''
                  runAfter: {
                    CreateSnapshots: ['TIMEDOUT', 'FAILED']
                  }
                }
              }
              runAfter: {
                FetchMessages: ['Succeeded']
              }
            }
          }
          limit: {
            count: 10
            timeout: 'PT180S'
          }
          runAfter: {}
        }
      }
    }
  }
  tags: tags
  dependsOn: [discoverResources, createSnapshots]
}

resource demandBasedDiscover 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${workflowPrefix}-demand-based-discover-vms-v2-${deploymentId}'
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
      parameters: {}
      triggers: {
        Poll: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Minute'
            interval: 3
          }
          runtimeConfiguration: {
            concurrency: {
              runs: 10
            }
          }
        }
      }
      actions: {
        FetchTasks: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/app/tasks'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              workflow: '@{last(split(workflow().run.id, \'/\'))}'
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {}
        }
        HasMessage: {
          type: 'If'
          expression: {
            and: [
              {
                equals: ['@outputs(\'FetchTasks\')[\'statusCode\']', 200]
              }
              {
                greater: ['@body(\'FetchTasks\')[\'count\']', 0]
              }
            ]
          }
          actions: {
            ExecuteTasks: {
              type: 'Workflow'
              inputs: {
                host: {
                  workflow: {
                    id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-discover-resources-v2-${deploymentId}'
                  }
                  triggerName: 'HttpTrigger'
                }
                headers: {
                  'content-type': 'application/json'
                }
                body: {}
                retryPolicy: {
                  type: 'none'
                }
              }
              limit: {
                timeout: 'PT60S'
              }
              runAfter: {}
            }
            SuppressErrorExecuteTasks: {
              type: 'Compose'
              inputs: ''
              runAfter: {
                ExecuteTasks: ['TIMEDOUT', 'FAILED']
              }
            }
            CreateSnapshots: {
              type: 'Workflow'
              inputs: {
                host: {
                  workflow: {
                    id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-create-snapshots-v2-${deploymentId}'
                  }
                  triggerName: 'HttpTrigger'
                }
                headers: {
                  'content-type': 'application/json'
                }
                body: {
                  parentId: '@workflow()[\'run\'][\'name\']'
                }
                retryPolicy: {
                  type: 'none'
                }
              }
              limit: {
                timeout: 'PT60S'
              }
              runAfter: {
                ExecuteTasks: ['Succeeded', 'TIMEDOUT', 'FAILED']
              }
            }
            SuppressErrorCreateSnapshot: {
              type: 'Compose'
              inputs: ''
              runAfter: {
                CreateSnapshots: ['TIMEDOUT', 'FAILED']
              }
            }
          }
          runAfter: {
            FetchTasks: ['Succeeded']
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [discoverResources, createSnapshots]
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
        QENDPOINT: {
          type: 'SecureString'
          defaultValue: qualysEndpoint
        }
      }
      triggers: {
        Poll: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Minute'
            interval: scanIntervalHours * 60
          }
          runtimeConfiguration: {
            concurrency: {
              runs: 1
            }
          }
        }
      }
      actions: {
        GetQualysTokenFromKV: {
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
        GetLocations: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/db/query'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              container: 'resource-inventory'
              body: {
                query: 'SELECT VALUE c.location FROM c WHERE c.state = "SnapshotsCompleted" AND c.retry < 3 GROUP BY c.location'
              }
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            GetQualysTokenFromKV: ['Succeeded']
          }
        }
        LogGetLocationsQueryFailed: {
          type: 'Scope'
          actions: {
            QueryFailedEventLog: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/db/create'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  container: 'event-logs'
                  body: {
                    item: {
                      parentId: '@{workflow()[\'run\'][\'name\']}'
                      triggerId: '@{workflow()[\'run\'][\'name\']}'
                      runId: '@{workflow()[\'run\'][\'name\']}'
                      resource: 'CosmosDb'
                      location: location
                      subscriptionId: subscriptionId
                      state: 'GetReadyToScanLocations'
                      input: {}
                      output: {
                        GetLocations: '@outputs(\'GetLocations\')'
                      }
                      error: true
                    }
                  }
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  type: 'none'
                }
              }
              runAfter: {}
            }
            QueryFailedEventLogSuppressError: {
              type: 'Compose'
              inputs: ''
              runAfter: {
                QueryFailedEventLog: ['TIMEDOUT', 'FAILED']
              }
            }
          }
          runAfter: {
            GetLocations: ['TIMEDOUT', 'FAILED']
          }
        }
        CheckQflowHealth: {
          type: 'Http'
          limit: {
            timeout: 'PT10S'
          }
          inputs: {
            uri: '${qualysEndpoint}/qflow/api/v1/health'
            headers: {
              Authorization: '@{concat(\'Bearer \', body(\'GetQualysTokenFromKV\')?[\'value\'])}'
            }
            method: 'GET'
            retryPolicy: {
              type: 'none'
            }
          }
          runAfter: {
            GetLocations: ['Succeeded']
          }
        }
        ForEachLocation: {
          type: 'Foreach'
          foreach: '@body(\'GetLocations\').resources'
          actions: {
            ConcurrentScan: {
              type: 'Workflow'
              inputs: {
                host: {
                  workflow: {
                    id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-concurrent-scanner-${deploymentId}'
                  }
                  triggerName: 'HttpTrigger'
                }
                headers: {
                  'content-type': 'application/json'
                }
                body: {
                  location: '@item()'
                }
                retryPolicy: {
                  type: 'none'
                }
              }
              limit: {
                timeout: 'PT14400S'
              }
              runAfter: {}
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: locationConcurrency
            }
          }
          runAfter: {
            CheckQflowHealth: ['Succeeded']
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
  dependsOn: [concurrentScanner]
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {
            concurrency: {
              runs: 1
            }
          }
        }
      }
      actions: {
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 202
            body: {
              message: 'Accepted'
            }
          }
          operationOptions: 'Asynchronous'
          runAfter: {}
        }
        CreateSnapshots: {
          type: 'Until'
          expression: '@and(equals(outputs(\'Query\')[\'statusCode\'], 200), equals(length(body(\'Query\').resources), 0))'
          actions: {
            Query: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/db/query'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  body: {
                    query: 'SELECT * FROM c WHERE c.state = \'Discovered\' AND c.retry < 3 OFFSET 0 LIMIT 50'
                    incr: true
                  }
                  container: 'resource-inventory'
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            ForEachVM: {
              type: 'Foreach'
              foreach: '@body(\'Query\').resources'
              actions: {
                CreateSnapshot: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/arm/compute'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      resource: 'snapshots'
                      method: 'beginCreateOrUpdate'
                      parameters: [
                        'qualys-snapshot-scanner'
                        'qualys-snapshot-@{item()[\'disks\'][0][\'uid\']}'
                        {
                          osType: 'Linux'
                          sku: {
                            name: 'Standard_LRS'
                          }
                          incremental: false
                          location: '@{item()[\'location\']}'
                          creationData: {
                            createOption: 'Copy'
                            sourceResourceId: '@{item()[\'disks\'][0][\'id\']}'
                          }
                          publicNetworkAccess: 'Disabled'
                          networkAccessPolicy: 'DenyAll'
                          dataAccessAuthMode: 'None'
                          encryption: {
                            type: 'EncryptionAtRestWithCustomerKey'
                            diskEncryptionSetId: '/subscriptions/${subscriptionId}/resourceGroups/qualys-snapshot-scanner/providers/Microsoft.Compute/diskEncryptionSets/qualys-encryption-set-@{item()[\'location\']}-${deploymentId}'
                          }
                          tags: {
                            App: 'qualys-snapshot-scanner'
                            Name: 'Qualys Snapshot Scanner'
                            ManagedByApp: 'QualysSnapshotScanner'
                            AppVersion: appVersion
                          }
                        }
                      ]
                    }
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {}
                }
                VerifySnapshot: {
                  type: 'Until'
                  expression: '@and(equals(outputs(\'CheckStatus\')[\'statusCode\'], 200), equals(body(\'CheckStatus\')[\'provisioningState\'], \'Succeeded\'))'
                  actions: {
                    Delay: {
                      type: 'Wait'
                      inputs: {
                        interval: {
                          count: '@min(mul(add(iterationIndexes(\'VerifySnapshot\'),1),10), 60)'
                          unit: 'Second'
                        }
                      }
                      runAfter: {}
                    }
                    CheckStatus: {
                      type: 'Http'
                      inputs: {
                        uri: '${functionAppUrl}/api/arm/compute'
                        headers: {
                          'Content-Type': 'application/json'
                        }
                        body: {
                          resource: 'snapshots'
                          method: 'get'
                          parameters: ['qualys-snapshot-scanner', 'qualys-snapshot-@{item()[\'disks\'][0][\'uid\']}']
                        }
                        method: 'POST'
                        authentication: {
                          identity: scannerIdentityResourceId
                          type: 'ManagedServiceIdentity'
                        }
                        retryPolicy: {
                          count: 3
                          interval: 'PT60S'
                          type: 'fixed'
                        }
                      }
                      runAfter: {
                        Delay: ['Succeeded']
                      }
                    }
                  }
                  limit: {
                    count: 25
                    timeout: 'PT600S'
                  }
                  runAfter: {
                    CreateSnapshot: ['Succeeded']
                  }
                }
                UpdateVMState: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/db/update'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      body: {
                        id: '@items(\'ForEachVM\')[\'id\']'
                        ops: [
                          {
                            op: 'add'
                            path: '/snapshots'
                            value: [
                              {
                                diskName: '@{items(\'ForEachVM\')[\'disks\'][0][\'name\']}'
                                diskSizeGB: '@body(\'CheckStatus\')?[\'diskSizeGB\']'
                                encryption: '@body(\'CheckStatus\')?[\'encryption\']'
                                id: '@{body(\'CheckStatus\')?[\'id\']}'
                                name: '@{body(\'CheckStatus\')?[\'name\']}'
                                uid: '@{items(\'ForEachVM\')[\'disks\'][0][\'uid\']}'
                              }
                            ]
                          }
                          {
                            op: 'replace'
                            path: '/state'
                            value: '@if(and(equals(outputs(\'CheckStatus\')?[\'statusCode\'], 200), equals(body(\'CheckStatus\')?[\'provisioningState\'], \'Succeeded\')), \'SnapshotsCompleted\', \'SnapshotsFailed\')'
                          }
                          {
                            op: 'replace'
                            path: '/retry'
                            value: 0
                          }
                        ]
                        partitionKey: '@items(\'ForEachVM\')[\'location\']'
                      }
                      container: 'resource-inventory'
                    }
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {
                    VerifySnapshot: ['Succeeded']
                  }
                }
                IsSnapshotCompleted: {
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: ['@outputs(\'CheckStatus\')?[\'statusCode\']', 200]
                      }
                      {
                        equals: ['@body(\'CheckStatus\')?[\'provisioningState\']', 'Succeeded']
                      }
                    ]
                  }
                  actions: {
                    CreateInventoryScans: {
                      type: 'Http'
                      inputs: {
                        uri: '${functionAppUrl}/api/scan/create'
                        headers: {
                          'Content-Type': 'application/json'
                        }
                        body: {
                          resources: '@body(\'Query\').resources'
                        }
                        method: 'POST'
                        authentication: {
                          identity: scannerIdentityResourceId
                          type: 'ManagedServiceIdentity'
                        }
                        retryPolicy: {
                          count: 3
                          interval: 'PT60S'
                          type: 'fixed'
                        }
                      }
                      runAfter: {}
                    }
                  }
                  runAfter: {
                    UpdateVMState: ['Succeeded']
                  }
                }
              }
              runtimeConfiguration: {
                concurrency: {
                  repetitions: 50
                }
              }
              runAfter: {
                Query: ['Succeeded']
              }
            }
          }
          limit: {
            count: 5000
            timeout: 'PT1440S'
          }
          runAfter: {
            SuccessResponse: ['Succeeded']
          }
        }
      }
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        InitializeDisksArray: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'Disks'
                type: 'array'
                value: []
              }
            ]
          }
          runAfter: {}
        }
        ForEachSnapshot: {
          type: 'Foreach'
          foreach: '@triggerBody()[\'snapshots\']'
          actions: {
            CreateDisk: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/arm/compute'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  resource: 'disks'
                  method: 'beginCreateOrUpdate'
                  parameters: [
                    'qualys-snapshot-scanner'
                    'qualys-disk-@{items(\'ForEachSnapshot\')[\'uid\']}'
                    {
                      osType: 'Linux'
                      sku: {
                        name: 'StandardSSD_LRS'
                      }
                      location: '@{triggerBody()[\'location\']}'
                      creationData: {
                        createOption: 'Copy'
                        sourceResourceId: '@{items(\'ForEachSnapshot\')[\'id\']}'
                      }
                      publicNetworkAccess: 'Disabled'
                      networkAccessPolicy: 'DenyAll'
                      dataAccessAuthMode: 'None'
                      encryption: {
                        type: 'EncryptionAtRestWithCustomerKey'
                        diskEncryptionSetId: '/subscriptions/${subscriptionId}/resourceGroups/qualys-snapshot-scanner/providers/Microsoft.Compute/diskEncryptionSets/qualys-encryption-set-@{triggerBody()[\'location\']}-${deploymentId}'
                      }
                      tags: {
                        App: 'qualys-snapshot-scanner'
                        Name: 'Qualys Snapshot Scanner'
                        ManagedByApp: 'QualysSnapshotScanner'
                        AppVersion: appVersion
                      }
                    }
                  ]
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            WaitUntilDiskCreated: {
              type: 'Until'
              expression: '@and(equals(outputs(\'CheckDiskStatus\')[\'statusCode\'], 200),equals(body(\'CheckDiskStatus\')[\'provisioningState\'], \'Succeeded\'))'
              actions: {
                WaitForDisk: {
                  type: 'Wait'
                  inputs: {
                    interval: {
                      count: '@min(mul(add(iterationIndexes(\'WaitUntilDiskCreated\'),1),10), 60)'
                      unit: 'Second'
                    }
                  }
                  runAfter: {}
                }
                CheckDiskStatus: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/arm/compute'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      resource: 'disks'
                      method: 'get'
                      parameters: ['qualys-snapshot-scanner', 'qualys-disk-@{items(\'ForEachSnapshot\')[\'uid\']}']
                    }
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {
                    WaitForDisk: ['Succeeded']
                  }
                }
              }
              limit: {
                count: 20
                timeout: 'PT600S'
              }
              runAfter: {
                CreateDisk: ['Succeeded']
              }
            }
            PushDisk: {
              type: 'AppendToArrayVariable'
              inputs: {
                name: 'Disks'
                value: {
                  disk: '@body(\'CheckDiskStatus\')'
                  snapshot: '@items(\'ForEachSnapshot\')'
                }
              }
              runAfter: {
                WaitUntilDiskCreated: ['Succeeded']
              }
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 10
            }
          }
          runAfter: {
            InitializeDisksArray: ['Succeeded']
          }
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: '@variables(\'Disks\')'
          }
          runAfter: {
            ForEachSnapshot: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 422
            body: {
              message: '@{outputs(\'ForEachSnapshot\')}'
            }
          }
          runAfter: {
            ForEachSnapshot: ['TIMEDOUT', 'FAILED']
          }
        }
      }
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        QueryUntilLastDocument: {
          type: 'Until'
          expression: '@equals(outputs(\'HasPendingMachines\'), bool(\'false\'))'
          actions: {
            Query: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/db/query'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  container: 'resource-inventory'
                  body: {
                    query: 'SELECT c.subscriptionId, c.location, c.resourceGroup, c.resourceId, c.id, c.userId, c.name, c.osType, c.scanTypes, c._ts, c.ttl, c.privateIpAddress, c.privateIpv6Address, c.host, c.arch, c.retry, c.snapshots, c.discoveryTaskId, c.type FROM c WHERE c.state = "SnapshotsCompleted" AND c.retry < 3 OFFSET 0 LIMIT @{mul(int(\'${scannersPerLocation}\'), int(\'${locationConcurrency}\'))}'
                    partitionKey: '@{triggerBody()[\'location\']}'
                    incr: true
                  }
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            HasPendingMachines: {
              type: 'Compose'
              inputs: '@and(equals(outputs(\'Query\')[\'statusCode\'], 200),not(equals(length(body(\'Query\').resources), 0)))'
              runAfter: {
                Query: ['Succeeded', 'TIMEDOUT', 'FAILED']
              }
            }
            Condition: {
              type: 'If'
              expression: {
                and: [
                  {
                    equals: ['@outputs(\'HasPendingMachines\')', '@bool(\'true\')']
                  }
                ]
              }
              actions: {
                PrepareBatches: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/format/split-array'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      array: '@body(\'Query\').resources'
                      size: scannersPerLocation
                    }
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {}
                }
                ForEachBatch: {
                  type: 'Foreach'
                  foreach: '@body(\'PrepareBatches\')'
                  actions: {
                    ExecuteScan: {
                      type: 'Workflow'
                      inputs: {
                        host: {
                          workflow: {
                            id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-prepare-scanner-machine-${deploymentId}'
                          }
                          triggerName: 'HttpTrigger'
                        }
                        headers: {
                          'content-type': 'application/json'
                        }
                        body: {
                          location: '@triggerBody()[\'location\']'
                          instances: '@items(\'ForEachBatch\')'
                        }
                        retryPolicy: {
                          type: 'none'
                        }
                      }
                      limit: {
                        timeout: 'PT1800S'
                      }
                      runAfter: {}
                    }
                    SuppressError: {
                      type: 'Compose'
                      inputs: ''
                      runAfter: {
                        ExecuteScan: ['TIMEDOUT', 'FAILED']
                      }
                    }
                  }
                  runtimeConfiguration: {
                    concurrency: {
                      repetitions: locationConcurrency
                    }
                  }
                  runAfter: {
                    PrepareBatches: ['Succeeded']
                  }
                }
              }
              runAfter: {
                HasPendingMachines: ['Succeeded']
              }
            }
          }
          limit: {
            count: 1000
            timeout: 'PT14400S'
          }
          runAfter: {}
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@{outputs(\'QueryUntilLastDocument\')}'
            }
          }
          runAfter: {
            QueryUntilLastDocument: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@{outputs(\'QueryUntilLastDocument\')}'
            }
          }
          runAfter: {
            QueryUntilLastDocument: ['TIMEDOUT', 'FAILED', 'SKIPPED']
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [prepareScanner]
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
        QENDPOINT: {
          type: 'SecureString'
          defaultValue: qualysEndpoint
        }
        SUBSCRIPTION_ID: {
          type: 'SecureString'
          defaultValue: subscriptionId
        }
        RESOURCE_GROUP_NAME: {
          type: 'SecureString'
          defaultValue: 'qualys-snapshot-scanner'
        }
        BUILD_VERSION: {
          type: 'SecureString'
          defaultValue: appVersion
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        InitializeId: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'Id'
                type: 'string'
                value: '@{workflow()[\'run\'][\'name\']}'
              }
            ]
          }
          runAfter: {}
        }
        InitializeVMIdsArray: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'VMIds'
                type: 'array'
                value: []
              }
            ]
          }
          runAfter: {
            InitializeId: ['Succeeded']
          }
        }
        InitializeInstanceAndDisksArray: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'InstanceAndDisks'
                type: 'array'
                value: []
              }
            ]
          }
          runAfter: {
            InitializeVMIdsArray: ['Succeeded']
          }
        }
        ForEachInstanceCreateDisks: {
          type: 'Foreach'
          foreach: '@triggerBody()[\'instances\']'
          actions: {
            AddVMId: {
              type: 'AppendToArrayVariable'
              inputs: {
                name: 'VMIds'
                value: '@{item()[\'id\']}'
              }
              runAfter: {}
            }
            CreateDisks: {
              type: 'Workflow'
              inputs: {
                host: {
                  workflow: {
                    id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-create-disks-${deploymentId}'
                  }
                  triggerName: 'HttpTrigger'
                }
                headers: {
                  'content-type': 'application/json'
                }
                body: {
                  parentId: '@variables(\'Id\')'
                  vmId: '@{item()[\'id\']}'
                  subscriptionId: '@{item()[\'subscriptionId\']}'
                  location: '@{triggerBody()[\'location\']}'
                  snapshots: '@item()[\'snapshots\']'
                }
                retryPolicy: {
                  count: 2
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              limit: {
                timeout: 'PT180S'
              }
              runAfter: {
                AddVMId: ['Succeeded']
              }
            }
            SetInstanceAndDisks: {
              type: 'AppendToArrayVariable'
              inputs: {
                name: 'InstanceAndDisks'
                value: {
                  instance: '@item()'
                  disks: '@body(\'CreateDisks\')'
                }
              }
              runAfter: {
                CreateDisks: ['Succeeded']
              }
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 10
            }
          }
          runAfter: {
            InitializeInstanceAndDisksArray: ['Succeeded']
          }
        }
        InitializeLun: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'DiskLun'
                type: 'integer'
                value: 0
              }
            ]
          }
          runAfter: {
            ForEachInstanceCreateDisks: ['Succeeded']
          }
        }
        InitializeDisksArray: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'Disks'
                type: 'array'
                value: []
              }
            ]
          }
          runAfter: {
            InitializeLun: ['Succeeded']
          }
        }
        InitializeTargetInstancesArray: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'TargetInstances'
                type: 'array'
                value: []
              }
            ]
          }
          runAfter: {
            InitializeDisksArray: ['Succeeded']
          }
        }
        InitializeScannerMachine: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'ScannerMachine'
                type: 'object'
                value: {}
              }
            ]
          }
          runAfter: {
            InitializeTargetInstancesArray: ['Succeeded']
          }
        }
        ForEachInstanceDisksSanitize: {
          type: 'Foreach'
          foreach: '@variables(\'InstanceAndDisks\')'
          actions: {
            ForEachCreatedDisk: {
              type: 'Foreach'
              foreach: '@items(\'ForEachInstanceDisksSanitize\')[\'disks\']'
              actions: {
                PushDisk: {
                  type: 'AppendToArrayVariable'
                  inputs: {
                    name: 'Disks'
                    value: {
                      lun: '@variables(\'DiskLun\')'
                      managedDisk: {
                        id: '@item()[\'disk\'][\'id\']'
                      }
                      createOption: 'Attach'
                      deleteOption: 'Delete'
                      caching: 'None'
                      writeAcceleratorEnabled: false
                    }
                  }
                  runAfter: {}
                }
                IncrementDiskLun: {
                  type: 'IncrementVariable'
                  inputs: {
                    name: 'DiskLun'
                    value: 1
                  }
                  runAfter: {
                    PushDisk: ['Succeeded']
                  }
                }
              }
              runtimeConfiguration: {
                concurrency: {
                  repetitions: 1
                }
              }
              runAfter: {}
            }
            AddToTargetInstances: {
              type: 'AppendToArrayVariable'
              inputs: {
                name: 'TargetInstances'
                value: '@items(\'ForEachInstanceDisksSanitize\')[\'instance\']'
              }
              runAfter: {
                ForEachCreatedDisk: ['Succeeded']
              }
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 1
            }
          }
          runAfter: {
            InitializeScannerMachine: ['Succeeded']
          }
        }
        GetSubnet: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/arm/network'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              resource: 'subnets'
              method: 'get'
              parameters: [
                'qualys-snapshot-scanner'
                'qualys-virtual-network-@{triggerBody()[\'location\']}'
                'qualys-subnet-@{triggerBody()[\'location\']}'
              ]
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            ForEachInstanceDisksSanitize: ['Succeeded']
          }
        }
        CreatePublicIp: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/arm/network'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              resource: 'publicIPAddresses'
              method: 'beginCreateOrUpdateAndWait'
              parameters: [
                'qualys-snapshot-scanner'
                'qualys-public-ip-@{variables(\'Id\')}'
                {
                  location: '@{triggerBody()[\'location\']}'
                  sku: {
                    name: 'Standard'
                  }
                  publicIPAllocationMethod: 'Static'
                  dnsSettings: {
                    domainNameLabel: 'qualys-domain-@{toLower(variables(\'Id\'))}'
                  }
                  tags: {
                    App: 'qualys-snapshot-scanner'
                    Name: 'Qualys Snapshot Scanner'
                    ManagedByApp: 'QualysSnapshotScanner'
                    AppVersion: appVersion
                  }
                }
              ]
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            GetSubnet: ['Succeeded']
          }
        }
        CreateNic: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/arm/network'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              resource: 'networkInterfaces'
              method: 'beginCreateOrUpdateAndWait'
              parameters: [
                'qualys-snapshot-scanner'
                'qualys-nic-@{variables(\'Id\')}'
                {
                  location: '@triggerBody()[\'location\']'
                  ipConfigurations: [
                    {
                      name: 'Ipv4config'
                      privateIPAllocationMethod: 'Dynamic'
                      subnet: {
                        id: '@body(\'GetSubnet\')[\'id\']'
                      }
                      publicIPAddress: {
                        id: '@body(\'CreatePublicIp\')[\'id\']'
                        deleteOption: 'Delete'
                      }
                    }
                  ]
                  tags: {
                    App: 'qualys-snapshot-scanner'
                    Name: 'Qualys Snapshot Scanner'
                    ManagedByApp: 'QualysSnapshotScanner'
                    AppVersion: appVersion
                  }
                }
              ]
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            CreatePublicIp: ['Succeeded']
          }
        }
        GetScannerImage: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/db/query'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              container: 'config'
              body: {
                query: 'SELECT VALUE c.data FROM c WHERE c.type = "image"'
                partitionKey: 'image'
              }
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            CreateNic: ['Succeeded']
          }
        }
        LaunchScannerMachine: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/arm/compute'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              resource: 'virtualMachines'
              method: 'beginCreateOrUpdate'
              parameters: [
                'qualys-snapshot-scanner'
                'qualys-vm-scanner-@{variables(\'Id\')}'
                {
                  location: '@triggerBody()[\'location\']'
                  hardwareProfile: {
                    vmSize: '@if(equals(\'${scannersPerLocation}\', \'4\'), \'Standard_B2s\', if(equals(\'${scannersPerLocation}\', \'8\'), \'Standard_B4ms\', if(equals(\'${scannersPerLocation}\', \'16\'), \'Standard_B8ms\', \'Standard_B1s\')))'
                  }
                  storageProfile: {
                    imageReference: {
                      communityGalleryImageId: '@body(\'GetScannerImage\')[\'resources\'][0]'
                    }
                    osDisk: {
                      createOption: 'FromImage'
                      deleteOption: 'Delete'
                      caching: 'None'
                      writeAcceleratorEnabled: false
                      managedDisk: {
                        storageAccountType: 'StandardSSD_LRS'
                      }
                    }
                  }
                  networkProfile: {
                    networkInterfaces: [
                      {
                        id: '/subscriptions/${subscriptionId}/resourceGroups/qualys-snapshot-scanner/providers/Microsoft.Network/networkInterfaces/qualys-nic-@{variables(\'Id\')}'
                        deleteOption: 'Delete'
                      }
                    ]
                  }
                  tags: {
                    App: 'qualys-snapshot-scanner'
                    Name: 'Qualys Snapshot Scanner'
                    ManagedByApp: 'QualysSnapshotScanner'
                    AppVersion: appVersion
                  }
                }
              ]
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            GetScannerImage: ['Succeeded']
          }
        }
        WaitUntilScannerMachineLaunch: {
          type: 'Until'
          expression: '@and(equals(outputs(\'CheckVMStatus\')[\'statusCode\'], 200),equals(body(\'CheckVMStatus\')[\'provisioningState\'], \'Succeeded\'))'
          actions: {
            WaitForVM: {
              type: 'Wait'
              inputs: {
                interval: {
                  count: 60
                  unit: 'Second'
                }
              }
              runAfter: {}
            }
            CheckVMStatus: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/arm/compute'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  resource: 'virtualMachines'
                  method: 'get'
                  parameters: [
                    'qualys-snapshot-scanner'
                    'qualys-vm-scanner-@{variables(\'Id\')}'
                  ]
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {
                WaitForVM: ['Succeeded']
              }
            }
          }
          limit: {
            count: 10
            timeout: 'PT600S'
          }
          runAfter: {
            LaunchScannerMachine: ['Succeeded']
          }
        }
        SetScannerMachineVariable: {
          type: 'SetVariable'
          inputs: {
            name: 'ScannerMachine'
            value: '@body(\'CheckVMStatus\')'
          }
          runAfter: {
            WaitUntilScannerMachineLaunch: ['Succeeded']
          }
        }
        AttachDisks: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/arm/compute'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              resource: 'virtualMachines'
              method: 'beginUpdateAndWait'
              parameters: [
                'qualys-snapshot-scanner'
                'qualys-vm-scanner-@{variables(\'Id\')}'
                {
                  storageProfile: {
                    dataDisks: '@variables(\'Disks\')'
                    diskControllerType: 'SCSI'
                  }
                }
              ]
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            SetScannerMachineVariable: ['Succeeded']
          }
        }
        ExecuteScan: {
          type: 'Workflow'
          inputs: {
            host: {
              workflow: {
                id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-run-commands-${deploymentId}'
              }
              triggerName: 'HttpTrigger'
            }
            headers: {
              'content-type': 'application/json'
            }
            body: {
              parentId: '@variables(\'Id\')'
              name: 'qualys-vm-scanner-@{variables(\'Id\')}'
              fqdn: '@body(\'CreatePublicIp\')[\'dnsSettings\'][\'fqdn\']'
              token: '@{base64(workflow()[\'run\'][\'name\'])}'
              vms: '@variables(\'TargetInstances\')'
              vmIds: '@variables(\'VMIds\')'
              resourceId: '@variables(\'ScannerMachine\')[\'id\']'
              location: '@{triggerBody()[\'location\']}'
            }
            retryPolicy: {
              type: 'none'
            }
          }
          limit: {
            timeout: 'PT1800S'
          }
          runAfter: {
            AttachDisks: ['Succeeded']
          }
        }
        ForEachInstanceUpdateStatus: {
          type: 'Foreach'
          foreach: '@body(\'ExecuteScan\')[\'vms\']'
          actions: {
            UpdateStatus: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/db/update'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  container: 'resource-inventory'
                  body: {
                    id: '@{item()[\'id\']}'
                    partitionKey: ['@{triggerBody()[\'location\']}']
                    ops: [
                      {
                        op: 'replace'
                        path: '/state'
                        value: '@if(equals(item()[\'status\'], bool(\'true\')), \'ScanCompleted\', \'ScanFailed\')'
                      }
                      {
                        op: 'replace'
                        path: '/error'
                        value: '@if(contains(item(), \'errorCode\'), item()[\'errorCode\'], \'\')'
                      }
                      {
                        op: 'replace'
                        path: '/ttl'
                        value: '@mul(3600, int(\'${scanIntervalHours}\'))'
                      }
                    ]
                  }
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            UpdateScanStatus: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/db/update'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  container: 'inventory-scan-status'
                  body: {
                    id: '@{item()[\'id\']}-os'
                    partitionKey: ['os']
                    ops: [
                      {
                        op: 'replace'
                        path: '/scanStatus'
                        value: '@if(equals(item()[\'status\'], bool(\'true\')), \'SCAN_COMPLETED\', \'SCAN_FAILED\')'
                      }
                      {
                        op: 'replace'
                        path: '/stateReason'
                        value: '@if(contains(item(), \'errorCode\'), item()[\'errorCode\'], \'\')'
                      }
                    ]
                  }
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {
                UpdateStatus: ['Succeeded']
              }
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 10
            }
          }
          runAfter: {
            ExecuteScan: ['Succeeded']
          }
        }
        GetSnapshots: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/db/query'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              container: 'resource-inventory'
              body: {
                query: 'SELECT VALUE c.id FROM c WHERE c.id in ("@{join(variables(\'VMIds\'),\'","\')}") AND (c.state != "SnapshotsCompleted" OR c.retry = 3)'
                partitionKey: '@{triggerBody()[\'location\']}'
              }
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            ForEachInstanceUpdateStatus: ['Succeeded', 'TIMEDOUT', 'FAILED', 'SKIPPED']
          }
        }
        GetSnapshotsArray: {
          type: 'Http'
          inputs: {
            uri: '${functionAppUrl}/api/format/get-snapshots-by-ids'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              ids: '@body(\'GetSnapshots\')[\'resources\']'
              vms: '@triggerBody()[\'instances\']'
            }
            method: 'POST'
            authentication: {
              identity: scannerIdentityResourceId
              type: 'ManagedServiceIdentity'
            }
            retryPolicy: {
              count: 3
              interval: 'PT60S'
              type: 'fixed'
            }
          }
          runAfter: {
            GetSnapshots: ['Succeeded']
          }
        }
        DeleteSnapshots: {
          type: 'Workflow'
          inputs: {
            host: {
              workflow: {
                id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-delete-snapshots-${deploymentId}'
              }
              triggerName: 'HttpTrigger'
            }
            headers: {
              'content-type': 'application/json'
            }
            body: {
              force: true
              parentId: '@variables(\'Id\')'
              location: '@triggerBody()[\'location\']'
              snapshots: '@body(\'GetSnapshotsArray\')'
            }
            retryPolicy: {
              type: 'none'
            }
          }
          limit: {
            timeout: 'PT300S'
          }
          runAfter: {
            GetSnapshotsArray: ['Succeeded']
          }
        }
        DeleteVM: {
          type: 'Workflow'
          inputs: {
            host: {
              workflow: {
                id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-delete-scanner-machines-${deploymentId}'
              }
              triggerName: 'HttpTrigger'
            }
            headers: {
              'content-type': 'application/json'
            }
            body: {
              force: true
              parentId: '@variables(\'Id\')'
              location: '@triggerBody()[\'location\']'
              vms: ['@variables(\'ScannerMachine\')']
            }
            retryPolicy: {
              type: 'none'
            }
          }
          limit: {
            timeout: 'PT300S'
          }
          runAfter: {
            ForEachInstanceUpdateStatus: ['Succeeded', 'TIMEDOUT', 'FAILED', 'SKIPPED']
          }
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@{actions(\'ForEachInstanceUpdateStatus\')[\'status\']}'
            }
          }
          runAfter: {
            ForEachInstanceUpdateStatus: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 422
            body: {
              message: '@{actions(\'ForEachInstanceUpdateStatus\')[\'status\']}'
            }
          }
          runAfter: {
            DeleteVM: ['Succeeded', 'TIMEDOUT', 'FAILED', 'SKIPPED']
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [runCommands, createDisks, deleteSnapshots, deleteScannerMachines]
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
        QENDPOINT: {
          type: 'SecureString'
          defaultValue: qualysEndpoint
        }
        SUBSCRIPTION_ID: {
          type: 'SecureString'
          defaultValue: subscriptionId
        }
        RESOURCE_GROUP_NAME: {
          type: 'SecureString'
          defaultValue: 'qualys-snapshot-scanner'
        }
        BUILD_VERSION: {
          type: 'SecureString'
          defaultValue: appVersion
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: 'RunCommands workflow triggered'
            }
          }
          runAfter: {}
        }
      }
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        ForEachSnapshot: {
          type: 'Foreach'
          foreach: '@triggerBody()[\'snapshots\']'
          actions: {
            IsForceDelete: {
              type: 'If'
              expression: {
                or: [
                  {
                    equals: ['@triggerBody()?[\'force\']', true]
                  }
                  {
                    lessOrEquals: ['@ticks(addHours(items(\'ForEachSnapshot\')[\'timeCreated\'], 6))', '@ticks(utcNow())']
                  }
                ]
              }
              actions: {
                DeleteSnapshot: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/arm/compute'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      resource: 'snapshots'
                      method: 'beginDelete'
                      parameters: ['qualys-snapshot-scanner', '@{items(\'ForEachSnapshot\')[\'name\']}']
                    }
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {}
                }
                WaitUntilSnapshotDeleted: {
                  type: 'Until'
                  expression: '@equals(outputs(\'CheckSnapshotStatus\')[\'statusCode\'], 404)'
                  actions: {
                    Wait: {
                      type: 'Wait'
                      inputs: {
                        interval: {
                          count: 30
                          unit: 'Second'
                        }
                      }
                      runAfter: {}
                    }
                    CheckSnapshotStatus: {
                      type: 'Http'
                      inputs: {
                        uri: '${functionAppUrl}/api/arm/compute'
                        headers: {
                          'Content-Type': 'application/json'
                        }
                        body: {
                          resource: 'snapshots'
                          method: 'get'
                          parameters: ['qualys-snapshot-scanner', '@{items(\'ForEachSnapshot\')[\'name\']}']
                        }
                        method: 'POST'
                        authentication: {
                          identity: scannerIdentityResourceId
                          type: 'ManagedServiceIdentity'
                        }
                        retryPolicy: {
                          type: 'none'
                        }
                      }
                      runAfter: {
                        Wait: ['Succeeded']
                      }
                    }
                    SupressError: {
                      type: 'Compose'
                      inputs: ''
                      runAfter: {
                        CheckSnapshotStatus: ['TIMEDOUT', 'FAILED']
                      }
                    }
                  }
                  limit: {
                    count: 20
                    timeout: 'PT600S'
                  }
                  runAfter: {
                    DeleteSnapshot: ['Succeeded']
                  }
                }
              }
              runAfter: {}
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 10
            }
          }
          runAfter: {}
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@{outputs(\'ForEachSnapshot\')}'
            }
          }
          runAfter: {
            ForEachSnapshot: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 422
            body: {
              message: '@{outputs(\'ForEachSnapshot\')}'
            }
          }
          runAfter: {
            ForEachSnapshot: ['TIMEDOUT', 'FAILED', 'SKIPPED']
          }
        }
      }
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        ForEachDisk: {
          type: 'Foreach'
          foreach: '@triggerBody()[\'disks\']'
          actions: {
            ShouldMatchCondition: {
              type: 'If'
              expression: {
                or: [
                  {
                    equals: ['@triggerBody()[\'force\']', true]
                  }
                  {
                    lessOrEquals: ['@ticks(addHours(items(\'ForEachDisk\')[\'timeCreated\'], 1))', '@ticks(utcNow())']
                  }
                ]
              }
              actions: {
                DeleteDisk: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/arm/compute'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      resource: 'disks'
                      method: 'beginDelete'
                      parameters: ['qualys-snapshot-scanner', '@{items(\'ForEachDisk\')[\'name\']}']
                    }
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {}
                }
                WaitUntilDiskDeleted: {
                  type: 'Until'
                  expression: '@equals(outputs(\'CheckDiskStatus\')[\'statusCode\'], 404)'
                  actions: {
                    Wait: {
                      type: 'Wait'
                      inputs: {
                        interval: {
                          count: 30
                          unit: 'Second'
                        }
                      }
                      runAfter: {}
                    }
                    CheckDiskStatus: {
                      type: 'Http'
                      inputs: {
                        uri: '${functionAppUrl}/api/arm/compute'
                        headers: {
                          'Content-Type': 'application/json'
                        }
                        body: {
                          resource: 'disks'
                          method: 'get'
                          parameters: ['qualys-snapshot-scanner', '@{items(\'ForEachDisk\')[\'name\']}']
                        }
                        method: 'POST'
                        authentication: {
                          identity: scannerIdentityResourceId
                          type: 'ManagedServiceIdentity'
                        }
                        retryPolicy: {
                          type: 'none'
                        }
                      }
                      runAfter: {
                        Wait: ['Succeeded']
                      }
                    }
                    SupressError: {
                      type: 'Compose'
                      inputs: ''
                      runAfter: {
                        CheckDiskStatus: ['TIMEDOUT', 'FAILED']
                      }
                    }
                  }
                  limit: {
                    count: 20
                    timeout: 'PT600S'
                  }
                  runAfter: {
                    DeleteDisk: ['Succeeded']
                  }
                }
              }
              runAfter: {}
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 50
            }
          }
          runAfter: {}
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@{outputs(\'ForEachDisk\')}'
            }
          }
          runAfter: {
            ForEachDisk: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 422
            body: {
              message: '@{outputs(\'ForEachDisk\')}'
            }
          }
          runAfter: {
            ForEachDisk: ['TIMEDOUT', 'FAILED']
          }
        }
      }
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        ForEachNic: {
          type: 'Foreach'
          foreach: '@triggerBody()[\'nics\']'
          actions: {
            IsVMsNIC: {
              type: 'If'
              expression: {
                and: [
                  {
                    startsWith: ['@items(\'ForEachNic\')[\'name\']', 'qualys-nic']
                  }
                  {
                    equals: ['@items(\'ForEachNic\')[\'tags\'][\'ManagedByApp\']', 'QualysSnapshotScanner']
                  }
                ]
              }
              actions: {
                Delay: {
                  type: 'Wait'
                  inputs: {
                    interval: {
                      count: 180
                      unit: 'Second'
                    }
                  }
                  runAfter: {}
                }
                DeleteNic: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/arm/network'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      resource: 'networkInterfaces'
                      method: 'beginDeleteAndWait'
                      parameters: ['qualys-snapshot-scanner', '@{items(\'ForEachNic\')[\'name\']}']
                    }
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {
                    Delay: ['Succeeded']
                  }
                }
              }
              runAfter: {}
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 50
            }
          }
          runAfter: {}
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@{outputs(\'ForEachNic\')}'
            }
          }
          runAfter: {
            ForEachNic: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 422
            body: {
              message: '@{outputs(\'ForEachNic\')}'
            }
          }
          runAfter: {
            ForEachNic: ['TIMEDOUT', 'FAILED', 'SKIPPED']
          }
        }
      }
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        ForEachPublicIp: {
          type: 'Foreach'
          foreach: '@triggerBody()[\'publicIps\']'
          actions: {
            Delay: {
              type: 'Wait'
              inputs: {
                interval: {
                  count: 180
                  unit: 'Second'
                }
              }
              runAfter: {}
            }
            DeletePublicIp: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/arm/network'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  resource: 'publicIPAddresses'
                  method: 'beginDeleteAndWait'
                  parameters: ['qualys-snapshot-scanner', '@{items(\'ForEachPublicIp\')[\'name\']}']
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {
                Delay: ['Succeeded']
              }
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 50
            }
          }
          runAfter: {}
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@{outputs(\'ForEachPublicIp\')}'
            }
          }
          runAfter: {
            ForEachPublicIp: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 422
            body: {
              message: '@{outputs(\'ForEachPublicIp\')}'
            }
          }
          runAfter: {
            ForEachPublicIp: ['TIMEDOUT', 'FAILED']
          }
        }
      }
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
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        HttpTrigger: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {}
          }
          operationOptions: 'SuppressWorkflowHeadersOnResponse'
          runtimeConfiguration: {}
        }
      }
      actions: {
        ForEachScannerMachine: {
          type: 'Foreach'
          foreach: '@triggerBody()[\'vms\']'
          actions: {
            ShouldMatchCondition: {
              type: 'If'
              expression: {
                or: [
                  {
                    equals: ['@triggerBody()[\'force\']', true]
                  }
                  {
                    lessOrEquals: ['@ticks(addHours(items(\'ForEachScannerMachine\')[\'timeCreated\'], 1))', '@ticks(utcNow())']
                  }
                ]
              }
              actions: {
                DeleteScannerMachine: {
                  type: 'Http'
                  inputs: {
                    uri: '${functionAppUrl}/api/arm/compute'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      resource: 'virtualMachines'
                      method: 'beginDelete'
                      parameters: [
                        'qualys-snapshot-scanner'
                        '@{items(\'ForEachScannerMachine\')[\'name\']}'
                        {
                          forceDeletion: true
                        }
                      ]
                    }
                    method: 'POST'
                    authentication: {
                      identity: scannerIdentityResourceId
                      type: 'ManagedServiceIdentity'
                    }
                    retryPolicy: {
                      count: 3
                      interval: 'PT60S'
                      type: 'fixed'
                    }
                  }
                  runAfter: {}
                }
                WaitUntilScannerMachineDeleted: {
                  type: 'Until'
                  expression: '@equals(outputs(\'CheckScannerMachineStatus\')[\'statusCode\'], 404)'
                  actions: {
                    Wait: {
                      type: 'Wait'
                      inputs: {
                        interval: {
                          count: 60
                          unit: 'Second'
                        }
                      }
                      runAfter: {}
                    }
                    CheckScannerMachineStatus: {
                      type: 'Http'
                      inputs: {
                        uri: '${functionAppUrl}/api/arm/compute'
                        headers: {
                          'Content-Type': 'application/json'
                        }
                        body: {
                          resource: 'virtualMachines'
                          method: 'get'
                          parameters: ['qualys-snapshot-scanner', '@{items(\'ForEachScannerMachine\')[\'name\']}']
                        }
                        method: 'POST'
                        authentication: {
                          identity: scannerIdentityResourceId
                          type: 'ManagedServiceIdentity'
                        }
                        retryPolicy: {
                          type: 'none'
                        }
                      }
                      runAfter: {
                        Wait: ['Succeeded']
                      }
                    }
                    SupressError: {
                      type: 'Compose'
                      inputs: ''
                      runAfter: {
                        CheckScannerMachineStatus: ['TIMEDOUT', 'FAILED']
                      }
                    }
                  }
                  limit: {
                    count: 10
                    timeout: 'PT600S'
                  }
                  runAfter: {
                    DeleteScannerMachine: ['Succeeded']
                  }
                }
              }
              runAfter: {}
            }
          }
          runtimeConfiguration: {
            concurrency: {
              repetitions: 50
            }
          }
          runAfter: {}
        }
        SuccessResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 200
            body: {
              message: '@{outputs(\'ForEachScannerMachine\')}'
            }
          }
          runAfter: {
            ForEachScannerMachine: ['Succeeded']
          }
        }
        ErrorResponse: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            headers: {
              'content-type': 'application/json'
            }
            statusCode: 422
            body: {
              message: '@{outputs(\'ForEachScannerMachine\')}'
            }
          }
          runAfter: {
            ForEachScannerMachine: ['TIMEDOUT', 'FAILED']
          }
        }
      }
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
      parameters: {}
      triggers: {
        Poll: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Minute'
            interval: 60
          }
          runtimeConfiguration: {
            concurrency: {
              runs: 1
            }
          }
        }
      }
      actions: {
        InitializeSnapshotsNextLink: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'SnapshotsNextLink'
                type: 'string'
              }
            ]
          }
          runAfter: {}
        }
        UntilSnapshotsNextLink: {
          type: 'Until'
          expression: '@equals(variables(\'SnapshotsNextLink\'), string(\'\'))'
          actions: {
            FetchSnapshots: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/arm/compute'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  resource: 'snapshots'
                  method: '@{if(equals(variables(\'SnapshotsNextLink\'), string(\'\')), \'_listByResourceGroup\', \'_listByResourceGroupNext\')}'
                  parameters: ['qualys-snapshot-scanner', '@{variables(\'SnapshotsNextLink\')}']
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            HasSnapshots: {
              type: 'If'
              expression: {
                and: [
                  {
                    greaterOrEquals: ['@length(body(\'FetchSnapshots\').value)', 1]
                  }
                ]
              }
              actions: {
                DeleteSnapshots: {
                  type: 'Workflow'
                  inputs: {
                    host: {
                      workflow: {
                        id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-delete-snapshots-${deploymentId}'
                      }
                      triggerName: 'HttpTrigger'
                    }
                    headers: {
                      'content-type': 'application/json'
                    }
                    body: {
                      parentId: '@{workflow()[\'run\'][\'name\']}'
                      snapshots: '@body(\'FetchSnapshots\').value'
                      force: false
                    }
                    retryPolicy: {
                      type: 'none'
                    }
                  }
                  limit: {
                    timeout: 'PT600S'
                  }
                  runAfter: {}
                }
                SetSnapshotsNextLink: {
                  type: 'SetVariable'
                  inputs: {
                    name: 'SnapshotsNextLink'
                    value: '@{if(empty(body(\'FetchSnapshots\')?[\'nextLink\']), \'\', body(\'FetchSnapshots\')[\'nextLink\'])}'
                  }
                  runAfter: {
                    DeleteSnapshots: ['Succeeded']
                  }
                }
              }
              runAfter: {
                FetchSnapshots: ['Succeeded']
              }
            }
          }
          limit: {
            count: 10
            timeout: 'PT600S'
          }
          runAfter: {
            InitializeSnapshotsNextLink: ['Succeeded']
          }
        }
        InitializeScannersNextLink: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'ScannersNextLink'
                type: 'string'
              }
            ]
          }
          runAfter: {}
        }
        UntilScannersNextLink: {
          type: 'Until'
          expression: '@equals(variables(\'ScannersNextLink\'), string(\'\'))'
          actions: {
            FetchScannerMachines: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/arm/compute'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  resource: 'virtualMachines'
                  method: '@{if(equals(variables(\'ScannersNextLink\'), string(\'\')), \'_list\', \'_listNext\')}'
                  parameters: ['qualys-snapshot-scanner', '@{variables(\'ScannersNextLink\')}']
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            HasScannerMachines: {
              type: 'If'
              expression: {
                and: [
                  {
                    greaterOrEquals: ['@length(body(\'FetchScannerMachines\').value)', 1]
                  }
                ]
              }
              actions: {
                DeleteScannerMachines: {
                  type: 'Workflow'
                  inputs: {
                    host: {
                      workflow: {
                        id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-delete-scanner-machines-${deploymentId}'
                      }
                      triggerName: 'HttpTrigger'
                    }
                    headers: {
                      'content-type': 'application/json'
                    }
                    body: {
                      parentId: '@{workflow()[\'run\'][\'name\']}'
                      vms: '@body(\'FetchScannerMachines\').value'
                      force: false
                    }
                    retryPolicy: {
                      type: 'none'
                    }
                  }
                  limit: {
                    timeout: 'PT600S'
                  }
                  runAfter: {}
                }
                SetScannersNextLink: {
                  type: 'SetVariable'
                  inputs: {
                    name: 'ScannersNextLink'
                    value: '@{if(empty(body(\'FetchScannerMachines\')?[\'nextLink\']), \'\', body(\'FetchScannerMachines\')[\'nextLink\'])}'
                  }
                  runAfter: {
                    DeleteScannerMachines: ['Succeeded']
                  }
                }
              }
              runAfter: {
                FetchScannerMachines: ['Succeeded']
              }
            }
          }
          limit: {
            count: 10
            timeout: 'PT600S'
          }
          runAfter: {
            InitializeScannersNextLink: ['Succeeded']
          }
        }
        InitializeDisksNextLink: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'DisksNextLink'
                type: 'string'
              }
            ]
          }
          runAfter: {
            UntilScannersNextLink: ['Succeeded', 'TIMEDOUT', 'FAILED']
          }
        }
        UntilDisksNextLink: {
          type: 'Until'
          expression: '@equals(variables(\'DisksNextLink\'), string(\'\'))'
          actions: {
            FetchDisks: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/arm/compute'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  resource: 'disks'
                  method: '@{if(equals(variables(\'DisksNextLink\'), string(\'\')), \'_listByResourceGroup\', \'_listByResourceGroupNext\')}'
                  parameters: ['qualys-snapshot-scanner', '@{variables(\'DisksNextLink\')}']
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            HasDisks: {
              type: 'If'
              expression: {
                and: [
                  {
                    greaterOrEquals: ['@length(body(\'FetchDisks\').value)', 1]
                  }
                ]
              }
              actions: {
                DeleteDisks: {
                  type: 'Workflow'
                  inputs: {
                    host: {
                      workflow: {
                        id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-delete-disks-${deploymentId}'
                      }
                      triggerName: 'HttpTrigger'
                    }
                    headers: {
                      'content-type': 'application/json'
                    }
                    body: {
                      parentId: '@{workflow()[\'run\'][\'name\']}'
                      disks: '@body(\'FetchDisks\').value'
                      force: false
                    }
                    retryPolicy: {
                      type: 'none'
                    }
                  }
                  limit: {
                    timeout: 'PT600S'
                  }
                  runAfter: {}
                }
                SetDisksNextLink: {
                  type: 'SetVariable'
                  inputs: {
                    name: 'DisksNextLink'
                    value: '@{if(empty(body(\'FetchDisks\')?[\'nextLink\']), \'\', body(\'FetchDisks\')[\'nextLink\'])}'
                  }
                  runAfter: {
                    DeleteDisks: ['Succeeded']
                  }
                }
              }
              runAfter: {
                FetchDisks: ['Succeeded']
              }
            }
          }
          limit: {
            count: 10
            timeout: 'PT600S'
          }
          runAfter: {
            InitializeDisksNextLink: ['Succeeded']
          }
        }
        InitializeNicNextLink: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'NicsNextLink'
                type: 'string'
              }
            ]
          }
          runAfter: {
            UntilScannersNextLink: ['Succeeded', 'TIMEDOUT', 'FAILED']
          }
        }
        UntilNicsNextLink: {
          type: 'Until'
          expression: '@equals(variables(\'NicsNextLink\'), string(\'\'))'
          actions: {
            FetchNics: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/arm/network'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  resource: 'networkInterfaces'
                  method: '@{if(equals(variables(\'NicsNextLink\'), string(\'\')), \'_list\', \'_listNext\')}'
                  parameters: ['qualys-snapshot-scanner', '@{variables(\'NicsNextLink\')}']
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            HasNics: {
              type: 'If'
              expression: {
                and: [
                  {
                    greaterOrEquals: ['@length(body(\'FetchNics\').value)', 1]
                  }
                ]
              }
              actions: {
                DeleteNics: {
                  type: 'Workflow'
                  inputs: {
                    host: {
                      workflow: {
                        id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-delete-nics-${deploymentId}'
                      }
                      triggerName: 'HttpTrigger'
                    }
                    headers: {
                      'content-type': 'application/json'
                    }
                    body: {
                      parentId: '@{workflow()[\'run\'][\'name\']}'
                      nics: '@body(\'FetchNics\').value'
                      force: false
                    }
                    retryPolicy: {
                      type: 'none'
                    }
                  }
                  limit: {
                    timeout: 'PT600S'
                  }
                  runAfter: {}
                }
                SetNicsNextLink: {
                  type: 'SetVariable'
                  inputs: {
                    name: 'NicsNextLink'
                    value: '@{if(empty(body(\'FetchNics\')?[\'nextLink\']), \'\', body(\'FetchNics\')[\'nextLink\'])}'
                  }
                  runAfter: {
                    DeleteNics: ['Succeeded']
                  }
                }
              }
              runAfter: {
                FetchNics: ['Succeeded']
              }
            }
          }
          limit: {
            count: 10
            timeout: 'PT600S'
          }
          runAfter: {
            InitializeNicNextLink: ['Succeeded']
          }
        }
        InitializePublicIpNextLink: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'PublicIpNextLink'
                type: 'string'
              }
            ]
          }
          runAfter: {
            UntilNicsNextLink: ['Succeeded', 'TIMEDOUT', 'FAILED']
          }
        }
        UntilPublicIpNextLink: {
          type: 'Until'
          expression: '@equals(variables(\'PublicIpNextLink\'), string(\'\'))'
          actions: {
            FetchPublicIps: {
              type: 'Http'
              inputs: {
                uri: '${functionAppUrl}/api/arm/network'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  resource: 'publicIPAddresses'
                  method: '@{if(equals(variables(\'PublicIpNextLink\'), string(\'\')), \'_list\', \'_listNext\')}'
                  parameters: ['qualys-snapshot-scanner', '@{variables(\'PublicIpNextLink\')}']
                }
                method: 'POST'
                authentication: {
                  identity: scannerIdentityResourceId
                  type: 'ManagedServiceIdentity'
                }
                retryPolicy: {
                  count: 3
                  interval: 'PT60S'
                  type: 'fixed'
                }
              }
              runAfter: {}
            }
            HasPublicIps: {
              type: 'If'
              expression: {
                and: [
                  {
                    greaterOrEquals: ['@length(body(\'FetchPublicIps\').value)', 1]
                  }
                ]
              }
              actions: {
                DeletePublicIps: {
                  type: 'Workflow'
                  inputs: {
                    host: {
                      workflow: {
                        id: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Logic/workflows/qualys-delete-public-ips-${deploymentId}'
                      }
                      triggerName: 'HttpTrigger'
                    }
                    headers: {
                      'content-type': 'application/json'
                    }
                    body: {
                      parentId: '@{workflow()[\'run\'][\'name\']}'
                      publicIps: '@body(\'FetchPublicIps\').value'
                      force: false
                    }
                    retryPolicy: {
                      type: 'none'
                    }
                  }
                  limit: {
                    timeout: 'PT600S'
                  }
                  runAfter: {}
                }
                SetPublicIpsNextLink: {
                  type: 'SetVariable'
                  inputs: {
                    name: 'PublicIpNextLink'
                    value: '@{if(empty(body(\'FetchPublicIps\')?[\'nextLink\']), \'\', body(\'FetchPublicIps\')[\'nextLink\'])}'
                  }
                  runAfter: {
                    DeletePublicIps: ['Succeeded']
                  }
                }
              }
              runAfter: {
                FetchPublicIps: ['Succeeded']
              }
            }
          }
          limit: {
            count: 10
            timeout: 'PT600S'
          }
          runAfter: {
            InitializePublicIpNextLink: ['Succeeded']
          }
        }
      }
    }
  }
  tags: tags
  dependsOn: [deleteSnapshots, deleteScannerMachines, deleteDisks, deleteNics, deletePublicIps]
}

output functionAppSyncerName string = functionAppSyncer.name
output registerServiceAccountName string = registerServiceAccount.name
output workflowNames object = {
  functionAppSyncer: functionAppSyncer.name
  registerServiceAccount: registerServiceAccount.name
  deregisterServiceAccount: deregisterServiceAccount.name
  pollBasedDiscover: pollBasedDiscover.name
  discoverResources: discoverResources.name
  demandBasedDiscover: demandBasedDiscover.name
  findScanCandidates: findScanCandidates.name
  createSnapshots: createSnapshots.name
  createDisks: createDisks.name
  concurrentScanner: concurrentScanner.name
  prepareScanner: prepareScanner.name
  runCommands: runCommands.name
  deleteSnapshots: deleteSnapshots.name
  deleteDisks: deleteDisks.name
  deleteNics: deleteNics.name
  deletePublicIps: deletePublicIps.name
  deleteScannerMachines: deleteScannerMachines.name
  cleanupResources: cleanupResources.name
}
