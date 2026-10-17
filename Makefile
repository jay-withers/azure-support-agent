TF_DIR := terraform
ENV ?= dev


.DEFAULT_GOAL := help

.PHONY: help install lint init fmt validate plan apply digest restart url logs admin-password dns bind-domain

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

install: ## Install pre-commit hooks (run once after cloning)
	pre-commit install
	pre-commit install --hook-type commit-msg

lint: ## Run all pre-commit hooks against every file
	pre-commit run --all-files

init: ## terraform init, without configuring the state backend
	terraform -chdir=$(TF_DIR) init -backend=false

fmt: ## terraform fmt -recursive
	terraform -chdir=$(TF_DIR) fmt -recursive

validate: init ## terraform init + validate (no Azure credentials needed)
	terraform -chdir=$(TF_DIR) validate

plan: ## terraform init + plan (set ENV, default dev)
	terraform -chdir=$(TF_DIR) init -reconfigure -backend-config=backends/$(ENV).hcl
	terraform -chdir=$(TF_DIR) plan -var-file=environments/$(ENV).tfvars

apply: ## terraform init + apply (set ENV, default dev)
	terraform -chdir=$(TF_DIR) init -reconfigure -backend-config=backends/$(ENV).hcl
	terraform -chdir=$(TF_DIR) apply -var-file=environments/$(ENV).tfvars

# The current digest behind upstream's moving `v1` tag (or TAG=latest). Compare
# it with image_digest in environments/$(ENV).tfvars; Renovate opens the bump PR
# on its own, but this is how to check or bump by hand. Upstream publishes no
# immutable tags, so a digest is the only way to name a specific build.
digest: ## Print the digest upstream's v1 tag points at, to compare with image_digest (TAG=v1)
	@curl -fsS "https://hub.docker.com/v2/repositories/zmustafa/azure-support-agent/tags/$(or $(TAG),v1)" \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])'

# After rotating secrets (bump secrets_version, apply): the Key Vault references
# are resolved when a replica starts, so the running one keeps the old
# DATABASE_URL — whose password no longer works — until restarted.
restart: ## Restart the active revision, re-resolving Key Vault secrets
	az containerapp revision restart \
		--name "$$(terraform -chdir=$(TF_DIR) output -raw container_app_name)" \
		--resource-group "$$(terraform -chdir=$(TF_DIR) output -raw resource_group_name)" \
		--revision "$$(az containerapp show \
			--name "$$(terraform -chdir=$(TF_DIR) output -raw container_app_name)" \
			--resource-group "$$(terraform -chdir=$(TF_DIR) output -raw resource_group_name)" \
			--query properties.latestRevisionName -o tsv)"

url: ## Print the application's URL
	@custom="$$(terraform -chdir=$(TF_DIR) output -raw custom_domain_url)"; \
		if [ -n "$$custom" ]; then echo "$$custom"; \
		else terraform -chdir=$(TF_DIR) output -raw app_url; echo; fi

logs: ## Tail the deployed app's logs
	az containerapp logs show \
		--name "$$(terraform -chdir=$(TF_DIR) output -raw container_app_name)" \
		--resource-group "$$(terraform -chdir=$(TF_DIR) output -raw resource_group_name)" \
		--container azsupagent --follow

# Only meaningful before the first sign-in: the app seeds the admin from this on
# first boot and forces a change on first login, after which this value is
# stale and the database holds the real one.
admin-password: ## Print the seeded first-login admin password
	@az keyvault secret show \
		--vault-name "$$(terraform -chdir=$(TF_DIR) output -raw key_vault_name)" \
		--name SEED-ADMIN-PASSWORD --query value -o tsv

# Both records must resolve *before* the apply that creates the certificate:
# Azure validates them during issuance, not after.
dns: ## Print the DNS records the custom domain needs
	@host="$$(terraform -chdir=$(TF_DIR) output -raw custom_domain_url | sed 's|^https://||')"; \
		if [ -z "$$host" ]; then echo "no custom_domain_name set; nothing to do"; exit 0; fi; \
		label="$${host%%.*}"; \
		echo "CNAME  $$label  ->  $$(terraform -chdir=$(TF_DIR) output -raw app_url | sed 's|^https://||')"; \
		echo "TXT    asuid.$$label  ->  $$(terraform -chdir=$(TF_DIR) output -raw custom_domain_verification_id)"

# The apply cannot finish the binding itself: ARM needs the managed
# certificate's id in the bind request and the provider has no field to put it
# in (hashicorp/terraform-provider-azurerm#27362, open). Run this after any
# apply that recreated the custom domain or the certificate. A plan afterwards
# reports no diff.
bind-domain: ## Finish binding the managed certificate (manual, see #27362)
	@host="$$(terraform -chdir=$(TF_DIR) output -raw custom_domain_url | sed 's|^https://||')"; \
		if [ -z "$$host" ]; then echo "no custom_domain_name set; nothing to do"; exit 0; fi; \
		app="$$(terraform -chdir=$(TF_DIR) output -raw container_app_name)"; \
		rg="$$(terraform -chdir=$(TF_DIR) output -raw resource_group_name)"; \
		env_id="$$(az containerapp show --name "$$app" --resource-group "$$rg" --query properties.environmentId -o tsv)"; \
		cert_id="$$(az containerapp env certificate list --ids "$$env_id" --managed-certificates-only \
			--query "[?properties.subjectName=='$$host'].id | [0]" -o tsv)"; \
		az containerapp hostname bind --name "$$app" --resource-group "$$rg" \
			--hostname "$$host" --certificate "$$cert_id" --environment "$$env_id"
