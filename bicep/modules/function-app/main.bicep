targetScope = 'resourceGroup'

param location string
param deploymentId string
param subscriptionId string
param scannerIdentityId string
param scannerIdentityClientId string
param functionAppSubnetId string
param storageAccountName string
@secure()
param storageAccountKey string
param cosmosDbEndpoint string
param cosmosDbName string
param keyVaultUri string
param qualysEndpoint string
param debugEnabled bool
param appVersion string
param scanIntervalHours int
param pollIntervalHours int
param locationConcurrency int
param scannersPerLocation int
param tags object

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = if (debugEnabled) {
  name: 'qualys-logs-${deploymentId}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
  tags: tags
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (debugEnabled) {
  name: 'qualys-insights-${deploymentId}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: debugEnabled ? logAnalyticsWorkspace.id : null
  }
  tags: tags
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'qualys-asp-${deploymentId}'
  location: location
  kind: 'linux'
  sku: {
    name: 'P1v2'
    tier: 'PremiumV2'
  }
  properties: {
    reserved: true
  }
  tags: tags
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: 'qualys-snapshot-scanner-v3-${deploymentId}'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scannerIdentityId}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    virtualNetworkSubnetId: functionAppSubnetId
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|18'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AZURE_CLIENT_ID', value: scannerIdentityClientId }
        { name: 'SUBSCRIPTION_ID', value: subscriptionId }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'node' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION', value: '~18' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccountKey};EndpointSuffix=core.windows.net' }
        { name: 'COSMOS_ENDPOINT', value: cosmosDbEndpoint }
        { name: 'COSMOS_DATABASE', value: cosmosDbName }
        { name: 'KEY_VAULT_URI', value: keyVaultUri }
        { name: 'QENDPOINT', value: qualysEndpoint }
        { name: 'SCAN_INTERVAL_HOURS', value: string(scanIntervalHours) }
        { name: 'POLL_INTERVAL_HOURS', value: string(pollIntervalHours) }
        { name: 'LOCATION_CONCURRENCY', value: string(locationConcurrency) }
        { name: 'SCANNERS_PER_LOCATION', value: string(scannersPerLocation) }
        { name: 'APP_VERSION', value: appVersion }
        #disable-next-line BCP318
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: debugEnabled ? appInsights.properties.InstrumentationKey : '' }
        #disable-next-line BCP318
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: debugEnabled ? appInsights.properties.ConnectionString : '' }
      ]
    }
  }
  #disable-next-line BCP318
  tags: union(tags, debugEnabled ? { 'hidden-link: /app-insights-resource-id': appInsights.id } : {})
}

output functionAppId string = functionApp.id
output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
#disable-next-line BCP318
output appInsightsConnectionString string = debugEnabled ? appInsights.properties.ConnectionString : ''
