#!/bin/bash
# check-status.sh
# Snapshot the lab state. Requires a prior OIDC login (no root fallback).

set -u

export VAULT_ADDR="${VAULT_ADDR:-https://localhost:8200}"
export VAULT_CACERT="${VAULT_CACERT:-}"
export VAULT_TLS_SERVER_NAME="${VAULT_TLS_SERVER_NAME:-localhost}"

if [ -z "${VAULT_CACERT}" ]; then
  echo "VAULT_CACERT is not set. Extract the lab CA with:"
  echo "    docker compose cp vault:/vault/tls/vault-ca.pem ./ca.pem"
  echo "    export VAULT_CACERT=\$PWD/ca.pem"
  exit 1
fi

if ! vault token lookup > /dev/null 2>&1; then
  cat <<'EOF' >&2
Not authenticated. The root token has been revoked by vault-init; operators
authenticate via OIDC. Run one of:

    vault login -method=oidc role=sre        # user 'sre' / 'srepass'
    vault login -method=oidc role=developer  # user 'developer' / 'devpass'

OIDC opens a browser callback against http://local-idp:8080.
EOF
  exit 1
fi

section() {
  echo
  echo "## $1"
}

section "Container status"
docker compose ps

section "Vault status"
vault status

section "Auth methods"
vault auth list

section "Secrets engines"
vault secrets list

section "Policies"
vault policy list

section "OIDC roles"
vault list auth/oidc/role 2>/dev/null || echo "  (insufficient policy)"

section "AppRole roles"
vault list auth/approle/role 2>/dev/null || echo "  (insufficient policy)"

section "Database connections"
vault list database/config 2>/dev/null || echo "  (insufficient policy)"

section "Database roles"
vault list database/roles 2>/dev/null || echo "  (insufficient policy)"

section "PKI mounts"
vault read pki/cert/ca 2>/dev/null | sed -n '1,5p' || true
vault read pki_int/cert/ca 2>/dev/null | sed -n '1,5p' || true

section "Active database leases per role"
for role in main-readonly main-readwrite main-short main-long payment-short \
            analytics-readonly analytics-readwrite analytics-long internal-readwrite; do
  out=$(vault list -format=json "sys/leases/lookup/database/creds/$role" 2>/dev/null) || out="[]"
  count=$(printf '%s' "$out" | grep -o '"[^"]*"' | grep -vc keys)
  echo "  database/creds/$role: ${count} lease(s)"
done

section "Last 5 audit log lines (vault container)"
docker compose exec -T vault tail -n 5 /vault/logs/audit.log 2>/dev/null \
  | sed 's/^/  /' || echo "  (audit file not readable from host shell)"

section "Application logs (last 3 lines each)"
for app in web-frontend api-server admin-panel auth-service payment notification \
           search batch-runner etl analytics webhook-receiver internal-cms; do
  echo "--- $app ---"
  docker compose logs --tail=3 "app-$app" 2>/dev/null | sed 's/^/  /' || echo "  (no logs)"
done
