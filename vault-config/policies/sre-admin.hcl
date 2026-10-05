path "sys/mounts" {
  capabilities = ["read", "list"]
}

path "sys/auth" {
  capabilities = ["read", "list"]
}

path "sys/policies/acl" {
  capabilities = ["list"]
}

path "sys/policies/acl/*" {
  capabilities = ["read"]
}

path "sys/audit" {
  # sys/audit is root-protected, so sudo is required in addition to read.
  # Without it `vault audit list` returns 403.
  capabilities = ["read", "list", "sudo"]
}

path "sys/leases/lookup" {
  capabilities = ["update"]
}

path "sys/leases/lookup/+/+/*" {
  # LIST on sys/leases/lookup is root-protected, so sudo is required in
  # addition to list. Without it every lease enumeration returns 403.
  capabilities = ["list", "sudo"]
}

path "auth/approle/role" {
  capabilities = ["list"]
}

path "auth/approle/role/*" {
  capabilities = ["read"]
}

path "auth/oidc/role" {
  capabilities = ["list"]
}

path "auth/oidc/role/*" {
  capabilities = ["read"]
}

path "database/config" {
  capabilities = ["list"]
}

path "database/config/*" {
  capabilities = ["read"]
}

path "database/roles" {
  capabilities = ["list"]
}

path "database/roles/*" {
  capabilities = ["read"]
}

# pki/+ stops at one segment, so it does not reach pki_int/roles/<name> or
# pki/cert/<serial>. Both are read during normal inspection.
path "pki/+" {
  capabilities = ["read", "list"]
}

path "pki/+/*" {
  capabilities = ["read", "list"]
}

path "pki_int/+" {
  capabilities = ["read", "list"]
}

path "pki_int/+/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata" {
  capabilities = ["list"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

path "secret-internal/metadata" {
  capabilities = ["list"]
}

path "secret-internal/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
