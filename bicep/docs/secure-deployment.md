# Secure Deployment of Qualys Azure Snapshot Scanner

This document describes the architecture and security model for deploying the Qualys Azure Snapshot Scanner using Azure Bicep with secure credential management.

## Overview

The Qualys Azure Snapshot Scanner provides agentless vulnerability assessment for Azure VMs by creating point-in-time disk snapshots and scanning them for security issues. This deployment uses Azure-native infrastructure-as-code (Bicep) with a focus on security best practices.

## Architecture

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

### Credential Management

The deployment eliminates plaintext secrets through multiple layers:

1. **Environment Variables at Deploy Time**: The Qualys subscription token is passed via environment variable (`QUALYS_TOKEN`), never stored in files.

2. **Immediate Key Vault Storage**: During deployment, the token is immediately stored in Azure Key Vault with RBAC-based access control.

3. **Runtime Retrieval**: Logic Apps retrieve the token at runtime using Managed Identity authentication to Key Vault.

### Managed Identity Authentication

Two User-Assigned Managed Identities handle all service-to-service authentication:

**Scanner Identity**
- Used by the Function App for target subscription operations
- Key Vault Secrets User role for reading the Qualys token
- Key Vault Crypto User role for disk encryption
- Custom role for VM/disk/snapshot read operations

**Logic App Identity**
- Used by all Logic App workflows
- Key Vault Secrets User role for reading the Qualys token
- Storage Blob Data Contributor for uploading Function App packages
- Custom role for VM lifecycle management

### Network Isolation

All data services are isolated from public internet access:

- **Private Endpoints**: Cosmos DB, Storage Account, and Key Vault are accessible only through private endpoints
- **Public Access Disabled**: All storage resources have public network access disabled
- **Network Security Groups**: Restrict traffic to HTTPS (443) and SSH (22) outbound only
- **VNet Peering**: Scanner networks connect to the service network for private endpoint access

### Disk Encryption

Scanner VMs use customer-managed keys:

- Dedicated Key Vault per target location
- RSA 2048-bit keys for disk encryption
- Disk Encryption Sets reference keys via Managed Identity
- Keys never leave the Key Vault boundary

### Least Privilege Roles

Custom role definitions provide minimal required permissions:

**Function App Role**
- Read-only access to VMs, disks, snapshots, and network resources
- Cosmos DB data access for state management

**Logic App Role**
- VM lifecycle management (create, delete)
- Disk and snapshot operations
- Network interface management
- Logic App workflow execution

**Target Scanner Role**
- Read-only VM and disk access in target subscriptions
- Snapshot creation and deletion for scanning

## Data Flow

1. **Deployment**: Bicep templates create all infrastructure, storing the Qualys token in Key Vault

2. **Code Sync**: Function App Syncer Logic App:
   - Retrieves Qualys token from Key Vault via Managed Identity
   - Downloads scanner code from Qualys servers
   - Uploads to Storage Account blob container

3. **Discovery**: Poll-based or event-based Logic Apps discover VMs in target subscriptions

4. **Scanning**:
   - Create disk snapshots in target subscriptions
   - Copy snapshots to scanner resource group
   - Create disks from snapshots
   - Attach disks to scanner VMs for analysis
   - Report findings to Qualys platform

5. **Cleanup**: Logic Apps delete temporary snapshots, disks, and scanner VMs

## Deployment

### Prerequisites

```bash
az login
az group create --name rg-qualys-scanner --location eastus
```

### Set Credentials via Environment Variables

```bash
export QUALYS_TOKEN="your-qualys-subscription-token"
export DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
```

### Deploy

```bash
az deployment group create \
  --resource-group rg-qualys-scanner \
  --template-file main.bicep \
  --parameters main.bicepparam
```

### Post-Deployment

1. Trigger the Function App Syncer Logic App to download scanner code
2. Verify the Function App is running
3. Check Cosmos DB for initial configuration data

## Monitoring

When `debugEnabled=true`:
- Application Insights captures Function App telemetry
- Log Analytics Workspace stores operational logs
- Query logs via Azure Portal or KQL

## Compliance Considerations

This deployment supports compliance requirements through:

- **Data Residency**: All resources deploy to specified Azure regions
- **Encryption**: Data encrypted at rest with customer-managed keys
- **Access Control**: RBAC-based access with least privilege
- **Audit Trail**: Azure Activity Log captures all management operations
- **Network Security**: Private endpoints prevent public internet exposure
