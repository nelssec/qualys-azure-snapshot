using './main.bicep'

param location = 'eastus'
param resourceGroupName = 'qualys-scanner-rg'
param qualysEndpoint = 'https://gateway.qg1.apps.qualys.com'
param qualysSubscriptionToken = readEnvironmentVariable('QUALYS_TOKEN', '')
param targetLocations = ['eastus']
param deployerObjectId = readEnvironmentVariable('DEPLOYER_OBJECT_ID', '')
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
