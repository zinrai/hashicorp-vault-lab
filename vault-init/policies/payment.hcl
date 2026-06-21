# payment.hcl

path "secret/data/payment/*" {
  capabilities = ["read"]
}

path "database/creds/payment-short" {
  capabilities = ["read"]
}
