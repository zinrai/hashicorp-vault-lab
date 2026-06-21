# admin-panel.hcl

path "database/creds/main-readonly" {
  capabilities = ["read"]
}

path "pki_int/issue/admin-panel" {
  capabilities = ["update"]
}
