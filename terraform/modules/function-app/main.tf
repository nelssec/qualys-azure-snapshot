variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "deployment_id" {
  type = number
}

variable "subscription_id" {
  type = string
}

variable "scanner_identity_id" {
  type = string
}

variable "scanner_identity_client_id" {
  type = string
}

variable "function_app_subnet_id" {
  type = string
}

variable "storage_account_name" {
  type = string
}

variable "storage_account_primary_key" {
  type      = string
  sensitive = true
}

variable "cosmos_db_endpoint" {
  type = string
}

variable "cosmos_db_name" {
  type = string
}

variable "key_vault_uri" {
  type = string
}

variable "qualys_endpoint" {
  type = string
}

variable "debug_enabled" {
  type = bool
}

variable "app_version" {
  type = string
}

variable "scan_interval_hours" {
  type = number
}

variable "poll_interval_hours" {
  type = number
}

variable "location_concurrency" {
  type = number
}

variable "scanners_per_location" {
  type = number
}

variable "tags" {
  type = map(string)
}

resource "azurerm_service_plan" "main" {
  name                = "qualys-asp-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = "FC1"

  tags = var.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  count = var.debug_enabled ? 1 : 0

  name                = "qualys-logs-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = var.tags
}

resource "azurerm_application_insights" "main" {
  count = var.debug_enabled ? 1 : 0

  name                = "qualys-insights-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.main[0].id
  application_type    = "web"

  tags = var.tags
}

resource "azurerm_linux_function_app" "main" {
  name                       = "qualys-snapshot-scanner-v3-${var.deployment_id}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = var.storage_account_name
  storage_account_access_key = var.storage_account_primary_key

  virtual_network_subnet_id = var.function_app_subnet_id

  identity {
    type         = "UserAssigned"
    identity_ids = [var.scanner_identity_id]
  }

  site_config {
    application_stack {
      node_version = "18"
    }

    ftps_state                             = "Disabled"
    minimum_tls_version                    = "1.2"
    application_insights_key               = var.debug_enabled ? azurerm_application_insights.main[0].instrumentation_key : null
    application_insights_connection_string = var.debug_enabled ? azurerm_application_insights.main[0].connection_string : null
  }

  app_settings = {
    "AZURE_CLIENT_ID"              = var.scanner_identity_client_id
    "SUBSCRIPTION_ID"              = var.subscription_id
    "FUNCTIONS_WORKER_RUNTIME"     = "node"
    "WEBSITE_NODE_DEFAULT_VERSION" = "~18"
    "WEBSITE_RUN_FROM_PACKAGE"     = "1"
    "COSMOS_ENDPOINT"              = var.cosmos_db_endpoint
    "COSMOS_DATABASE"              = var.cosmos_db_name
    "KEY_VAULT_URI"                = var.key_vault_uri
    "QENDPOINT"                    = var.qualys_endpoint
    "SCAN_INTERVAL_HOURS"          = tostring(var.scan_interval_hours)
    "POLL_INTERVAL_HOURS"          = tostring(var.poll_interval_hours)
    "LOCATION_CONCURRENCY"         = tostring(var.location_concurrency)
    "SCANNERS_PER_LOCATION"        = tostring(var.scanners_per_location)
    "APP_VERSION"                  = var.app_version
  }

  tags = merge(var.tags, {
    "hidden-link: /app-insights-resource-id" = var.debug_enabled ? azurerm_application_insights.main[0].id : ""
  })

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID"],
    ]
  }
}

output "function_app_id" {
  value = azurerm_linux_function_app.main.id
}

output "function_app_name" {
  value = azurerm_linux_function_app.main.name
}

output "function_app_hostname" {
  value = azurerm_linux_function_app.main.default_hostname
}

output "function_app_principal_id" {
  value = azurerm_linux_function_app.main.identity[0].principal_id
}

output "app_insights_connection_string" {
  value     = var.debug_enabled ? azurerm_application_insights.main[0].connection_string : null
  sensitive = true
}
