# ============================================================
# Vault policy — platform admin (break-glass, humans via OIDC)
# Apply: vault policy write platform-admin vault/files/policies/admin.hcl
# Bind to an OIDC group, NOT to a long-lived token. Audit every use.
# ============================================================

# Manage secrets engines' data + config.
path "secret/*"    { capabilities = ["create", "read", "update", "delete", "list"] }
path "database/*"  { capabilities = ["create", "read", "update", "delete", "list"] }
path "pki/*"       { capabilities = ["create", "read", "update", "delete", "list"] }
path "transit/*"   { capabilities = ["create", "read", "update", "delete", "list"] }

# Manage auth methods + policies.
path "sys/auth/*"     { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/policies/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "auth/*"         { capabilities = ["create", "read", "update", "delete", "list"] }

# Operational visibility.
path "sys/health"       { capabilities = ["read"] }
path "sys/mounts"       { capabilities = ["read", "list"] }
path "sys/leases/*"     { capabilities = ["create", "read", "update", "delete", "list"] }
