locals {
  # By digest, because upstream publishes only moving tags — see
  # var.image_digest. This repository is the source of truth for the running
  # version: nothing outside Terraform changes it.
  image = "docker.io/zmustafa/azure-support-agent@${var.image_digest}"

  # uvicorn binds this, the Dockerfile EXPOSEs it, and every probe checks it.
  target_port = 8000

  # Upstream's own sizing, and not one to shave like finances' 0.25 vCPU: one
  # request can spawn the az CLI and two MCP server subprocesses (Node and
  # Python) alongside uvicorn. Memory must be 2 GiB per vCPU.
  container_cpu    = 1
  container_memory = "2Gi"

  # The URL the app builds OIDC/SAML redirect URIs from and checks every POST's
  # Origin against (CSRF), so it has to be the address the browser actually
  # uses. The fallback is assembled from the app's name and the environment's
  # default domain — exactly what the ingress FQDN will be — rather than read
  # from the app itself, which would be a self-reference.
  #
  # Consequence: with a custom domain set, POSTs from the azurecontainerapps.io
  # URL are refused. Use the custom domain.
  public_base_url = (
    var.custom_domain_name != ""
    ? "https://${var.custom_domain_name}"
    : "https://${module.naming.container_app.name}.${data.azurerm_container_app_environment.platform.default_domain}"
  )

  # Everything the app needs that is not a secret, matching upstream's
  # deploy/main.bicep. The two secrets are Key Vault references on the app
  # itself, not entries here.
  common_env = {
    SEED_ADMIN_USERNAME = var.admin_username
    COOKIE_SECURE       = "true"
    # ACA ingress appends the client address it saw to X-Forwarded-For; the
    # app reads it right-to-left, so this restores real client IPs for the
    # login throttle, the audit log and the in-app allowlist.
    TRUST_FORWARDED_HEADERS = "true"
    PUBLIC_BASE_URL         = local.public_base_url
    FRONTEND_ORIGIN         = local.public_base_url
    # Paths inside upstream's image.
    ENTRA_MCP_COMMAND                     = "/opt/eidmcp/bin/python"
    ENTRA_MCP_ARGS                        = "/app/third_party/entraid-mcp-server/run_server.py"
    AZURE_EXTENSION_DIR                   = "/opt/az-extensions"
    BROWSER_PROFILE_DIR                   = "/tmp/browser-profiles"
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = "1"
  }
}
