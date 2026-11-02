# ============================================================
# Vault policy — read-only access for External Secrets Operator (ESO)
# Apply after `vault operator init/unseal`:
#   vault policy write eso-read vault/files/policies/eso-read.hcl
# Then bind to the ESO Kubernetes auth role (see config/policies/README note
# in the SecretStore: external-secrets/manifests/example-secretstore.yaml).
# ============================================================

# KV v2 read for the shared platform secrets mount.
path "secret/data/platform/*" {
  capabilities = ["read"]
}
path "secret/metadata/platform/*" {
  capabilities = ["read", "list"]
}

# Database dynamic credentials (short-lived) for app roles.
path "database/creds/app-*" {
  capabilities = ["read"]
}
