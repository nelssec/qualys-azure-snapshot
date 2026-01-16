targetScope = 'subscription'

@description('Azure region for deployment')
param location string

@description('Resource group name for deployment')
param resourceGroupName string = 'qualys-scanner-rg'

@description('Qualys platform API endpoint')
param qualysEndpoint string

@secure()
@description('Qualys subscription token')
param qualysSubscriptionToken string

@description('Azure regions to scan VMs in')
param targetLocations array

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
param pollIntervalHours int = 4

@description('Maximum concurrent location scans')
param locationConcurrency int = 5

@description('Scanner VMs per location')
param scannersPerLocation int = 1

@description('Application version')
param appVersion string = '3.20.0'

@description('Additional resource tags')
param tags object = {}

@description('Custom deployment ID (5 digits recommended). If not provided, a unique ID is generated.')
param customDeploymentId string = ''

@description('Role boundary for custom RBAC roles. Use subscription ID for single subscription, or management group ID for tenant-wide scanning.')
param roleBoundary string = subscription().id

var deploymentId = empty(customDeploymentId) ? substring(uniqueString(subscription().id, resourceGroupName), 0, 5) : customDeploymentId

var commonTags = union({
  App: 'qualys-snapshot-scanner'
  AppVersion: appVersion
  Name: 'Qualys Snapshot Scanner'
}, tags)

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: commonTags
}

module roles 'modules/roles/main.bicep' = {
  name: 'roles-${deploymentId}'
  params: {
    deploymentId: deploymentId
    roleBoundary: roleBoundary
  }
}

module security 'modules/security/main.bicep' = {
  name: 'security-${deploymentId}'
  scope: rg
  params: {
    location: location
    deploymentId: deploymentId
    tenantId: subscription().tenantId
    deployerObjectId: deployerObjectId
    qualysSubscriptionToken: qualysSubscriptionToken
    targetLocations: targetLocations
    tags: commonTags
  }
}

module networking 'modules/networking/main.bicep' = {
  name: 'networking-${deploymentId}'
  scope: rg
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
  scope: rg
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
  scope: rg
  params: {
    location: location
    deploymentId: deploymentId
    scannerIdentityId: security.outputs.scannerIdentityId
    scannerIdentityPrincipalId: security.outputs.scannerIdentityPrincipalId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    cosmosDnsZoneId: networking.outputs.cosmosDnsZoneId
    tags: commonTags
  }
}

module keyVaultPrivateEndpoint 'modules/keyvault-pe/main.bicep' = {
  name: 'keyvault-pe-${deploymentId}'
  scope: rg
  params: {
    location: location
    deploymentId: deploymentId
    keyVaultId: security.outputs.secretsKeyVaultId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    keyvaultDnsZoneId: networking.outputs.keyvaultDnsZoneId
    tags: commonTags
  }
}

module functionApp 'modules/function-app/main.bicep' = {
  name: 'function-app-${deploymentId}'
  scope: rg
  params: {
    location: location
    deploymentId: deploymentId
    subscriptionId: subscription().subscriptionId
    scannerIdentityId: security.outputs.scannerIdentityId
    scannerIdentityClientId: security.outputs.scannerIdentityClientId
    functionAppSubnetId: networking.outputs.functionAppSubnetId
    storageAccountName: storage.outputs.storageAccountName
    storageAccountKey: storage.outputs.storageAccountKey
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
  scope: rg
  params: {
    location: location
    deploymentId: deploymentId
    subscriptionId: subscription().subscriptionId
    tenantId: subscription().tenantId
    logicAppIdentityId: security.outputs.logicAppIdentityId
    secretsKeyVaultName: security.outputs.secretsKeyVaultName
    qualysTokenSecretName: security.outputs.qualysTokenSecretName
    qualysEndpoint: qualysEndpoint
    functionAppHostname: functionApp.outputs.functionAppHostname
    storageAccountName: storage.outputs.storageAccountName
    storageContainerName: storage.outputs.storageContainerName
    eventBasedDiscovery: eventBasedDiscovery
    appVersion: appVersion
    pollIntervalHours: pollIntervalHours
    scanIntervalHours: scanIntervalHours
    locationConcurrency: locationConcurrency
    scannersPerLocation: scannersPerLocation
    tags: commonTags
  }
}

output deploymentId string = deploymentId
output resourceGroupName string = rg.name
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
