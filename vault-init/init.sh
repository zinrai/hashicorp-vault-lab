#!/bin/sh
# vault-init: one-shot bootstrap for the lab Vault.
# Operator-facing notes:
# - Assumes VAULT_ADDR / VAULT_CACERT / VAULT_TLS_SERVER_NAME / VAULT_TOKEN=root
#   are set by docker-compose.
# - Idempotent on first run only; intended to run once against a fresh dev Vault.
# - Last step revokes the root token. After this script, operators must
#   authenticate via OIDC (sre or developer role).

set -eu

step() {
  echo
  echo "==> $*"
}

step "Wait for Vault TLS listener"
until vault status > /dev/null 2>&1; do
  sleep 1
done

step "Enable audit device (file)"
vault audit enable file file_path=/vault/logs/audit.log

step "Enable auth methods"
vault auth enable approle
vault auth enable -path=oidc oidc

step "Configure OIDC backend against local-idp"
vault write auth/oidc/config \
  oidc_discovery_url="http://local-idp:8080" \
  oidc_client_id="vault" \
  oidc_client_secret="vault-secret" \
  default_role="sre"

step "Enable secrets engines"
# Vault dev mode pre-mounts secret/ as KV v2; remount cleanly so we own its config.
vault secrets disable secret > /dev/null 2>&1 || true
vault secrets enable -path=secret -version=2 kv
vault secrets enable -path=secret-internal -version=2 kv
vault secrets enable database
vault secrets enable pki
vault secrets enable -path=pki_int pki

step "Tune mount lease ceilings"
vault secrets tune -max-lease-ttl=24h database
vault secrets tune -max-lease-ttl=87600h pki
vault secrets tune -max-lease-ttl=43800h pki_int

step "Generate PKI root CA"
vault write -field=certificate pki/root/generate/internal \
  common_name="lab.example.local Root CA" \
  ttl=87600h > /dev/null

vault write pki/config/urls \
  issuing_certificates="https://vault:8200/v1/pki/ca" \
  crl_distribution_points="https://vault:8200/v1/pki/crl" > /dev/null

step "Generate PKI intermediate CSR and sign with root"
vault write -field=csr pki_int/intermediate/generate/internal \
  common_name="lab.example.local Intermediate CA" \
  > /tmp/pki_int.csr

vault write -field=certificate pki/root/sign-intermediate \
  csr=@/tmp/pki_int.csr \
  format=pem_bundle ttl=43800h \
  > /tmp/pki_int.pem

vault write pki_int/intermediate/set-signed \
  certificate=@/tmp/pki_int.pem > /dev/null

vault write pki_int/config/urls \
  issuing_certificates="https://vault:8200/v1/pki_int/ca" \
  crl_distribution_points="https://vault:8200/v1/pki_int/crl" > /dev/null

step "Define PKI issuing role on intermediate"
vault write pki_int/roles/admin-panel \
  allowed_domains="lab.example.local" \
  allow_subdomains=true \
  max_ttl="24h"

step "Configure database connections"
vault write database/config/postgres-main \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres-main:5432/postgres?sslmode=disable" \
  allowed_roles="main-readonly,main-readwrite,main-short,main-long" \
  username="vault-admin" password="adminpass"

vault write database/config/postgres-payment \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres-payment:5432/postgres?sslmode=disable" \
  allowed_roles="payment-short" \
  username="vault-admin" password="adminpass"

vault write database/config/postgres-analytics \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres-analytics:5432/postgres?sslmode=disable" \
  allowed_roles="analytics-readonly,analytics-readwrite,analytics-long" \
  username="vault-admin" password="adminpass"

vault write database/config/postgres-internal \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres-internal:5432/postgres?sslmode=disable" \
  allowed_roles="internal-readwrite" \
  username="vault-admin" password="adminpass"

step "Rotate database root credentials"
# After this point the vault-admin/adminpass pair posted in this script is
# no longer valid against any Postgres; only Vault holds the new password.
vault write -force database/rotate-root/postgres-main > /dev/null
vault write -force database/rotate-root/postgres-payment > /dev/null
vault write -force database/rotate-root/postgres-analytics > /dev/null
vault write -force database/rotate-root/postgres-internal > /dev/null

step "Create database roles"
CREATE_STMT_RW="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
  GRANT CONNECT ON DATABASE postgres TO \"{{name}}\"; \
  GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"

CREATE_STMT_RO="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
  GRANT CONNECT ON DATABASE postgres TO \"{{name}}\"; \
  GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"

vault write database/roles/main-readonly \
  db_name=postgres-main creation_statements="$CREATE_STMT_RO" \
  default_ttl="1h" max_ttl="24h"

