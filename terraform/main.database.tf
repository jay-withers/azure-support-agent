# PostgreSQL Flexible Server, dedicated to this app.
#
# **Password auth, and why it can't be Entra-only like market-agent's.** The app
# builds its SQLAlchemy engine from one static DATABASE_URL
# (backend/app/core/db.py upstream) and has no hook to fetch a fresh Entra token
# per connection — and alembic, which runs on every boot, opens its own
# connection the same way. A token pasted into the URL would work for an hour.
# So this server takes a password, and sharing market-agent's Entra-only server
# was ruled out rather than loosening that server's posture for a neighbour.
#
# The password never reaches state: it is ephemeral (main.key-vault.tf) and set
# through `administrator_password_wo`.
#
# The cost is real: Flexible Server has no serverless or auto-pause tier, so
# this bills its SKU per hour for as long as it exists — roughly £13/month on
# B1ms, which is nearly the whole bill for this project while the scale-to-zero
# app is idle.
resource "azurerm_postgresql_flexible_server" "this" {
  # checkov:skip=CKV_AZURE_136: geo-redundant backup doubles backup storage cost and
  #   cannot be changed after creation — see geo_redundant_backup_enabled below.
  # checkov:skip=CKV2_AZURE_57: no private endpoint. It is a standing cost and there's no
  #   VNet to attach it to — the Container Apps environment is Consumption-only.
  #   Access is the generated password plus TLS, behind the firewall rule below.
  name                = module.naming.postgresql_server.name_unique
  resource_group_name = azurerm_resource_group.this.name
  location            = var.postgres_location
  version             = var.postgres_version

  sku_name = var.postgres_sku_name

  # Storage can never be reduced, only grown, and it bills the provisioned
  # figure rather than bytes used. auto_grow_enabled is therefore off on
  # purpose: left on, a runaway table silently and permanently raises the floor.
  storage_mb        = 32768
  storage_tier      = "P4"
  auto_grow_enabled = false

  # Seven days is the minimum. Geo-redundant backup is a second copy at extra
  # cost and is immutable after creation, so it is set explicitly rather than
  # left to the provider default.
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  # No high_availability block: a standby replica doubles the compute bill to
  # buy availability a single-user tool doesn't need.

  public_network_access_enabled = true

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  administrator_login               = local.postgres_admin_login
  administrator_password_wo         = ephemeral.random_password.postgres_admin.result
  administrator_password_wo_version = var.secrets_version

  zone = var.postgres_zone

  tags = local.tags

  lifecycle {
    # Chat history, audit log, assessments and scheduled tasks live here and
    # exist nowhere else. Destroying the rest of this stack should not take
    # them with it: `terraform destroy` fails until this is removed by hand.
    prevent_destroy = true

    # Azure fills this in itself when omitted, and reports values that differ
    # from an empty config on the next plan.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  # Upstream's name. alembic creates every table inside it on first boot.
  name      = "azsup"
  server_id = azurerm_postgresql_flexible_server.this.id

  # UTF8 with a deterministic sort order. Both force replacement of the
  # database if changed.
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

# 0.0.0.0-0.0.0.0 is Azure's sentinel for "allow other Azure services", which is
# what lets the container app reach the database without a VNet. Despite the
# name it is not scoped to this subscription or tenant — any Azure resource
# anywhere can open a connection. There is no narrower rule to write: a
# Consumption environment egresses from addresses that are not stable. It does
# not cover developer machines either; add a rule by hand for a psql session.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  # checkov:skip=CKV2_AZURE_26: the sentinel described above grants reachability, not
  #   access: a connection still needs the generated password, over TLS.
  name             = "AllowAllAzureIps"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
