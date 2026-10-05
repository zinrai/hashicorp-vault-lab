# main-long (8h), not main-readonly (1h). A batch run can outlive a 1h lease,
# and a credential that expires mid-run fails the job rather than degrading it.
# The exposure window is traded for the run completing. analytics-readwrite
# stays at 1h because the writes are incremental and restartable.

path "database/creds/main-long" {
  capabilities = ["read"]
}

path "database/creds/analytics-readwrite" {
  capabilities = ["read"]
}
