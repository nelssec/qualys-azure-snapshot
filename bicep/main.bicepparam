using './main.bicep'

param qualysEndpoint = 'https://gateway.qg1.apps.qualys.com'
param qualysSubscriptionToken = readEnvironmentVariable('QUALYS_TOKEN', '')
param targetLocations = ['eastus', 'westus2']
param deployerObjectId = readEnvironmentVariable('DEPLOYER_OBJECT_ID', '')
param targetSubscriptions = []
param targetCloud = 'AzureCloud'
param debugEnabled = false
param eventBasedDiscovery = false
param scanIntervalHours = 24
param pollIntervalHours = 4
param locationConcurrency = 5
param scannersPerLocation = 1
param appVersion = '3.20.0'
param customDeploymentId = ''
param tags = {}
