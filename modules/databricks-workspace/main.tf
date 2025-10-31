terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.104.0"
    }

    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.50.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

# Capture current client information (tenant ID is required for Databricks auth binding outputs)
data "azurerm_client_config" "current" {}

data "azuread_applications" "existing" {
  filter = format("displayName eq '%s'", replace(var.service_principal_display_name, "'", "''"))
}

data "azuread_service_principals" "existing" {
  filter = format("displayName eq '%s'", replace(var.service_principal_display_name, "'", "''"))
}

locals {
  existing_application          = try(data.azuread_applications.existing.applications[0], null)
  create_application            = local.existing_application == null
  created_application           = try(azuread_application.databricks[0], null)
  existing_service_principal    = try(data.azuread_service_principals.existing.service_principals[0], null)
  create_service_principal      = local.existing_service_principal == null
  created_service_principal     = try(azuread_service_principal.databricks[0], null)
  application_object_id         = coalesce(try(local.created_application.object_id, null), try(local.existing_application.object_id, null))
  application_client_id         = coalesce(try(local.created_application.application_id, null), try(local.existing_application.app_id, null))
  service_principal_object_id   = coalesce(try(local.created_service_principal.object_id, null), try(local.existing_service_principal.object_id, null))
  secret_duration_hours         = var.service_principal_secret_validity_days * 24
  managed_resource_group_name   = coalesce(var.managed_resource_group_name, format("%s-managed-rg", var.workspace_name))
  service_principal_secret_name = var.service_principal_secret_name
}

resource "azuread_application" "databricks" {
  count                = local.create_application ? 1 : 0
  display_name         = var.service_principal_display_name
  owners               = var.application_owner_object_ids
  prevent_duplicate_names = true
}

resource "azuread_service_principal" "databricks" {
  count = local.create_service_principal ? 1 : 0

  application_id = coalesce(
    try(local.created_application.application_id, null),
    try(local.existing_application.app_id, null)
  )
}

resource "azuread_application_password" "databricks" {
  application_object_id = local.application_object_id
  display_name          = var.service_principal_secret_display_name
  end_date_relative     = format("%dh", local.secret_duration_hours)
}

resource "azurerm_key_vault_secret" "databricks_spn" {
  name         = local.service_principal_secret_name
  value        = azuread_application_password.databricks.value
  key_vault_id = var.key_vault_id

  content_type = var.service_principal_secret_content_type
  tags         = var.tags
}

resource "azurerm_databricks_workspace" "this" {
  name                        = var.workspace_name
  location                    = var.location
  resource_group_name         = var.resource_group_name
  sku                         = var.workspace_sku
  managed_resource_group_name = local.managed_resource_group_name
  tags                        = var.tags
}

resource "azurerm_role_assignment" "workspace_contributor" {
  scope                = azurerm_databricks_workspace.this.id
  role_definition_name = var.workspace_role_definition_name
  principal_id         = local.service_principal_object_id
}
