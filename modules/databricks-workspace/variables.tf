variable "workspace_name" {
  description = "Name of the Azure Databricks workspace to create."
  type        = string
}

variable "resource_group_name" {
  description = "Existing Azure resource group where the workspace will be deployed."
  type        = string
}

variable "location" {
  description = "Azure region for the workspace (e.g. eastus2)."
  type        = string
}

variable "workspace_sku" {
  description = "Databricks workspace SKU (standard, premium, trial)."
  type        = string

  validation {
    condition     = contains(["standard", "premium", "trial"], lower(var.workspace_sku))
    error_message = "workspace_sku must be one of standard, premium, or trial (case-insensitive)."
  }
}

variable "managed_resource_group_name" {
  description = "Name of the managed resource group created by Databricks. Defaults to <workspace_name>-managed-rg when omitted."
  type        = string
  default     = null
}

variable "existing_application_object_id" {
  description = "Optional Azure AD application object ID to reuse instead of creating a new application."
  type        = string
  default     = ""
}

variable "service_principal_display_name" {
  description = "Display name of the Azure AD application/service principal used for Databricks automation."
  type        = string
}

variable "service_principal_secret_name" {
  description = "Name of the Key Vault secret that will store the generated service principal client secret."
  type        = string
}

variable "service_principal_secret_display_name" {
  description = "Display name assigned to the Azure AD application password credential."
  type        = string
  default     = "TerraformManagedSecret"
}

variable "service_principal_secret_validity_days" {
  description = "Number of days the generated service principal secret should remain valid."
  type        = number
  default     = 180

  validation {
    condition     = var.service_principal_secret_validity_days > 0
    error_message = "service_principal_secret_validity_days must be greater than zero."
  }
}

variable "service_principal_secret_content_type" {
  description = "Content type metadata to attach to the Key Vault secret."
  type        = string
  default     = "application/x-ms-application-id+secret"
}

variable "application_owner_object_ids" {
  description = "Optional list of Azure AD object IDs to set as owners on the application when it is created."
  type        = list(string)
  default     = []
}

variable "workspace_role_definition_name" {
  description = "Azure built-in role to assign to the service principal at the workspace scope."
  type        = string
  default     = "Contributor"
}

variable "key_vault_id" {
  description = "Resource ID of the Key Vault where the service principal secret will be stored."
  type        = string
}

variable "tags" {
  description = "Optional tags applied to the workspace and Key Vault secret."
  type        = map(string)
  default     = {}
}
