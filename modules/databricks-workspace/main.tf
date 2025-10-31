terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"   # stays on v4.x
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"   # v3.x semantics
    }
  }
}

provider "azurerm" {
  features {}
}
provider "azuread" {}

# Current client
data "azurerm_client_config" "current" {}

# If the caller supplied an existing app object ID, read it; otherwise, skip.
data "azuread_application" "existing" {
  count     = var.existing_application_object_id != "" ? 1 : 0
  object_id = var.existing_application_object_id
}

# Create a new AAD application if we were not given one.
resource "azuread_application" "databricks" {
  count                   = var.existing_application_object_id == "" ? 1 : 0
  display_name            = var.service_principal_display_name
  owners                  = var.application_owner_object_ids
  prevent_duplicate_names = true
}

# Compute handles for "the application we will use"
locals {
  created_application   = try(azuread_application.databricks[0], null)
  existing_application  = try(data.azuread_application.existing[0], null)

  # v3: id = object ID; application_id = app (client) ID
  application_object_id = coalesce(
    try(local.created_application.id, null),
    try(local.existing_application.id, null)
  )
  application_client_id = coalesce(
    try(local.created_application.application_id, null),
    try(local.existing_application.application_id, null)
  )
}

# If we are reusing an app, try to read its service principal; otherwise we will create it
data "azuread_service_principal" "existing" {
  count          = var.existing_application_object_id != "" ? 1 : 0
  application_id = local.application_client_id
}

resource "azuread_service_principal" "databricks" {
  count = var.existing_application_object_id == "" ? 1 : 0

  # v3: still uses the application's client (app) ID
  application_id = local.application_client_id
}

locals {
  created_service_principal  = try(azuread_service_principal.databricks[0], null)
  existing_service_principal = try(data.azuread_service_principal.existing[0], null)

  service_principal_object_id = coalesce(
    try(local.created_service_principal.id, null),     # object ID
    try(local.existing_service_principal.id, null)
  )

  secret_duration_hours         = var.service_principal_secret_validity_days * 24
  managed_resource_group_name   = coalesce(var.managed_resource_group_name, format("%s-managed-rg", var.workspace_name))
  service_principal_secret_name = var.service_principal_secret_name
}

# v3: expects application_id = **object ID** of the application (not client ID)
resource "azuread_application_password" "databricks" {
  application_object_id = local.application_object_id
  display_name      = var.service_principal_secret_display_name
  end_date_relative = format("%dh", local.secret_duration_hours)
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
