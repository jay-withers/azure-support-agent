variable "environment" {
  description = "Deployment environment. Drives resource naming, and selects which shared platform environment this project deploys onto."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "environment must be one of: dev, stg, prd."
  }
}

variable "image_digest" {
  description = "Digest of upstream's `docker.io/zmustafa/azure-support-agent` image to run. Upstream publishes only moving tags (`latest`, `v1`), so the version is pinned by digest. Renovate opens a PR bumping this when upstream's `v1` moves; merging it and running `make apply` is the deploy."
  type        = string

  validation {
    # A moving tag deploys nothing: Container Apps creates a revision only when
    # the template changes, so re-pointing `v1` upstream would leave a tag
    # reference identical and the running app unchanged.
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must be a full sha256:<64 hex> digest, not a tag."
  }
}
