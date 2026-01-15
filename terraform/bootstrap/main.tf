terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.85"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "location" {
  description = "Azure region for the state storage"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group name for state storage"
  type        = string
  default     = "rg-terraform-state"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_resource_group" "state" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    Purpose   = "terraform-state"
    ManagedBy = "terraform-bootstrap"
  }
}

resource "azurerm_storage_account" "state" {
  name                            = "stqualystf${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true

  blob_properties {
    versioning_enabled = true
  }

  tags = {
    Purpose   = "terraform-state"
    ManagedBy = "terraform-bootstrap"
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

output "resource_group_name" {
  description = "Resource group name for backend config"
  value       = azurerm_resource_group.state.name
}

output "storage_account_name" {
  description = "Storage account name for backend config"
  value       = azurerm_storage_account.state.name
}

output "container_name" {
  description = "Container name for backend config"
  value       = azurerm_storage_container.state.name
}

output "backend_config" {
  description = "Complete backend.hcl content - copy this to ../backend.hcl"
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.state.name}"
    key                  = "qualys-snapshot-scanner.tfstate"
  EOT
}

output "next_steps" {
  description = "Instructions for next steps"
  value       = <<-EOT

    Backend storage created successfully!

    Next steps:
    1. Copy the backend config:
       cd ..
       cat > backend.hcl << 'EOF'
    ${azurerm_resource_group.state.name}
    ${azurerm_storage_account.state.name}
    ${azurerm_storage_container.state.name}
       EOF

    2. Or simply run from the terraform directory:
       terraform init -backend-config="resource_group_name=${azurerm_resource_group.state.name}" \
                      -backend-config="storage_account_name=${azurerm_storage_account.state.name}" \
                      -backend-config="container_name=${azurerm_storage_container.state.name}" \
                      -backend-config="key=qualys-snapshot-scanner.tfstate"

  EOT
}
