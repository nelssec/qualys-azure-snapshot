output "deployment_id" {
  description = "Unique deployment identifier"
  value       = local.deployment_id
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "scanner_identity" {
  description = "Scanner managed identity details"
  value = {
    id           = module.security.scanner_identity_id
    client_id    = module.security.scanner_identity_client_id
    principal_id = module.security.scanner_identity_principal_id
  }
}

output "key_vault" {
  description = "Secrets Key Vault details"
  value = {
    name = module.security.secrets_key_vault_name
    uri  = module.security.secrets_key_vault_uri
  }
}

output "function_app" {
  description = "Function App details"
  value = {
    name     = module.function_app.function_app_name
    hostname = module.function_app.function_app_hostname
  }
}

output "cosmos_db" {
  description = "Cosmos DB details"
  value = {
    name     = module.cosmos.cosmos_db_name
    endpoint = module.cosmos.cosmos_db_endpoint
  }
}

output "storage_account" {
  description = "Storage account name"
  value       = module.storage.storage_account_name
}

output "logic_app_workflows" {
  description = "Logic App workflow names"
  value       = module.logic_apps.workflow_names
}
