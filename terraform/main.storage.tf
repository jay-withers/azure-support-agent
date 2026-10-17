# The Azure Files share mounted at /app/.data.
#
# Not optional, even with PostgreSQL holding the relational data. The app keeps
# its JSON registries there, and — because SECRETS_ENCRYPTION_KEY is left unset —
# the Fernet key it generates on first boot to encrypt every Azure connection's
# service-principal secret. On the container's own disk that key would vanish
# at the next scale-to-zero, and every saved connection with it.
resource "azurerm_storage_account" "appdata" {
  # **`prevent_destroy` is set**, for the encryption key above: losing it makes
  # every stored connection credential in the database undecryptable.
  #
  # checkov:skip=CKV_AZURE_206: LRS on purpose. The share holds a key file and small
  #   registries; share soft-delete covers the realistic risk of an accidental delete.
  # checkov:skip=CKV_AZURE_59: public network access stays enabled — a scale-to-zero
  #   container app on a Consumption-only shared environment has neither a VNet to
  #   peer nor a static egress IP to allow.
  # checkov:skip=CKV_AZURE_33: no queues are used, so queue logging has nothing
  #   to log.
  # checkov:skip=CKV_AZURE_35: default network action Allow, for the same reason as
  #   CKV_AZURE_59.
  # checkov:skip=CKV_AZURE_190: no blob containers exist in this account at all.
  # checkov:skip=CKV2_AZURE_1: platform-managed keys. A CMK needs a Key Vault key,
  #   rotation and an identity grant, to protect one key file and some JSON.
  # checkov:skip=CKV2_AZURE_33: no private endpoint, as above.
  # checkov:skip=CKV2_AZURE_38: soft delete is configured on the share below, which
  #   is the only data this account holds.
  # checkov:skip=CKV2_AZURE_40: shared key access is required — see below.
  # checkov:skip=CKV2_AZURE_41: no SAS is ever issued from this account.
  # checkov:skip=CKV2_AZURE_47: no blob containers, as CKV_AZURE_190.
  # `.name_unique`, not `.name`: storage account names are globally unique
  # across every Azure tenant.
  name                = module.naming.storage_account.name_unique
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  account_tier             = "Standard"
  account_kind             = "StorageV2"
  account_replication_type = "LRS"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Enabled"

  # **On, unlike finances' state account, and not by choice.** Container Apps
  # mounts Azure Files over SMB with the account key — there is no managed
  # identity option for an environment storage mount — so shared keys cannot be
  # turned off here. The key is held by the environment storage below.
  shared_access_key_enabled = true

  share_properties {
    retention_policy {
      days = 30
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy
resource "azurerm_storage_share" "appdata" {
  # The share itself carries no `prevent_destroy`: the account above already
  # blocks the destroy, and share soft-delete covers the rest.
  name               = "appdata"
  storage_account_id = azurerm_storage_account.appdata.id
  # GiB. The contents are a key file and JSON measured in kilobytes; quota is a
  # cap, not a charge, on a standard account.
  quota = 5
}

# **Registered on the *platform's* environment, not in this project's resource
# group.** Like a managed certificate, an environment storage is a child of the
# environment, so this is one of the resources here that lands in the platform's
# resource group — the apply identity needs write access there, which being
# subscription-scoped it has.
#
# The name is project-prefixed because environment storages share one namespace
# across every tenant on the platform.
#
# The account key is an argument here, so it **is** in state — unlike the two
# passwords. There is no write-only variant of this argument; the state
# container's RBAC is what protects it.
resource "azurerm_container_app_environment_storage" "appdata" {
  name                         = "${var.project_name}-appdata"
  container_app_environment_id = data.azurerm_container_app_environment.platform.id
  account_name                 = azurerm_storage_account.appdata.name
  share_name                   = azurerm_storage_share.appdata.name
  access_key                   = azurerm_storage_account.appdata.primary_access_key
  access_mode                  = "ReadWrite"
}
