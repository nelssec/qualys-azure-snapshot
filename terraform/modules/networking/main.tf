variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "deployment_id" {
  type = number
}

variable "target_locations" {
  type = list(string)
}

variable "target_cloud" {
  type = string
}

variable "tags" {
  type = map(string)
}

locals {
  dns_suffixes = {
    AzureCloud = {
      keyvault = "privatelink.vaultcore.azure.net"
      blob     = "privatelink.blob.core.windows.net"
      cosmos   = "privatelink.documents.azure.com"
      web      = "privatelink.azurewebsites.net"
    }
    AzureUSGovernment = {
      keyvault = "privatelink.vaultcore.usgovcloudapi.net"
      blob     = "privatelink.blob.core.usgovcloudapi.net"
      cosmos   = "privatelink.documents.azure.us"
      web      = "privatelink.azurewebsites.us"
    }
    AzureChinaCloud = {
      keyvault = "privatelink.vaultcore.azure.cn"
      blob     = "privatelink.blob.core.chinacloudapi.cn"
      cosmos   = "privatelink.documents.azure.cn"
      web      = "privatelink.chinacloudsites.cn"
    }
  }

  dns = local.dns_suffixes[var.target_cloud]
}

resource "azurerm_network_security_group" "scanner" {
  name                = "qualys-scanner-nsg-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowHTTPSOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowSSHOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "service" {
  name                = "qualys-service-nsg-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowHTTPSInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_virtual_network" "service" {
  name                = "qualys-service-vnet-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "function_app" {
  name                 = "function-app-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.service.name
  address_prefixes     = ["10.0.1.0/24"]

  delegation {
    name = "function-app-delegation"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "private-endpoints-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.service.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "function_app" {
  subnet_id                 = azurerm_subnet.function_app.id
  network_security_group_id = azurerm_network_security_group.service.id
}

resource "azurerm_virtual_network" "scanner" {
  for_each = toset(var.target_locations)

  name                = "qualys-scanner-vnet-${each.value}-${var.deployment_id}"
  location            = each.value
  resource_group_name = var.resource_group_name
  address_space       = ["10.${index(var.target_locations, each.value) + 1}.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "scanner" {
  for_each = toset(var.target_locations)

  name                 = "scanner-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.scanner[each.key].name
  address_prefixes     = ["10.${index(var.target_locations, each.value) + 1}.1.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "scanner" {
  for_each = toset(var.target_locations)

  subnet_id                 = azurerm_subnet.scanner[each.key].id
  network_security_group_id = azurerm_network_security_group.scanner.id
}

resource "azurerm_virtual_network_peering" "scanner_to_service" {
  for_each = toset(var.target_locations)

  name                         = "scanner-to-service-${each.value}"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.scanner[each.key].name
  remote_virtual_network_id    = azurerm_virtual_network.service.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "service_to_scanner" {
  for_each = toset(var.target_locations)

  name                         = "service-to-scanner-${each.value}"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.service.name
  remote_virtual_network_id    = azurerm_virtual_network.scanner[each.key].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_private_dns_zone" "keyvault" {
  name                = local.dns.keyvault
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "blob" {
  name                = local.dns.blob
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "cosmos" {
  name                = local.dns.cosmos
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  name                  = "keyvault-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = azurerm_virtual_network.service.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "blob-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.service.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "cosmos" {
  name                  = "cosmos-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.cosmos.name
  virtual_network_id    = azurerm_virtual_network.service.id
  registration_enabled  = false
  tags                  = var.tags
}

output "service_vnet_id" {
  value = azurerm_virtual_network.service.id
}

output "service_vnet_name" {
  value = azurerm_virtual_network.service.name
}

output "function_app_subnet_id" {
  value = azurerm_subnet.function_app.id
}

output "private_endpoint_subnet_id" {
  value = azurerm_subnet.private_endpoints.id
}

output "scanner_vnet_ids" {
  value = { for k, v in azurerm_virtual_network.scanner : k => v.id }
}

output "scanner_subnet_ids" {
  value = { for k, v in azurerm_subnet.scanner : k => v.id }
}

output "keyvault_dns_zone_id" {
  value = azurerm_private_dns_zone.keyvault.id
}

output "blob_dns_zone_id" {
  value = azurerm_private_dns_zone.blob.id
}

output "cosmos_dns_zone_id" {
  value = azurerm_private_dns_zone.cosmos.id
}
