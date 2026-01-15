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

variable "tenant_id" {
  type = string
}

variable "deployer_object_id" {
  type = string
}

variable "qualys_subscription_token" {
  type      = string
  sensitive = true
}

variable "target_locations" {
  type = list(string)
}

variable "role_boundary" {
  type = string
}

variable "tags" {
  type = map(string)
}

locals {
  location_abbrev = {
    eastus             = "eus"
    eastus2            = "eus2"
    westus             = "wus"
    westus2            = "wus2"
    westus3            = "wus3"
    centralus          = "cus"
    northcentralus     = "ncus"
    southcentralus     = "scus"
    westcentralus      = "wcus"
    canadacentral      = "cac"
    canadaeast         = "cae"
    brazilsouth        = "brs"
    northeurope        = "neu"
    westeurope         = "weu"
    uksouth            = "uks"
    ukwest             = "ukw"
    francecentral      = "frc"
    francesouth        = "frs"
    germanywestcentral = "gwc"
    norwayeast         = "noe"
    switzerlandnorth   = "swn"
    uaenorth           = "uan"
    southafricanorth   = "san"
    australiaeast      = "aue"
    australiasoutheast = "ause"
    australiacentral   = "auc"
    eastasia           = "ea"
    southeastasia      = "sea"
    japaneast          = "jpe"
    japanwest          = "jpw"
    koreacentral       = "krc"
    koreasouth         = "krs"
    centralindia       = "inc"
    southindia         = "ins"
    westindia          = "inw"
    usgovvirginia      = "ugv"
    usgovarizona       = "uga"
    usgovtexas         = "ugt"
  }
}

resource "azurerm_user_assigned_identity" "scanner" {
  name                = "qualys-snapshot-scanner-target-cmi-${var.deployment_id}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "logic_app" {
  name                = "qualys-snapshot-scanner-service-cmi-${var.deployment_id}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_key_vault" "secrets" {
  name                          = "qualyskv${var.deployment_id}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  soft_delete_retention_days    = 7
  purge_protection_enabled      = true
  enable_rbac_authorization     = true
  public_network_access_enabled = false

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "deployer_keyvault_admin" {
  scope                = azurerm_key_vault.secrets.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = var.deployer_object_id
}

resource "azurerm_role_assignment" "scanner_keyvault_reader" {
  scope                = azurerm_key_vault.secrets.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.scanner.principal_id
}

resource "azurerm_role_assignment" "logic_app_keyvault_reader" {
  scope                = azurerm_key_vault.secrets.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.logic_app.principal_id
}

resource "azurerm_key_vault_secret" "qualys_token" {
  name         = "qualys-subscription-token"
  value        = var.qualys_subscription_token
  key_vault_id = azurerm_key_vault.secrets.id

  depends_on = [azurerm_role_assignment.deployer_keyvault_admin]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault" "disk_encryption" {
  for_each = toset(var.target_locations)

  name                          = "qualysdisk${local.location_abbrev[each.value]}${var.deployment_id}"
  location                      = each.value
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  enabled_for_disk_encryption   = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = true
  enable_rbac_authorization     = true
  public_network_access_enabled = false

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "deployer_disk_kv_admin" {
  for_each = toset(var.target_locations)

  scope                = azurerm_key_vault.disk_encryption[each.key].id
  role_definition_name = "Key Vault Administrator"
  principal_id         = var.deployer_object_id
}

resource "azurerm_role_assignment" "scanner_disk_kv_crypto" {
  for_each = toset(var.target_locations)

  scope                = azurerm_key_vault.disk_encryption[each.key].id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.scanner.principal_id
}

resource "azurerm_key_vault_key" "disk_encryption" {
  for_each = toset(var.target_locations)

  name         = "disk-encryption-key"
  key_vault_id = azurerm_key_vault.disk_encryption[each.key].id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  depends_on = [azurerm_role_assignment.deployer_disk_kv_admin]
}

resource "azurerm_disk_encryption_set" "main" {
  for_each = toset(var.target_locations)

  name                = "qualys-disk-encryption-${each.value}-${var.deployment_id}"
  resource_group_name = var.resource_group_name
  location            = each.value
  key_vault_key_id    = azurerm_key_vault_key.disk_encryption[each.key].id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.scanner.id]
  }

  tags = var.tags

  depends_on = [azurerm_role_assignment.scanner_disk_kv_crypto]
}

resource "azurerm_role_definition" "function_app" {
  name        = "Qualys Scanner Function App Role ${var.deployment_id}"
  scope       = var.role_boundary
  description = "Custom role for Qualys Snapshot Scanner Function App"

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachineScaleSets/read",
      "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read",
      "Microsoft.Compute/disks/read",
      "Microsoft.Compute/snapshots/read",
      "Microsoft.Network/networkInterfaces/read",
      "Microsoft.Network/publicIPAddresses/read",
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/subnets/read",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.DocumentDB/databaseAccounts/readMetadata",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*",
    ]
  }

  assignable_scopes = [var.role_boundary]
}

