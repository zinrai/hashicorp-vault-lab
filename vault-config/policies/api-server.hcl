
path "secret/data/api-server/*" {
  capabilities = ["read"]
}

path "database/creds/main-readwrite" {
  capabilities = ["read"]
}
