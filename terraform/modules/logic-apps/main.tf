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

variable "logic_app_identity_id" {
  type = string
}

variable "logic_app_identity_principal_id" {
  type = string
}

variable "scanner_identity_id" {
  type = string
}

variable "scanner_identity_client_id" {
  type = string
}

variable "secrets_key_vault_name" {
  type = string
}

variable "secrets_key_vault_uri" {
  type = string
}

variable "qualys_token_secret_name" {
  type = string
}

variable "qualys_endpoint" {
  type = string
}

variable "function_app_hostname" {
  type = string
}

variable "function_app_name" {
  type = string
}

variable "storage_account_name" {
  type = string
}

variable "storage_container_name" {
  type = string
}

variable "cosmos_db_endpoint" {
  type = string
}

variable "service_bus_namespace" {
  type = string
}

variable "target_locations" {
  type = list(string)
}

variable "target_subscriptions" {
  type = list(string)
}

variable "event_based_discovery" {
  type = bool
}

variable "app_version" {
  type = string
}

variable "tags" {
  type = map(string)
}

locals {
  workflow_prefix = "qualys"

  managed_identity_auth = jsonencode({
    type     = "ManagedServiceIdentity"
    identity = var.logic_app_identity_id
  })
}

resource "azurerm_resource_group_template_deployment" "keyvault_connection" {
  name                = "keyvault-connection-${var.deployment_id}"
  resource_group_name = var.resource_group_name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    resources = [
      {
        type       = "Microsoft.Web/connections"
        apiVersion = "2016-06-01"
        name       = "keyvault-${var.deployment_id}"
        location   = var.location
        kind       = "V1"
        properties = {
          displayName = "Key Vault Connection"
          api = {
            id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Web/locations/${var.location}/managedApis/keyvault"
          }
          parameterValueType = "Alternative"
          alternativeParameterValues = {
            vaultName = var.secrets_key_vault_name
          }
        }
      }
    ]
  })
}

resource "azurerm_resource_group_template_deployment" "keyvault_connection_access" {
  name                = "keyvault-access-${var.deployment_id}"
  resource_group_name = var.resource_group_name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    resources = [
      {
        type       = "Microsoft.Web/connections/accessPolicies"
        apiVersion = "2016-06-01"
        name       = "keyvault-${var.deployment_id}/logic-app-access"
        location   = var.location
        properties = {
          principal = {
            type = "ActiveDirectory"
            identity = {
              tenantId = var.tenant_id
              objectId = var.logic_app_identity_principal_id
            }
          }
        }
      }
    ]
  })

  depends_on = [azurerm_resource_group_template_deployment.keyvault_connection]
}

resource "azurerm_logic_app_workflow" "function_app_syncer" {
  name                = "${local.workflow_prefix}-function-app-syncer-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  workflow_parameters = {
    "$connections" = jsonencode({
      defaultValue = {}
      type         = "Object"
    })
  }

  parameters = {
    "$connections" = jsonencode({
      keyvault = {
        connectionId   = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Web/connections/keyvault-${var.deployment_id}"
        connectionName = "keyvault-${var.deployment_id}"
        connectionProperties = {
          authentication = {
            type     = "ManagedServiceIdentity"
            identity = var.logic_app_identity_id
          }
        }
        id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Web/locations/${var.location}/managedApis/keyvault"
      }
    })
  }

  tags = var.tags

  depends_on = [azurerm_resource_group_template_deployment.keyvault_connection_access]
}

resource "azurerm_logic_app_trigger_recurrence" "function_app_syncer" {
  name         = "Recurrence"
  logic_app_id = azurerm_logic_app_workflow.function_app_syncer.id
  frequency    = "Hour"
  interval     = 1
}

resource "azurerm_logic_app_action_custom" "syncer_get_token" {
  name         = "GetQualysToken"
  logic_app_id = azurerm_logic_app_workflow.function_app_syncer.id

  body = jsonencode({
    type = "ApiConnection"
    inputs = {
      host = {
        connection = {
          name = "@parameters('$connections')['keyvault']['connectionId']"
        }
      }
      method = "get"
      path   = "/secrets/@{encodeURIComponent('${var.qualys_token_secret_name}')}/value"
    }
    runAfter = {}
  })
}

