# auth-service.hcl

path "secret/data/auth-service/*" {
  capabilities = ["read"]
}

path "database/creds/main-readwrite" {
  capabilities = ["read"]
}
