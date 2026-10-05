#!/bin/bash
#
# With the vault CLI's own VAULT_ADDR, VAULT_CACERT and an operator's token
# from vault login, not a token of its own: the lab is configured like any
# other change, by someone, under audit. Safe to run again, not once only:
# the cluster keeps its state, and this is how changes reach it.
#
# Not audit, and no root token: those are the Vault's own, set up before any
# application came to it. Not the AppRole secret IDs either: handing them to
# the agents is the deployment's job.

set -euo pipefail
cd "$(dirname "$0")"

: "${VAULT_ADDR:?}"
APPS=$(ls ../apps | sed 's/\.yaml$//')

step() { printf '\n==> %s\n' "$*"; }

# Enabled once, not disabled and enabled again: that would delete what the
# applications are using.
mount() {
  local path=$1
  shift
  vault read "sys/mounts/$path" >/dev/null 2>&1 || vault secrets enable -path="$path" "$@"
}

auth() {
  vault read "sys/auth/$1" >/dev/null 2>&1 || vault auth enable -path="$1" "$1"
}

# Written once, not on every run: rotate-root then replaces the seed
# password, and writing the seed again would break the connection.
database() {
  local name=$1 roles=$2
  vault read "database/config/$name" >/dev/null 2>&1 && return
  vault write "database/config/$name" \
    plugin_name=postgresql-database-plugin \
    connection_url="postgresql://{{username}}:{{password}}@$name:5432/postgres?sslmode=disable" \
    allowed_roles="$roles" \
    username="vault-admin" password="adminpass"
  vault write -force "database/rotate-root/$name" >/dev/null
}

# The redirect is the vault CLI's, not the UI's: the cluster runs no UI.
oidc_role() {
  local role=$1 policy=$2 ttl=$3 max_ttl=$4
  vault write "auth/oidc/role/$role" \
    bound_audiences="vault" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="email" oidc_scopes="email" \
    token_policies="$policy" token_ttl="$ttl" token_max_ttl="$max_ttl" >/dev/null
  echo "oidc role $role"
}

db_role() {
  local role=$1 db=$2 statements=$3 default_ttl=$4 max_ttl=$5
  vault write "database/roles/$role" db_name="$db" \
    creation_statements="$statements" default_ttl="$default_ttl" max_ttl="$max_ttl" >/dev/null
  echo "database role $role"
}

step "Auth methods"
auth approle
auth oidc

vault write auth/oidc/config \
  oidc_discovery_url="http://local-idp:5556/dex" \
  oidc_client_id="vault" \
  oidc_client_secret="vault-secret" \
  default_role="sre"

# Operator sessions bounded too, not Vault's 32-day default, which would sit
# oddly next to the 20m application tokens. incident apart from sre: sre
# looks, incident stops, and the audit log tells the two apart.
oidc_role sre       sre-admin          8h  24h
oidc_role developer developer-readonly 8h  24h
oidc_role incident  incident-response  30m 1h

step "Secrets engines"
mount secret -version=2 kv
mount secret-internal -version=2 kv
mount database database
mount pki pki
mount pki_int pki
vault secrets tune -max-lease-ttl=24h database
vault secrets tune -max-lease-ttl=87600h pki
vault secrets tune -max-lease-ttl=43800h pki_int

# Generated once, not on every run: a new CA would invalidate every
# certificate already issued.
step "PKI"
if ! vault read pki/issuer/default >/dev/null 2>&1; then
  vault write -field=certificate pki/root/generate/internal \
    common_name="lab.example.local Root CA" ttl=87600h >/dev/null
fi
if ! vault read pki_int/issuer/default >/dev/null 2>&1; then
  csr=$(vault write -field=csr pki_int/intermediate/generate/internal \
    common_name="lab.example.local Intermediate CA")
  cert=$(vault write -field=certificate pki/root/sign-intermediate \
    csr="$csr" format=pem_bundle ttl=43800h)
  vault write pki_int/intermediate/set-signed certificate="$cert" >/dev/null
fi
for mnt in pki pki_int; do
  vault write "$mnt/config/urls" \
    issuing_certificates="$VAULT_ADDR/v1/$mnt/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/$mnt/crl" >/dev/null
done
vault write pki_int/roles/admin-panel \
  allowed_domains="lab.example.local" allow_subdomains=true max_ttl="24h"

step "Databases"
database postgres-main "main-readonly,main-readwrite,main-short,main-long"
database postgres-payment "payment-short"
database postgres-analytics "analytics-readonly,analytics-readwrite,analytics-long"
database postgres-internal "internal-readwrite"

CREATE_RW="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
  GRANT CONNECT ON DATABASE postgres TO \"{{name}}\"; \
  GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"
CREATE_RO="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
  GRANT CONNECT ON DATABASE postgres TO \"{{name}}\"; \
  GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"

db_role main-readonly       postgres-main      "$CREATE_RO" 1h  24h
db_role main-readwrite      postgres-main      "$CREATE_RW" 1h  24h
db_role main-short          postgres-main      "$CREATE_RW" 15m 15m
db_role main-long           postgres-main      "$CREATE_RO" 8h  24h
db_role payment-short       postgres-payment   "$CREATE_RW" 10m 10m
db_role analytics-readonly  postgres-analytics "$CREATE_RO" 1h  24h
db_role analytics-readwrite postgres-analytics "$CREATE_RW" 1h  24h
db_role analytics-long      postgres-analytics "$CREATE_RO" 8h  24h
db_role internal-readwrite  postgres-internal  "$CREATE_RW" 1h  24h

step "Policies"
for f in policies/*.hcl; do
  vault policy write "$(basename "$f" .hcl)" "$f"
done

step "AppRole roles"
# Not the default policy alongside: it is not defined in this repository,
# so a reader seeing it in vault token lookup would have nothing to look up.
# Everything an application needs is in self-renewal.
for app in $APPS; do
  vault write "auth/approle/role/$app" \
    token_policies="self-renewal,$app" token_no_default_policy=true \
    token_ttl="20m" token_max_ttl="2h" \
    secret_id_ttl="720h" secret_id_num_uses=0 >/dev/null
  echo "approle role $app"
done

step "KV secrets"
vault kv put secret/config global-app-name="my-web-service" log-level="info" >/dev/null
vault kv put secret/api-server/config max-connections=100 >/dev/null
vault kv put secret/auth-service/jwt-key key="dummy-jwt-signing-key-do-not-use-in-production" >/dev/null
vault kv put secret/payment/stripe api-key="sk_test_dummy_stripe_key" >/dev/null
vault kv put secret/notification/sendgrid api-key="SG.dummy_sendgrid_key" >/dev/null
vault kv put secret/notification/webhook secret="dummy-webhook-secret" >/dev/null
vault kv put secret/webhook-receiver/secret secret="dummy-webhook-secret" >/dev/null
vault kv put secret-internal/internal-cms/config admin-password="dummy-internal-password" >/dev/null

echo
echo "==> Configured. Next, the deployment hands each agent its wrapped role ID and secret ID."
