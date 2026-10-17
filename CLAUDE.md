# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Runs a self-hosted copy of
[zmustafa/AzureSupportAgent](https://github.com/zmustafa/AzureSupportAgent) on
the shared Azure Container Apps environment owned by
`jay-withers/azure-container-apps`. There is no application code here: the
container runs upstream's Docker Hub image
(`docker.io/zmustafa/azure-support-agent`), **deployed by digest** with
`make deploy` because upstream publishes only moving tags (`latest`, `v1`). The repo is a Terraform root config
modelled on `jay-withers/finances` (same shared-platform lookup, deploy flow,
custom-domain workaround), plus the template's dev container, pre-commit hooks,
CI and Renovate.

## Dev container

The repo is built around the dev container at `.devcontainer/devcontainer.json`,
which uses the image `ghcr.io/jay-withers/dev-container/terraform`. It provides
Terraform, TFLint, terraform-docs, and Checkov, and runs `make install` on
creation. Prefer working inside the container so tool versions match CI.

## Terraform layout

`terraform/` is a **root config**, not a module. It has a partial `backend "azurerm" {}`
(values in `terraform/backends/<env>.hcl`), its own `provider "azurerm"` in
`versions.tf`, and a committed `.terraform.lock.hcl`. Only `dev` exists
(`environments/dev.tfvars`, `backends/dev.hcl`), because the shared environment
is resolved by name in `data.tf`: a plan against an environment the platform
hasn't been applied to fails at the data source. CI therefore validates only;
`make plan`/`make apply` need real Azure credentials. The Terraform version is
pinned in `.terraform-version` at the repo root and must be ≥ 1.11 for
write-only arguments and ephemeral resources.

Files are split by concern: `main.tf` (naming + RG), `main.container-apps.tf`,
`main.database.tf`, `main.storage.tf`, `main.key-vault.tf`,
`main.identity.tf`, `locals.container-apps.tf`, `locals.database.tf`,
`variables.required.tf`/`variables.optional.tf`, `data.tf`, `outputs.tf`.

Key design points, each explained in comments at the relevant resource:

- **Region:** the RG takes the shared environment's region (an app can't sit in a
  different region from its environment). The PostgreSQL server is the exception:
  it uses `var.postgres_location` (default `northeurope`), because this
  subscription blocks PostgreSQL in westeurope (see market-agent).
- **Database is password auth, dedicated.** Upstream builds its engine from a
  static `DATABASE_URL` with no Entra token hook, so it can't use market-agent's
  Entra-only server. The passwords (Postgres admin, seeded app admin) are
  `ephemeral "random_password"` values that flow only into write-only arguments
  (`administrator_password_wo`, `azurerm_key_vault_secret.value_wo`), so they
  are **never in state**. `var.secrets_version` drives every `*_wo_version`;
  bump it to rotate, then `make restart`.
- **Secrets reach the app as Key Vault references** (`secret { key_vault_secret_id, identity }`),
  so `DATABASE-URL`/`SEED-ADMIN-PASSWORD` must exist before the app. That's why
  Terraform writes them, unlike finances, where secrets are set by hand.
- **Azure Files at `/app/.data` is required.** It holds the app's generated
  Fernet key (which encrypts stored connection credentials) and JSON registries.
  The `azurerm_container_app_environment_storage` is a child of the
  **platform's** environment, so it lands in the platform RG (as the managed
  certificate does), and its account key is in state (no write-only variant).
- **Scale to zero** (min 0, max 1, 1 vCPU / 2 GiB). The app's in-process
  schedulers don't run while it's scaled down; that's an accepted trade-off.
