variable "subscription_id" {
  description = "Azure Subscription ID for deploying scanner resources"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "Must be a valid GUID."
  }
}

variable "location" {
  description = "Primary Azure region for scanner resources"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-qualys-snapshot-scanner"
}

variable "target_subscription_ids" {
  description = "List of subscription IDs to scan"
  type        = list(string)
  default     = []
}

variable "target_locations" {
  description = "Azure regions where VMs should be discovered"
  type        = list(string)
  default     = ["eastus"]
}

variable "target_management_groups" {
  description = "Management group IDs for event-based scanning"
  type        = list(string)
  default     = []
}

variable "target_role_boundary" {
  description = "Scope for role assignments (subscription or management group path)"
  type        = string
  default     = ""
}

variable "qualys_api_endpoint" {
  description = "Qualys API Gateway URL (e.g., https://qualysapi.qualys.com)"
  type        = string

  validation {
    condition     = can(regex("^https://", var.qualys_api_endpoint))
    error_message = "Must start with https://"
  }
}

variable "qualys_subscription_token" {
  description = "Qualys subscription token. Pass via TF_VAR_qualys_subscription_token"
  type        = string
  sensitive   = true
}

variable "scan_interval_hours" {
  description = "Scan frequency in hours (24-720)"
  type        = number
  default     = 24

  validation {
    condition     = var.scan_interval_hours >= 24 && var.scan_interval_hours <= 720
    error_message = "Must be between 24 and 720."
  }
}

variable "poll_interval_hours" {
  description = "Polling frequency in hours (1-24)"
  type        = number
  default     = 4

  validation {
    condition     = var.poll_interval_hours >= 1 && var.poll_interval_hours <= 24
    error_message = "Must be between 1 and 24."
  }
}

variable "scanner_pause_interval_minutes" {
  description = "Pause between scans in minutes (5-720)"
  type        = number
  default     = 10

  validation {
    condition     = var.scanner_pause_interval_minutes >= 5 && var.scanner_pause_interval_minutes <= 720
    error_message = "Must be between 5 and 720."
  }
}

variable "location_concurrency" {
  description = "Number of locations to scan concurrently (1-25)"
  type        = number
  default     = 5

  validation {
    condition     = var.location_concurrency >= 1 && var.location_concurrency <= 25
    error_message = "Must be between 1 and 25."
  }
}

variable "scanners_per_location" {
  description = "Scanner VMs per location (1-30)"
  type        = number
  default     = 1

  validation {
    condition     = var.scanners_per_location >= 1 && var.scanners_per_location <= 30
    error_message = "Must be between 1 and 30."
  }
}

variable "event_based_discovery" {
  description = "Enable event-based discovery for ephemeral VMs"
  type        = bool
  default     = true
}

variable "scan_sampling_enabled" {
  description = "Enable scan sampling for VMSS"
  type        = bool
  default     = false
}

variable "sampling_percentage" {
  description = "Percentage of VMSS to scan (1-50)"
  type        = number
  default     = 10

  validation {
    condition     = var.sampling_percentage >= 1 && var.sampling_percentage <= 50
    error_message = "Must be between 1 and 50."
  }
}

variable "vm_must_have_tags" {
  description = "All tags must be present (format: key=value)"
  type        = list(string)
  default     = []
}

variable "vm_at_least_one_tag" {
  description = "At least one tag must be present"
  type        = list(string)
  default     = []
}

variable "vm_none_of_tags" {
  description = "VMs with these tags are excluded"
  type        = list(string)
  default     = []
}

variable "target_cloud" {
  description = "Azure cloud environment"
  type        = string
  default     = "AzureCloud"

  validation {
    condition     = contains(["AzureCloud", "AzureUSGovernment", "AzureChinaCloud"], var.target_cloud)
    error_message = "Must be AzureCloud, AzureUSGovernment, or AzureChinaCloud."
  }
}

variable "debug_enabled" {
  description = "Enable debug logging and Application Insights"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags to apply to all resources (merged with default Qualys tags)"
  type        = map(string)
  default     = {}
}

variable "app_version" {
  description = "Scanner application version"
  type        = string
  default     = "3.20.0"
}
