# azure-support-agent

A self-hosted copy of
[zmustafa/AzureSupportAgent](https://github.com/zmustafa/AzureSupportAgent), an
AI-driven Azure operations workbench, running on the shared Azure Container Apps
environment (`jay-withers/azure-container-apps`).

This repository holds no application code. Terraform creates the app on a
Microsoft placeholder image, and `make deploy` rolls out upstream's published
image by digest. The repo owns only the infrastructure around it: a container app,
a PostgreSQL Flexible Server, an Azure Files share for the app's state and
encryption key, a Key Vault and an identity. See
[terraform/README.md](terraform/README.md) for what is created, the first-apply
runbook and how secrets are handled.

## Getting started

Open the repository in the dev container (VS Code: **Reopen in Container**). It
ships with Terraform, TFLint, terraform-docs and Checkov, and runs `make install`
on creation to wire up the pre-commit hooks. You also need the Azure CLI, signed
in with `az login`, for anything that touches Azure.

## Commands

Run `make` to list every target. The main ones:

```bash
make validate          # terraform init (no backend) + validate — no Azure credentials
make lint              # every pre-commit hook against every file
make plan              # init against backends/dev.hcl + plan with environments/dev.tfvars
make apply             # ... + apply
make digest            # digest upstream's v1 tag currently points at
make deploy IMAGE_DIGEST=sha256:...   # roll an image onto the running app
make url               # the app's URL
make admin-password    # first-login admin password, from Key Vault
make logs              # tail the app's logs
```

## Cost

Roughly £13/month, nearly all of it the PostgreSQL server (B1ms, which has no
auto-pause tier). The app scales to zero and bills only while a replica is
running. While it's scaled down, the app's own scheduled automations and
monitors don't run.

## GitHub repo settings

Branch protection and other repo-level settings are managed centrally by
[jay-withers/github-repos](https://github.com/jay-withers/github-repos).
