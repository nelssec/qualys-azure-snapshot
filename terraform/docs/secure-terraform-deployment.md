# Securing Qualys Azure Snapshot Scanner with Pure Terraform

## Introduction

The Qualys Azure Snapshot Scanner provides agentless vulnerability assessment for Azure VMs by creating point-in-time snapshots and scanning them for security issues. While the original deployment tool works well, it relies on a Node.js wrapper and requires plaintext credentials in configuration files. This article describes how we refactored the deployment to use pure Terraform with Azure-native secret management.

## The Problem

The original deployment approach had several characteristics that prompted this refactoring:

1. **Plaintext Secrets**: The `user-config.json` file required the Qualys subscription token to be stored in plaintext on disk
2. **Wrapper Complexity**: A 134KB bundled `deploy.js` file orchestrated Terraform CDK, making customization difficult
3. **State Management**: Terraform state was stored in a custom HTTP backend on Qualys servers, limiting visibility and control
4. **Limited Transparency**: The CDK abstraction made it harder to understand and audit the deployed infrastructure

## The Solution

The refactored deployment uses pure HashiCorp Terraform with these key improvements:

- **Azure Key Vault** for all secrets, with RBAC-based access control
- **User-Assigned Managed Identities** for all service-to-service authentication
- **Azure Storage Backend** for Terraform state with versioning enabled
- **Modular Architecture** for maintainability and clarity

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Resource Group                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────────┐   │
│  │   Security   │     │  Networking  │     │       Storage        │   │
│  │   Module     │     │   Module     │     │       Module         │   │
│  ├──────────────┤     ├──────────────┤     ├──────────────────────┤   │
│  │ • Managed    │     │ • Service    │     │ • Storage Account    │   │
│  │   Identities │     │   VNet       │     │ • Blob Container     │   │
│  │ • Key Vault  │     │ • Scanner    │     │ • Service Bus        │   │
│  │ • Disk       │     │   VNets      │     │                      │   │
│  │   Encryption │     │ • VNet       │     │                      │   │
│  │ • Custom     │     │   Peering    │     │                      │   │
│  │   Roles      │     │ • Private    │     │                      │   │
│  │              │     │   DNS Zones  │     │                      │   │
│  └──────────────┘     └──────────────┘     └──────────────────────┘   │
│                                                                         │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────────┐   │
│  │   Cosmos DB  │     │ Function App │     │     Logic Apps       │   │
│  │   Module     │     │   Module     │     │       Module         │   │
│  ├──────────────┤     ├──────────────┤     ├──────────────────────┤   │
│  │ • Serverless │     │ • Linux Flex │     │ • Function App       │   │
│  │   Account    │     │   Consumption│     │   Syncer             │   │
│  │ • SQL        │     │ • Node.js 18 │     │ • Register Service   │   │
│  │   Database   │     │ • VNet       │     │   Account            │   │
│  │ • Containers │     │   Integration│     │ • Discovery          │   │
│  │   for state  │     │ • App        │     │   Workflows          │   │
│  │ • Private    │     │   Insights   │     │ • Scanning           │   │
│  │   Endpoint   │     │   (optional) │     │   Workflows          │   │
│  └──────────────┘     └──────────────┘     └──────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Security Model

### No Plaintext Secrets

The Qualys subscription token is stored in Azure Key Vault and accessed at runtime by Logic Apps using Managed Identity authentication. The token never appears in:

- Terraform state files
- Configuration files
- Environment variables on deployed resources

### Managed Identity Authentication

Two User-Assigned Managed Identities are created:

1. **Scanner Identity**: Used by the Function App and for target subscription operations
   - Key Vault Secrets User (read Qualys token)
   - Key Vault Crypto User (disk encryption)
   - Custom roles for VM/disk/snapshot operations

2. **Logic App Identity**: Used by all Logic App workflows
   - Key Vault Secrets User (read Qualys token)
   - Storage Blob Data Contributor (upload Function App packages)
   - Custom role for VM lifecycle management

### Network Isolation

- All data services use private endpoints (Cosmos DB, Storage, Key Vault)
- Public network access is disabled on all storage resources
- Network Security Groups restrict traffic to HTTPS and SSH outbound only
- VNet peering connects scanner networks to the service network for private endpoint access

### Disk Encryption

