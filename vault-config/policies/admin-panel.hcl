# The only consumer of pki_int, not one of several: a second would make the
# intermediate a shared credential template, and revoking it would reach
# both, which is the granularity trap that database/creds/main-readwrite
# demonstrates on purpose.

path "database/creds/main-readonly" {
  capabilities = ["read"]
}

path "pki_int/issue/admin-panel" {
  capabilities = ["update"]
}
