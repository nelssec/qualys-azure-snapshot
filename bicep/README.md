# Qualys Azure Snapshot Scanner - Bicep Deployment

Azure Bicep templates for deploying the Qualys Azure Snapshot Scanner with secure credential management.

## Features

- **Azure Key Vault** for all secrets - Qualys token stored securely and accessed at runtime
- **User-Assigned Managed Identities** for all service-to-service authentication
- **Private endpoints** for all data services (Cosmos DB, Storage, Key Vault)
- **Customer-managed keys** for disk encryption
- **No plaintext credentials** - secrets passed via environment variables or Key Vault references

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- Azure subscription with Owner or Contributor access
- Qualys subscription with Azure Snapshot Scanner entitlement

## Quick Start

1. **Create a resource group:**
   ```bash
   az group create --name rg-qualys-scanner --location eastus
   ```

2. **Set environment variables:**
   ```bash
   export QUALYS_TOKEN="your-qualys-subscription-token"
   export DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
   ```

3. **Deploy:**
   ```bash
   az deployment group create \
     --resource-group rg-qualys-scanner \
     --template-file main.bicep \
     --parameters main.bicepparam
   ```

4. **Trigger initial sync:**
   After deployment, run the `qualys-function-app-syncer-*` Logic App from the Azure Portal to download the scanner code.

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `qualysEndpoint` | Yes | - | Qualys platform API endpoint |
| `qualysSubscriptionToken` | Yes | - | Qualys subscription token (via env var) |
| `targetLocations` | Yes | - | Azure regions to scan VMs in |
| `deployerObjectId` | Yes | - | Object ID of deploying user (via env var) |
| `targetSubscriptions` | No | [current] | Subscription IDs to scan |
| `targetCloud` | No | AzureCloud | Azure cloud environment |
| `debugEnabled` | No | false | Enable Application Insights |
| `eventBasedDiscovery` | No | false | Use event-based VM discovery |
| `scanIntervalHours` | No | 24 | Hours between scan cycles |
| `pollIntervalHours` | No | 24 | Hours between poll-based discovery |
| `locationConcurrency` | No | 5 | Maximum concurrent location scans |
| `scannersPerLocation` | No | 1 | Scanner VMs per location |
| `appVersion` | No | 3.20.0 | Application version |
| `tags` | No | {} | Additional resource tags |

## Secure Credential Handling

The deployment uses environment variables for sensitive values:

```bash
export QUALYS_TOKEN="your-token"
export DEPLOYER_OBJECT_ID="your-object-id"
```

The `main.bicepparam` file references these via `readEnvironmentVariable()`:
```bicep
param qualysSubscriptionToken = readEnvironmentVariable('QUALYS_TOKEN', '')
param deployerObjectId = readEnvironmentVariable('DEPLOYER_OBJECT_ID', '')
```

The Qualys token is immediately stored in Azure Key Vault during deployment and is never persisted in deployment logs or state.

## Preview Changes

```bash
az deployment group what-if \
  --resource-group rg-qualys-scanner \
  --template-file main.bicep \
  --parameters main.bicepparam
```

## Module Structure

```
bicep/
├── main.bicep                    # Entry point
├── main.bicepparam               # Parameters (uses env vars for secrets)
├── modules/
│   ├── security/main.bicep       # Identities, Key Vaults, roles
│   ├── networking/main.bicep     # VNets, subnets, NSGs, DNS zones
│   ├── storage/main.bicep        # Storage Account, Service Bus
│   ├── cosmos/main.bicep         # Cosmos DB
│   ├── function-app/main.bicep   # Function App
│   └── logic-apps/main.bicep     # Logic App workflows
└── docs/
```

## Resources Created

### Security
- Scanner managed identity (for target subscription operations)
- Logic App managed identity (for workflow operations)
- Secrets Key Vault (stores Qualys token)
- Disk encryption Key Vaults (one per target location)
- Disk encryption sets with customer-managed keys
- Custom role definitions with least-privilege permissions

### Networking
- Service VNet (10.0.0.0/16)
  - Function App subnet with delegation
  - Private endpoints subnet
- Scanner VNets (one per target location)
- VNet peering between scanner and service networks
- Private DNS zones (Key Vault, Blob, Cosmos DB)
- Network Security Groups

### Storage
- Storage Account for Function App packages (private access only)
- Service Bus namespace with discovery and scanning queues
- Private endpoint for blob access

### Cosmos DB
- Serverless Cosmos DB account
- Scanner database with containers: config, tasks, event-logs, resource-inventory, inventory-scan-status, leases
- Private endpoint

### Function App
- Flex Consumption App Service Plan
- Linux Function App (Node.js 18)
- VNet integration
- Application Insights (when debugEnabled=true)

### Logic Apps
- Function App Syncer (downloads scanner code from Qualys)
- Register/Deregister Service Account
- Discovery workflows (poll-based and event-based)
- Scanning workflows (create snapshots, create disks, prepare scanner)
- Cleanup workflows (delete snapshots, disks, NICs, public IPs, scanner machines)

## Security Model

1. **No plaintext secrets on disk** - Qualys token stored only in Key Vault
2. **No service principal keys** - All authentication uses Managed Identity
3. **Network isolation** - Private endpoints for all data services
4. **Least privilege** - Custom roles with minimal required permissions
5. **Encryption at rest** - Customer-managed keys for disk encryption

## Cleanup

Delete all resources:
```bash
az group delete --name rg-qualys-scanner --yes
```

Key Vaults with purge protection will be soft-deleted. To fully remove:
```bash
az keyvault purge --name qualyskv<deployment-id>
```
