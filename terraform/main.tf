data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {
  subscription_id = var.subscription_id
}

resource "random_integer" "deployment_id" {
  min = 10000
  max = 99999
}

locals {
  deployment_id        = random_integer.deployment_id.result
  qualys_endpoint      = trimsuffix(var.qualys_api_endpoint, "/")
  target_subscriptions = length(var.target_subscription_ids) > 0 ? var.target_subscription_ids : [var.subscription_id]
  role_boundary        = var.target_role_boundary != "" ? var.target_role_boundary : "/subscriptions/${var.subscription_id}"

  common_tags = merge({
    App        = "qualys-snapshot-scanner"
    AppVersion = var.app_version
    Name       = "Qualys Snapshot Scanner"
  }, var.tags)

  azure_endpoints = {
    AzureCloud = {
      resource_manager = "https://management.azure.com"
      storage          = "https://storage.azure.com"
      keyvault_dns     = "privatelink.vaultcore.azure.net"
      blob_dns         = "privatelink.blob.core.windows.net"
      cosmos_dns       = "privatelink.documents.azure.com"
    }
    AzureUSGovernment = {
      resource_manager = "https://management.usgovcloudapi.net"
      storage          = "https://storage.azure.com"
      keyvault_dns     = "privatelink.vaultcore.usgovcloudapi.net"
      blob_dns         = "privatelink.blob.core.usgovcloudapi.net"
      cosmos_dns       = "privatelink.documents.azure.us"
    }
    AzureChinaCloud = {
      resource_manager = "https://management.chinacloudapi.cn"
      storage          = "https://storage.azure.com"
      keyvault_dns     = "privatelink.vaultcore.azure.cn"
      blob_dns         = "privatelink.blob.core.chinacloudapi.cn"
      cosmos_dns       = "privatelink.documents.azure.cn"
    }
  }

  endpoints = local.azure_endpoints[var.target_cloud]
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

module "security" {
  source = "./modules/security"

  resource_group_name       = azurerm_resource_group.main.name
  location                  = azurerm_resource_group.main.location
  deployment_id             = local.deployment_id
  subscription_id           = var.subscription_id
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  deployer_object_id        = data.azurerm_client_config.current.object_id
  qualys_subscription_token = var.qualys_subscription_token
  target_locations          = var.target_locations
  role_boundary             = local.role_boundary
  tags                      = local.common_tags
}

module "networking" {
  source = "./modules/networking"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  deployment_id       = local.deployment_id
  target_locations    = var.target_locations
  target_cloud        = var.target_cloud
  tags                = local.common_tags
}

module "storage" {
  source = "./modules/storage"

  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  deployment_id              = local.deployment_id
  scanner_identity_id        = module.security.scanner_identity_id
  scanner_identity_principal = module.security.scanner_identity_principal_id
  private_endpoint_subnet_id = module.networking.private_endpoint_subnet_id
  virtual_network_id         = module.networking.service_vnet_id
  tags                       = local.common_tags

  depends_on = [module.security, module.networking]
}

module "cosmos" {
  source = "./modules/cosmos"

  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  deployment_id                 = local.deployment_id
  scanner_identity_id           = module.security.scanner_identity_id
  scanner_identity_principal_id = module.security.scanner_identity_principal_id
  private_endpoint_subnet_id    = module.networking.private_endpoint_subnet_id
  virtual_network_id            = module.networking.service_vnet_id
  debug_enabled                 = var.debug_enabled
  tags                          = local.common_tags

  depends_on = [module.security, module.networking]
}

module "function_app" {
  source = "./modules/function-app"

  resource_group_name         = azurerm_resource_group.main.name
  location                    = azurerm_resource_group.main.location
  deployment_id               = local.deployment_id
  subscription_id             = var.subscription_id
  scanner_identity_id         = module.security.scanner_identity_id
  scanner_identity_client_id  = module.security.scanner_identity_client_id
  function_app_subnet_id      = module.networking.function_app_subnet_id
  storage_account_name        = module.storage.storage_account_name
  storage_account_primary_key = module.storage.storage_account_primary_key
  cosmos_db_endpoint          = module.cosmos.cosmos_db_endpoint
  cosmos_db_name              = module.cosmos.cosmos_db_name
  key_vault_uri               = module.security.secrets_key_vault_uri
  qualys_endpoint             = local.qualys_endpoint
  debug_enabled               = var.debug_enabled
  app_version                 = var.app_version
  scan_interval_hours         = var.scan_interval_hours
  poll_interval_hours         = var.poll_interval_hours
  location_concurrency        = var.location_concurrency
  scanners_per_location       = var.scanners_per_location
  tags                        = local.common_tags

  depends_on = [module.security, module.networking, module.storage, module.cosmos]
}

module "logic_apps" {
  source = "./modules/logic-apps"

  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  deployment_id                   = local.deployment_id
  subscription_id                 = var.subscription_id
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  logic_app_identity_id           = module.security.logic_app_identity_id
  logic_app_identity_principal_id = module.security.logic_app_identity_principal_id
  scanner_identity_id             = module.security.scanner_identity_id
  scanner_identity_client_id      = module.security.scanner_identity_client_id
  secrets_key_vault_name          = module.security.secrets_key_vault_name
  secrets_key_vault_uri           = module.security.secrets_key_vault_uri
  qualys_token_secret_name        = module.security.qualys_token_secret_name
  qualys_endpoint                 = local.qualys_endpoint
  function_app_hostname           = module.function_app.function_app_hostname
  function_app_name               = module.function_app.function_app_name
  storage_account_name            = module.storage.storage_account_name
  storage_container_name          = module.storage.storage_container_name
  cosmos_db_endpoint              = module.cosmos.cosmos_db_endpoint
  service_bus_namespace           = module.storage.service_bus_namespace
  target_locations                = var.target_locations
  target_subscriptions            = local.target_subscriptions
  event_based_discovery           = var.event_based_discovery
  app_version                     = var.app_version
  tags                            = local.common_tags

  depends_on = [module.security, module.networking, module.storage, module.cosmos, module.function_app]
}

resource "azurerm_resource_provider_registration" "compute" {
  name = "Microsoft.Compute"
}

resource "azurerm_resource_provider_registration" "storage" {
  name = "Microsoft.Storage"
}

resource "azurerm_resource_provider_registration" "network" {
  name = "Microsoft.Network"
}

resource "azurerm_resource_provider_registration" "web" {
  name = "Microsoft.Web"
}

resource "azurerm_resource_provider_registration" "logic" {
  name = "Microsoft.Logic"
}

resource "azurerm_resource_provider_registration" "documentdb" {
  name = "Microsoft.DocumentDB"
}

resource "azurerm_resource_provider_registration" "eventgrid" {
  name = "Microsoft.EventGrid"
}

resource "azurerm_resource_provider_registration" "keyvault" {
  name = "Microsoft.KeyVault"
}

resource "time_sleep" "wait_for_deployment" {
  depends_on      = [module.function_app, module.logic_apps]
  create_duration = "60s"
}

resource "null_resource" "trigger_function_app_syncer" {
  depends_on = [time_sleep.wait_for_deployment]

  triggers = {
    deployment_id = local.deployment_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      az rest --method POST \
        --uri "https://management.azure.com/subscriptions/${var.subscription_id}/resourceGroups/${azurerm_resource_group.main.name}/providers/Microsoft.Logic/workflows/qualys-function-app-syncer-${local.deployment_id}/triggers/Recurrence/run?api-version=2019-05-01"
    EOT
  }
}

resource "time_sleep" "wait_for_function_app" {
  depends_on      = [null_resource.trigger_function_app_syncer]
  create_duration = "120s"
}

resource "null_resource" "restart_function_app" {
  depends_on = [time_sleep.wait_for_function_app]

  triggers = {
    deployment_id = local.deployment_id
  }

  provisioner "local-exec" {
    command = "az functionapp restart --name qualys-snapshot-scanner-v3-${local.deployment_id} --resource-group ${azurerm_resource_group.main.name}"
  }
}
