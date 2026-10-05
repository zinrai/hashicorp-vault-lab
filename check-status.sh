#!/bin/bash
# With your token, not a privileged one: the output shows what your
# policies let you see.

set -u

: "${VAULT_ADDR:?set as for the vault CLI}"
: "${VAULT_CACERT:?set as for the vault CLI}"

if ! vault token lookup > /dev/null 2>&1; then
  echo "Not logged in. Run: vault login -method=oidc role=sre" >&2
  exit 1
fi

section() {
  echo
  echo "## $1"
}

section "Container status"
docker compose -f "$(dirname "$0")/compose.yaml" --profile apps ps

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

# Which roles hold leases, not how many each: a snapshot to read, and the
# count per role is docs/EXPLORING.md 4's command.
section "Database roles holding leases"
vault list sys/leases/lookup/database/creds/ 2>/dev/null || echo "  (none, or insufficient policy)"


section "Application logs (last 3 lines each)"
for app in $(ls "$(dirname "$0")/apps" | sed 's/\.yaml$//'); do
  echo "--- $app ---"
  docker logs --tail=3 "app-$app" 2>&1 | sed 's/^/  /' || echo "  (no logs)"
done