resource "azurerm_role_definition" "logic_app" {
  name        = "Qualys Scanner Logic App Role ${var.deployment_id}"
  scope       = var.role_boundary
  description = "Custom role for Qualys Snapshot Scanner Logic Apps"

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/write",
      "Microsoft.Compute/virtualMachines/delete",
      "Microsoft.Compute/virtualMachines/runCommand/action",
      "Microsoft.Compute/virtualMachineScaleSets/read",
      "Microsoft.Compute/disks/read",
      "Microsoft.Compute/disks/write",
      "Microsoft.Compute/disks/delete",
      "Microsoft.Compute/disks/beginGetAccess/action",
      "Microsoft.Compute/disks/endGetAccess/action",
      "Microsoft.Compute/snapshots/read",
      "Microsoft.Compute/snapshots/write",
      "Microsoft.Compute/snapshots/delete",
      "Microsoft.Compute/snapshots/beginGetAccess/action",
      "Microsoft.Compute/snapshots/endGetAccess/action",
      "Microsoft.Network/networkInterfaces/read",
      "Microsoft.Network/networkInterfaces/write",
      "Microsoft.Network/networkInterfaces/delete",
      "Microsoft.Network/networkInterfaces/join/action",
      "Microsoft.Network/publicIPAddresses/read",
      "Microsoft.Network/publicIPAddresses/write",
      "Microsoft.Network/publicIPAddresses/delete",
      "Microsoft.Network/publicIPAddresses/join/action",
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/subnets/read",
      "Microsoft.Network/virtualNetworks/subnets/join/action",
      "Microsoft.Network/networkSecurityGroups/read",
      "Microsoft.Network/networkSecurityGroups/join/action",
      "Microsoft.Logic/workflows/read",
      "Microsoft.Logic/workflows/write",
      "Microsoft.Logic/workflows/run/action",
      "Microsoft.Logic/workflows/triggers/run/action",
      "Microsoft.Web/sites/read",
      "Microsoft.Web/sites/restart/action",
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/listKeys/action",
      "Microsoft.Storage/storageAccounts/blobServices/containers/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/write",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
    ]
  }

  assignable_scopes = [var.role_boundary]
}

resource "azurerm_role_definition" "target_scanner" {
  name        = "Qualys Target Scanner Role ${var.deployment_id}"
  scope       = var.role_boundary
  description = "Custom role for scanning VMs in target subscriptions"

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachineScaleSets/read",
      "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read",
      "Microsoft.Compute/disks/read",
      "Microsoft.Compute/disks/beginGetAccess/action",
      "Microsoft.Compute/snapshots/read",
      "Microsoft.Compute/snapshots/write",
      "Microsoft.Compute/snapshots/delete",
      "Microsoft.Network/networkInterfaces/read",
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/subnets/read",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
    ]
  }

  assignable_scopes = [var.role_boundary]
}

resource "azurerm_role_assignment" "function_app_role" {
  scope              = var.role_boundary
  role_definition_id = azurerm_role_definition.function_app.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.scanner.principal_id
}

resource "azurerm_role_assignment" "logic_app_role" {
  scope              = var.role_boundary
  role_definition_id = azurerm_role_definition.logic_app.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.logic_app.principal_id
}

resource "azurerm_role_assignment" "target_scanner_role" {
  scope              = var.role_boundary
  role_definition_id = azurerm_role_definition.target_scanner.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.scanner.principal_id
}

output "scanner_identity_id" {
  value = azurerm_user_assigned_identity.scanner.id
}

output "scanner_identity_client_id" {
  value = azurerm_user_assigned_identity.scanner.client_id
}

output "scanner_identity_principal_id" {
  value = azurerm_user_assigned_identity.scanner.principal_id
}

output "logic_app_identity_id" {
  value = azurerm_user_assigned_identity.logic_app.id
}

output "logic_app_identity_client_id" {
  value = azurerm_user_assigned_identity.logic_app.client_id
}

output "logic_app_identity_principal_id" {
  value = azurerm_user_assigned_identity.logic_app.principal_id
}

output "secrets_key_vault_id" {
  value = azurerm_key_vault.secrets.id
}

output "secrets_key_vault_name" {
  value = azurerm_key_vault.secrets.name
}

output "secrets_key_vault_uri" {
  value = azurerm_key_vault.secrets.vault_uri
}

output "qualys_token_secret_name" {
  value = azurerm_key_vault_secret.qualys_token.name
}

output "disk_encryption_set_ids" {
  value = { for k, v in azurerm_disk_encryption_set.main : k => v.id }
}
