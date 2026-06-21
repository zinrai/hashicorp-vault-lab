# webhook-receiver.hcl

path "secret/data/webhook-receiver/*" {
  capabilities = ["read"]
}

path "database/creds/main-readwrite" {
  capabilities = ["read"]
}
