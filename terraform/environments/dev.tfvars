environment = "dev"

custom_domain_name = "support.jaywithers.uk"

# The app version. Renovate bumps this when upstream's v1 tag moves; `make apply`
# rolls it out.
# renovate: datasource=docker depName=zmustafa/azure-support-agent tag=v1
image_digest = "sha256:8f333b4fbaa34c3738dd59ad3dfdc9b8058733ae5c13a92a8a1080171fa14a07"
