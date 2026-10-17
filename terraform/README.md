# Terraform

The infrastructure for a self-hosted
[Azure Support Agent](https://github.com/zmustafa/AzureSupportAgent): everything
this project owns, and nothing it shares. The Container Apps environment it runs
on lives in `jay-withers/azure-container-apps` and is looked up by name
(`data.tf`), not through its state.

## What it creates

In this project's resource group (`rg-supportagent-<env>`, in the shared
environment's region):

- the container app: upstream's image at the digest in `environments/<env>.tfvars`
  (see [Deploying images](#deploying-images)), 1 vCPU / 2 GiB, scale to zero,
  max one replica
- a user-assigned identity, used only to resolve its Key Vault secrets
- a Key Vault holding `DATABASE-URL` and `SEED-ADMIN-PASSWORD`
- a PostgreSQL Flexible Server (B1ms, password auth) and its `azsup` database,
  in `var.postgres_location` (`northeurope`, because PostgreSQL is blocked in
  westeurope on this subscription)
- a storage account with the `appdata` Azure Files share mounted at `/app/.data`

In the **platform's** resource group, because they are children of the
environment: the `<project>-appdata` environment storage and, if a custom domain
is set, the managed certificate.

## Secrets

No secret value is in source, and the two passwords are not in state either.
They come from `ephemeral "random_password"` resources and reach Azure only
through write-only arguments (`administrator_password_wo`, `value_wo`). To
rotate them, bump `secrets_version`, run `make apply`, then `make restart`.
Key Vault references are resolved when a replica starts, so the running one
keeps the old password until it restarts.

The storage account key **is** in state, because `azurerm_container_app_environment_storage`
has no write-only variant. Azure Files mounts in Container Apps authenticate
with the account key only.

## First apply

1. Create the state container once:
   `az storage container create --account-name sttfsharedjw --name azure-support-agent --auth-mode login`
2. With `custom_domain_name` commented out in `environments/dev.tfvars`, run
   `make apply`. A 403 on a Key Vault secret means the deployer's new role
   assignment hasn't propagated yet: re-run the apply.
3. `make dns` prints the CNAME and `asuid` TXT records. Create both at the DNS
   provider and wait until they resolve.
4. Restore `custom_domain_name`, run `make apply` to issue the certificate, then
   `make bind-domain`.
5. `make url`, then sign in as `admin` with `make admin-password`. The app forces
   a password change.
6. In the app, configure an AI provider and an Azure connection (a service
   principal) under **Settings**. Terraform grants the app no Azure RBAC.

## Deploying images

The running version is controlled from this repository. `image_digest` in
`environments/<env>.tfvars` pins upstream's image, and Terraform owns it along
with the app's env, port and probes. There's no `ignore_changes`, so a plan
always shows what is actually deployed.

Upstream publishes only moving tags (`latest`, `v1`), so builds are named by
digest. To upgrade:

1. Renovate opens a PR bumping `image_digest` when upstream's `v1` tag moves.
   To bump by hand instead, `make digest` prints the current one.
2. Merge it, then run `make apply`.

Rolling back is the same thing with an older digest.

## Cost

Roughly £13/month, nearly all of it the PostgreSQL server, which has no
auto-pause tier. The app bills only while a replica is running.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 5.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.7 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 5.10.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_naming"></a> [naming](#module\_naming) | Azure/naming/azurerm | ~> 0.4 |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_container_app.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_app) | resource |
| [azurerm_container_app_custom_domain.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_app_custom_domain) | resource |
| [azurerm_container_app_environment_managed_certificate.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_app_environment_managed_certificate) | resource |
| [azurerm_container_app_environment_storage.appdata](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_app_environment_storage) | resource |
| [azurerm_key_vault.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_key_vault_secret.database_url](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_secret) | resource |
| [azurerm_key_vault_secret.seed_admin_password](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_secret) | resource |
| [azurerm_postgresql_flexible_server.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server) | resource |
| [azurerm_postgresql_flexible_server_database.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_database) | resource |
| [azurerm_postgresql_flexible_server_firewall_rule.allow_azure_services](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_firewall_rule) | resource |
| [azurerm_resource_group.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.deployer_secrets_officer](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.identity_secrets_user](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.appdata](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_share.appdata](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_share) | resource |
| [azurerm_user_assigned_identity.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_container_app_environment.platform](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/container_app_environment) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_admin_username"></a> [admin\_username](#input\_admin\_username) | Username of the local admin account seeded on first boot. Its password is generated into Key Vault (`make admin-password`), and the app forces a change on first sign-in. | `string` | `"admin"` | no |
| <a name="input_allowed_client_ip_ranges"></a> [allowed\_client\_ip\_ranges](#input\_allowed\_client\_ip\_ranges) | Client IP ranges (CIDR) allowed to reach the app, enforced at the Container Apps ingress before any request reaches the container. Empty allows the whole internet, leaving the app's own sign-in and in-app allowlist in front of it. An Allow list that omits your own address makes the app unreachable from your browser, not from Azure: `az containerapp ingress access-restriction remove` recovers. | <pre>list(object({<br/>    name             = string<br/>    ip_address_range = string<br/>    description      = optional(string, "")<br/>  }))</pre> | `[]` | no |
| <a name="input_custom_domain_name"></a> [custom\_domain\_name](#input\_custom\_domain\_name) | Hostname to bind to the app with a free Azure-managed certificate, e.g. `support.jaywithers.uk`. Empty creates neither the certificate nor the binding; the default `*.azurecontainerapps.io` URL always works either way. The CNAME (to that default FQDN) and the `asuid.<label>` TXT record (holding `custom_domain_verification_id`) must already resolve before apply, because Azure validates both during issuance — `make dns` prints them. | `string` | `""` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment. Drives resource naming, and selects which shared platform environment this project deploys onto. | `string` | n/a | yes |
| <a name="input_image_digest"></a> [image\_digest](#input\_image\_digest) | Digest of upstream's `docker.io/zmustafa/azure-support-agent` image to run. Upstream publishes only moving tags (`latest`, `v1`), so the version is pinned by digest. Renovate opens a PR bumping this when upstream's `v1` moves; merging it and running `make apply` is the deploy. | `string` | n/a | yes |
| <a name="input_key_vault_administrator_object_ids"></a> [key\_vault\_administrator\_object\_ids](#input\_key\_vault\_administrator\_object\_ids) | Extra Entra object IDs granted Key Vault Secrets Officer, so they can read the seeded admin password. Whoever runs `terraform apply` is always included, so this is only for a second person or a second machine. | `list(string)` | `[]` | no |
| <a name="input_platform_environment_name"></a> [platform\_environment\_name](#input\_platform\_environment\_name) | Name of the shared Container Apps environment this app runs on. | `string` | `"cae-platform-dev"` | no |
| <a name="input_platform_resource_group_name"></a> [platform\_resource\_group\_name](#input\_platform\_resource\_group\_name) | Resource group holding the shared Container Apps environment. | `string` | `"rg-platform-dev"` | no |
| <a name="input_platform_workload_profile_name"></a> [platform\_workload\_profile\_name](#input\_platform\_workload\_profile\_name) | Workload profile on the shared environment the app runs on. The platform is a workload-profiles environment, so Azure assigns every app a profile whether or not one is named; leaving this unset makes every plan try to clear the `Consumption` Azure filled in. | `string` | `"Consumption"` | no |
| <a name="input_postgres_location"></a> [postgres\_location](#input\_postgres\_location) | Region the PostgreSQL Flexible Server is created in. Independent of the app's region, which is fixed by the shared environment. | `string` | `"northeurope"` | no |
| <a name="input_postgres_sku_name"></a> [postgres\_sku\_name](#input\_postgres\_sku\_name) | Compute SKU. Burstable B1ms is the smallest Flexible Server offers; there is no serverless or auto-pause tier, so this bills per hour for as long as the server exists. | `string` | `"B_Standard_B1ms"` | no |
| <a name="input_postgres_version"></a> [postgres\_version](#input\_postgres\_version) | Major PostgreSQL version. Upstream's own deployment template runs 16. | `string` | `"16"` | no |
| <a name="input_postgres_zone"></a> [postgres\_zone](#input\_postgres\_zone) | Availability zone the server is placed in. northeurope offers 1, 2 and 3 for B1ms. | `string` | `"1"` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Short name for this project, used by the naming module for every resource. | `string` | `"supportagent"` | no |
| <a name="input_secrets_version"></a> [secrets\_version](#input\_secrets\_version) | Bump to rotate the PostgreSQL admin password, and the DATABASE-URL and SEED-ADMIN-PASSWORD secrets derived from it. The values are write-only and never stored in state, so Terraform cannot see them change — this number is how it knows to resend them. After bumping and applying, `make restart` so the running revision picks up the new DATABASE-URL. | `number` | `1` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags merged over the defaults in locals.tf. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_app_url"></a> [app\_url](#output\_app\_url) | The application's stable default HTTPS URL. With a custom domain set, sign in through custom\_domain\_url instead: the app's CSRF origin check accepts only one origin. |
| <a name="output_container_app_name"></a> [container\_app\_name](#output\_container\_app\_name) | Name of the container app, for `make logs` and `make restart`. |
| <a name="output_custom_domain_url"></a> [custom\_domain\_url](#output\_custom\_domain\_url) | The bound custom domain, if var.custom\_domain\_name is set. Empty otherwise. |
| <a name="output_custom_domain_verification_id"></a> [custom\_domain\_verification\_id](#output\_custom\_domain\_verification\_id) | Domain verification ID, published as the `asuid.<label>` TXT record before apply. |
| <a name="output_key_vault_name"></a> [key\_vault\_name](#output\_key\_vault\_name) | Key Vault name, for reading SEED-ADMIN-PASSWORD — see `make admin-password`. |
| <a name="output_postgres_fqdn"></a> [postgres\_fqdn](#output\_postgres\_fqdn) | Hostname of the PostgreSQL Flexible Server, for a psql session (which needs a firewall rule for your address, added by hand). |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | This project's resource group. |
<!-- END_TF_DOCS -->
