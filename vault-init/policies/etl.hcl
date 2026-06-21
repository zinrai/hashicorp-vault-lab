# etl.hcl

path "database/creds/main-long" {
  capabilities = ["read"]
}

path "database/creds/analytics-readwrite" {
  capabilities = ["read"]
}