Scanner VMs use customer-managed keys stored in dedicated Key Vaults per target location. The encryption is handled through Azure Disk Encryption Sets that reference keys in the per-location Key Vaults.

## Module Breakdown

### Security Module

Creates all identity and access control resources:

```hcl
module "security" {
  source = "./modules/security"

  resource_group_name       = azurerm_resource_group.main.name
  location                  = var.location
  deployment_id             = local.deployment_id
  subscription_id           = data.azurerm_client_config.current.subscription_id
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  deployer_object_id        = data.azurerm_client_config.current.object_id
  qualys_subscription_token = var.qualys_subscription_token
  target_locations          = var.target_locations
  role_boundary             = local.role_boundary
  tags                      = local.common_tags
}
```

The module creates:
- User-Assigned Managed Identities for scanner and logic apps
- Secrets Key Vault with the Qualys token
- Disk Encryption Key Vaults (one per target location)
- Disk Encryption Sets for scanner VMs
- Custom role definitions scoped appropriately

### Networking Module

Creates the network topology:

```hcl
module "networking" {
  source = "./modules/networking"

  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  deployment_id       = local.deployment_id
  target_locations    = var.target_locations
  target_cloud        = var.target_cloud
  tags                = local.common_tags
}
```

The module creates:
- Service VNet with Function App and Private Endpoint subnets
- Scanner VNets (one per target location) with scanner subnets
- VNet peering between scanner and service networks
- Private DNS zones for Key Vault, Blob, and Cosmos DB
- Network Security Groups for service and scanner subnets

### Storage Module

Creates data storage resources:

```hcl
module "storage" {
  source = "./modules/storage"

  resource_group_name        = azurerm_resource_group.main.name
  location                   = var.location
  deployment_id              = local.deployment_id
  scanner_identity_id        = module.security.scanner_identity_id
  scanner_identity_principal = module.security.scanner_identity_principal_id
  private_endpoint_subnet_id = module.networking.private_endpoint_subnet_id
  virtual_network_id         = module.networking.service_vnet_id
  tags                       = local.common_tags
}
```

The module creates:
- Storage Account for Function App packages
- Blob container for deployed packages
- Service Bus namespace with discovery and scanning queues
- Private endpoint for blob access

### Cosmos DB Module

Creates the document database:

```hcl
module "cosmos" {
  source = "./modules/cosmos"

  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.location
  deployment_id                 = local.deployment_id
  scanner_identity_id           = module.security.scanner_identity_id
  scanner_identity_principal_id = module.security.scanner_identity_principal_id
  private_endpoint_subnet_id    = module.networking.private_endpoint_subnet_id
  virtual_network_id            = module.networking.service_vnet_id
  debug_enabled                 = var.debug_enabled
  tags                          = local.common_tags
}
```

The module creates:
- Serverless Cosmos DB account with session consistency
- SQL database named "scanner"
- Containers: config, tasks, event-logs, resource-inventory, inventory-scan-status, leases
- SQL role assignment for Managed Identity access
- Private endpoint for Cosmos DB

### Function App Module

Creates the serverless compute:

```hcl
module "function_app" {
  source = "./modules/function-app"

  resource_group_name         = azurerm_resource_group.main.name
  location                    = var.location
  deployment_id               = local.deployment_id
  subscription_id             = data.azurerm_client_config.current.subscription_id
  scanner_identity_id         = module.security.scanner_identity_id
  scanner_identity_client_id  = module.security.scanner_identity_client_id
  function_app_subnet_id      = module.networking.function_app_subnet_id
  storage_account_name        = module.storage.storage_account_name
  storage_account_primary_key = module.storage.storage_account_primary_key
  cosmos_db_endpoint          = module.cosmos.cosmos_db_endpoint
  cosmos_db_name              = module.cosmos.cosmos_db_database_name
  key_vault_uri               = module.security.secrets_key_vault_uri
  qualys_endpoint             = var.qualys_endpoint
  debug_enabled               = var.debug_enabled
  app_version                 = var.app_version
  scan_interval_hours         = var.scan_interval_hours
  poll_interval_hours         = var.poll_interval_hours
  location_concurrency        = var.location_concurrency
  scanners_per_location       = var.scanners_per_location
  tags                        = local.common_tags
}
```

The module creates:
- Linux Flex Consumption App Service Plan
- Function App with Node.js 18 runtime
- Optional Application Insights (when debug_enabled = true)
- VNet integration for private endpoint access

