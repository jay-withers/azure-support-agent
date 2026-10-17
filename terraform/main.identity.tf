# One identity for this project, used by the container app to resolve its
# Key Vault-backed secrets (DATABASE-URL, SEED-ADMIN-PASSWORD).
#
# Per-project rather than one shared across the platform: identities are free,
# and this one can read the database credentials of an app that holds other
# tenants' service-principal secrets. A platform-wide identity would make them
# reachable from any future tenant's image.
#
# It is granted no Azure RBAC beyond its own vault. The agent's access to the
# subscriptions it investigates is configured inside the app (Settings → Azure
# connections), not through this identity.
resource "azurerm_user_assigned_identity" "this" {
  name                = module.naming.user_assigned_identity.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}
