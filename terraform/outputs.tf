output "resource_group_name" {
  description = "This project's resource group."
  value       = azurerm_resource_group.this.name
}

# Taken from the ingress block rather than `latest_revision_fqdn`, which changes
# with every revision and so is the wrong thing to bookmark.
output "app_url" {
  description = "The application's stable default HTTPS URL. With a custom domain set, sign in through custom_domain_url instead: the app's CSRF origin check accepts only one origin."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "container_app_name" {
  description = "Name of the container app, for `make logs` and `make restart`."
  value       = azurerm_container_app.this.name
}

output "key_vault_name" {
  description = "Key Vault name, for reading SEED-ADMIN-PASSWORD — see `make admin-password`."
  value       = azurerm_key_vault.this.name
}

output "postgres_fqdn" {
  description = "Hostname of the PostgreSQL Flexible Server, for a psql session (which needs a firewall rule for your address, added by hand)."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

# --- the custom domain --------------------------------------------------------
#
# Both are empty when var.custom_domain_name is unset, so `make url` falls back
# to app_url and `make dns` prints nothing to do.

output "custom_domain_url" {
  description = "The bound custom domain, if var.custom_domain_name is set. Empty otherwise."
  value       = var.custom_domain_name != "" ? "https://${var.custom_domain_name}" : ""
}

# The value of the asuid.<label> TXT record. Azure checks it during binding to
# prove the domain is ours, and it is stable for the life of the app.
output "custom_domain_verification_id" {
  description = "Domain verification ID, published as the `asuid.<label>` TXT record before apply."
  value       = azurerm_container_app.this.custom_domain_verification_id
  sensitive   = true
}
