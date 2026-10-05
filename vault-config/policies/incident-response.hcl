# Not folded into sre-admin: an operator does not need to be able to stop
# production in order to look at it. Keeping the two apart means the session
# used for routine inspection cannot revoke anything by accident, and the
# audit log distinguishes looking from acting.
#
# No sys/policies/acl/* or auth/*/role/* writes: stopping what is currently
# running and changing what will be issued next are different powers. A
# token holding the latter can rewrite a role's policies inside its own TTL,
# which defeats bounding damage by time. In this lab that power belongs to
# the Vault's operators, who configure it under their own names.

# By accessor, not by token: the accessor carries no authority of its own,
# which is why it is what appears in the audit log.
path "auth/token/lookup-accessor" {
  capabilities = ["update"]
}

path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}

# sudo, not list alone: listing accessors is root-protected.
path "auth/token/accessors" {
  capabilities = ["list", "sudo"]
}

path "sys/leases/revoke" {
  capabilities = ["update"]
}

# sudo, not update alone: revoking by prefix is root-protected.
path "sys/leases/revoke-prefix/*" {
  capabilities = ["update", "sudo"]
}

path "sys/leases/lookup" {
  capabilities = ["update"]
}

path "sys/leases/lookup/+/+/*" {
  # LIST on sys/leases/lookup is root-protected, so sudo is required in
  # addition to list. Without it every lease enumeration returns 403.
  capabilities = ["list", "sudo"]
}

# Reads too, not revocation alone: enough to identify a target without
# opening a second session.
path "auth/approle/role" {
  capabilities = ["list"]
}

path "auth/approle/role/*" {
  capabilities = ["read"]
}

path "database/roles" {
  capabilities = ["list"]
}

path "database/roles/*" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
