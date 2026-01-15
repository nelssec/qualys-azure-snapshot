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

variable "scanner_identity_principal" {
  type = string
}

variable "private_endpoint_subnet_id" {
  type = string
}

variable "virtual_network_id" {
  type = string
}

variable "tags" {
  type = map(string)
}

resource "azurerm_storage_account" "main" {
  name                            = "qualysst${var.deployment_id}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = false
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.scanner_identity_id]
  }

  tags = var.tags
}

resource "azurerm_storage_container" "function_packages" {
  name                  = "function-app-packages"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "scanner_storage_blob_contributor" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.scanner_identity_principal
}

resource "azurerm_role_assignment" "scanner_storage_queue_contributor" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = var.scanner_identity_principal
}

resource "azurerm_private_endpoint" "storage_blob" {
  name                = "qualys-storage-pe-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "storage-blob-connection"
    private_connection_resource_id = azurerm_storage_account.main.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
}

resource "azurerm_servicebus_namespace" "main" {
  name                = "qualys-sb-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_servicebus_queue" "discovery" {
  name                = "discovery-queue"
  namespace_id        = azurerm_servicebus_namespace.main.id
  enable_partitioning = false
  max_delivery_count  = 10
  lock_duration       = "PT5M"
  default_message_ttl = "P1D"
}

resource "azurerm_servicebus_queue" "scanning" {
  name                = "scanning-queue"
  namespace_id        = azurerm_servicebus_namespace.main.id
  enable_partitioning = false
  max_delivery_count  = 10
  lock_duration       = "PT5M"
  default_message_ttl = "P1D"
}

output "storage_account_id" {
  value = azurerm_storage_account.main.id
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "storage_account_primary_key" {
  value     = azurerm_storage_account.main.primary_access_key
  sensitive = true
}

output "storage_account_primary_blob_endpoint" {
  value = azurerm_storage_account.main.primary_blob_endpoint
}

output "storage_container_name" {
  value = azurerm_storage_container.function_packages.name
}

output "service_bus_namespace" {
  value = azurerm_servicebus_namespace.main.name
}

output "service_bus_namespace_id" {
  value = azurerm_servicebus_namespace.main.id
}

output "service_bus_connection_string" {
  value     = azurerm_servicebus_namespace.main.default_primary_connection_string
  sensitive = true
}