resource "azurerm_logic_app_action_custom" "syncer_download_zip" {
  name         = "DownloadFunctionAppZip"
  logic_app_id = azurerm_logic_app_workflow.function_app_syncer.id

  body = jsonencode({
    type = "Http"
    inputs = {
      method = "GET"
      uri    = "${var.qualys_endpoint}/qflow/snapshot/v2/azure-snapshot-scanner-${var.app_version}-functionapps.zip?format=binary&useCache=true"
      headers = {
        Authorization = "Bearer @{body('GetQualysToken')?['value']}"
      }
      retryPolicy = {
        type     = "fixed"
        count    = 3
        interval = "PT30S"
      }
    }
    runAfter = {
      GetQualysToken = ["Succeeded"]
    }
    limit = {
      timeout = "PT5M"
    }
  })

  depends_on = [azurerm_logic_app_action_custom.syncer_get_token]
}

resource "azurerm_logic_app_action_custom" "syncer_upload_blob" {
  name         = "UploadToBlob"
  logic_app_id = azurerm_logic_app_workflow.function_app_syncer.id

  body = jsonencode({
    type = "Http"
    inputs = {
      method = "PUT"
      uri    = "https://${var.storage_account_name}.blob.core.windows.net/${var.storage_container_name}/released-package.zip"
      headers = {
        "x-ms-blob-type" = "BlockBlob"
        "x-ms-version"   = "2020-10-02"
        "x-ms-date"      = "@{utcNow('R')}"
        "Content-Type"   = "application/octet-stream"
      }
      body = "@body('DownloadFunctionAppZip')"
      authentication = {
        type     = "ManagedServiceIdentity"
        identity = var.logic_app_identity_id
        audience = "https://storage.azure.com/"
      }
      retryPolicy = {
        type     = "fixed"
        count    = 3
        interval = "PT60S"
      }
    }
    runAfter = {
      DownloadFunctionAppZip = ["Succeeded"]
    }
    limit = {
      timeout = "PT5M"
    }
  })

  depends_on = [azurerm_logic_app_action_custom.syncer_download_zip]
}

resource "azurerm_logic_app_workflow" "register_service_account" {
  name                = "${local.workflow_prefix}-register-service-account-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  workflow_parameters = {
    "$connections" = jsonencode({
      defaultValue = {}
      type         = "Object"
    })
  }

  parameters = {
    "$connections" = jsonencode({
      keyvault = {
        connectionId   = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Web/connections/keyvault-${var.deployment_id}"
        connectionName = "keyvault-${var.deployment_id}"
        connectionProperties = {
          authentication = {
            type     = "ManagedServiceIdentity"
            identity = var.logic_app_identity_id
          }
        }
        id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Web/locations/${var.location}/managedApis/keyvault"
      }
    })
  }

  tags = var.tags

  depends_on = [azurerm_resource_group_template_deployment.keyvault_connection_access]
}

resource "azurerm_logic_app_trigger_http_request" "register_service_account" {
  name         = "manual"
  logic_app_id = azurerm_logic_app_workflow.register_service_account.id

  schema = jsonencode({
    type       = "object"
    properties = {}
  })
}

resource "azurerm_logic_app_action_custom" "register_get_token" {
  name         = "GetQualysToken"
  logic_app_id = azurerm_logic_app_workflow.register_service_account.id

  body = jsonencode({
    type = "ApiConnection"
    inputs = {
      host = {
        connection = {
          name = "@parameters('$connections')['keyvault']['connectionId']"
        }
      }
      method = "get"
      path   = "/secrets/@{encodeURIComponent('${var.qualys_token_secret_name}')}/value"
    }
    runAfter = {}
  })
}

