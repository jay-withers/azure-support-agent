terraform {
  # 1.11 is the floor for write-only arguments (`administrator_password_wo`,
  # `value_wo`) and ephemeral resources, which keep the database and admin
  # passwords out of state entirely — see main.key-vault.tf.
  required_version = ">= 1.11"

  # Partial: per-environment values live in backends/<env>.hcl.
  #   terraform init -backend-config=backends/dev.hcl
  # Anything not touching state must init with -backend=false, or this prompts.
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    # Both module.naming's transitive dependency and the source of the ephemeral
    # passwords; 3.7 is the first release with `ephemeral "random_password"`.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      # False on purpose: with this true, `terraform destroy` fails whenever
      # Azure has parked anything in the group that Terraform doesn't manage.
      prevent_deletion_if_contains_resources = false
    }

    key_vault {
      # Let destroy actually remove the vault rather than leaving a soft-deleted
      # one holding the globally unique name.
      purge_soft_delete_on_destroy = true
    }
  }

  use_oidc = true
}
