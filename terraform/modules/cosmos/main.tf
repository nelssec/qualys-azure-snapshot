variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "deployment_id" {
  type = number
}

variable "scanner_identity_id" {
  type = string
}

variable "scanner_identity_principal_id" {
  type = string
}

variable "private_endpoint_subnet_id" {
  type = string
}

variable "virtual_network_id" {
  type = string
}

variable "debug_enabled" {
  type = bool
}

variable "tags" {
  type = map(string)
}

resource "azurerm_cosmosdb_account" "main" {
  name                              = "qualys-cosmos-${var.deployment_id}"
  location                          = var.location
  resource_group_name               = var.resource_group_name
  offer_type                        = "Standard"
  kind                              = "GlobalDocumentDB"
  public_network_access_enabled     = false
  local_authentication_disabled     = !var.debug_enabled
  is_virtual_network_filter_enabled = true

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.scanner_identity_id]
  }

  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "scanner" {
  name                = "scanner"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "config" {
  name                = "config"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.scanner.name
  partition_key_paths = ["/id"]
}

resource "azurerm_cosmosdb_sql_container" "tasks" {
  name                = "tasks"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.scanner.name
  partition_key_paths = ["/id"]
  default_ttl         = 259200
}

resource "azurerm_cosmosdb_sql_container" "event_logs" {
  name                = "event-logs"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.scanner.name
  partition_key_paths = ["/id"]
  default_ttl         = 604800
}

resource "azurerm_cosmosdb_sql_container" "resource_inventory" {
  name                = "resource-inventory"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.scanner.name
  partition_key_paths = ["/id"]
  default_ttl         = 86400
}

resource "azurerm_cosmosdb_sql_container" "inventory_scan_status" {
  name                = "inventory-scan-status"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.scanner.name
  partition_key_paths = ["/id"]
}

resource "azurerm_cosmosdb_sql_container" "leases" {
  name                = "leases"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.scanner.name
  partition_key_paths = ["/id"]
}

resource "azurerm_cosmosdb_sql_role_assignment" "scanner" {
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = var.scanner_identity_principal_id
  scope               = azurerm_cosmosdb_account.main.id
}

resource "azurerm_private_endpoint" "cosmos" {
  name                = "qualys-cosmos-pe-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "cosmos-connection"
    private_connection_resource_id = azurerm_cosmosdb_account.main.id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }
}

output "cosmos_db_id" {
  value = azurerm_cosmosdb_account.main.id
}

output "cosmos_db_name" {
  value = azurerm_cosmosdb_account.main.name
}

output "cosmos_db_endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}

output "cosmos_db_database_name" {
  value = azurerm_cosmosdb_sql_database.scanner.name
}
