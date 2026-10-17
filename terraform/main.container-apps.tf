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
    target_port      = local.target_port
    transport        = "auto"

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
      image  = local.image
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

      # The startup probe carries the cold start — migrations included — so the
      # liveness probe never has to tolerate it: up to 10 × 10s before the
      # platform gives up on a new replica.
      startup_probe {
        transport               = "HTTP"
        port                    = local.target_port
        path                    = "/healthz"
        initial_delay           = 5
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 10
      }

      # **The probes are different on purpose.** Liveness decides whether to
      # restart the container, so it must not depend on the database — a
      # database blip would otherwise turn into a restart loop. /healthz answers
      # from memory; /readyz is the one that checks dependencies.
      liveness_probe {
        transport               = "HTTP"
        port                    = local.target_port
        path                    = "/healthz"
        interval_seconds        = 30
        timeout                 = 3
        failure_count_threshold = 3
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = local.target_port
        path                    = "/readyz"
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
        success_count_threshold = 1
      }
    }

    volume {
      name         = "appdata"
      storage_name = azurerm_container_app_environment_storage.appdata.name
      storage_type = "AzureFile"
    }
  }

  tags = local.tags

  # **No ignore_changes, unlike finances.** Terraform owns the image as well as
  # everything else: the version is var.image_digest in environments/<env>.tfvars,
  # bumped by Renovate, and `make apply` is the deploy. Nothing changes the
  # running app outside Terraform, so a plan is always the truth about what is
  # deployed — including env, so a new custom domain's PUBLIC_BASE_URL lands
  # with the same apply that binds it.

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