vault write database/roles/main-readwrite \
  db_name=postgres-main creation_statements="$CREATE_STMT_RW" \
  default_ttl="1h" max_ttl="24h"

vault write database/roles/main-short \
  db_name=postgres-main creation_statements="$CREATE_STMT_RW" \
  default_ttl="15m" max_ttl="15m"

vault write database/roles/main-long \
  db_name=postgres-main creation_statements="$CREATE_STMT_RO" \
  default_ttl="8h" max_ttl="24h"

vault write database/roles/payment-short \
  db_name=postgres-payment creation_statements="$CREATE_STMT_RW" \
  default_ttl="10m" max_ttl="10m"

vault write database/roles/analytics-readonly \
  db_name=postgres-analytics creation_statements="$CREATE_STMT_RO" \
  default_ttl="1h" max_ttl="24h"

vault write database/roles/analytics-readwrite \
  db_name=postgres-analytics creation_statements="$CREATE_STMT_RW" \
  default_ttl="1h" max_ttl="24h"

vault write database/roles/analytics-long \
  db_name=postgres-analytics creation_statements="$CREATE_STMT_RO" \
  default_ttl="8h" max_ttl="24h"

vault write database/roles/internal-readwrite \
  db_name=postgres-internal creation_statements="$CREATE_STMT_RW" \
  default_ttl="1h" max_ttl="24h"

step "Write policies"
for f in /init/policies/*.hcl; do
  name=$(basename "$f" .hcl)
  vault policy write "$name" "$f"
done

step "Define OIDC roles"
vault write auth/oidc/role/sre \
  bound_audiences="vault" \
  allowed_redirect_uris="http://localhost:8200/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  user_claim="sub" \
  token_policies="sre-admin"

vault write auth/oidc/role/developer \
  bound_audiences="vault" \
  allowed_redirect_uris="http://localhost:8200/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  user_claim="sub" \
  token_policies="developer-readonly"

step "Configure AppRole roles for 12 applications"
APPS="web-frontend api-server admin-panel auth-service payment notification search batch-runner etl analytics webhook-receiver internal-cms"

for app in $APPS; do
  vault write "auth/approle/role/$app" \
    token_policies="base,$app" \
    token_ttl="20m" \
    token_max_ttl="2h" \
    secret_id_ttl="720h" \
    secret_id_num_uses=0
done

step "Initialize KV secrets"
vault kv put secret/config \
  global-app-name="my-web-service" \
  log-level="info"

vault kv put secret/api-server/config \
  max-connections=100

vault kv put secret/auth-service/jwt-key \
  key="dummy-jwt-signing-key-do-not-use-in-production"

vault kv put secret/payment/stripe \
  api-key="sk_test_dummy_stripe_key"

vault kv put secret/notification/sendgrid \
  api-key="SG.dummy_sendgrid_key"

vault kv put secret/notification/webhook \
  secret="dummy-webhook-secret"

vault kv put secret/webhook-receiver/secret \
  secret="dummy-webhook-secret"

vault kv put secret-internal/internal-cms/config \
  admin-password="dummy-internal-password"

step "Distribute response-wrapped role-id and secret-id"
# Each agent receives single-use wrap tokens (TTL 600s). The agent's
# entrypoint unwraps once on first start. Container restart re-runs the
# entrypoint, finds the wrap already consumed, and fails -- this is the
# intended real-env behaviour: re-provisioning requires re-running vault-init
# (the orchestrator's job in production).
mkdir -p /vault-bootstrap
chmod 0755 /vault-bootstrap
for app in $APPS; do
  mkdir -p "/vault-bootstrap/$app"
  vault read -field=wrapping_token -wrap-ttl=600 \
    "auth/approle/role/$app/role-id" > "/vault-bootstrap/$app/role-id.wrap"
  vault write -force -field=wrapping_token -wrap-ttl=600 \
    "auth/approle/role/$app/secret-id" > "/vault-bootstrap/$app/secret-id.wrap"
  chmod 0444 "/vault-bootstrap/$app/role-id.wrap" "/vault-bootstrap/$app/secret-id.wrap"
done

step "Revoke initial root token"
# Real-env analog: 'vault operator generate-root' is then used only when truly
# needed, gated by unseal-key quorum. In this lab (dev mode) Vault restart
# regenerates root; the revocation here demonstrates the operational shape.
vault token revoke -self

echo
echo "==> vault-init complete. Operators authenticate via OIDC:"
echo "    vault login -method=oidc role=sre        # user 'sre' / 'srepass'"
echo "    vault login -method=oidc role=developer  # user 'developer' / 'devpass'"
