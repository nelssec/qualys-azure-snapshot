targetScope = 'resourceGroup'

@description('Azure region for deployment')
param location string = resourceGroup().location

@description('Qualys platform API endpoint')
param qualysEndpoint string

@secure()
@description('Qualys subscription token')
param qualysSubscriptionToken string

@description('Azure regions to scan VMs in')
param targetLocations array

@description('Subscription IDs to scan')
param targetSubscriptions array = [subscription().subscriptionId]

@description('Azure cloud environment')
@allowed(['AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud'])
param targetCloud string = 'AzureCloud'

@description('Object ID of the deploying user/service principal')
param deployerObjectId string

@description('Enable Application Insights and extended logging')
param debugEnabled bool = false

@description('Use event-based VM discovery')
param eventBasedDiscovery bool = false

@description('Hours between scan cycles')
param scanIntervalHours int = 24

@description('Hours between poll-based discovery cycles')
param pollIntervalHours int = 24

@description('Maximum concurrent location scans')
param locationConcurrency int = 5

@description('Scanner VMs per location')
param scannersPerLocation int = 1

@description('Application version')
param appVersion string = '3.20.0'

@description('Additional resource tags')
param tags object = {}

var deploymentId = uniqueString(resourceGroup().id)
var roleBoundary = subscription().id

var commonTags = union({
  App: 'qualys-snapshot-scanner'
  AppVersion: appVersion
  Name: 'Qualys Snapshot Scanner'
}, tags)

module security 'modules/security/main.bicep' = {
  name: 'security-${deploymentId}'
  params: {
    location: location
    deploymentId: deploymentId
    tenantId: subscription().tenantId
    deployerObjectId: deployerObjectId
    qualysSubscriptionToken: qualysSubscriptionToken
    targetLocations: targetLocations
    roleBoundary: roleBoundary
    tags: commonTags
  }
}

module networking 'modules/networking/main.bicep' = {
  name: 'networking-${deploymentId}'
  params: {
    location: location
    deploymentId: deploymentId
    targetLocations: targetLocations
    targetCloud: targetCloud
    tags: commonTags
  }
}

module storage 'modules/storage/main.bicep' = {
  name: 'storage-${deploymentId}'
  params: {
    location: location
    deploymentId: deploymentId
    scannerIdentityId: security.outputs.scannerIdentityId
    scannerIdentityPrincipalId: security.outputs.scannerIdentityPrincipalId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    blobDnsZoneId: networking.outputs.blobDnsZoneId
    tags: commonTags
  }
}

module cosmos 'modules/cosmos/main.bicep' = {
  name: 'cosmos-${deploymentId}'
  params: {
    location: location
    deploymentId: deploymentId
    scannerIdentityId: security.outputs.scannerIdentityId
    scannerIdentityPrincipalId: security.outputs.scannerIdentityPrincipalId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    cosmosDnsZoneId: networking.outputs.cosmosDnsZoneId
    debugEnabled: debugEnabled
    tags: commonTags
  }
}

resource storageAccountRef 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: 'qualysst${deploymentId}'
  dependsOn: [storage]
}

module functionApp 'modules/function-app/main.bicep' = {
  name: 'function-app-${deploymentId}'
  params: {
    location: location
    deploymentId: deploymentId
    subscriptionId: subscription().subscriptionId
    scannerIdentityId: security.outputs.scannerIdentityId
    scannerIdentityClientId: security.outputs.scannerIdentityClientId
    functionAppSubnetId: networking.outputs.functionAppSubnetId
    storageAccountName: storage.outputs.storageAccountName
    storageAccountKey: storageAccountRef.listKeys().keys[0].value
    cosmosDbEndpoint: cosmos.outputs.cosmosDbEndpoint
    cosmosDbName: cosmos.outputs.cosmosDbDatabaseName
    keyVaultUri: security.outputs.secretsKeyVaultUri
    qualysEndpoint: qualysEndpoint
    debugEnabled: debugEnabled
    appVersion: appVersion
    scanIntervalHours: scanIntervalHours
    pollIntervalHours: pollIntervalHours
    locationConcurrency: locationConcurrency
    scannersPerLocation: scannersPerLocation
    tags: commonTags
  }
}

module logicApps 'modules/logic-apps/main.bicep' = {
  name: 'logic-apps-${deploymentId}'
  params: {
    location: location
    deploymentId: deploymentId
    subscriptionId: subscription().subscriptionId
    tenantId: subscription().tenantId
    logicAppIdentityId: security.outputs.logicAppIdentityId
    logicAppIdentityPrincipalId: security.outputs.logicAppIdentityPrincipalId
    scannerIdentityId: security.outputs.scannerIdentityId
    scannerIdentityClientId: security.outputs.scannerIdentityClientId
    secretsKeyVaultName: security.outputs.secretsKeyVaultName
    qualysTokenSecretName: security.outputs.qualysTokenSecretName
    qualysEndpoint: qualysEndpoint
    functionAppHostname: functionApp.outputs.functionAppHostname
    functionAppName: functionApp.outputs.functionAppName
    storageAccountName: storage.outputs.storageAccountName
    storageContainerName: storage.outputs.storageContainerName
    cosmosDbEndpoint: cosmos.outputs.cosmosDbEndpoint
    serviceBusNamespace: storage.outputs.serviceBusNamespace
    targetLocations: targetLocations
    targetSubscriptions: targetSubscriptions
    eventBasedDiscovery: eventBasedDiscovery
    appVersion: appVersion
    tags: commonTags
  }
}

output deploymentId string = deploymentId
output resourceGroupName string = resourceGroup().name
output scannerIdentity object = {
  id: security.outputs.scannerIdentityId
  clientId: security.outputs.scannerIdentityClientId
  principalId: security.outputs.scannerIdentityPrincipalId
}
output keyVault object = {
  name: security.outputs.secretsKeyVaultName
  uri: security.outputs.secretsKeyVaultUri
}
output functionApp object = {
  name: functionApp.outputs.functionAppName
  hostname: functionApp.outputs.functionAppHostname
}
output cosmosDb object = {
  name: cosmos.outputs.cosmosDbName
  endpoint: cosmos.outputs.cosmosDbEndpoint
}
output storageAccount string = storage.outputs.storageAccountName
output logicAppWorkflows object = logicApps.outputs.workflowNames