- **Terraform never deploys the real image.** It creates the app on Microsoft's
  placeholder `mcr.microsoft.com/k8se/quickstart:latest` with the ingress on
  port 80 (the placeholder's port), and `ignore_changes` covers the container's
  image and env plus `ingress[0].target_port`. `make deploy IMAGE_DIGEST=...`
  (az CLI) moves the ingress to 8000 first, then swaps in upstream's image and
  pushes `PUBLIC_BASE_URL`/`FRONTEND_ORIGIN`. So after a fresh apply the app
  serves the placeholder until the first `make deploy`. No `command`/`args` are
  set, so the image's CMD stays the only source of truth.
- **No explicit probes.** Upstream's `/healthz`/`/readyz` on 8000 would fail
  the placeholder's first revision, and Terraform can't set anything on create
  only. Container Apps' default TCP probes on the current ingress port suit both
  images. Don't add HTTP probes back without solving that.
- **Custom domain** (`support.jaywithers.uk`): same CNAME/asuid flow and
  `make bind-domain` workaround as finances (azurerm#25788, #27362).
- `prevent_destroy` is set on the PostgreSQL server/database and the storage
  account. `terraform/.tflint.hcl` excludes only `azurerm_key_vault` and
  `azurerm_key_vault_secret` from `azurerm_resources_missing_prevent_destroy`,
  since both secrets are regenerable.

The `README.md` in `terraform/` is generated by terraform-docs between the
`BEGIN_TF_DOCS` / `END_TF_DOCS` markers; do not hand-edit those blocks. The
prose above them (first-apply runbook, secrets, deploy flow) is hand-written.

**File layout is enforced, not just conventional**:
`locals`/`variable`/`output`/`data` blocks must live in a matching
`locals.tf`/`variables.tf`/`outputs.tf`/`data.tf`, and `terraform{}`/`provider{}`
blocks in `versions.tf`, or a topic-scoped variant of any of them (e.g.
`locals.container-apps.tf`, `variables.optional.tf`), via the local pre-commit
hook `scripts/check-tf-standards.sh`. TFLint's
`terraform_standard_module_structure` rule is left disabled in favour of it.
The canonical copy of that script lives in the template repo; `terraform-root-aks`,
`azure-landingzone` and `github-repos` carry verbatim copies, so don't let this
one diverge.

`terraform/environments/dev.tfvars` is committed intentionally. Don't put
secrets in it (`gitleaks` scans as a backstop).

## Commands

`make` with no target prints the self-documenting help (the default goal).

```bash
make install           # install pre-commit hooks (run once after cloning)
make lint              # run all pre-commit hooks against every file
make fmt               # terraform fmt -recursive
make validate          # terraform init -backend=false + validate (no Azure auth)
make plan / apply      # init against backends/$(ENV).hcl + plan/apply (ENV default dev)
make digest            # digest upstream's v1 tag points at (TAG=... to override)
make deploy IMAGE_DIGEST=sha256:...   # az containerapp update to that digest
make restart           # restart the revision (re-resolves Key Vault secrets)
make url / logs / admin-password / dns / bind-domain
```

## Commit messages

Commits must follow [Conventional Commits](https://www.conventionalcommits.org/) — enforced by commitlint at commit-msg time. Examples: `feat: add tflint`, `fix: correct resource group name`, `chore: bump azurerm provider`.

## Pre-commit config

Hooks are in `.pre-commit-config.yaml` at the repo root. The `no-commit-to-branch` hook blocks direct commits to `main`. `terraform_fmt`/`terraform_validate`/`terraform_docs` come from `antonbabenko/pre-commit-terraform`. TFLint and Checkov are run by local hooks instead of that repo's `terraform_tflint`/`terraform_checkov`: `scripts/tflint-per-env.sh` and `scripts/checkov-per-env.sh` each glob `terraform/environments/*.tfvars` and run their tool once per environment with `--var-file`, so rules that depend on concrete variable values are evaluated against what each environment actually deploys. Both scripts prune hidden directories via `-name '.?*'`; don't switch that to `-name '.*'`, which also matches the find root `.` and silently prunes everything. `checkov-per-env.sh` deliberately does **not** pass `--download-external-modules` (≈15s per run for no benefit, since `Azure/naming/azurerm` has no resources); the "Failed to download module" warning it logs is harmless. Checkov's secret scan reads a literal `user:pass@` URL template as a hardcoded credential, which is why `DATABASE-URL`'s userinfo is assembled with `join` in `main.key-vault.tf`.

## CI

Workflows are prefixed `ci-` (pull-request checks) or `cd-` (post-merge delivery):

- **ci-pre-commit**: runs all linters on PRs to `main` via the reusable `jay-withers/workflows` pre-commit workflow (pinned by SHA).
- **ci-terraform**: calls the shared `terraform.yml` with `directories: '["terraform"]'` for credential-free init (`-backend=false`) and validate. There is no plan job. Require `terraform / Terraform` in branch protection.
- **cd-tag**: auto-creates a semver tag on every merge to `main` (default bump: patch). No image is built here.

## GitHub repo settings

Branch protection and other repo-level GitHub settings aren't templated as
files here. They're managed centrally by
[jay-withers/github-repos](https://github.com/jay-withers/github-repos)'s
Terraform root module, which is the single source of truth for every
jay-withers repo. Add this repo to that module's `var.repos` to pick them up.
