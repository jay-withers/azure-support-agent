# The web application.
#
# Runs on the shared platform environment (see data.tf) but lives in this
# project's own resource group. That is allowed across resource groups but not
# across regions, which is why the resource group takes its location from the
# environment rather than from a variable of its own.
resource "azurerm_container_app" "this" {
  name                         = module.naming.container_app.name
  container_app_environment_id = data.azurerm_container_app_environment.platform.id
  resource_group_name          = azurerm_resource_group.this.name

  # No `location` argument: a container app inherits its environment's region.

  # Stated rather than left unset: on a workload-profiles environment Azure
  # assigns the app a profile regardless, and an unset argument then shows as
  # `"Consumption" -> null` drift on every plan.
  workload_profile_name = var.platform_workload_profile_name

  # Single, not Multiple. Background work is coordinated through database
  # leases, and two revisions answering at once would mean two schedulers.
  revision_mode = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  # Key Vault references, resolved by the platform when a revision starts —
  # the values are in neither this configuration nor state. Versionless ids, so
  # a rotated secret is picked up by the next revision or restart rather than
  # needing a Terraform change.
  secret {
    name                = "database-url"
    key_vault_secret_id = azurerm_key_vault_secret.database_url.versionless_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  secret {
    name                = "admin-password"
    key_vault_secret_id = azurerm_key_vault_secret.seed_admin_password.versionless_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  ingress {
    # Reachable from the internet. The app's own sign-in (local users, forced
    # password change on first login, optional OIDC/SAML) is what stands in
    # front of it, plus var.allowed_client_ip_ranges if set.
    external_enabled = true
    # Seed value only — see local.bootstrap_target_port and ignore_changes.
    target_port = local.bootstrap_target_port
    transport   = "auto"

    dynamic "ip_security_restriction" {
      for_each = var.allowed_client_ip_ranges
      content {
        name             = ip_security_restriction.value.name
        description      = ip_security_restriction.value.description
        ip_address_range = ip_security_restriction.value.ip_address_range
        action           = "Allow"
      }
    }

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # **Scale to zero, a deliberate trade.** At 1 vCPU / 2 GiB a standing replica
    # runs well past the monthly free grant, on a platform designed so nothing
    # bills while idle. What it costs:
    #   - the first request after idle waits for a cold start: a large image,
    #     then `alembic upgrade head`, then uvicorn;
    #   - the app's own background work — scheduled automations, monitors,
    #     War Room watches — does not run while there are no replicas. Nothing
    #     wakes it on a schedule; only an HTTP request does.
    # Raise min_replicas to 1 if those schedules start to matter.
    min_replicas = 0
    # One. Upstream supports more (database leases coordinate them), but each
    # replica brings its own connection pool to a B1ms server.
    max_replicas = 1

    container {
      name   = "azsupagent"
      image  = local.bootstrap_image
      cpu    = local.container_cpu
      memory = local.container_memory

      # **No `command` or `args`, deliberately.** The image's CMD runs migrations
      # and then uvicorn, and repeating it here would be a second source of
      # truth for a string upstream owns and Terraform cannot see change.
      # market-agent took a full outage in September 2026 from a stale `command`
      # under ignore_changes.

      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }

      env {
        name        = "SEED_ADMIN_PASSWORD"
        secret_name = "admin-password"
      }

      volume_mounts {
        name = "appdata"
        path = "/app/.data"
      }

      # **No explicit probes, deliberately.** Upstream's /healthz and /readyz on
      # 8000 don't exist in the quickstart image this app is created with, so
      # HTTP probes would fail the very first revision — and Terraform has no way
      # to set something on create only. With none declared, Container Apps
      # applies its default TCP probes on whatever the ingress port currently
      # is, which suits both images. The default startup probe allows ~240s,
      # enough for a cold start that runs `alembic upgrade head` first.
    }

    volume {
      name         = "appdata"
      storage_name = azurerm_container_app_environment_storage.appdata.name
      storage_type = "AzureFile"
    }
  }

  tags = local.tags

  # `make deploy` (az cli) owns the running image, env and ingress port after
  # the app is created: it swaps the quickstart placeholder for upstream's image
  # and moves the ingress from 80 to 8000. Ignoring them is what stops the next
  # apply from rolling the app back to the placeholder.
  #
  # The whole `env` list is ignored rather than individual entries, because
  # indexing into a map-driven `dynamic` block by position would silently shift
  # if common_env gained or lost a key. The trade-off: a change to any value in
  # common_env (a new custom domain changes PUBLIC_BASE_URL, for one) needs a
  # `make deploy` to land on a running revision — `terraform plan` will report
  # no diff even though the value it computes has moved.
  lifecycle {
    ignore_changes = [
      template[0].container[0].image,
      template[0].container[0].env,
      ingress[0].target_port,
    ]
  }

  # A secret reference that cannot be resolved fails the revision at start-up,
  # not the apply — so the identity's read access has to exist first.
  depends_on = [azurerm_role_assignment.identity_secrets_user]
}

# --- the custom domain --------------------------------------------------------
#
# Both resources are guarded by the same count on var.custom_domain_name. A
# hostname binds to exactly one container app globally, so an unconditional
# binding would make a second environment's plan claim the domain that dev
# already holds, the moment one ever exists.
#
# **The certificate is created in the *platform's* resource group, not this
# project's.** It is a child of the environment and takes its resource group
# from the environment's id, like the environment storage in main.storage.tf.
#
# **Both DNS records must resolve before apply.** Azure validates them during
# issuance and binding, not after: the CNAME for support.jaywithers.uk pointing
# at the app's default *.azurecontainerapps.io FQDN, and the TXT record at
# asuid.support carrying custom_domain_verification_id. `make dns` prints both
# with their values filled in.
resource "azurerm_container_app_environment_managed_certificate" "this" {
  count = var.custom_domain_name != "" ? 1 : 0

  name                         = replace(var.custom_domain_name, ".", "-")
  container_app_environment_id = data.azurerm_container_app_environment.platform.id
  subject_name                 = var.custom_domain_name
  domain_control_validation    = "CNAME"

  # Azure requires the hostname to already be registered on an app or route in
  # the environment before it will issue the managed certificate.
  depends_on = [azurerm_container_app_custom_domain.this]
}

resource "azurerm_container_app_custom_domain" "this" {
  count = var.custom_domain_name != "" ? 1 : 0

  name                     = var.custom_domain_name
  container_app_id         = azurerm_container_app.this.id
  certificate_binding_type = "Disabled"

  # container_app_environment_certificate_id is deliberately unset. That field
  # accepts a bring-your-own azurerm_container_app_environment_certificate
  # only; passing a *managed* certificate's id 400s the plan, because its id
  # carries a `managedCertificates` segment the provider's parser rejects
  # (hashicorp/terraform-provider-azurerm#25788).
  #
  # **The apply cannot finish the bind, and says nothing about it.** It reports
  # certificate_binding_type = "Disabled" with no error while
  # `az containerapp hostname list` still shows BindingType Disabled: ARM's
  # bind operation needs the certificate id in the request and the provider has
  # no field to put it in (hashicorp/terraform-provider-azurerm#27362, open).
  # Until it lands, `make bind-domain` is the manual step after any apply that
  # recreates either of these two resources. A plan afterwards reports no diff,
  # because the CLI sets the same binding type this resource already declares.
  #
  # gym-log, market-agent and finances hit and confirmed all of this first; the
  # workaround is the same in all of them.
}
