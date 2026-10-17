locals {
  # Upstream's own deployment template uses the same login; nothing depends on
  # the name, but matching it keeps upstream's runbooks applicable.
  postgres_admin_login = "azsupadmin"
}
