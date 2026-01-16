# Qualys Azure Snapshot Scanner - Bicep Deployment

Infrastructure-as-Code deployment for the Qualys Azure Snapshot Scanner using Azure Bicep with enterprise-grade security.

## Features

- **Subscription-scoped deployment** - Creates resource group and all resources in a single deployment
- **Azure Key Vault** - Qualys token stored securely and accessed at runtime via managed identity
- **User-Assigned Managed Identities** - No service principal keys or secrets
- **Private endpoints** - Network isolation for Cosmos DB, Storage, and Key Vault
- **Customer-managed keys** - Disk encryption with keys stored in dedicated Key Vaults
- **Custom RBAC roles** - Least-privilege permissions scoped to subscription or management group
- **Multi-cloud support** - AzureCloud, AzureUSGovernment, and AzureChinaCloud

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- Subscription with Owner access (for custom role definitions)
- Qualys subscription with Azure Snapshot Scanner entitlement
- Qualys subscription token from your Qualys platform

## Quick Start

```bash
az deployment sub create \
  --location eastus \
  --template-file main.bicep \
  --parameters \
    location=eastus \
    qualysEndpoint='https://gateway.qg1.apps.qualys.com' \
    qualysSubscriptionToken='your-qualys-token' \
    targetLocations='["eastus"]' \
    deployerObjectId=$(az ad signed-in-user show --query id -o tsv)
```

After deployment, the `qualys-function-app-syncer` Logic App automatically downloads the scanner code from Qualys on an hourly schedule. You can trigger it manually from the Azure Portal for immediate setup.

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `location` | Yes | - | Azure region for deployment |
| `qualysEndpoint` | Yes | - | Qualys platform API endpoint |
| `qualysSubscriptionToken` | Yes | - | Qualys subscription token |
| `targetLocations` | Yes | - | Azure regions to scan VMs in |
| `deployerObjectId` | Yes | - | Object ID of deploying user/service principal |
| `resourceGroupName` | No | qualys-scanner-rg | Resource group name |
| `customDeploymentId` | No | auto-generated | Custom deployment identifier (5 chars) |
| `targetCloud` | No | AzureCloud | Azure cloud (AzureCloud, AzureUSGovernment, AzureChinaCloud) |
| `roleBoundary` | No | subscription | Assignable scope for custom roles |
| `debugEnabled` | No | false | Enable Application Insights logging |
| `eventBasedDiscovery` | No | false | Enable event-based VM discovery |
| `scanIntervalHours` | No | 24 | Hours between scan cycles |
| `pollIntervalHours` | No | 4 | Hours between poll-based discovery |
| `locationConcurrency` | No | 5 | Maximum concurrent location scans |
| `scannersPerLocation` | No | 1 | Scanner VMs per location |
| `appVersion` | No | 3.20.0 | Scanner application version |
| `tags` | No | {} | Additional resource tags |

## Qualys Platform Endpoints

| Region | Endpoint |
|--------|----------|
| US Platform 1 | `https://gateway.qg1.apps.qualys.com` |
| US Platform 2 | `https://gateway.qg2.apps.qualys.com` |
| US Platform 3 | `https://gateway.qg3.apps.qualys.com` |
| EU Platform 1 | `https://gateway.qg1.apps.qualys.eu` |
| Canada | `https://gateway.qg1.apps.qualys.ca` |

## Module Structure

```
bicep/
├── main.bicep                      # Entry point (subscription scope)
├── main.bicepparam                 # Parameter file with env var support
└── modules/
    ├── roles/main.bicep            # Custom RBAC role definitions
    ├── security/main.bicep         # Identities, Key Vaults, encryption
    ├── networking/main.bicep       # VNets, subnets, NSGs, DNS zones
    ├── storage/main.bicep          # Storage Account, Service Bus
    ├── cosmos/main.bicep           # Cosmos DB
    ├── function-app/main.bicep     # Function App (Premium V2)
    ├── keyvault-pe/main.bicep      # Key Vault private endpoint
    └── logic-apps/main.bicep       # 18 Logic App workflows
```

## Resources Created

### Identity & Security
- **Scanner Identity** - User-assigned managed identity for VM scanning operations
- **Logic App Identity** - User-assigned managed identity for workflow operations
- **Secrets Key Vault** - Stores Qualys subscription token with private endpoint
- **Disk Encryption Key Vaults** - One per target location with customer-managed keys
- **Disk Encryption Sets** - Enable CMK encryption for scanner disks
- **Custom RBAC Roles** - Three least-privilege roles for scanner, logic apps, and function app

