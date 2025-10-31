# Databricks Workspace Terraform Module

This module provisions an Azure Databricks workspace and ensures a reusable automation identity is available for Databricks/Terraform operations. It will:

- Reuse an existing Azure AD application/service principal if it already exists by display name, or create a new one if needed.
- Generate (or rotate) a client secret for the service principal with a configurable lifetime.
- Persist the secret in an existing Azure Key Vault.
- Deploy an `azurerm_databricks_workspace` with the requested SKU and tags.
- Assign the service principal a role (default: `Contributor`) scoped to the workspace resource.

## Prerequisites

- Terraform `>= 1.5.0`.
- Configured `azurerm` provider (with `features {}`) authenticated to the target subscription.
- Configured `azuread` provider authenticated to the same tenant.
- The identity executing Terraform must already have **Key Vault Secret Set** permission on the target Key Vault so the module can write the generated secret.
- The target resource group and Key Vault must already exist.

## Usage

```hcl
provider "azurerm" {
  features {}
}

provider "azuread" {}

module "databricks_workspace" {
  source = "../modules/databricks-workspace"

  workspace_name        = "adf-tf-dev"
  resource_group_name   = "adf-tf-rg"
  location              = "eastus2"
  workspace_sku         = "premium"
  key_vault_id          = "/subscriptions/910ebf13-1058-405d-b6cf-eda03e5288d1/resourceGroups/fabric-rg/providers/Microsoft.KeyVault/vaults/kvfabricprodeus2rh"

  service_principal_display_name = "adb-tf-dev-spn"
  service_principal_secret_name  = "adb-tf-dev-spn-secret"

  tags = {
    environment = "dev"
    workload    = "databricks"
  }
}
```

### Rotating the secret

Re-running the module rotates the service principal credential managed by Terraform. The Key Vault secret will be updated in place (with a new version) whenever the password resource changes.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `workspace_name` | string | n/a | Databricks workspace name. |
| `resource_group_name` | string | n/a | Resource group that will host the workspace. |
| `location` | string | n/a | Azure region for the workspace. |
| `workspace_sku` | string | n/a | Workspace SKU (`standard`, `premium`, or `trial`). |
| `managed_resource_group_name` | string | `null` | Custom managed resource group name; defaults to `<workspace_name>-managed-rg`. |
| `service_principal_display_name` | string | n/a | Display name for the automation service principal. Reused if it already exists. |
| `service_principal_secret_name` | string | n/a | Key Vault secret name that stores the generated client secret. |
| `service_principal_secret_display_name` | string | `"TerraformManagedSecret"` | Display name attached to the Azure AD password credential. |
| `service_principal_secret_validity_days` | number | `180` | Secret lifetime in days. |
| `service_principal_secret_content_type` | string | `"application/x-ms-application-id+secret"` | Content type metadata applied to the Key Vault secret. |
| `application_owner_object_ids` | list(string) | `[]` | Optional Azure AD object IDs to set as application owners (only used on create). |
| `workspace_role_definition_name` | string | `"Contributor"` | Workspace-scoped role assigned to the service principal. |
| `key_vault_id` | string | n/a | Resource ID of the Key Vault that will store the secret. |
| `tags` | map(string) | `{}` | Tags applied to the workspace and Key Vault secret. |

## Outputs

| Name | Description |
|------|-------------|
| `service_principal_client_id` | Azure AD application (client) ID. |
| `service_principal_object_id` | Azure AD object ID of the service principal. |
| `service_principal_tenant_id` | Azure AD tenant ID. |
| `service_principal_secret_value` | Generated client secret (sensitive). |
| `service_principal_secret_id` | Resource ID of the Key Vault secret. |
| `databricks_workspace_id` | Resource ID of the workspace. |
| `databricks_workspace_url` | Workspace URL endpoint. |
| `managed_resource_group_name` | Managed resource group name backing the workspace. |

## Notes

- If an application or service principal named `service_principal_display_name` already exists, it will be reused. If a service principal does not exist for that application, the module will create one.
- Ensure the named Key Vault allows the Terraform runner identity to write new secrets (via access policies or RBAC + Key Vault permissions).
- The generated secret is written to Key Vault and also returned as a sensitive output. Handle it with care or remove the output if that does not meet your security requirements.