### Logic Apps Module

Creates the workflow orchestration:

```hcl
module "logic_apps" {
  source = "./modules/logic-apps"

  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  deployment_id                   = local.deployment_id
  subscription_id                 = data.azurerm_client_config.current.subscription_id
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  logic_app_identity_id           = module.security.logic_app_identity_id
  logic_app_identity_principal_id = module.security.logic_app_identity_principal_id
  scanner_identity_id             = module.security.scanner_identity_id
  scanner_identity_client_id      = module.security.scanner_identity_client_id
  secrets_key_vault_name          = module.security.secrets_key_vault_name
  secrets_key_vault_uri           = module.security.secrets_key_vault_uri
  qualys_token_secret_name        = module.security.qualys_token_secret_name
  qualys_endpoint                 = var.qualys_endpoint
  function_app_hostname           = module.function_app.function_app_hostname
  function_app_name               = module.function_app.function_app_name
  storage_account_name            = module.storage.storage_account_name
  storage_container_name          = module.storage.storage_container_name
  cosmos_db_endpoint              = module.cosmos.cosmos_db_endpoint
  service_bus_namespace           = module.storage.service_bus_namespace
  target_locations                = var.target_locations
  target_subscriptions            = var.target_subscriptions
  event_based_discovery           = var.event_based_discovery
  app_version                     = var.app_version
  tags                            = local.common_tags
}
```

The module creates:
- Key Vault API connection with Managed Identity authentication
- Function App Syncer workflow (downloads scanner code from Qualys)
- Register/Deregister Service Account workflows
- Discovery workflows (poll-based and optional event-based)
- Scanning workflows (create snapshots, create disks, prepare scanner)
- Cleanup workflows (delete snapshots, disks, NICs, public IPs, scanner machines)

## Deployment Process

### Prerequisites

1. Azure CLI installed and authenticated
2. Terraform >= 1.5.0 installed
3. Qualys subscription with Azure Snapshot Scanner entitlement
4. Azure subscription with Owner or Contributor access

### Step 1: Create Backend Storage

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

This creates the Azure Storage Account for Terraform state.

### Step 2: Configure Backend

Create `backend.hcl` with the values from bootstrap output:

```hcl
resource_group_name  = "rg-terraform-state"
storage_account_name = "stqualystfxxxxxxxx"
container_name       = "tfstate"
key                  = "qualys-snapshot-scanner.tfstate"
```

### Step 3: Configure Variables

Create `terraform.tfvars`:

```hcl
location                  = "eastus"
qualys_subscription_token = "your-qualys-token"
qualys_endpoint           = "https://gateway.qg1.apps.qualys.com"
target_locations          = ["eastus", "westus2"]
target_subscriptions      = ["subscription-id-1", "subscription-id-2"]
```

### Step 4: Deploy

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

### Step 5: Trigger Initial Sync

After deployment, manually trigger the Function App Syncer Logic App to download the scanner code from Qualys servers.

## Comparison with Original Deployment

| Aspect | Original | Terraform |
|--------|----------|-----------|
| Secret Storage | Plaintext JSON file | Azure Key Vault |
| State Backend | Qualys HTTP backend | Azure Storage |
| Authentication | Service Principal keys | Managed Identity |
| Deployment Tool | Node.js wrapper | Pure Terraform |
| Customization | Modify bundled code | Edit Terraform modules |
| Auditability | Limited visibility | Full IaC transparency |
| Multi-cloud | Bundled per-cloud | Terraform variables |

## Key Security Benefits

1. **No secrets on disk**: Qualys token stored only in Key Vault
2. **No service principal keys**: All authentication uses Managed Identity
3. **State encryption**: Azure Storage encrypts state at rest
4. **Network isolation**: Private endpoints for all data services
5. **Audit trail**: Terraform state tracks all changes
6. **Least privilege**: Custom roles with minimal required permissions

## Conclusion

By refactoring to pure Terraform with Azure-native secret management, we achieve a more secure, transparent, and maintainable deployment. The modular architecture makes it easy to customize for specific requirements while maintaining security best practices.

The Function App code itself still comes from Qualys servers (downloaded by the Function App Syncer Logic App), ensuring you always run the latest supported scanner version. This preserves compatibility while giving you full control over the infrastructure that runs it.