### Networking
- **Service VNet** (10.0.0.0/16)
  - Function App subnet with Microsoft.Web/serverFarms delegation
  - Private endpoints subnet with restrictive NSG
- **Scanner VNets** - One per target location for scanner VM isolation
- **VNet Peering** - Bidirectional peering between service and scanner networks
- **Private DNS Zones** - Key Vault, Blob Storage, Cosmos DB, Service Bus
- **Network Security Groups** - Restrictive inbound/outbound rules

### Data Services
- **Storage Account** - Function App packages with private endpoint
- **Service Bus** - Discovery and scanning queues (Standard tier)
- **Cosmos DB** - Serverless account with private endpoint
  - Containers: config, tasks, event-logs, resource-inventory, inventory-scan-status, leases

### Compute
- **App Service Plan** - Premium V2 (P1v2) for VNet integration
- **Function App** - Linux Node.js 18 with managed identity authentication
- **Application Insights** - Optional logging when debugEnabled=true

### Logic Apps (18 workflows)
| Workflow | Purpose |
|----------|---------|
| function-app-syncer | Downloads scanner code from Qualys |
| register-service-account | Registers scanner with Qualys platform |
| deregister-service-account | Deregisters scanner from Qualys |
| poll-based-discover-vms-v2 | Scheduled VM discovery |
| discover-resources-v2 | Resource discovery orchestration |
| demand-based-discover-vms-v2 | On-demand VM discovery |
| find-scan-candidates | Identifies VMs ready for scanning |
| create-snapshots-v2 | Creates disk snapshots |
| create-disks | Creates disks from snapshots |
| concurrent-scanner | Manages concurrent scan operations |
| prepare-scanner-machine | Prepares scanner VMs |
| run-commands | Executes commands on scanner VMs |
| cleanup-resources-v2 | Orchestrates resource cleanup |
| delete-snapshots | Removes completed snapshots |
| delete-disks | Removes scanner disks |
| delete-nics | Removes scanner NICs |
| delete-public-ips | Removes scanner public IPs |
| delete-scanner-machines | Removes scanner VMs |

## Security Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Azure Subscription                       │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Key Vault  │◄───│  Logic Apps  │───►│  Cosmos DB   │      │
│  │  (Private)   │    │  (18 flows)  │    │  (Private)   │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│         ▲                   │                    ▲              │
│         │                   ▼                    │              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Storage    │◄───│ Function App │───►│  Service Bus │      │
│  │  (Private)   │    │  (VNet Int)  │    │  (Standard)  │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│                             │                                   │
│                      ┌──────┴──────┐                           │
│                      ▼             ▼                           │
│               ┌───────────┐ ┌───────────┐                      │
│               │ Scanner   │ │ Scanner   │  (Per-location)      │
│               │ VNet      │ │ VNet      │                      │
│               └───────────┘ └───────────┘                      │
└─────────────────────────────────────────────────────────────────┘
```

**Security Controls:**
1. No plaintext secrets - Qualys token stored only in Key Vault
2. Managed Identity authentication - No service principal keys
3. Private endpoints - All data services isolated from public internet
4. Custom RBAC roles - Minimal permissions for each component
5. Customer-managed keys - Disk encryption with dedicated Key Vaults
6. Network segmentation - Scanner VNets isolated from service VNet

## Preview Changes

```bash
az deployment sub what-if \
  --location eastus \
  --template-file main.bicep \
  --parameters location=eastus qualysEndpoint='...' ...
```

## Cleanup

Delete all resources:
```bash
az group delete --name qualys-scanner-rg --yes
```

Delete custom role definitions:
```bash
az role definition list --query "[?contains(roleName, 'Qualys')].name" -o tsv | \
  xargs -I {} az role definition delete --name {}
```

Key Vaults with purge protection remain soft-deleted for the retention period (7 days minimum).

## Troubleshooting

**Key Vault conflict on redeploy:**
Soft-deleted Key Vaults block redeployment with the same name. Use a different `customDeploymentId` or wait for the soft-delete retention period.

**Logic App workflow failures:**
Check the Logic App run history in the Azure Portal. Common issues:
- Key Vault access denied - Verify managed identity has Key Vault Secrets User role
- Qualys API errors - Verify the subscription token is valid and not expired

**Function App not running:**
- Verify the function-app-syncer Logic App has run successfully
- Check Application Insights logs if debugEnabled=true
