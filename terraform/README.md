# Qualys Azure Snapshot Scanner - Pure Terraform

This is a complete Terraform implementation of the Qualys Azure Snapshot Scanner that deploys the **same infrastructure** as the original `deploy.js` but with improved security:

- **No plaintext secrets** in config files
- **Qualys token stored in Azure Key Vault**
- **Logic Apps retrieve token at runtime** via Managed Identity
- **Azure Storage backend** for Terraform state (not Qualys HTTP backend)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Qualys Snapshot Scanner                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐       │
│  │   Key Vault     │     │ Managed         │     │  Function App   │       │
│  │   ───────────   │◄────│ Identities      │────►│  ───────────    │       │
│  │ • Qualys Token  │     │ ───────────     │     │ • Scanner Code  │       │
│  │ • Disk Keys     │     │ • Scanner ID    │     │ • Orchestration │       │
│  └────────┬────────┘     │ • LogicApp ID   │     └────────┬────────┘       │
│           │              └─────────────────┘              │                 │
│           │                                               │                 │
│           ▼                                               ▼                 │
│  ┌─────────────────┐                            ┌─────────────────┐        │
│  │   Logic Apps    │                            │   Cosmos DB     │        │
│  │   ───────────   │                            │   ───────────   │        │
│  │ • Download ZIP  │────── Qualys API ─────────►│ • Tasks         │        │
│  │ • Discover VMs  │                            │ • Inventory     │        │
│  │ • Snapshots     │                            │ • Event Logs    │        │
│  │ • Cleanup       │                            └─────────────────┘        │
│  └─────────────────┘                                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **Azure CLI** installed and authenticated:
   ```bash
   az login
   az account set --subscription "your-subscription-id"
   ```

2. **Terraform** >= 1.5.0

3. **Permissions**:
   - `Owner` or `Contributor` + `User Access Administrator` on the subscription
   - Ability to register resource providers

4. **Qualys Subscription Token** from your Qualys account

## Quick Start

### 1. Create Backend Storage (One-Time)

The backend storage is created via Terraform (no shell scripts):

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

This outputs the backend configuration. Copy it:
```bash
terraform output -raw backend_config > ../backend.hcl
```

### 2. Configure Variables

```bash
cd ..
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 3. Set Qualys Token (Securely!)

```bash
export TF_VAR_qualys_subscription_token="your-qualys-token"
```

### 4. Deploy

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

## Project Structure

```
terraform/
├── main.tf                 # Main orchestration
├── variables.tf            # Input variables
├── outputs.tf              # Output values
├── providers.tf            # Provider configuration
├── versions.tf             # Terraform/provider versions
├── backend.tf              # Backend configuration
├── bootstrap/              # One-time backend storage setup (uses local state)
│   └── main.tf
└── modules/
    ├── security/           # Managed identities, Key Vault, roles
    ├── networking/         # VNets, subnets, NSGs, DNS
    ├── storage/            # Storage account, Service Bus
    ├── cosmos/             # Cosmos DB
    ├── function-app/       # Function App (flex consumption)
    └── logic-apps/         # All 18 Logic App workflows
```

## Security Model

### How Qualys Token is Handled

```
1. You set: export TF_VAR_qualys_subscription_token="..."
                              │
                              ▼
2. Terraform stores in Key Vault (encrypted, access-controlled)
                              │
                              ▼
3. Logic Apps retrieve at runtime via Managed Identity
   (no token in Terraform state or Logic App definitions!)
                              │
                              ▼
4. Token used for Qualys API calls (download ZIP, register, etc.)
```

### Key Security Features

| Feature | Implementation |
|---------|----------------|
| Secret storage | Azure Key Vault with RBAC |
| Authentication | User-Assigned Managed Identities |
| Network security | Private endpoints, NSGs |
| Disk encryption | Customer-managed keys |
| State encryption | Azure Storage with encryption at rest |

## Variables Reference

### Required

| Variable | Description |
|----------|-------------|
| `subscription_id` | Azure subscription for scanner resources |
| `qualys_api_endpoint` | Qualys API URL (e.g., `https://qualysapi.qualys.com`) |
| `qualys_subscription_token` | Qualys token (pass via `TF_VAR_`) |

### Target Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `target_subscription_ids` | `[]` | Subscriptions to scan |
| `target_locations` | `["eastus"]` | Regions for VM discovery |
| `target_role_boundary` | `""` | RBAC scope |

### Scanner Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `scan_interval_hours` | `24` | Hours between scans |
| `poll_interval_hours` | `4` | Hours between discovery polls |
| `location_concurrency` | `5` | Concurrent locations |
| `scanners_per_location` | `1` | Scanner VMs per location |
| `event_based_discovery` | `true` | Enable event-based discovery |

## CI/CD Integration

### GitHub Actions

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
      ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
      ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      ARM_USE_OIDC: true
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        run: terraform init -backend-config=backend.hcl
        working-directory: terraform

      - name: Terraform Apply
        env:
          TF_VAR_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          TF_VAR_qualys_api_endpoint: "https://qualysapi.qualys.com"
          TF_VAR_qualys_subscription_token: ${{ secrets.QUALYS_TOKEN }}
        run: terraform apply -auto-approve
        working-directory: terraform
```

## Comparison with Original deploy.js

| Aspect | deploy.js | This Terraform |
|--------|-----------|----------------|
| Secret storage | `user-config.json` (plaintext) | Key Vault |
| State backend | Qualys HTTP proxy | Azure Storage |
| Logic App token | Embedded in definitions | Key Vault reference |
| Deployment | Node.js orchestrator | Pure Terraform |
| Infrastructure | Identical | Identical |

## Updating Qualys Token

To rotate the token:

```bash
# Update via Terraform
export TF_VAR_qualys_subscription_token="new-token"
terraform apply

# Or directly in Key Vault
az keyvault secret set \
  --vault-name "qualyskv<deployment-id>" \
  --name "qualys-subscription-token" \
  --value "new-token"
```

## Destroying Resources

```bash
terraform destroy
```

Note: Key Vault has soft delete enabled. To fully purge:
```bash
az keyvault purge --name "qualyskv<deployment-id>"
```

## Troubleshooting

### "Key Vault access denied"
Ensure you have `Key Vault Administrator` role on the subscription.

### Logic App workflow fails
Check the Logic App run history in Azure Portal. Common issues:
- Key Vault access policy not propagated (wait a few minutes)
- Qualys token expired or invalid

### Function App not starting
1. Check Application Insights logs (if `debug_enabled = true`)
2. Verify the function app syncer Logic App ran successfully
3. Try restarting: `az functionapp restart --name qualys-snapshot-scanner-v3-<id> --resource-group <rg>`
