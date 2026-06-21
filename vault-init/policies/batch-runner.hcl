# batch-runner.hcl

path "database/creds/main-readwrite" {
  capabilities = ["read"]
}

path "database/creds/analytics-readwrite" {
  capabilities = ["read"]
}
