# Named after what it grants, not after its place in a stack: it is attached
# to every application token, so a careless addition widens every token at
# once, and anything that is not about renewing your own credentials should
# look wrong here. Vault has no policy inheritance, so nothing added here can
# be narrowed later by a more specific policy.
#
# Instead of Vault's built-in "default", not alongside it: every grant below
# is also in "default", but the AppRole roles set token_no_default_policy, so
# vault token lookup on an application token lists only policies this
# repository defines.

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "sys/leases/renew" {
  capabilities = ["update"]
}

path "sys/leases/lookup" {
  capabilities = ["update"]
}