resource "azurerm_logic_app_action_custom" "register_with_qualys" {
  name         = "RegisterWithQualys"
  logic_app_id = azurerm_logic_app_workflow.register_service_account.id

  body = jsonencode({
    type = "Http"
    inputs = {
      method = "POST"
      uri    = "${var.qualys_endpoint}/conn/snapshot/v1.0/azure/serviceaccount"
      headers = {
        Authorization  = "Bearer @{body('GetQualysToken')?['value']}"
        "Content-Type" = "application/json"
      }
      body = {
        subscriptionId    = var.subscription_id
        tenantId          = var.tenant_id
        managedIdentityId = var.scanner_identity_client_id
        resourceGroupName = var.resource_group_name
        deploymentId      = var.deployment_id
      }
      retryPolicy = {
        type     = "fixed"
        count    = 3
        interval = "PT30S"
      }
    }
    runAfter = {
      GetQualysToken = ["Succeeded"]
    }
  })

  depends_on = [azurerm_logic_app_action_custom.register_get_token]
}

resource "azurerm_logic_app_workflow" "deregister_service_account" {
  name                = "${local.workflow_prefix}-deregister-service-account-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  workflow_parameters = {
    "$connections" = jsonencode({
      defaultValue = {}
      type         = "Object"
    })
  }

  parameters = {
    "$connections" = jsonencode({
      keyvault = {
        connectionId   = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Web/connections/keyvault-${var.deployment_id}"
        connectionName = "keyvault-${var.deployment_id}"
        connectionProperties = {
          authentication = {
            type     = "ManagedServiceIdentity"
            identity = var.logic_app_identity_id
          }
        }
        id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Web/locations/${var.location}/managedApis/keyvault"
      }
    })
  }

  tags = var.tags

  depends_on = [azurerm_resource_group_template_deployment.keyvault_connection_access]
}

resource "azurerm_logic_app_workflow" "discover_resources" {
  name                = "${local.workflow_prefix}-discover-resources-v2-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "poll_based_discover" {
  name                = "${local.workflow_prefix}-poll-based-discover-vms-v2-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "event_based_discover" {
  count = var.event_based_discovery ? 1 : 0

  name                = "${local.workflow_prefix}-event-based-discover-vms-v2-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "create_snapshots" {
  name                = "${local.workflow_prefix}-create-snapshots-v2-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "create_disks" {
  name                = "${local.workflow_prefix}-create-disks-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "prepare_scanner" {
  name                = "${local.workflow_prefix}-prepare-scanner-machine-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "run_commands" {
  name                = "${local.workflow_prefix}-run-commands-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "concurrent_scanner" {
  name                = "${local.workflow_prefix}-concurrent-scanner-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "find_scan_candidates" {
  name                = "${local.workflow_prefix}-find-scan-candidates-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "delete_snapshots" {
  name                = "${local.workflow_prefix}-delete-snapshots-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "delete_disks" {
  name                = "${local.workflow_prefix}-delete-disks-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "delete_nics" {
  name                = "${local.workflow_prefix}-delete-nics-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "delete_public_ips" {
  name                = "${local.workflow_prefix}-delete-public-ips-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "delete_scanner_machines" {
  name                = "${local.workflow_prefix}-delete-scanner-machines-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "cleanup_resources" {
  name                = "${local.workflow_prefix}-cleanup-resources-v2-${var.deployment_id}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logic_app_identity_id]
  }

  tags = var.tags
}

output "function_app_syncer_name" {
  value = azurerm_logic_app_workflow.function_app_syncer.name
}

output "register_service_account_name" {
  value = azurerm_logic_app_workflow.register_service_account.name
}

output "workflow_names" {
  value = {
    function_app_syncer      = azurerm_logic_app_workflow.function_app_syncer.name
    register_service_account = azurerm_logic_app_workflow.register_service_account.name
    discover_resources       = azurerm_logic_app_workflow.discover_resources.name
    create_snapshots         = azurerm_logic_app_workflow.create_snapshots.name
    prepare_scanner          = azurerm_logic_app_workflow.prepare_scanner.name
    cleanup_resources        = azurerm_logic_app_workflow.cleanup_resources.name
  }
}
