variable "project_name" {
  description = "Short name for this project, used by the naming module for every resource."
  type        = string
  default     = "supportagent"

  validation {
    # Lowercase only (container apps reject uppercase), and short enough that
    # names stay inside the naming module's limits — it truncates silently
    # rather than failing. Changing this is also how to resolve a clash on the
    # globally unique Key Vault, storage account or PostgreSQL server name.
    condition     = can(regex("^[a-z][a-z0-9]{1,14}$", var.project_name))
    error_message = "project_name must be 2-15 lowercase alphanumerics starting with a letter."
  }
}

variable "tags" {
  description = "Tags merged over the defaults in locals.tf."
  type        = map(string)
  default     = {}
}

variable "key_vault_administrator_object_ids" {
  description = "Extra Entra object IDs granted Key Vault Secrets Officer, so they can read the seeded admin password. Whoever runs `terraform apply` is always included, so this is only for a second person or a second machine."
  type        = list(string)
  default     = []
}

# --- the shared platform ------------------------------------------------------
#
# Resolved by name rather than from the platform's Terraform state. These
# defaults match jay-withers/azure-container-apps at its own defaults; run
# `make outputs` there to confirm.

variable "platform_resource_group_name" {
  description = "Resource group holding the shared Container Apps environment."
  type        = string
  default     = "rg-platform-dev"
}

variable "platform_environment_name" {
  description = "Name of the shared Container Apps environment this app runs on."
  type        = string
  default     = "cae-platform-dev"
}

variable "platform_workload_profile_name" {
  description = "Workload profile on the shared environment the app runs on. The platform is a workload-profiles environment, so Azure assigns every app a profile whether or not one is named; leaving this unset makes every plan try to clear the `Consumption` Azure filled in."
  type        = string
  default     = "Consumption"
}

# --- the database -------------------------------------------------------------

variable "postgres_location" {
  # Constrained from two directions, per market-agent's main.database.tf: the
  # `allowed-locations-dev` policy denies anything outside westeurope and
  # northeurope, and this subscription is blocked from provisioning PostgreSQL
  # in westeurope. A database in a different region from the app is allowed;
  # only the app has to match its environment.
  description = "Region the PostgreSQL Flexible Server is created in. Independent of the app's region, which is fixed by the shared environment."
  type        = string
  default     = "northeurope"
}

variable "postgres_sku_name" {
  description = "Compute SKU. Burstable B1ms is the smallest Flexible Server offers; there is no serverless or auto-pause tier, so this bills per hour for as long as the server exists."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_version" {
  description = "Major PostgreSQL version. Upstream's own deployment template runs 16."
  type        = string
  default     = "16"
}

variable "postgres_zone" {
  description = "Availability zone the server is placed in. northeurope offers 1, 2 and 3 for B1ms."
  type        = string
  default     = "1"
}

variable "secrets_version" {
  description = "Bump to rotate the PostgreSQL admin password, and the DATABASE-URL and SEED-ADMIN-PASSWORD secrets derived from it. The values are write-only and never stored in state, so Terraform cannot see them change — this number is how it knows to resend them. After bumping and applying, `make restart` so the running revision picks up the new DATABASE-URL."
  type        = number
  default     = 1
}

# --- the app ------------------------------------------------------------------

variable "admin_username" {
  description = "Username of the local admin account seeded on first boot. Its password is generated into Key Vault (`make admin-password`), and the app forces a change on first sign-in."
  type        = string
  default     = "admin"
}

variable "allowed_client_ip_ranges" {
  description = "Client IP ranges (CIDR) allowed to reach the app, enforced at the Container Apps ingress before any request reaches the container. Empty allows the whole internet, leaving the app's own sign-in and in-app allowlist in front of it. An Allow list that omits your own address makes the app unreachable from your browser, not from Azure: `az containerapp ingress access-restriction remove` recovers."
  type = list(object({
    name             = string
    ip_address_range = string
    description      = optional(string, "")
  }))
  default = []
}

# --- the custom domain --------------------------------------------------------

variable "custom_domain_name" {
  description = "Hostname to bind to the app with a free Azure-managed certificate, e.g. `support.jaywithers.uk`. Empty creates neither the certificate nor the binding; the default `*.azurecontainerapps.io` URL always works either way. The CNAME (to that default FQDN) and the `asuid.<label>` TXT record (holding `custom_domain_verification_id`) must already resolve before apply, because Azure validates both during issuance — `make dns` prints them."
  type        = string
  default     = ""

  validation {
    # An apex domain cannot be a CNAME, and CNAME is the only validation method
    # these resources use. Caught here rather than as an opaque DNS failure
    # midway through certificate issuance.
    condition     = var.custom_domain_name == "" || length(split(".", var.custom_domain_name)) > 2
    error_message = "custom_domain_name must be a subdomain, not an apex domain: validation is by CNAME, which an apex record cannot hold."
  }
}
