output "service_principal_client_id" {
  description = "Client (application) ID of the Databricks automation service principal."
  value       = local.application_client_id
}

output "service_principal_object_id" {
  description = "Object ID of the Databricks automation service principal."
  value       = local.service_principal_object_id
}

output "service_principal_tenant_id" {
  description = "Azure AD tenant ID associated with the service principal."
  value       = data.azurerm_client_config.current.tenant_id
}

output "service_principal_secret_value" {
  description = "Client secret value generated for the service principal."
  value       = azuread_application_password.databricks.value
  sensitive   = true
}

output "service_principal_secret_id" {
  description = "Resource ID of the Key Vault secret storing the service principal credential."
  value       = azurerm_key_vault_secret.databricks_spn.id
}

output "databricks_workspace_id" {
  description = "Resource ID of the Databricks workspace."
  value       = azurerm_databricks_workspace.this.id
}

output "databricks_workspace_url" {
  description = "Workspace URL endpoint for Databricks."
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "managed_resource_group_name" {
  description = "Name of the managed resource group backing the Databricks workspace."
  value       = local.managed_resource_group_name
}
