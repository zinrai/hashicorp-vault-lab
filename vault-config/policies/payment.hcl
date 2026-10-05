# payment-short, not the 1h main-readwrite the other write-path applications
# use. Payment data is the one thing here worth a 10m exposure window, and it
# is also the only application small enough that a rotation every ~7m costs
# nothing. Both halves have to be true before a short TTL is worth taking.

path "secret/data/payment/*" {
  capabilities = ["read"]
}

path "database/creds/payment-short" {
  capabilities = ["read"]
}
